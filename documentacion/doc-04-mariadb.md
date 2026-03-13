# DOC-04 — MariaDB Alta Disponibilidad (StatefulSet + Replicación)

## ¿Qué hace este archivo?

Despliega MariaDB en modo Alta Disponibilidad con replicación binlog asíncrona. Define cuatro recursos: un `ConfigMap` con la configuración y el script de arranque, un `Service` headless para DNS estable entre Pods, un `Service` ClusterIP fijo al Pod primary, y el `StatefulSet` con dos réplicas (`mariadb-0` como primary y `mariadb-1` como replica de solo lectura). La configuración real de la replicación (CHANGE MASTER, START SLAVE) se delega al Job del archivo `04b-mariadb-replication-job.yaml`.

---

## Conceptos de Kubernetes utilizados

### StatefulSet
A diferencia de un `Deployment`, un `StatefulSet` garantiza tres propiedades clave:
- **Identidad de red estable**: los Pods se llaman `mariadb-0`, `mariadb-1`… y mantienen ese nombre incluso al ser reprogramados.
- **Orden de arranque/parada**: los Pods arrancan en orden ascendente (0 antes que 1) y se paran en orden descendente.
- **Almacenamiento persistente individual**: cada Pod obtiene su propio PVC via `volumeClaimTemplates`, que persiste entre reinicios del Pod.

Estas propiedades son esenciales para una base de datos con replicación: el primary siempre es el Pod con ordinal 0, lo que permite que el script de arranque tome decisiones basadas en el hostname.

### Service Headless (`clusterIP: None`)
El Service headless no balancea tráfico. En su lugar, el DNS del clúster resuelve el nombre del Service a los registros A individuales de cada Pod. Esto permite acceder a `mariadb-0` directamente via `mariadb-0.mariadb-headless.databases.svc.cluster.local`, imprescindible para configurar la replicación (el replica necesita conocer la dirección exacta del primary).

### Service ClusterIP con selector de Pod específico
El selector `statefulset.kubernetes.io/pod-name: mariadb-0` hace que este Service apunte siempre y exclusivamente al Pod primary. WordPress lo usa como `WORDPRESS_DB_HOST`, garantizando que todas las escrituras vayan al nodo correcto.

### Init Containers
Los dos init containers se ejecutan en secuencia antes del contenedor principal:
1. `fix-perms`: ejecuta `chown` como root para corregir la propiedad del directorio de datos, necesario porque los volúmenes montados pueden pertenecer a root.
2. `init-scripts`: copia el script de arranque desde el ConfigMap a un `emptyDir` compartido, añadiéndole permisos de ejecución. Los ficheros de ConfigMap montados como volumen son de solo lectura y no son directamente ejecutables por el entrypoint.

### volumeClaimTemplates
Genera automáticamente los PVCs `mariadb-storage-mariadb-0` y `mariadb-storage-mariadb-1` (5 GiB cada uno). Estos PVCs no se borran al eliminar el StatefulSet, lo que protege los datos ante reinicios accidentales. Para borrar también los datos hay que eliminar los PVCs manualmente.

---

## Decisiones de diseño

| Decisión | Justificación |
|---|---|
| Rol determinado por ordinal del hostname | Solución simple y sin dependencias externas. El StatefulSet garantiza que mariadb-0 siempre es el primary, lo que hace el script determinista. |
| Script en ConfigMap, no en imagen | Permite modificar el comportamiento de arranque sin reconstruir la imagen Docker. Favorece la separación entre configuración y código. |
| Sin sidecars ni agentes | Diseño minimalista para Minikube. Añadir ProxySQL o un sidecar de exportación de métricas aumentaría la complejidad y el consumo de recursos. |
| Anti-afinidad `preferred` (soft) | Permite que ambos Pods arranquen en Minikube (un solo nodo) sin quedarse en `Pending`. En producción con varios nodos, el scheduler intentará separarlos. |
| Replicación delegada al Job `04b` | Separar la configuración de la replicación del arranque del StatefulSet permite reintentar el proceso sin reiniciar los Pods de base de datos. |
| `read-only=1` en la replica | Impide escrituras accidentales directas a la replica, que romperían la consistencia de la replicación. |
| `sync-binlog=1` en el primary | Garantiza que ningún evento del binlog se pierda ante un crash del primary, a costa de algo de rendimiento de escritura. |

---

## Dependencias con otros archivos

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | Debe crear el namespace `databases` antes de aplicar este archivo. |
| `01-secrets.yaml` | Debe existir el Secret `mariadb-secret` con las claves `mariadb-root-password` y `mariadb-user-password`. Sin él, los Pods no arrancan. |
| `04b-mariadb-replication-job.yaml` | Configura la replicación activa (CHANGE MASTER / START SLAVE) una vez que ambos Pods están listos. Debe ejecutarse **después** de que este StatefulSet esté en Running. |
| `06-wordpress.yaml` | WordPress usa el Service `mariadb` (ClusterIP al primary) como host de base de datos. Depende de que este archivo esté desplegado y el primary listo. |
| `07-network-policy.yaml` | Las NetworkPolicies del proyecto controlan qué Pods pueden conectarse al puerto 3306. Verificar que WordPress tenga acceso permitido. |
| `10-prometheus.yaml` | Si se despliega un exporter de métricas para MariaDB, necesitará acceso al Service headless o al ClusterIP del primary. |

---

## Advertencias y puntos críticos

### ⚠️ Sin failover automático
Este diseño **no implementa failover automático**. Si `mariadb-0` cae, WordPress pierde la conexión a la base de datos hasta que el Pod se recupere (Kubernetes lo reiniciará automáticamente, pero la base de datos tardará en estar lista). La replica (`mariadb-1`) no se promueve a primary de forma automática. Para failover automático sería necesario añadir Orchestrator, ProxySQL con health checks, o migrar a Galera Cluster.

### ⚠️ `imagePullPolicy: Never` en init-scripts
El init container `init-scripts` usa `busybox` con `imagePullPolicy: Never`. Esto asume que la imagen `busybox` ya está disponible en el registro local de Minikube. Si no está precargada, el Pod quedará en `ErrImageNeverPull`. Para producción, cambiar a `IfNotPresent`.

### ⚠️ La password aparece en el argumento del probe
El comando de readiness/liveness usa `-p"${MYSQL_ROOT_PASSWORD}"`, lo que puede exponer la contraseña en los logs del sistema si el proceso de probe falla y Kubernetes registra el comando completo. Una alternativa más segura es usar un fichero `.my.cnf` con las credenciales o un wrapper script.

### ⚠️ Replicación asíncrona: riesgo de pérdida de datos
Con `sync-binlog=1` en el primary pero sin configuración de semisync, existe una ventana de pérdida de datos si el primary cae antes de que los eventos sean replicados. Para entornos críticos, activar `rpl_semi_sync_master_enabled`.

### ℹ️ Los PVCs no se eliminan con el StatefulSet
Al ejecutar `kubectl delete statefulset mariadb`, los PVCs (`mariadb-storage-mariadb-0/1`) permanecen. Esto es un comportamiento intencional de Kubernetes para proteger los datos. Para una limpieza completa, borrar los PVCs manualmente después del StatefulSet.

### ℹ️ Orden de aplicación crítico
Aplicar en este orden: `00-namespace.yaml` → `01-secrets.yaml` → `02-configmap.yaml` → `04-mariadb.yaml` → esperar a que ambos Pods estén en `Running/Ready` → `04b-mariadb-replication-job.yaml`.
