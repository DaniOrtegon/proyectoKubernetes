# DOC-05 — Redis Alta Disponibilidad con Sentinel

## ¿Qué hace este archivo?

Despliega Redis en modo Alta Disponibilidad mediante un `StatefulSet` de 3 Pods con el patrón **master + 2 réplicas + 3 Sentinels sidecar**. Define cinco recursos: un `ConfigMap` con las configuraciones de master, replica y Sentinel más el script de arranque; un `Service` headless para DNS estable; un `Service` ClusterIP para Sentinel; un `Service` ClusterIP genérico para Redis; y el `StatefulSet` con dos contenedores por Pod (Redis y Sentinel). Proporciona caché persistente para WordPress con failover automático ante caída del master.

---

## Conceptos de Kubernetes utilizados

### Patrón sidecar
Cada Pod del StatefulSet contiene dos contenedores que comparten la misma red (namespace de red del Pod):
- **`redis`**: el proceso principal de Redis.
- **`sentinel`**: Redis Sentinel, que monitoriza el estado del Redis local y coordina el failover con los Sentinels de los otros Pods.

Al compartir red, Sentinel puede conectarse al Redis del mismo Pod via `127.0.0.1` (loopback). Esto es lo que justifica la configuración `sentinel monitor mymaster 127.0.0.1 6379 2` en el ConfigMap.

### Redis Sentinel y quorum
Sentinel es el componente de alta disponibilidad de Redis. Tres Sentinels monitorizan continuamente los nodos y, cuando detectan que el master no responde, votan para iniciar un failover:

- **Quorum = 2**: al menos 2 de los 3 Sentinels deben acordar que el master está caído para iniciar el proceso. Esto tolera el fallo de 1 Sentinel sin disparar un failover falso.
- **Failover**: Sentinel elige una réplica como nuevo master, reconfigura el resto de réplicas para seguir al nuevo master y notifica a los clientes via el protocolo Pub/Sub de Sentinel.

### emptyDir para la configuración de Sentinel
Sentinel modifica su propio fichero de configuración en runtime (escribe el estado del clúster: master actual, Sentinels conocidos, épocas de failover). Como los volúmenes de ConfigMap son read-only, el fichero se copia a un `emptyDir` antes de arrancarlo. La consecuencia es que el estado de Sentinel **no persiste** entre reinicios del Pod; Sentinel redescubre el clúster desde la configuración base.

### Tres Services con propósitos distintos

| Service | Tipo | Propósito |
|---|---|---|
| `redis-headless` | Headless | DNS estable por Pod; usado por réplicas para localizar el master y por Sentinels para descubrirse entre sí |
| `redis-sentinel` | ClusterIP | Punto de entrada para clientes que usan el protocolo Sentinel (descubrimiento dinámico del master) |
| `redis` | ClusterIP | Acceso directo a Redis sin Sentinel; balancea entre todos los Pods indiscriminadamente |

---

## Decisiones de diseño

| Decisión | Justificación |
|---|---|
| Sentinel como sidecar (no como Pod independiente) | Evita la necesidad de un segundo StatefulSet o Deployment para los Sentinels. Reduce la complejidad operativa al colocar el Sentinel junto al Redis que monitoriza. |
| 3 Sentinels (quorum=2) | El número mínimo para un sistema de quorum que tolere 1 fallo. Con 2 Sentinels y quorum=2, el fallo de cualquiera de ellos bloquearía el failover. |
| Persistencia doble: AOF + RDB | AOF (`appendonly yes + appendfsync everysec`) garantiza pérdida máxima de 1 segundo de datos. RDB (`save`) proporciona snapshots periódicos más eficientes para recovery tras reinicio completo. |
| `masterauth` en todos los nodos | En un failover, una réplica se convierte en master. Si solo el master tuviera `requirepass` y las réplicas no tuvieran `masterauth`, el nuevo master no podría autenticar a sus nuevas réplicas. |
| Script de arranque en lugar de dos imágenes | Un único ConfigMap y una única imagen gestionan tanto el master como las réplicas, simplificando el mantenimiento. |
| `sentinel-data` como emptyDir | La configuración de Sentinel es efímera porque se regenera en cada arranque. Usar un PVC sería costoso y aportaría poco valor dado que el descubrimiento es automático. |

