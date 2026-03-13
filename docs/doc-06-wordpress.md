# DOC-06 — Deployment de WordPress en Alta Disponibilidad

## ¿Qué hace este archivo?

Define el `Deployment` de WordPress y su `Service` NodePort. El Deployment arranca con una réplica (KEDA tomará el control desde `09-keda-wordpress.yaml` para escalar entre 2 y 10) y configura WordPress para operar en modo quasi-stateless: la base de datos va a MariaDB primary, la caché de objetos a Redis via Sentinel, los uploads a MinIO/S3, y el tracing distribuido al OTel Collector. El `SecurityContext` aplica un perfil de seguridad reforzado con sistema de ficheros raíz inmutable.

---

## Conceptos de Kubernetes utilizados

### Deployment vs StatefulSet
WordPress usa un `Deployment` porque es una aplicación stateless por diseño cuando sus dependencias de estado se externalizan correctamente (BD, caché, almacenamiento de objetos). A diferencia del StatefulSet de MariaDB o Redis, las réplicas de WordPress son intercambiables: no tienen identidad de red estable ni requieren almacenamiento individual por Pod.

### SecurityContext en dos niveles
Kubernetes permite definir políticas de seguridad a nivel de Pod y a nivel de contenedor. Ambas se combinan (la más restrictiva prevalece):

- **Nivel Pod**: `runAsNonRoot`, `runAsUser: 33` (www-data), `fsGroup: 33`, `seccompProfile: RuntimeDefault`. Aplica a todos los contenedores del Pod.
- **Nivel contenedor**: `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: ALL`. Aplica solo al contenedor WordPress.

`readOnlyRootFilesystem: true` es la restricción más impactante: impide cualquier escritura en el sistema de ficheros del contenedor fuera de los `volumeMounts` explícitos. Por eso son necesarios los dos `emptyDir` para `/tmp` y `/var/run/apache2`.

### WORDPRESS_CONFIG_EXTRA
La imagen oficial de WordPress (`wordpress:6.4`) soporta la variable de entorno `WORDPRESS_CONFIG_EXTRA`, que inyecta código PHP arbitrario en `wp-config.php` durante el entrypoint. Esto permite configurar constantes de WordPress (Redis, MinIO, OTel) sin modificar la imagen ni crear un ConfigMap con el fichero completo de `wp-config.php`.

### Tres tipos de probe encadenadas
WordPress tiene una cadena de tres probes con responsabilidades distintas:

```
[Arranque]  startupProbe  → hasta 5 min para que WP esté listo
               ↓ (cuando pasa)
[Tráfico]   readinessProbe → excluye del Service si no responde
[Salud]     livenessProbe  → reinicia el contenedor si está bloqueado
```

El `startupProbe` es crítico: sin él, `livenessProbe` reiniciaría WordPress antes de que termine de arrancar la primera vez.

### NodePort + Ingress (coexistencia)
El Service usa `NodePort: 30080` para acceso directo sin Ingress (útil en Minikube). El archivo `08-ingress.yaml` define además un Ingress con TLS para acceso por nombre de dominio. Ambos pueden coexistir: el Ingress es el path recomendado para producción; el NodePort es el fallback de desarrollo.

---

## Decisiones de diseño

| Decisión | Justificación |
|---|---|
| `replicas: 1` en el Deployment | KEDA gestiona el número de réplicas. Si se pone 2 aquí y KEDA también tiene `minReplicas: 2`, no hay conflicto, pero dejar 1 deja claro que la gestión real es de KEDA. |
| `readOnlyRootFilesystem: true` | Mitiga ataques de ejecución de código: aunque un atacante consiga RCE en PHP, no puede modificar ficheros del contenedor ni instalar herramientas. Es la defensa en profundidad más efectiva a nivel de contenedor. |
| Probes en `/wp-login.php` con header `Host` | `/wp-login.php` fuerza a WordPress a inicializar la conexión a BD y Redis, siendo una prueba más real que `/` o un healthcheck sintético. El header `Host: wp-k8s.local` es necesario porque Apache responde por VirtualHost y devuelve 404 sin él. |
| Redis via Sentinel (no directo) | Usar `WP_REDIS_SENTINEL_CONNECTION` garantiza que el plugin `Redis Object Cache` siempre conecte al master actual, incluso tras un failover automático. Conectar directamente a `redis:6379` puede enviar escrituras a una réplica. |
| Secrets duplicados en ambos namespaces | Los Secrets son namespace-scoped en Kubernetes. `mariadb-secret` existe en `databases` y debe replicarse en `wordpress` para que el Deployment pueda referenciarlo. Es una simplificación pragmática para Minikube; en producción usar External Secrets Operator o Vault. |
| `anti-afinidad preferred` (soft) | Permite que múltiples réplicas de WordPress convivan en el mismo nodo en Minikube. En producción multi-nodo, cambiar a `required` para garantizar separación real. |

