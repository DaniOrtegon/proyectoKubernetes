# KubeNet — WordPress HA en Kubernetes

Despliegue de WordPress en Alta Disponibilidad sobre Minikube. Arquitectura de producción completa con HA, observabilidad, seguridad, backup y escalado automático, usando manifiestos YAML planos y un script `deploy.sh` que automatiza todo el proceso.

**Entorno:** Minikube · Kubernetes 1.25+ · Docker · Debian Linux

---

## Índice

- [Requisitos](#requisitos)
- [Despliegue rápido](#despliegue-rápido)
- [Arquitectura](#arquitectura)
- [Archivos del proyecto](#archivos-del-proyecto)
- [Alta Disponibilidad](#alta-disponibilidad)
- [Seguridad](#seguridad)
- [Escalado con KEDA](#escalado-con-keda)
- [Observabilidad](#observabilidad)
- [Backup y recuperación](#backup-y-recuperación)
- [CI/CD](#cicd)
- [URLs de acceso](#urls-de-acceso)
- [Comandos útiles](#comandos-útiles)
- [Decisiones de diseño](#decisiones-de-diseño)

---

## Requisitos

```bash
minikube, kubectl, helm, docker, kubeseal
```

Recursos mínimos recomendados para Minikube: **4 CPUs, 8GB RAM, 40GB disco**.

---

## Despliegue rápido

```bash
# 1. Clonar el repositorio
git clone <repo> && cd KubeNet

# 2. Ejecutar el script de despliegue
chmod +x deploy.sh && ./deploy.sh

# 3. En una terminal separada, abrir el tunnel
minikube tunnel

# 4. Acceder a WordPress
https://wp-k8s.local
```

El script es **idempotente** — se puede ejecutar múltiples veces sin romper el entorno.

---

## Arquitectura

### Stack de aplicación

| Componente | Imagen | Namespace | Réplicas |
|---|---|---|---|
| WordPress | `wordpress:6.4` | wordpress | 2 mín · 10 máx (KEDA) |
| MariaDB primary | `mariadb:10.6` | databases | 1 (mariadb-0) |
| MariaDB replica | `mariadb:10.6` | databases | 1 (mariadb-1) |
| Redis master + réplicas | `redis:7-alpine` | databases | 3 pods + 3 Sentinels |
| MinIO | `minio/minio:latest` | storage | 1 |

### Namespaces

| Namespace | Contenido | Pod Security |
|---|---|---|
| `wordpress` | WordPress, Ingress, KEDA, PDB | enforce: baseline |
| `databases` | MariaDB HA, Redis HA | enforce: baseline |
| `monitoring` | Prometheus, Grafana, Loki, Jaeger, OTel | enforce: baseline |
| `security` | cert-manager, Sealed Secrets | enforce: baseline |
| `storage` | MinIO, CronJobs backup | enforce: baseline |
| `velero` | Velero backup agent | enforce: privileged |

### Flujo de una petición

```
Browser → minikube tunnel → nginx Ingress (TLS) → Service wordpress
       → Pod WordPress → Redis Sentinel (caché) / MariaDB primary (BD)
```

---

## Archivos del proyecto

| Archivo | Descripción |
|---|---|
| `namespace.yaml` | 7 namespaces con Pod Security Standards |
| `secrets.yaml` | Plantilla de credenciales (fallback manual — no se aplica directamente) |
| `configmap.yaml` | Configuración no sensible de MariaDB y WordPress |
| `pvc.yaml` | PVC wordpress-pvc (2Gi) |
| `mariadb.yaml` | StatefulSet MariaDB HA primary + replica |
| `mariadb-replication-job.yaml` | Job que configura la replicación activa |
| `redis.yaml` | StatefulSet Redis HA + Sentinels |
| `wordpress.yaml` | Deployment WordPress + Service |
| `network-policy.yaml` | 19 NetworkPolicies (default-deny + allow explícitos) |
| `ingress.yaml` | Ingress con TLS para WordPress y monitoring |
| `keda-wordpress.yaml` | ScaledObject KEDA (req/s + CPU fallback) |
| `prometheus.yaml` | Prometheus + Alertmanager + SLOs + Slack |
| `loki.yaml` | Loki + Promtail DaemonSet |
| `grafana.yaml` | Grafana con datasources y dashboards provisionados |
| `pdb.yaml` | PodDisruptionBudget WordPress |
| `resource-quota.yaml` | LimitRange + ResourceQuota por namespace |
| `cert-manager.yaml` | CA self-signed + certificados TLS automáticos |
| `minio.yaml` | MinIO + buckets wordpress-uploads y wordpress-backups |
| `tracing.yaml` | Jaeger all-in-one + OTel Collector DaemonSet |
| `backup.yaml` | CronJobs backup MariaDB, uploads y limpieza + Job restore |
| `velero.yaml` | Bucket setup + NetworkPolicy para Velero |
| `deploy.sh` | Script de despliegue automatizado e idempotente |
| `cleanup.sh` | Desinstalador rápido |
| `RUNBOOK.md` | 6 runbooks operacionales con RTO documentado |
| `MEJORAS.md` | Tabla de 20 mejoras con estado implementado/pendiente |

---

## Alta Disponibilidad

### WordPress
- Mínimo 2 réplicas garantizadas por KEDA
- `PodDisruptionBudget` con `minAvailable: 1` — rolling updates sin downtime
- Readiness y liveness probes configuradas

### MariaDB
- `mariadb-0` actúa como primary, `mariadb-1` como replica
- Replicación activa configurada automáticamente por Job post-despliegue
- Service `mariadb` → primary · Service `mariadb-read` → replica (lectura)
- PVC independiente por pod via `volumeClaimTemplates`

### Redis con Sentinel
- 1 master (`redis-0`) + 2 réplicas + 3 Sentinels (sidecar por pod)
- Failover automático: si el master falla, los Sentinels votan y promueven una réplica
- WordPress conecta via Sentinel — el failover es transparente para la aplicación

---

## Seguridad

### NetworkPolicies — 19 políticas
Arquitectura **default-deny** en todos los namespaces. Solo se permite tráfico explícitamente declarado: Ingress→WordPress, WordPress→MariaDB/Redis/OTel/MinIO, Prometheus scrape, Promtail→Loki, OTel→Jaeger, backups→MinIO, Velero→MinIO+API.

### Sealed Secrets
Secrets cifrados con `kubeseal` antes de guardarse en el repositorio. El descifrado solo es posible con la clave privada del clúster donde se generaron.

### TLS con cert-manager
- CA self-signed propia del clúster (`selfsigned-issuer` → `ca-issuer`)
- Renovación automática 30 días antes de expirar
- `wordpress-tls` para `wp-k8s.local` · `monitoring-tls` con SAN para grafana y prometheus

### Pod Security Standards
- `enforce: baseline` — rechaza pods privilegiados, hostPID/hostNetwork, escalada de privilegios
- `warn/audit: restricted` — informa de mejoras posibles sin bloquear
- `velero`: `privileged` (necesario para snapshots CSI)

---

## Escalado con KEDA

KEDA reemplaza al HPA nativo para escalar WordPress de forma **proactiva** por tráfico real, no por CPU.

| Parámetro | Valor |
|---|---|
| minReplicaCount | 2 |
| maxReplicaCount | 10 |
| Trigger principal | req/s en Ingress via Prometheus · threshold: 100 req/s |
| Trigger fallback | CPU > 70% |
| Scale up | +2 pods cada 30s · estabilización 30s |
| Scale down | -1 pod cada 60s · estabilización 120s |

El HPA original (`hpa-wordpress.yaml`) se conserva como referencia y fallback.

---

## Observabilidad

| Herramienta | Versión | Función |
|---|---|---|
| Prometheus | v2.48.0 | Métricas, SLOs, Service Discovery automático |
| Alertmanager | v0.26.0 | Alertas a Slack via webhook |
| Grafana | v10.2.3 | Dashboards unificados, datasources provisionados automáticamente |
| Loki | v2.9.3 | Logs centralizados, retención 31 días |
| Promtail | v2.9.3 | DaemonSet recolector de logs por nodo |
| Jaeger | v1.52 | Trazas distribuidas |
| OTel Collector | v0.91.0 | DaemonSet receptor OTLP |

**SLOs:** disponibilidad ≥ 99.5% · latencia p95 ≤ 2s

---

## Backup y recuperación

| CronJob | Horario | Origen | Destino |
|---|---|---|---|
| `mariadb-backup` | 2:00 AM diario | mysqldump completo | MinIO `wordpress-backups/mariadb/` |
| `wordpress-uploads-backup` | 3:00 AM diario | PVC wp-content/uploads | MinIO `wordpress-backups/uploads/` |
| `backup-cleanup` | 4:00 AM domingos | Backups >30 días | Eliminación automática |

**RPO:** ~24h · **RTO:** ~15 min

Velero hace snapshot completo del clúster a la 1:00 AM (namespaces wordpress + databases, TTL 30 días, backend MinIO).

---

## CI/CD

Pipeline GitHub Actions con validación en cada push:

- **kubeval + kubeconform** — sintaxis y schemas de Kubernetes
- **kube-score** — mejores prácticas (security, resources, probes)
- **detect-secrets** — detección de credenciales hardcodeadas
- **Script Python** — verifica `resources.requests/limits` en todos los contenedores

---

## URLs de acceso

> Requisito previo: `minikube tunnel` en terminal separada

| Servicio | URL | Credenciales |
|---|---|---|
| WordPress | https://wp-k8s.local | — |
| Grafana | https://grafana.monitoring.local | admin / admin123 |
| Prometheus | https://prometheus.monitoring.local | — |
| MinIO | http://minio.storage.local | minioadmin / Minio#2024! |
| Jaeger | `kubectl port-forward -n monitoring svc/jaeger-query 16686:16686` | — |

---

## Comandos útiles

```bash
# Estado general
kubectl get pods -A

# Escalado KEDA
kubectl get scaledobject -n wordpress

# Logs
kubectl logs -n wordpress -l app=wordpress -f
kubectl logs -n databases -l app=mariadb -f

# Estado replicación MariaDB
kubectl exec -n databases mariadb-1 -- mysql -u root -p'RootDB#2026!' \
  -e 'SHOW SLAVE STATUS\G' 2>/dev/null | grep -E 'Running|Behind'

# Backups Velero
velero backup get
velero backup create manual --include-namespaces wordpress,databases
velero restore create --from-backup <nombre-backup>

# Deshacer todo
./cleanup.sh
```

---

## Decisiones de diseño

| Decisión | Alternativa descartada | Motivo |
|---|---|---|
| YAMLs planos | Helm Chart propio | Claridad y control directo |
| KEDA | HPA nativo | Escalado proactivo por req/s vs reactivo por CPU |
| Sealed Secrets | External Secrets Operator | Sin dependencia de proveedor externo |
| MinIO local | Amazon S3 | Entorno local, API S3 compatible |
| Jaeger in-memory | Jaeger + Elasticsearch | Sin dependencia adicional en Minikube |
| PSS baseline | PSS restricted | Imágenes corren como root por defecto |
| imagePullPolicy: Never | IfNotPresent | Red de Minikube sin acceso a registries externos |
| minikube tunnel manual | Servicio systemd | Más simple y fiable en desarrollo local |
