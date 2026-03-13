# ⎈ KubeNet — WordPress HA en Kubernetes

> WordPress 6.4 en alta disponibilidad sobre Minikube. Stack completo de producción: bases de datos replicadas, escalado automático, observabilidad full-stack, seguridad zero-trust y backup automatizado.

---

## Arquitectura general

```
Internet / Usuario
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│  edge/          NGINX Ingress + cert-manager (TLS self-signed)  │
└─────────────────────────────────────────────────────────────────┘
        │ wp-k8s.local          │ grafana.monitoring.local
        ▼                       ▼
┌───────────────┐     ┌─────────────────────────────────────────┐
│  app/         │     │  observability/                         │
│  WordPress    │────▶│  Prometheus · Loki · Grafana · Jaeger   │
│  2–5 pods HPA │     └─────────────────────────────────────────┘
└───────┬───────┘
        │ 3306          │ 6379/26379       │ S3:9000
        ▼               ▼                  ▼
┌─────────────────────────────┐   ┌──────────────┐
│  data/                      │   │  storage/    │
│  MariaDB Primary + Replica  │   │  MinIO S3    │
│  Redis Master + 2R + 3 Sentinel   Velero Backup│
└─────────────────────────────┘   └──────────────┘
        │
┌──────────────────────────────────────────────────┐
│  core/   Namespaces · Secrets · NetworkPolicies  │
│          ResourceQuota · LimitRange · PDB        │
└──────────────────────────────────────────────────┘
```

---

## Stack tecnológico

| Capa | Tecnología | Versión |
|---|---|---|
| CMS | WordPress | 6.4 |
| Base de datos | MariaDB HA (Primary + Replica) | 10.6 |
| Caché / sesiones | Redis Sentinel (1M + 2R + 3S) | 6.2 |
| Object storage | MinIO S3-compatible | latest |
| Ingress | NGINX Ingress Controller | — |
| TLS | cert-manager self-signed CA | — |
| Escalado | HPA v2 (CPU + Memoria) | autoscaling/v2 |
| Métricas | Prometheus + Alertmanager | 2.48.0 / 0.26.0 |
| Logs | Loki + Promtail | 2.9.3 |
| Dashboards | Grafana | 10.2.3 |
| Trazas | Jaeger + OpenTelemetry Collector | 1.52 / 0.91.0 |
| Backup clúster | Velero + MinIO | — |
| Plataforma | Minikube | 1 nodo |

---

## Estructura del repositorio

```
proyectoKubernetes/
├── README.md
├── .gitignore
├── docs/
│   └── runbook.md              # Procedimientos operacionales
├── scripts/
│   ├── deploy.sh               # Despliegue completo en orden
│   └── cleanup.sh              # Limpieza del clúster
├── dashboards/
│   └── Kubernetes_Dashboard.json
└── k8s/
    ├── core/                   # Namespaces, Secrets, NetworkPolicies, Quotas
    ├── storage/                # PVC, MinIO, Backup, Velero
    ├── data/                   # MariaDB, Redis
    ├── app/                    # WordPress, HPA
    ├── edge/                   # Ingress, cert-manager
    └── observability/          # Prometheus, Loki, Grafana, Jaeger
```

Cada carpeta contiene su propio `README.md` con descripción de archivos y un directorio `docs/` con documentación técnica detallada de cada recurso.

---

## Requisitos previos

```bash
# Minikube con recursos suficientes
minikube start --cpus=4 --memory=8192 --disk-size=30g

# Addons necesarios
minikube addons enable ingress
minikube addons enable metrics-server
minikube addons enable volumesnapshots
minikube addons enable csi-hostpath-driver

# Herramientas
kubectl   >= 1.28
helm      >= 3.0      # Para cert-manager y Velero
```

---

## Despliegue rápido

```bash
# Clonar el repositorio
git clone <repo-url>
cd proyectoKubernetes

# Despliegue completo (orden correcto garantizado)
chmod +x scripts/deploy.sh
./scripts/deploy.sh

# Verificar estado
kubectl get pods -A
kubectl get ingress -A
```

### Orden de aplicación manual

```bash
# 1. Fundamentos
kubectl apply -f k8s/core/namespace.yaml
kubectl apply -f k8s/core/secrets.yaml
kubectl apply -f k8s/core/configmap.yaml
kubectl apply -f k8s/core/network-policy.yaml
kubectl apply -f k8s/core/resource-quota.yaml
kubectl apply -f k8s/core/pdb.yaml

# 2. Almacenamiento
kubectl apply -f k8s/storage/pvc.yaml
kubectl apply -f k8s/storage/minio.yaml

# 3. Bases de datos
kubectl apply -f k8s/data/mariadb.yaml
kubectl wait --for=condition=ready pod/mariadb-0 -n databases --timeout=120s
kubectl apply -f k8s/data/mariadb-replication-job.yaml
kubectl apply -f k8s/data/redis.yaml

# 4. Aplicación
kubectl apply -f k8s/app/wordpress.yaml
kubectl apply -f k8s/app/hpa-wordpress.yaml

# 5. Borde de entrada
kubectl apply -f k8s/edge/cert-manager.yaml
kubectl apply -f k8s/edge/ingress.yaml

# 6. Observabilidad
kubectl apply -f k8s/observability/prometheus.yaml
kubectl apply -f k8s/observability/loki.yaml
kubectl apply -f k8s/observability/grafana.yaml
kubectl apply -f k8s/observability/tracing.yaml

# 7. Backup
kubectl apply -f k8s/storage/backup.yaml
kubectl apply -f k8s/storage/velero.yaml
```

