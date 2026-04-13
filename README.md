# 🚀 KubeNet — WordPress HA en Kubernetes

> Infraestructura cloud-native completa sobre Minikube, diseñada como entorno de producción simulado con foco en alta disponibilidad, escalado inteligente, observabilidad end-to-end y seguridad real.

[![Kubernetes](https://img.shields.io/badge/Kubernetes-Minikube-326CE5?logo=kubernetes&logoColor=white)](https://minikube.sigs.k8s.io/)
[![WordPress](https://img.shields.io/badge/WordPress-HA-21759B?logo=wordpress&logoColor=white)](https://wordpress.org/)
[![KEDA](https://img.shields.io/badge/Autoscaling-KEDA-FF6B35)](https://keda.sh/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## 📑 Índice

1. [Descripción](#-descripción)
2. [Stack tecnológico](#-stack-tecnológico)
3. [Requisitos previos](#-requisitos-previos)
4. [Despliegue rápido](#-despliegue-rápido)
5. [Arquitectura](#-arquitectura)
6. [Alta disponibilidad](#-alta-disponibilidad)
7. [Escalado automático (KEDA)](#-escalado-automático-keda)
8. [Seguridad](#-seguridad)
9. [Observabilidad](#-observabilidad)
10. [Backup y recuperación](#-backup-y-recuperación)
11. [CI/CD](#-cicd)
12. [Accesos](#-accesos)
13. [Estructura del proyecto](#-estructura-del-proyecto)
14. [Decisiones de diseño](#-decisiones-de-diseño)
15. [Limitaciones conocidas](#-limitaciones-conocidas)
16. [Próximas mejoras](#-próximas-mejoras)
17. [Valor del proyecto](#-valor-del-proyecto)
18. [Comandos útiles](#-comandos-útiles)
19. [Licencia](#-licencia)

---

## 📋 Descripción

KubeNet es un despliegue de WordPress en alta disponibilidad sobre Kubernetes (Minikube) pensado como **entorno de producción simulado**, no como demo básica. Integra las capas habituales de una arquitectura cloud-native real:

- **Alta disponibilidad** en todos los componentes críticos
- **Escalado automático** basado en tráfico real (req/s), no solo CPU
- **Observabilidad end-to-end**: métricas, logs, trazas y alertas
- **Seguridad en profundidad**: NetworkPolicies, Sealed Secrets, TLS automático, Pod Security Standards
- **Backup y recuperación** automatizada con objetivos RPO/RTO definidos

---

## 🧠 Stack tecnológico

| Capa | Tecnología |
|---|---|
| Orquestación | Kubernetes (Minikube) |
| Aplicación | WordPress |
| Base de datos | MariaDB (Primary + Replica) |
| Caché | Redis + Sentinel |
| Autoscaling | KEDA |
| Almacenamiento | MinIO (S3 compatible) |
| TLS | cert-manager |
| Backup | Velero |
| Métricas | Prometheus |
| Visualización | Grafana |
| Logs | Loki |
| Trazas | Jaeger + OpenTelemetry |
| Secrets | Sealed Secrets (kubeseal) |

---

## ⚙️ Requisitos previos

### Recursos de la máquina

| Recurso | Mínimo |
|---|---|
| CPU | 4 cores |
| RAM | 8 GB |
| Disco | 40 GB |

### Herramientas (se instalan automáticamente con `install.sh`)

```
Docker · kubectl · Minikube · Helm
```

---

## ⚡ Despliegue rápido

```bash
# 1. Clonar el repositorio
git clone <repo>
cd KubeNet

# 2. Instalar dependencias (Docker, kubectl, Minikube, Helm)
chmod +x install.sh
./install.sh

# ⚠️  Si Docker se acaba de instalar, cierra sesión y vuelve a entrar antes de continuar

# 3. Arrancar Minikube
minikube start --cpus=4 --memory=8192

# 4. Configurar contraseñas (se generan interactivamente, nunca se guardan en el repo)
chmod +x setup.sh
./setup.sh

# 5. Desplegar
chmod +x deploy.sh
./deploy.sh

# 6. Exponer servicios — ejecutar en otra terminal y dejarlo corriendo
minikube tunnel
```

Acceso tras el despliegue: **https://wp-k8s.local**

> ✔ El script `deploy.sh` es **idempotente**: puede ejecutarse múltiples veces sin romper el estado del clúster.
> El navegador mostrará un aviso de certificado — es normal, el TLS es self-signed. Acepta la excepción.

---


## 🏗️ Arquitectura

### Flujo de petición

```
Browser
  │
  ▼
Ingress NGINX (TLS)
  │
  ▼
Service WordPress
  │
  ┌──────────┴──────────┐
  ▼                     ▼
Redis (caché)     MariaDB Primary
                       │
                       ▼
                  MariaDB Replica
```

### Namespaces

| Namespace | Propósito |
|---|---|
| `wordpress` | Aplicación |
| `databases` | MariaDB + Redis |
| `monitoring` | Observabilidad |
| `security` | cert-manager + Sealed Secrets |
| `storage` | MinIO + backups |
| `velero` | Snapshots de clúster |

### Componentes y HA

| Componente | Tipo | Alta Disponibilidad |
|---|---|---|
| WordPress | Deployment | Sí (mín. 2 pods) |
| MariaDB | StatefulSet | Primary + Replica |
| Redis | StatefulSet | Sentinel failover |
| MinIO | Deployment | Persistente |
| Prometheus Stack | Stateful | Observabilidad |

---

## 🔁 Alta disponibilidad

### WordPress

- Mínimo 2 réplicas activas
- `PodDisruptionBudget` configurado
- `readinessProbe` y `livenessProbe` en todos los pods

### MariaDB

- `mariadb-0` → **Primary** (lectura/escritura)
- `mariadb-1` → **Replica** (lectura + failover)
- Replicación automática gestionada por Job de inicialización

### Redis + Sentinel

- 1 master + 2 réplicas
- 3 instancias de Sentinel para quórum
- Failover automático y transparente para la aplicación

---

## 📈 Escalado automático (KEDA)

El autoscaling de WordPress está gestionado por **KEDA** (Kubernetes Event-Driven Autoscaling), usando métricas reales de tráfico en lugar de solo CPU.

| Parámetro | Valor |
|---|---|
| Mínimo de pods | 2 |
| Máximo de pods | 10 |
| Trigger principal | Prometheus (req/s) |
| Trigger fallback | CPU |

**Ventajas frente a HPA clásico:**
- Escala de forma **proactiva** ante picos de tráfico, no reactiva
- Evita saturación antes de que ocurra
- Soporta múltiples triggers y métricas externas

---

## 🔐 Seguridad

### NetworkPolicies

- Modelo **default-deny** en todos los namespaces
- Solo tráfico explícitamente declarado está permitido

### Sealed Secrets

- Secrets cifrados y versionables en el repositorio
- El descifrado solo es posible dentro del clúster con la clave privada del controlador

> ⚠️ No se almacenan credenciales reales ni en texto plano en el repositorio.

### TLS (cert-manager)

- CA interna del clúster gestionada por cert-manager
- Certificados auto-renovables
- HTTPS forzado en todos los endpoints públicos
- WordPress configurado con `FORCE_SSL_ADMIN` y `FORCE_SSL_LOGIN`

### Pod Security Standards

- Perfil `baseline` aplicado a todos los namespaces
- Perfil `privileged` únicamente en el namespace de Velero (requerido por los drivers de snapshot)

---

## 📊 Observabilidad

| Herramienta | Propósito |
|---|---|
| Prometheus | Recolección de métricas |
| Grafana | Dashboards y alertas |
| Loki | Agregación de logs |
| Jaeger | Trazas distribuidas |
| OpenTelemetry | Instrumentación y telemetría |

### SLOs definidos

| Indicador | Objetivo |
|---|---|
| Disponibilidad | ≥ 99.5% |
| Latencia p95 | ≤ 2s |

El dashboard de Grafana personalizado (`Kubernetes_Dashboard.json`) está incluido en el repositorio para importación directa.

---

## 💾 Backup y recuperación

### Estrategia

| Tipo | Frecuencia |
|---|---|
| DB dump (MariaDB) | Diario |
| Uploads (wp-content) | Diario |
| Snapshots de clúster (Velero) | Diario |

### Objetivos

| Indicador | Valor |
|---|---|
| RPO (Recovery Point Objective) | 24h |
| RTO (Recovery Time Objective) | ~15 min |

---

## 🔄 CI/CD

Validación automática en cada push al repositorio:

```
kubeconform / kubeval    → validación de manifiestos YAML
kube-score               → análisis de buenas prácticas
detect-secrets           → detección de credenciales expuestas
resource validation      → comprobación de limits/requests
```

---

## 🌐 Accesos

| Servicio | URL |
|---|---|
| WordPress | https://wp-k8s.local |
| Grafana | https://grafana.monitoring.local |
| Prometheus | https://prometheus.monitoring.local |
| MinIO | http://minio.storage.local |

> Requiere `minikube tunnel` activo y las entradas correspondientes en `/etc/hosts`.

---

## 📁 Estructura del proyecto

```
.
├── install.sh                       # Instalación de dependencias (Docker, kubectl, Minikube, Helm)
├── deploy.sh                        # Script de despliegue idempotente
├── setup.sh                         # Configuración inicial de contraseñas
├── runbook.md                        # Procedimientos operativos
│
└── k8s/
    ├── app/
    │   ├── wordpress.yaml            # Deployment + Service de WordPress
    │   └── keda-wordpress.yaml       # ScaledObject KEDA (min:2 max:10, req/s + CPU)
    │
    ├── core/
    │   ├── namespace.yaml            # Namespaces del proyecto
    │   ├── configmap.yaml            # ConfigMaps (mariadb-config + wordpress-config)
    │   ├── network-policy.yaml       # NetworkPolicies (default-deny + reglas explícitas)
    │   ├── pdb.yaml                  # PodDisruptionBudget de WordPress
    │   └── resource-quota.yaml       # ResourceQuota y LimitRange
    │
    ├── data/
    │   ├── mariadb.yaml              # MariaDB HA — StatefulSet (primary + replica)
    │   ├── mariadb-replication-job.yaml  # Job de configuración de replicación
    │   └── redis.yaml                # Redis HA — StatefulSet + Sentinel sidecars
    │
    ├── edge/
    │   ├── cert-manager.yaml         # ClusterIssuers + Certificados TLS
    │   └── ingress.yaml              # Ingress NGINX con TLS
    │
    ├── observability/
    │   ├── prometheus.yaml           # Prometheus + Alertmanager
    │   ├── grafana.yaml              # Grafana con datasources integrados
    │   ├── loki.yaml                 # Loki + Promtail
    │   └── tracing.yaml              # Jaeger + OTel Collector
    │
    └── storage/
        ├── pvc.yaml                  # PersistentVolumeClaims
        ├── minio.yaml                # MinIO — almacenamiento S3 compatible
        ├── backup.yaml               # CronJobs de backup (MariaDB + uploads)
        └── velero.yaml               # Velero — bucket setup + NetworkPolicy
```

---

## ⚖️ Decisiones de diseño

| Decisión | Motivo |
|---|---|
| YAML plano (sin Helm) | Control total sobre cada manifiesto |
| KEDA en lugar de HPA | Escalado real por tráfico, no solo CPU |
| MinIO | Almacenamiento S3 local sin dependencia cloud |
| Sealed Secrets | Seguridad sin necesidad de gestión cloud externa |
| Jaeger en modo simple | Menor complejidad operativa para entorno local |
| Minikube | Entorno completamente reproducible en local |
| setup.sh interactivo | Sin archivos de ejemplo en el repo — las contraseñas nunca se versionan |

---

## 🚧 Limitaciones conocidas

- Entorno local (no cloud real): sin LoadBalancer externo ni DNS público
- Algunas imágenes no están optimizadas para ejecución rootless
- Sin GitOps implementado (ArgoCD / Flux fuera del alcance actual)

---

## 📌 Próximas mejoras

- [ ] Migración de manifiestos a Helm / Kustomize
- [ ] GitOps con ArgoCD
- [ ] External Secrets Operator
- [ ] Clúster multi-nodo real
- [ ] Pipeline CI con despliegue automático en cada merge

---

## 🧠 Valor del proyecto

Este proyecto demuestra capacidad para:

- Diseñar arquitecturas cloud-native completas
- Operar Kubernetes de forma realista, no solo declarativa
- Implementar observabilidad real (métricas + logs + trazas)
- Gestionar fallos, runbooks y recuperación
- Tomar decisiones técnicas razonadas y documentadas

---

## 🧰 Comandos útiles

```bash
# Estado general del clúster
kubectl get pods -A

# Logs de WordPress en tiempo real
kubectl logs -n wordpress -l app=wordpress -f

# Ver ScaledObject de KEDA
kubectl get scaledobject -n wordpress

# Listar backups de Velero
velero backup get

# Verificar certificados TLS
kubectl get certificates -A

# Estado de la replicación MariaDB
MARIADB_ROOT_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.mariadb-root-password}' | base64 -d)
kubectl exec -n databases mariadb-1 -- \
  mysql -u root -p"$MARIADB_ROOT_PASS" -e 'SHOW SLAVE STATUS\G' 2>/dev/null \
  | grep -E 'Running|Behind'

# Limpiar el entorno completo
./deploy.sh --cleanup
```

---

## 📄 Licencia

MIT
