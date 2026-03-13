# DOC-06 — Deployment de WordPress en Alta Disponibilidad

## ¿Qué hace este archivo?

Define el `Deployment` de WordPress y su `Service` NodePort. El Deployment arranca con una réplica (KEDA tomará el control desde `09-keda-wordpress.yaml` para escalar entre 2 y 10) y configura WordPress para operar en modo quasi-stateless: la base de datos va a MariaDB primary, la caché de objetos a Redis via Sentinel, los uploads a MinIO/S3, y el tracing distribuido al OTel Collector. El `SecurityContext` aplica un perfil de seguridad reforzado con sistema de ficheros raíz inmutable.

---

## Conceptos de Kubernetes utilizados

### Deployment vs StatefulSet
WordPress usa un `Deployment` porque es una aplicación stateless por diseño cuando sus dependencias de estado se externalizan correctamente (BD, caché, almacenamiento de objetos). A diferencia del StatefulSet de MariaDB o Redis, las réplicas de WordPress son intercambiables: no tienen identidad de red estable ni requieren almacenamiento individual por Pod.

### SecurityContext en dos niveles
Kubernetes permite definir políticas de seguridad a nivel de Pod y a nivel de contenedor. Ambas se combinan:

- **Nivel Pod**: `runAsNonRoot`, `runAsUser: 33` (www-data), `fsGroup: 33`, `seccompProfile: RuntimeDefault`. Aplica a todos los contenedores del Pod.
- **Nivel contenedor**: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: ALL`. Aplica solo al contenedor WordPress.

`readOnlyRootFilesystem: true` garantiza que el sistema de ficheros del contenedor sea inmutable en tiempo de ejecución. Los dos `emptyDir` para `/tmp` y `/var/run/apache2` proveen los únicos puntos de escritura efímeros que PHP y Apache necesitan para su operación normal.

### WORDPRESS_CONFIG_EXTRA
La imagen oficial de WordPress soporta la variable de entorno `WORDPRESS_CONFIG_EXTRA`, que inyecta código PHP en `wp-config.php` durante el entrypoint. Esto permite configurar constantes de WordPress (Redis, MinIO, OTel) sin modificar la imagen ni gestionar un ConfigMap con el fichero completo de `wp-config.php`.

### Tres tipos de probe encadenadas
WordPress tiene una cadena de tres probes con responsabilidades distintas:

```
[Arranque]  startupProbe  → hasta 5 min para que WP esté listo
               ↓ (cuando pasa)
[Tráfico]   readinessProbe → excluye del Service si no responde
[Salud]     livenessProbe  → reinicia el contenedor si está bloqueado
```

El `startupProbe` es imprescindible: sin él, `livenessProbe` reiniciaría WordPress antes de que termine de arrancar la primera vez. Las probes usan `/wp-login.php` con el header `Host: wp-k8s.local` porque este endpoint fuerza a WordPress a verificar la conexión a BD y Redis, siendo una prueba de salud más completa que un simple ping de red.

### NodePort + Ingress (coexistencia)
El Service usa `NodePort: 30080` para acceso directo sin Ingress, útil durante el desarrollo en Minikube. El archivo `08-ingress.yaml` define además un Ingress con TLS para acceso por nombre de dominio. Ambos coexisten: el Ingress es el path recomendado para acceso externo; el NodePort proporciona un acceso directo de diagnóstico.

---

## Decisiones de diseño

| Decisión | Justificación |
|---|---|
| `replicas: 1` en el Deployment | KEDA gestiona el número de réplicas a partir de su configuración en `09-keda-wordpress.yaml`. El valor 1 es el estado inicial antes de que KEDA entre en funcionamiento. |
| `readOnlyRootFilesystem: true` | Defensa en profundidad: limita el impacto de una eventual ejecución de código arbitrario en PHP, impidiendo la modificación de ficheros del contenedor. |
| Redis via Sentinel | Usar `WP_REDIS_SENTINEL_CONNECTION` garantiza que el plugin `Redis Object Cache` siempre conecte al master actual, incluso tras un failover automático de Sentinel. |
| Secrets duplicados en ambos namespaces | Los Secrets son namespace-scoped en Kubernetes. `mariadb-secret` se replica en el namespace `wordpress` para que el Deployment pueda referenciarlo directamente. Es una solución pragmática y explícita para el entorno Minikube. |
| Anti-afinidad `preferred` (soft) | Permite que múltiples réplicas de WordPress convivan en el mismo nodo en Minikube, mientras que en producción multi-nodo el scheduler las distribuirá automáticamente. |
| MinIO con `remove-local-file: false` | En la fase actual del proyecto, los uploads se guardan tanto en MinIO como en el PVC local. Esto facilita la transición progresiva hacia un diseño completamente stateless, permitiendo verificar el funcionamiento de MinIO antes de eliminar la copia local. |

---

## Dependencias con otros archivos

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | El namespace `wordpress` debe existir. |
| `01-secrets.yaml` | Deben existir `mariadb-secret`, `redis-secret` y `minio-secret` en el namespace `wordpress`. |
| `02-configmap.yaml` | El ConfigMap `wordpress-config` debe proveer `WORDPRESS_DB_HOST`, `WORDPRESS_DB_NAME`, `WORDPRESS_DB_USER`. |
| `03-pvc.yaml` | El PVC `wordpress-pvc` debe estar en estado `Bound` antes de que el Deployment arranque. |
| `04-mariadb.yaml` | MariaDB primary debe estar listo en `mariadb.databases.svc.cluster.local:3306`. |
| `05-redis.yaml` | Redis Sentinel debe estar listo en `redis-sentinel.databases.svc.cluster.local:26379`. |
| `07-network-policy.yaml` | Las NetworkPolicies deben permitir los flujos necesarios desde WordPress hacia sus dependencias. |
| `08-ingress.yaml` | El Ingress apunta al Service `wordpress:80` para acceso por nombre de dominio con TLS. |
| `09-keda-wordpress.yaml` | KEDA toma el control del número de réplicas del Deployment. |
| `16-minio.yaml` | MinIO debe estar operativo con el bucket `wordpress-uploads` creado. |
| `17-tracing.yaml` | El OTel Collector debe estar desplegado en `monitoring` para recibir trazas. |

---

## Puntos a tener en cuenta

### Activación del plugin Redis Object Cache
Las constantes `WP_REDIS_SENTINEL` y `WP_REDIS_SENTINEL_CONNECTION` definidas en `WORDPRESS_CONFIG_EXTRA` configuran la conexión, pero el plugin `Redis Object Cache` debe estar instalado y activado desde el panel de WordPress para que la caché entre en funcionamiento.

### Evolución hacia stateless completo
La configuración actual de MinIO incluye `remove-local-file: false` como paso intermedio en la adopción de almacenamiento de objetos. Una vez verificado el correcto funcionamiento del bucket `wordpress-uploads`, el siguiente paso natural es activar `remove-local-file: true` y reducir el tamaño del PVC o eliminarlo del Deployment.

### Compatibilidad TLS con MinIO
La opción `force-https: false` está alineada con la configuración actual de MinIO en Minikube, que opera en HTTP. Al habilitar TLS en MinIO (con Cert-manager, ya disponible en el stack), este valor debe actualizarse a `true` para garantizar que las URLs de los medios se generen con HTTPS.