---

## Dependencias con otros archivos

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | El namespace `wordpress` debe existir. |
| `01-secrets.yaml` | Deben existir `mariadb-secret`, `redis-secret` y `minio-secret` en el namespace `wordpress`. |
| `02-configmap.yaml` | El ConfigMap `wordpress-config` debe proveer `WORDPRESS_DB_HOST`, `WORDPRESS_DB_NAME`, `WORDPRESS_DB_USER`. |
| `03-pvc.yaml` | El PVC `wordpress-pvc` debe estar provisionado y en estado `Bound` antes de que el Deployment arranque. |
| `04-mariadb.yaml` | MariaDB primary debe estar listo y accesible en `mariadb.databases.svc.cluster.local:3306`. |
| `05-redis.yaml` | Redis Sentinel debe estar listo en `redis-sentinel.databases.svc.cluster.local:26379`. |
| `07-network-policy.yaml` | Las NetworkPolicies deben permitir: `wordpress → mariadb:3306`, `wordpress → redis-sentinel:26379`, `wordpress → otel-collector:4318`, `wordpress → minio:9000`. |
| `08-ingress.yaml` | El Ingress apunta al Service `wordpress:80` para acceso por nombre de dominio con TLS. |
| `09-keda-wordpress.yaml` | KEDA toma el control del número de réplicas del Deployment. |
| `16-minio.yaml` | MinIO debe estar operativo con el bucket `wordpress-uploads` creado. |
| `17-tracing.yaml` | El OTel Collector debe estar desplegado en `monitoring` para recibir trazas. |

---

## Advertencias y puntos críticos

### ⚠️ `remove-local-file: false` en la configuración de MinIO
Con esta opción, los uploads se guardan **tanto** en MinIO como en el PVC local (`/var/www/html/wp-content/uploads`). Esto duplica el almacenamiento y mantiene una dependencia del PVC para los uploads, impidiendo que WordPress sea completamente stateless. Cambiar a `true` para un diseño limpio, asegurándose primero de que MinIO está bien replicado.

### ⚠️ `force-https: false` en la configuración de MinIO
Las URLs de los archivos subidos se generan con HTTP. En producción con TLS habilitado (Cert-manager + Ingress), los navegadores bloquearán contenido mixto (Mixed Content). Cambiar a `true` cuando MinIO tenga certificado válido.

### ⚠️ `replicas: 1` puede confundir
Si KEDA no está instalado o el `ScaledObject` de `09-keda-wordpress.yaml` no se ha aplicado, WordPress corre con una sola réplica sin HA. Verificar siempre el estado del ScaledObject con `kubectl get scaledobject -n wordpress`.

### ⚠️ El PVC `wordpress-pvc` es ReadWriteOnce
Como se documenta en `DOC-03-pvc.md`, el PVC montado en `/var/www/html` es `ReadWriteOnce`. Con KEDA escalando a múltiples réplicas en el mismo nodo (Minikube), funciona. En producción multi-nodo, las réplicas en nodos distintos no podrán montar el PVC y quedarán en `Pending`. Solución: migrar uploads a MinIO con `remove-local-file: true` y eliminar el PVC del Deployment.

### ⚠️ Las probes usan `/wp-login.php` — dependencia de BD
Si MariaDB está caído o lento, `/wp-login.php` tardará en responder o devolverá error. Esto puede hacer que todos los Pods de WordPress fallen la `readinessProbe` simultáneamente, dejando el Service sin backends. Considerar un endpoint de healthcheck ligero (`/wp-content/health.php`) que no dependa de la BD para las probes de liveness.

### ℹ️ `WORDPRESS_CONFIG_EXTRA` es código PHP ejecutado como root lógico de WP
Cualquier error de sintaxis en este bloque romperá WordPress completamente (pantalla blanca). Validar el contenido PHP antes de aplicar cambios. En producción, gestionar esta configuración a través de un ConfigMap versionado.

### ℹ️ Compatibilidad del plugin Redis Object Cache con Sentinel
El plugin `Redis Object Cache` de WordPress debe estar instalado y configurado para usar el protocolo Sentinel. La configuración vía `WORDPRESS_CONFIG_EXTRA` define las constantes, pero el plugin debe estar activo en el panel de WordPress para que surtan efecto.
