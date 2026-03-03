#!/bin/bash
# ============================================================
# deploy.sh - Script de despliegue para el proyecto Kubernetes
# Entorno: Minikube + Kubernetes v1.35 + StorageClass: standard
# ============================================================

set -e

# --- Colores ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ============================================================
# FUNCIÓN: Verificaciones previas
# ============================================================
check_requirements() {
  log_info "Verificando requisitos previos..."

  command -v kubectl &>/dev/null || log_error "kubectl no encontrado."
  log_success "kubectl encontrado"

  command -v docker &>/dev/null || log_error "docker no encontrado en el host."
  log_success "docker encontrado"

  minikube status | grep -q "Running" || log_error "Minikube no está corriendo. Ejecuta: minikube start"
  log_success "Minikube está activo"

  kubectl get storageclass standard &>/dev/null || log_error "StorageClass 'standard' no encontrada."
  log_success "StorageClass 'standard' disponible"
}

# ============================================================
# FUNCIÓN: Descargar imágenes en el host y cargarlas en Minikube
# Solución al problema de DNS/UDP dentro de la VM de Minikube
# ============================================================
load_images() {
  log_info "Descargando imágenes en el host y cargándolas en Minikube..."
  echo ""

  # Lista de imágenes necesarias
  IMAGES=(
    "mariadb:10.6"
    "redis:6.2-alpine"
    "wordpress:6.4"
    "prom/prometheus:v2.48.0"
    "grafana/grafana:10.2.3"
    "grafana/loki:2.9.3"
    "grafana/promtail:2.9.3"
    "registry.k8s.io/ingress-nginx/controller:v1.14.1"
    "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.5"
  )

  for IMAGE in "${IMAGES[@]}"; do
    # Comprueba si la imagen ya está cargada en Minikube
    if minikube image ls 2>/dev/null | grep -q "$(echo $IMAGE | cut -d: -f1)"; then
      log_success "Ya cargada en Minikube: $IMAGE"
      continue
    fi

    # Descarga en el host si no existe
    if ! docker image inspect "$IMAGE" &>/dev/null; then
      log_info "Descargando en host: $IMAGE"
      docker pull "$IMAGE" || log_error "No se pudo descargar $IMAGE. Verifica tu conexión a internet."
    else
      log_success "Ya existe en host: $IMAGE"
    fi

    # Carga en Minikube
    log_info "Cargando en Minikube: $IMAGE"
    minikube image load "$IMAGE" && log_success "Cargada en Minikube: $IMAGE"
  done

  echo ""
  log_success "Todas las imágenes están disponibles en Minikube"
}

# ============================================================
# FUNCIÓN: Instalar Ingress Controller via manifest oficial
# ============================================================
install_ingress_controller() {
  # Si ya está corriendo, no hacemos nada
  if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null | grep -q "Running"; then
    log_success "Ingress Controller ya está corriendo"
    return
  fi

  log_info "Instalando Ingress Controller..."

  # Limpia cualquier instalación previa rota
  kubectl delete namespace ingress-nginx --ignore-not-found=true 2>/dev/null
  sleep 3

  # Aplica el manifest oficial para baremetal
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.14.1/deploy/static/provider/baremetal/deploy.yaml \
    || log_error "No se pudo aplicar el manifest del Ingress Controller."

  log_info "Esperando a que el Ingress Controller esté listo (puede tardar 2-3 minutos)..."
  local retries=0
  local max_retries=24
  until kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null | grep -q "Running"; do
    retries=$((retries + 1))
    if [ $retries -ge $max_retries ]; then
      log_error "El Ingress Controller no arrancó en 4 minutos. Revisa: kubectl get pods -n ingress-nginx"
    fi
    echo -n "."
    sleep 10
  done
  echo ""
  log_success "Ingress Controller está listo"
}

