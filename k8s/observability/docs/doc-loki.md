# DOC-11 — Loki + Promtail (`11-loki.yaml`)

## Qué hace este archivo

Despliega el stack de agregación de logs del clúster compuesto por dos componentes:

- **Loki**: sistema de almacenamiento y consulta de logs indexado por labels (análogo a Prometheus pero para logs). Persiste los datos en un PVC de 10Gi con retención de 31 días.
- **Promtail**: agente recolector desplegado como `DaemonSet` (uno por nodo) que lee los logs de todos los contenedores del nodo desde el sistema de ficheros del host y los envía a Loki.

## Conceptos de Kubernetes utilizados

**DaemonSet** garantiza que exactamente un pod de Promtail se ejecuta en cada nodo del clúster. Cuando se añaden nuevos nodos, el DaemonSet despliega automáticamente un pod en ellos. Esto es el patrón estándar para agentes de infraestructura (log shippers, métricas de nodo, agentes de seguridad).

**HostPath volumes** — Promtail monta `/var/log` y `/var/lib/docker/containers` del nodo directamente en el contenedor. Esto le permite leer los ficheros de log de todos los contenedores del nodo sin necesitar acceso a la API de Kubernetes para obtener el contenido en sí.

**RBAC para service discovery de pods** — aunque Promtail lee los logs desde el filesystem del nodo, usa la API de Kubernetes para enriquecer cada log con metadatos (nombre del pod, namespace, labels). Para esto necesita un `ClusterRole` con permisos de lectura sobre `pods`, `namespaces` y `nodes`.

**Relabeling en Promtail** — similar a Prometheus, Promtail usa `relabel_configs` para extraer metadatos de los pods y convertirlos en labels de los logs. Esto permite filtrar en Grafana por `{namespace="wordpress"}` o `{pod="mariadb-0"}`.

**ConfigMap para configuración de Loki** — la configuración de Loki es compleja (schema, almacenamiento, compactor) y se gestiona desde un ConfigMap. El parámetro `auth_enabled: false` simplifica el despliegue eliminando la autenticación multi-tenant, apropiado para entornos de desarrollo.

## Decisiones de diseño

Loki usa almacenamiento en filesystem local (no S3/GCS) porque en Minikube no hay un sistema de objetos accesible. El schema `v13` con `tsdb` es el más reciente y eficiente de Loki 2.9, con mejor rendimiento de consulta que los schemas anteriores basados en BoltDB.

El filtro de namespaces en Promtail (`regex: wordpress|databases|monitoring|security`) limita el volumen de logs enviados a Loki, ignorando los namespaces del sistema (`kube-system`, `kube-public`) que generan ruido y no son relevantes para el proyecto.

La retención de 744h (31 días) está alineada con la política de backups de `18-backup.yaml`, que también retiene datos durante 30 días. El `compactor` con `retention_enabled: true` limpia automáticamente los chunks más antiguos.

El contexto de seguridad `runAsUser: 10001` / `runAsNonRoot: true` en Loki cumple con el `PodSecurityStandard` `baseline` aplicado en los namespaces del proyecto, evitando que el proceso corra como root.

## Dependencias

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | Crea el namespace `monitoring` |
| `12-grafana.yaml` | Grafana consume Loki como datasource de logs (`http://loki.monitoring.svc.cluster.local:3100`) |
| `07-network-policy.yaml` | Las NetworkPolicies deben permitir tráfico desde Promtail (en todos los namespaces) hacia Loki en `monitoring` |

## Advertencias y puntos críticos

- Promtail monta directorios del host con `readOnly: true`. En entornos con `PodSecurityStandard` `restricted`, los volúmenes `hostPath` están prohibidos. La tolerancia `key: node-role.kubernetes.io/master` permite que Promtail corra en el nodo master de Minikube, necesario para recoger sus logs.
- Loki **no indexa el contenido** de los logs, solo las labels. Las consultas por contenido (regex en el mensaje) son más lentas que las consultas por label. Diseñar bien las labels en Promtail es crítico para el rendimiento.
- El Service de Loki es `ClusterIP` intencionalmente: no debe exponerse al exterior. Grafana accede via DNS interno `loki.monitoring.svc.cluster.local:3100`.
- Con `replication_factor: 1` y almacenamiento `filesystem`, no hay redundancia de datos. Un fallo del PVC implica pérdida de todos los logs almacenados.