---

## Acceso a los servicios

```bash
# Obtener IP de Minikube
minikube ip   # → X.X.X.X

# Añadir al /etc/hosts
echo "$(minikube ip) wp-k8s.local grafana.monitoring.local prometheus.monitoring.local" | sudo tee -a /etc/hosts
```

| Servicio | URL | Credenciales |
|---|---|---|
| WordPress | https://wp-k8s.local | — |
| Grafana | https://grafana.monitoring.local | admin / admin123 |
| Prometheus | https://prometheus.monitoring.local | — |
| MinIO Console | `kubectl port-forward -n storage svc/minio 9001:9001` → localhost:9001 | minioadmin / Minio#2024! |
| Jaeger UI | `kubectl port-forward -n monitoring svc/jaeger-query 16686:16686` → localhost:16686 | — |

> ⚠️ El certificado TLS es self-signed. El navegador mostrará un aviso de seguridad — es esperado en entorno local.

---

## Namespaces

| Namespace | Contenido |
|---|---|
| `wordpress` | WordPress Deployment, HPA, PVC, Secrets |
| `databases` | MariaDB StatefulSet, Redis StatefulSet |
| `monitoring` | Prometheus, Alertmanager, Grafana, Loki, Promtail, Jaeger, OTel |
| `storage` | MinIO, CronJobs de backup |
| `cert-manager` | Operador cert-manager, CA raíz |
| `velero` | Velero backup del clúster |
| `security` | Recursos de seguridad adicionales |

---

## Alta disponibilidad

| Componente | Estrategia HA | Failover |
|---|---|---|
| WordPress | HPA 2–5 réplicas + PDB minAvailable:1 | Automático (<30s) |
| MariaDB | Primary + Replica asíncrona | Manual (replica es read-only) |
| Redis | 1 Master + 2 Replicas + 3 Sentinels (quorum=2) | Automático (<5s) |
| MinIO | Single node + backup diario | Restauración manual |

---

## Observabilidad

### SLO definido
- **Disponibilidad WordPress**: 99.9% de requests exitosas
- **Error budget mensual**: 43 minutos
- **Burn rate crítico** (x14.4): alerta en <1h de consumir el budget
- **Burn rate warning** (x3): alerta si se agota en ~5 días

### Alertas configuradas
- `PodDown` — pod fuera de Running >2 min → **critical**
- `MariaDBPodDown` — pod MariaDB fuera de Running >1 min → **critical**
- `OOMKill` — contenedor terminado por falta de memoria → **warning**
- `HighCPUUsage` — CPU >80% durante 5 min → **warning**
- `HighMemoryUsage` — Memoria >80% durante 5 min → **warning**
- `WordPressSLOBurnRateHigh` — burn rate x14.4 → **critical**

---

## Seguridad

- **19 NetworkPolicies** con modelo default-deny en todos los namespaces
- **Pod Security Standards** perfil `baseline` en todos los workloads
- `readOnlyRootFilesystem: true` en WordPress
- `runAsNonRoot: true` + `capabilities: DROP ALL` en todos los contenedores
- Certificados TLS gestionados automáticamente por cert-manager
- Secrets en base64 (reemplazables por Sealed Secrets en producción)

---

## Backup y recuperación

| Backup | Horario | Destino | Retención |
|---|---|---|---|
| MariaDB dump | Diario 2:00 AM | MinIO `wordpress-backups/mariadb/` | 30 días |
| WordPress uploads | Diario 3:00 AM | MinIO `wordpress-backups/uploads/` | 30 días |
| Clúster completo (Velero) | Diario 1:00 AM | MinIO `velero-backups/` | 30 días |
| Limpieza backups | Domingo 4:00 AM | — | — |

**RTO estimado**: ~15 minutos  
**RPO estimado**: ~24 horas

### Restaurar backup de MariaDB

```bash
# 1. Editar el Job de restauración con el nombre del backup
kubectl edit job mariadb-restore-manual -n databases
# Cambiar: suspend: true → false
#          BACKUP_FILE: "CHANGE_ME.sql.gz" → "wordpress_20240101_020000.sql.gz"

# 2. Ver logs de la restauración
kubectl logs -n databases job/mariadb-restore-manual -f
```

---

## Limpieza

```bash
./scripts/cleanup.sh

# O manualmente
minikube delete
```

---

## Documentación

Cada bloque tiene su propia documentación técnica en `docs/`:

- [`k8s/core/docs/`](k8s/core/docs/) — Namespaces, Secrets, NetworkPolicies, Quotas, PDB
- [`k8s/storage/docs/`](k8s/storage/docs/) — PVC, MinIO, Backup, Velero
- [`k8s/data/docs/`](k8s/data/docs/) — MariaDB, Redis
- [`k8s/app/docs/`](k8s/app/docs/) — WordPress, HPA
- [`k8s/edge/docs/`](k8s/edge/docs/) — Ingress, cert-manager
- [`k8s/observability/docs/`](k8s/observability/docs/) — Prometheus, Loki, Grafana, Jaeger
- [`docs/runbook.md`](docs/runbook.md) — Procedimientos operacionales completos
