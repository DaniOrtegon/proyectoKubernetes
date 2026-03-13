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

Estas propiedades son esenciales para una base de datos con replicación: el primary siempre es el Pod con ordinal 0, lo que permite que el script de arranque tome decisiones basadas en el hostname de forma determinista.

### Service Headless (`clusterIP: None`)
El Service headless no balancea tráfico. En su lugar, el DNS del clúster resuelve el nombre del Service a los registros A individuales de cada Pod. Esto permite acceder a `mariadb-0` directamente via `mariadb-0.mariadb-headless.databases.svc.cluster.local`, imprescindible para configurar la replicación.

### Service ClusterIP con selector de Pod específico
El selector `statefulset.kubernetes.io/pod-name: mariadb-0` hace que este Service apunte siempre y exclusivamente al Pod primary. WordPress lo usa como `WORDPRESS_DB_HOST`, garantizando que todas las escrituras vayan al nodo correcto.

### Init Containers
Los dos init containers se ejecutan en secuencia antes del contenedor principal:
1. `fix-perms`: ejecuta `chown` como root para corregir la propiedad del directorio de datos, necesario porque los volúmenes montados pueden pertenecer a root.
2. `init-scripts`: copia el script de arranque desde el ConfigMap a un `emptyDir` compartido añadiéndole permisos de ejecución. Los ficheros de ConfigMap montados como volumen son de solo lectura y no son directamente ejecutables.

### volumeClaimTemplates
Genera automáticamente los PVCs `mariadb-storage-mariadb-0` y `mariadb-storage-mariadb-1` (5 GiB cada uno). Estos PVCs no se borran al eliminar el StatefulSet, protegiendo los datos ante reinicios accidentales.

---

## Decisiones de diseño

| Decisión | Justificación |
|---|---|
| Rol determinado por ordinal del hostname | Solución simple y sin dependencias externas. El StatefulSet garantiza que `mariadb-0` siempre es el primary, haciendo el script completamente determinista. |
| Script en ConfigMap, no en imagen | Permite modificar el comportamiento de arranque sin reconstruir la imagen Docker, favoreciendo la separación entre configuración y código. |
| Sin sidecars ni agentes | Diseño minimalista alineado con el entorno Minikube. Mantiene el consumo de recursos bajo y la complejidad operativa reducida. |
| Anti-afinidad `preferred` (soft) | Permite que ambos Pods arranquen en Minikube (un solo nodo) sin quedarse en `Pending`. En producción con varios nodos, el scheduler intentará separarlos automáticamente. |
| Replicación delegada al Job `04b` | Separar la configuración de la replicación del arranque del StatefulSet permite reintentar el proceso sin reiniciar los Pods de base de datos. |
| `read-only=1` en la replica | Impide escrituras accidentales directas en la replica, protegiendo la consistencia de la replicación. |
| `sync-binlog=1` en el primary | Garantiza durabilidad: ningún evento del binlog se pierde ante un crash del primary. |

---

## Dependencias con otros archivos

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | Debe crear el namespace `databases` antes de aplicar este archivo. |
| `01-secrets.yaml` | Debe existir el Secret `mariadb-secret` con las claves `mariadb-root-password` y `mariadb-user-password`. |
| `04b-mariadb-replication-job.yaml` | Configura la replicación activa una vez que ambos Pods están listos. Debe ejecutarse después de que este StatefulSet esté en Running. |
| `06-wordpress.yaml` | WordPress usa el Service `mariadb` (ClusterIP al primary) como host de base de datos. |
| `07-network-policy.yaml` | Las NetworkPolicies controlan el acceso al puerto 3306 desde WordPress y entre los propios Pods de MariaDB. |

---

## Puntos a tener en cuenta

### Orden de aplicación
Aplicar en este orden: `00-namespace.yaml` → `01-secrets.yaml` → `04-mariadb.yaml` → esperar a que ambos Pods estén en `Running/Ready` → `04b-mariadb-replication-job.yaml`.

### Persistencia de los PVCs
Al ejecutar `kubectl delete statefulset mariadb`, los PVCs `mariadb-storage-mariadb-0/1` permanecen. Este es el comportamiento intencional de Kubernetes para proteger los datos. Para una limpieza completa del entorno de desarrollo, borrar los PVCs manualmente tras eliminar el StatefulSet.

### `imagePullPolicy` en entorno Minikube
El init container `init-scripts` usa `imagePullPolicy: Never` para trabajar con imágenes precargadas en el registro local de Minikube, evitando dependencias de conectividad con registros externos durante el despliegue.