---

## Dependencias con otros archivos

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | El namespace `databases` debe existir antes de aplicar este archivo. |
| `06-wordpress.yaml` | WordPress usa Redis como Object Cache. Debe configurarse con el Service `redis-sentinel` (puerto 26379) o `redis` (puerto 6379) como endpoint. |
| `02-configmap.yaml` | Si el ConfigMap global del proyecto define variables de conexión a Redis, deben coincidir con la contraseña y el puerto configurados aquí. |
| `07-network-policy.yaml` | Las NetworkPolicies deben permitir: tráfico WordPress→Redis (6379), comunicación inter-Sentinel (26379) y Redis→Redis (replicación, 6379). |
| `09-keda-wordpress.yaml` | KEDA escala WordPress basándose en métricas de Prometheus. Si Redis está sobrecargado, afecta al rendimiento de WordPress y puede disparar el escalado. |
| `10-prometheus.yaml` | Para monitorizar Redis con Prometheus se necesitaría un `redis-exporter` (no incluido en este archivo). Las métricas de Sentinel también son exportables. |

---

## Advertencias y puntos críticos

### ⚠️ Contraseña en texto plano en el ConfigMap
`Redis#2024!` aparece en texto plano en `redis-master.conf`, `redis-replica.conf` y `sentinel.conf`. Un ConfigMap no está cifrado en etcd por defecto. Cualquier usuario con acceso de lectura al namespace puede obtener la contraseña con `kubectl get configmap redis-config -o yaml`.

**Solución recomendada**: usar Sealed Secrets (ya disponible en el stack) para gestionar la contraseña de Redis. El fichero de configuración debería montarse desde un Secret, no desde un ConfigMap. Alternativamente, inyectar la contraseña via variable de entorno y usar un script de arranque que la sustituya en el fichero de configuración antes de arrancarlo.

### ⚠️ El Service `redis` (ClusterIP genérico) no es master-aware
El selector `app: redis` balancea entre los 3 Pods (master y réplicas). Tras un failover de Sentinel, el master cambia de Pod pero el Service sigue enviando escrituras a todos los Pods. Las réplicas (ahora `read-only`) rechazarán las escrituras con el error `READONLY You can't write against a read only replica`.

**Solución**: los clientes que necesiten escribir deben usar el protocolo Sentinel (conectarse a `redis-sentinel:26379` y usar `SENTINEL get-master-addr-by-name mymaster` para descubrir el master actual). El plugin `Redis Object Cache` de WordPress soporta configuración con Sentinel.

### ⚠️ La contraseña aparece en los comandos de las probes
El comando `redis-cli -a 'Redis#2024!'` expone la contraseña en texto plano. Si las probes fallan, Kubernetes puede registrar el comando completo en los logs del kubelet.

### ⚠️ `sentinel-data` es efímero
El estado de Sentinel (master actual, épocas de failover, Sentinels conocidos) se pierde al reiniciar el Pod. Esto no es un problema grave porque Sentinel redescubre el clúster automáticamente, pero puede causar un retraso de segundos a minutos si todos los Pods se reician simultáneamente (por ejemplo, tras un rollout).

### ⚠️ Las réplicas apuntan hardcoded a `redis-0` como master inicial
`redis-replica.conf` contiene `replicaof redis-0.redis-headless...`. Tras un failover donde `redis-1` se convierte en master, si `redis-0` se recupera, intentará conectarse a sí mismo como master (bucle). Sentinel debería reconfigurarlo automáticamente, pero hay una ventana de inconsistencia.

### ℹ️ Recursos del sidecar Sentinel son muy ajustados
`limits.memory: 64Mi` puede quedarse corto en clústeres con muchos eventos de Sentinel o logs extensos. Monitorizar el consumo en producción.
