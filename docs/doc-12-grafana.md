# DOC-12 — Grafana (`12-grafana.yaml`)

## Qué hace este archivo

Despliega Grafana como plataforma central de visualización del proyecto. Incluye:

- **PVC** de 5Gi para persistir dashboards, usuarios y configuración editada en la UI.
- **Secret** con credenciales del admin (`admin/admin123`).
- **ConfigMaps de provisioning**: datasources (Prometheus + Loki), proveedor de dashboards y dos dashboards predefinidos (Kubernetes Overview y WordPress K8s Project).
- **Deployment** de Grafana 10.2.3 con todos los ConfigMaps montados.
- **Service** ClusterIP expuesto al exterior via Ingress (`08-ingress.yaml`).

## Conceptos de Kubernetes utilizados

**Provisioning de Grafana** — Grafana soporta configuración como código mediante ficheros YAML en directorios específicos. El directorio `/etc/grafana/provisioning/datasources/` configura las fuentes de datos automáticamente al arrancar. El directorio `/etc/grafana/provisioning/dashboards/` configura los proveedores de dashboards que luego leen JSON de `/var/lib/grafana/dashboards/`. Esto evita tener que configurar manualmente la UI después de cada reinicio.

**Montaje de ficheros individuales con `subPath`** — el campo `subPath` en un `volumeMount` permite montar un fichero concreto de un ConfigMap en una ruta específica del contenedor sin sobrescribir el directorio completo. Aquí se usa para montar `kubernetes.json` y `wordpress-k8s.json` en `/var/lib/grafana/dashboards/` sin interferir con otros ficheros del directorio.

**Variables de entorno desde Secrets** — las credenciales del admin se inyectan via `secretKeyRef`, evitando que aparezcan en texto plano en el Deployment. Grafana lee `GF_SECURITY_ADMIN_USER` y `GF_SECURITY_ADMIN_PASSWORD` como variables de entorno estándar.

**Dashboard como código (JSON en ConfigMap)** — los dashboards se definen como JSON embebido en ConfigMaps. El `disableDeletion: true` en el proveedor impide que los dashboards provisionados se borren desde la UI, garantizando idempotencia en los redespliegues.

## Decisiones de diseño

Los datasources apuntan a los servicios internos del clúster por DNS (`prometheus.monitoring.svc.cluster.local`, `loki.monitoring.svc.cluster.local`). Esto desacopla Grafana de las IPs concretas de los pods y es resiliente a reinicios.

El dashboard `wordpress-k8s.json` incluye variables de template (`namespace`) que permiten filtrar las métricas por namespace sin modificar las queries PromQL. Esto hace el dashboard reutilizable en proyectos con múltiples entornos.

El contexto de seguridad usa UID/GID 472, que es el usuario `grafana` por convención en la imagen oficial. Esto cumple con `runAsNonRoot: true` y garantiza que el proceso tiene permisos de escritura en el PVC (via `fsGroup: 472`).

## Dependencias

| Archivo | Relación |
|---|---|
| `10-prometheus.yaml` | Fuente de datos principal; Grafana consulta `prometheus:9090` |
| `11-loki.yaml` | Fuente de datos de logs; Grafana consulta `loki:3100` |
| `08-ingress.yaml` | Expone `grafana:3000` en `grafana.monitoring.local` con TLS |
| `17-tracing.yaml` | El Service `jaeger-query:16686` puede añadirse como datasource de trazas en Grafana |
| `00-namespace.yaml` | Crea el namespace `monitoring` |

## Advertencias y puntos críticos

- La contraseña `admin123` en el Secret está en base64 pero **no cifrada**. Cualquiera con acceso al namespace `monitoring` puede decodificarla. En producción debe sustituirse por un Sealed Secret o un Secret gestionado por un KMS.
- El `updateIntervalSeconds: 30` en el proveedor de dashboards significa que los cambios en los ConfigMaps tardan hasta 30 segundos en reflejarse en Grafana sin reiniciar el pod.
- `disableDeletion: true` impide borrar dashboards desde la UI, pero los cambios realizados manualmente en la UI **se pierden** en cada reinicio porque Grafana recarga el JSON del ConfigMap. Para modificar dashboards, hay que actualizar el ConfigMap.
- El PVC de 5Gi almacena la base de datos SQLite de Grafana (usuarios, organizaciones, alertas creadas en la UI). Si se borra el PVC, se pierden todas estas configuraciones aunque los datasources y dashboards provisionados se recuperen al reiniciar.
