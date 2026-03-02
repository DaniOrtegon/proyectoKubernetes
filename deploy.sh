#!/bin/bash
# ============================================================
# deploy.sh - Script de despliegue para el proyecto Kubernetes
# Entorno: Minikube + Kubernetes v1.35 + StorageClass: standard
# ============================================================

set -e  # Para el script si cualquier comando falla

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sin color

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ============================================================
# FUNCIÓN: Verificaciones previas
# ============================================================
check_requirements() {
  log_info "Verificando requisitos previos..."

  # kubectl disponible
  command -v kubectl &>/dev/null || log_error "kubectl no encontrado. Instálalo primero."
  log_success "kubectl encontrado: $(kubectl version --client --short 2>/dev/null || echo 'ver instalada')"

  # Minikube corriendo
  minikube status | grep -q "Running" || log_error "Minikube no está corriendo. Ejecuta: minikube start"
  log_success "Minikube está activo"

  # Ingress addon habilitado
  if ! minikube addons list | grep -q "ingress.*enabled"; then
    log_warn "Ingress addon no está habilitado. Habilitando..."
    minikube addons enable ingress
    log_success "Ingress habilitado"
  else
    log_success "Ingress addon ya está habilitado"
  fi

  # Metrics Server para HPA
  if ! minikube addons list | grep -q "metrics-server.*enabled"; then
    log_warn "Metrics Server no está habilitado. Habilitando..."
    minikube addons enable metrics-server
    log_success "Metrics Server habilitado"
  else
    log_success "Metrics Server ya está habilitado"
  fi

  # StorageClass standard existe
  kubectl get storageclass standard &>/dev/null || log_error "StorageClass 'standard' no encontrada."
  log_success "StorageClass 'standard' disponible"
}

# ============================================================
# FUNCIÓN: Esperar a que un Deployment esté Ready
# ============================================================
wait_for_deployment() {
  local namespace=$1
  local deployment=$2
  local timeout=${3:-120}

  log_info "Esperando a que '$deployment' esté Ready en namespace '$namespace'..."
  kubectl rollout status deployment/$deployment -n $namespace --timeout=${timeout}s \
    && log_success "$deployment está Ready" \
    || log_error "$deployment no arrancó en ${timeout}s. Revisa: kubectl describe pod -n $namespace"
}

# ============================================================
# FUNCIÓN: Desplegar un archivo YAML
# ============================================================
apply_file() {
  local file=$1
  local description=$2
  log_info "Aplicando: $description ($file)..."
  kubectl apply -f $file \
    && log_success "$description aplicado correctamente" \
    || log_error "Error al aplicar $file"
}

# ============================================================
# FUNCIÓN: Deshacer todo (cleanup)
# ============================================================
cleanup() {
  echo ""
  log_warn "Deshaciendo todo el despliegue..."
  for file in 12-grafana.yaml 11-loki.yaml 10-prometheus.yaml \
              09-hpa-wordpress.yaml 08-ingress.yaml 07-network-policy.yaml \
              06-wordpress.yaml 05-redis.yaml 04-mariadb.yaml \
              03-pvc.yaml 02-configmap.yaml 01-secrets.yaml 00-namespace.yaml; do
    [ -f "$file" ] && kubectl delete -f $file --ignore-not-found=true && log_success "$file eliminado"
  done
  log_success "Cleanup completado."
  exit 0
}

# ============================================================
# MAIN
# ============================================================
echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   Despliegue del proyecto Kubernetes - WordPress HA${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# Opción --cleanup para deshacer todo
[ "$1" == "--cleanup" ] && cleanup

# 1. Verificaciones previas
check_requirements
echo ""

# 2. Namespaces (siempre primero)
apply_file "00-namespace.yaml" "Namespaces (security, wordpress, databases, monitoring)"
sleep 2

# 3. Secrets (antes que cualquier Deployment)
apply_file "01-secrets.yaml" "Secrets de MariaDB (databases + wordpress)"

# 4. ConfigMaps
apply_file "02-configmap.yaml" "ConfigMaps (mariadb-config + wordpress-config)"

# 5. PersistentVolumeClaims
apply_file "03-pvc.yaml" "PersistentVolumeClaims (mariadb-pvc + wordpress-pvc)"

# 6. Base de datos: MariaDB
apply_file "04-mariadb.yaml" "Deployment + Service de MariaDB"
wait_for_deployment "databases" "mariadb" 120

# 7. Cache: Redis
apply_file "05-redis.yaml" "Deployment + Service de Redis"
wait_for_deployment "databases" "redis" 60

# 8. WordPress (depende de MariaDB y Redis)
apply_file "06-wordpress.yaml" "Deployment + Service de WordPress"
wait_for_deployment "wordpress" "wordpress" 120

# 9. Seguridad: NetworkPolicies
apply_file "07-network-policy.yaml" "NetworkPolicies (databases + wordpress)"

# 10. Ingress de WordPress
apply_file "08-ingress.yaml" "Ingress de WordPress (wp-k8s.local)"

# 11. HPA de WordPress
apply_file "09-hpa-wordpress.yaml" "HorizontalPodAutoscaler de WordPress"

# 12. Monitoring: Prometheus
apply_file "10-prometheus.yaml" "Prometheus (RBAC + ConfigMap + Deployment + Service)"
wait_for_deployment "monitoring" "prometheus" 120

# 13. Monitoring: Loki + Promtail
apply_file "11-loki.yaml" "Loki + Promtail (Deployment + DaemonSet)"
wait_for_deployment "monitoring" "loki" 120

# 14. Monitoring: Grafana
apply_file "12-grafana.yaml" "Grafana (Deployment + Service + Ingress)"
wait_for_deployment "monitoring" "grafana" 120

# ============================================================
# RESUMEN FINAL
# ============================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   ✅ Despliegue completado con éxito${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""

MINIKUBE_IP=$(minikube ip)

echo -e "${BLUE}📌 URLs de acceso:${NC}"
echo -e "   WordPress:  http://wp-k8s.local  (o http://${MINIKUBE_IP}:30080)"
echo -e "   Grafana:    http://grafana.monitoring.local  (o http://${MINIKUBE_IP}:30030)"
echo -e "   Prometheus: http://prometheus.monitoring.local  (o http://${MINIKUBE_IP}:30090)"
echo ""
echo -e "${BLUE}📌 Añade esto a tu /etc/hosts si usas dominios locales:${NC}"
echo -e "   ${MINIKUBE_IP} wp-k8s.local grafana.monitoring.local prometheus.monitoring.local"
echo ""
echo -e "${BLUE}📌 Comandos útiles:${NC}"
echo -e "   Ver todos los pods:     kubectl get pods -A"
echo -e "   Ver estado del HPA:     kubectl get hpa -n wordpress"
echo -e "   Ver logs de WordPress:  kubectl logs -n wordpress -l app=wordpress -f"
echo -e "   Ver logs de MariaDB:    kubectl logs -n databases -l app=mariadb -f"
echo -e "   Deshacer todo:          ./deploy.sh --cleanup"
echo ""