# ============================================================
# FUNCIÓN: Metrics Server
# ============================================================
install_metrics_server() {
  if ! minikube addons list | grep -q "metrics-server.*enabled"; then
    log_warn "Metrics Server no habilitado. Habilitando..."
    minikube addons enable metrics-server
    log_success "Metrics Server habilitado"
  else
    log_success "Metrics Server ya está habilitado"
  fi
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
  log_warn "Eliminando Ingress Controller..."
  kubectl delete namespace ingress-nginx --ignore-not-found=true 2>/dev/null
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

[ "$1" == "--cleanup" ] && cleanup

# 1. Verificaciones previas
check_requirements
echo ""

# 2. Descargar y cargar imágenes en Minikube (evita ImagePullBackOff)
load_images
echo ""

# 3. Instalar Ingress Controller
install_ingress_controller
echo ""

# 4. Metrics Server
install_metrics_server
echo ""

# 5. Namespaces
apply_file "00-namespace.yaml" "Namespaces (security, wordpress, databases, monitoring)"
sleep 2

# 6. Secrets
apply_file "01-secrets.yaml" "Secrets de MariaDB (databases + wordpress)"

# 7. ConfigMaps
apply_file "02-configmap.yaml" "ConfigMaps (mariadb-config + wordpress-config)"

# 8. PVCs
apply_file "03-pvc.yaml" "PersistentVolumeClaims (mariadb-pvc + wordpress-pvc)"

# 9. MariaDB
apply_file "04-mariadb.yaml" "Deployment + Service de MariaDB"
wait_for_deployment "databases" "mariadb" 120

# 10. Redis
apply_file "05-redis.yaml" "Deployment + Service de Redis"
wait_for_deployment "databases" "redis" 60

# 11. WordPress
apply_file "06-wordpress.yaml" "Deployment + Service de WordPress"
wait_for_deployment "wordpress" "wordpress" 120

# 12. NetworkPolicies
apply_file "07-network-policy.yaml" "NetworkPolicies (databases + wordpress)"

# 13. Ingress
apply_file "08-ingress.yaml" "Ingress (wp-k8s.local + monitoring.local)"

# 14. HPA
apply_file "09-hpa-wordpress.yaml" "HorizontalPodAutoscaler de WordPress"

# 15. Prometheus
apply_file "10-prometheus.yaml" "Prometheus (RBAC + ConfigMap + Deployment + Service)"
wait_for_deployment "monitoring" "prometheus" 120

# 16. Loki + Promtail
apply_file "11-loki.yaml" "Loki + Promtail (Deployment + DaemonSet)"
wait_for_deployment "monitoring" "loki" 120

# 17. Grafana
apply_file "12-grafana.yaml" "Grafana (Deployment + Service)"
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

echo -e "${BLUE}📌 Añade estas líneas a tu /etc/hosts:${NC}"
echo -e "   ${MINIKUBE_IP} wp-k8s.local"
echo -e "   ${MINIKUBE_IP} grafana.monitoring.local"
echo -e "   ${MINIKUBE_IP} prometheus.monitoring.local"
echo ""
echo -e "${BLUE}📌 URLs de acceso via Ingress:${NC}"
echo -e "   WordPress:  http://wp-k8s.local"
echo -e "   Grafana:    http://grafana.monitoring.local  (admin / admin123)"
echo -e "   Prometheus: http://prometheus.monitoring.local"
echo ""
echo -e "${BLUE}📌 URLs alternativas via NodePort:${NC}"
echo -e "   WordPress:  http://${MINIKUBE_IP}:30080"
echo -e "   Grafana:    http://${MINIKUBE_IP}:30030"
echo -e "   Prometheus: http://${MINIKUBE_IP}:30090"
echo ""
echo -e "${BLUE}📌 Comandos útiles:${NC}"
echo -e "   Ver todos los pods:     kubectl get pods -A"
echo -e "   Ver estado del HPA:     kubectl get hpa -n wordpress"
echo -e "   Ver logs de WordPress:  kubectl logs -n wordpress -l app=wordpress -f"
echo -e "   Ver logs de MariaDB:    kubectl logs -n databases -l app=mariadb -f"
echo -e "   Deshacer todo:          ./deploy.sh --cleanup"
echo ""
