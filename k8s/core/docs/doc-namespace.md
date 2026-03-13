# namespace.yaml — Documento de referencia

## ¿Qué hace este archivo?

Define los seis namespaces que estructuran el proyecto WordPress HA en Kubernetes. Un namespace es la unidad de aislamiento lógico de Kubernetes — agrupa recursos relacionados y permite aplicar políticas de seguridad, red y acceso de forma independiente para cada área del sistema.

## Namespaces definidos

| Namespace | Componentes | Propósito |
|-----------|-------------|-----------|
| `wordpress` | Deployment, Service, KEDA, PDB, PVC | Capa de aplicación |
| `databases` | MariaDB StatefulSet, Redis StatefulSet + Sentinels | Persistencia de datos |
| `monitoring` | Prometheus, Grafana, Loki, Promtail, Jaeger, OTel | Observabilidad |
| `security` | cert-manager, Sealed Secrets Controller | Seguridad transversal |
| `storage` | MinIO, CronJobs de backup | Almacenamiento S3 |
| `velero` | Velero | Backup completo del clúster |

## Pod Security Standards

Cada namespace lleva tres labels que activan el sistema de seguridad de pods de Kubernetes (disponible desde la versión 1.25, que reemplazó al deprecado PodSecurityPolicy).

**`enforce: baseline`** — Es el nivel activo de protección. Kubernetes rechaza directamente cualquier pod que intente usar contenedores privilegiados, acceder al PID o red del host, montar volúmenes peligrosos o escalar privilegios. El pod simplemente no arranca.

**`warn: restricted`** — Nivel informativo. Si un pod no cumple el perfil más estricto (`restricted`), Kubernetes muestra un aviso en la salida de `kubectl apply`. No bloquea nada, pero informa de qué habría que mejorar para alcanzar la máxima seguridad.

**`audit: restricted`** — Registra en el audit log del clúster cualquier pod que no cumpliría el perfil `restricted`. Útil para auditorías de seguridad y para identificar qué workloads habría que endurecer en el futuro.

## ¿Por qué `baseline` y no `restricted`?

El perfil `restricted` requiere que todos los contenedores corran como usuarios no-root, tengan un `seccompProfile` definido y eliminen todas las capabilities del sistema. Las imágenes actuales del proyecto (WordPress, MariaDB, MinIO, Grafana) corren como root por defecto y no cumplen estos requisitos. Aplicar `restricted` como `enforce` rompería todos los pods.

`baseline` ofrece protección real contra los vectores de ataque más comunes sin requerir modificaciones en las imágenes. La combinación `enforce: baseline` + `warn/audit: restricted` es el equilibrio correcto: protección activa hoy, hoja de ruta clara para llegar a `restricted` mañana.

## Excepción: namespace `velero`

Velero usa el perfil `privileged` (sin restricciones) porque necesita acceso especial al nodo del clúster para crear snapshots de PVCs mediante el driver CSI. Es la única excepción justificada al perfil `baseline` del resto del proyecto.

## Relación con otros archivos

Las NetworkPolicies definidas en `network-policy.yaml` usan estos namespaces como unidades de aislamiento de red — `databases` solo acepta conexiones desde `wordpress`, `monitoring` solo acepta scraping desde Prometheus, etc. Sin los namespaces correctamente definidos, las NetworkPolicies no funcionan.
