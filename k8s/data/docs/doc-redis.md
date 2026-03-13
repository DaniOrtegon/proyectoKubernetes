# DOC-05 — Redis Alta Disponibilidad con Sentinel

## ¿Qué hace este archivo?

Despliega Redis en modo Alta Disponibilidad mediante un `StatefulSet` de 3 Pods con el patrón **master + 2 réplicas + 3 Sentinels sidecar**. Define cinco recursos: un `ConfigMap` con las configuraciones de master, replica y Sentinel más el script de arranque; un `Service` headless para DNS estable; un `Service` ClusterIP para Sentinel; un `Service` ClusterIP para Redis; y el `StatefulSet` con dos contenedores por Pod (Redis y Sentinel). Proporciona caché persistente para WordPress con failover automático ante caída del master.

---

## Conceptos de Kubernetes utilizados

### Patrón sidecar
Cada Pod del StatefulSet contiene dos contenedores que comparten la misma red (namespace de red del Pod):
- **`redis`**: el proceso principal de Redis.
- **`sentinel`**: Redis Sentinel, que monitoriza el estado del Redis local y coordina el failover con los Sentinels de los otros Pods.

Al compartir red, Sentinel puede conectarse al Redis del mismo Pod via `127.0.0.1` (loopback). Esto es lo que justifica la configuración `sentinel monitor mymaster 127.0.0.1 6379 2` en el ConfigMap: Sentinel monitoriza siempre su Redis local y se comunica con los otros Sentinels a través de la red del clúster.

### Redis Sentinel y quorum
Sentinel es el componente de alta disponibilidad de Redis. Tres Sentinels monitorizan continuamente los nodos y, cuando detectan que el master no responde, votan para iniciar un failover:

- **Quorum = 2**: al menos 2 de los 3 Sentinels deben acordar que el master está caído para iniciar el proceso. Tolera el fallo de 1 Sentinel sin disparar un failover falso, y tolera el fallo del master con los 2 Sentinels restantes activos.
- **Failover**: Sentinel elige una réplica como nuevo master, reconfigura el resto de réplicas para seguir al nuevo master y notifica a los clientes via el protocolo Pub/Sub de Sentinel.

### emptyDir para la configuración de Sentinel
Sentinel modifica su propio fichero de configuración en runtime (escribe el estado del clúster: master actual, Sentinels conocidos, épocas de failover). Como los volúmenes de ConfigMap son read-only, el fichero se copia a un `emptyDir` antes de arrancarlo. Sentinel redescubre el clúster automáticamente en cada arranque a partir de la configuración base, por lo que la no-persistencia del estado es un comportamiento correcto y esperado.

### Tres Services con propósitos distintos

| Service | Tipo | Propósito |
|---|---|---|
| `redis-headless` | Headless | DNS estable por Pod; usado por réplicas para localizar el master y por Sentinels para descubrirse entre sí |
| `redis-sentinel` | ClusterIP | Punto de entrada para clientes que usan el protocolo Sentinel (descubrimiento dinámico del master) |
| `redis` | ClusterIP | Acceso directo a Redis para clientes que no requieren descubrimiento de master |

---

## Decisiones de diseño

| Decisión | Justificación |
|---|---|
| Sentinel como sidecar (no como Pod independiente) | Evita la necesidad de un segundo StatefulSet para los Sentinels. Reduce la complejidad operativa al colocar el Sentinel junto al Redis que monitoriza, simplificando el modelo de despliegue. |
| 3 Sentinels (quorum=2) | El número mínimo para un sistema de quorum robusto que tolere exactamente 1 fallo de Sentinel. Con 2 Sentinels, cualquier fallo individual bloquearía el failover. |
| Persistencia doble: AOF + RDB | AOF (`appendonly yes + appendfsync everysec`) garantiza pérdida máxima de 1 segundo de datos. RDB (`save`) proporciona snapshots periódicos eficientes para recovery tras reinicio completo. La combinación de ambos es la práctica recomendada por la documentación oficial de Redis. |
| `masterauth` en todos los nodos | En un failover, una réplica se convierte en master. Configurar `masterauth` en todos los nodos garantiza que el nuevo master pueda autenticar a sus nuevas réplicas sin intervención manual. |
| Script de arranque compartido | Un único ConfigMap y una única imagen gestionan tanto el master como las réplicas, simplificando el mantenimiento y garantizando consistencia en la configuración base. |
| Anti-afinidad `preferred` (soft) | Permite que los 3 Pods arranquen en Minikube (un solo nodo) sin conflictos. En un clúster multi-nodo, el scheduler distribuirá los Pods automáticamente, mejorando la disponibilidad real. |

---

## Dependencias con otros archivos

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | El namespace `databases` debe existir antes de aplicar este archivo. |
| `06-wordpress.yaml` | WordPress usa Redis como Object Cache configurado con `WP_REDIS_SENTINEL_CONNECTION` apuntando al Service `redis-sentinel:26379`. |
| `07-network-policy.yaml` | Las NetworkPolicies permiten tráfico WordPress→Redis (6379 y 26379) y la comunicación inter-Pod para la replicación Redis. |
| `10-prometheus.yaml` | Para monitorizar Redis con Prometheus se puede añadir un `redis-exporter` como sidecar adicional al StatefulSet. |

---

## Puntos a tener en cuenta

### Configuración del cliente WordPress con Sentinel
El plugin `Redis Object Cache` de WordPress debe estar instalado y activo para que las constantes definidas en `WORDPRESS_CONFIG_EXTRA` (`06-wordpress.yaml`) surtan efecto. La conexión via Sentinel garantiza que, tras un failover automático, WordPress continúe conectando al master actual sin intervención manual.

### Gestión de credenciales
La contraseña de Redis está configurada de forma uniforme en todos los nodos (master y réplicas) mediante `requirepass` y `masterauth`. Para entornos de producción, la práctica recomendada es gestionar estas credenciales con Sealed Secrets (ya disponible en el stack) montando los ficheros de configuración desde Secrets en lugar de ConfigMaps, añadiendo una capa adicional de protección en etcd.

### Escalado de recursos del sidecar Sentinel
Los recursos del contenedor Sentinel están dimensionados conservadoramente (`50m` CPU, `32Mi` memoria) dado su rol de coordinación de metadatos. En entornos con alta frecuencia de eventos o logs extensos, estos valores pueden ajustarse al alza sin impacto en el proceso principal de Redis.
