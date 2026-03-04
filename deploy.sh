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
# ============================================================
load_images() {
  log_info "Descargando imágenes en el host y cargándolas en Minikube..."
  echo ""

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
    "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.10.0"
  )

  for IMAGE in "${IMAGES[@]}"; do
    if ! docker image inspect "$IMAGE" &>/dev/null; then
      log_info "Descargando en host: $IMAGE"
      docker pull "$IMAGE" || log_error "No se pudo descargar $IMAGE."
    else
      log_success "Ya existe en host: $IMAGE"
    fi
    log_info "Cargando en Minikube: $IMAGE"
    minikube image load "$IMAGE" && log_success "Cargada en Minikube: $IMAGE"
  done

  echo ""
  log_success "Todas las imágenes están disponibles en Minikube"
}

# ============================================================
# FUNCIÓN: Instalar Ingress Controller
# ============================================================
install_ingress_controller() {
  if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null | grep -q "Running"; then
    log_success "Ingress Controller ya está corriendo"
  else
    log_info "Instalando Ingress Controller..."
    kubectl delete namespace ingress-nginx --ignore-not-found=true 2>/dev/null
    sleep 5

    curl -sL https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.14.1/deploy/static/provider/baremetal/deploy.yaml \
      | sed 's/@sha256:[a-f0-9]*//g' \
      | kubectl apply -f - \
      || log_error "No se pudo aplicar el manifest del Ingress Controller."

    log_info "Parcheando Jobs para usar imágenes locales..."
    sleep 5
    for JOB in ingress-nginx-admission-create ingress-nginx-admission-patch; do
      kubectl patch job $JOB -n ingress-nginx --type=json \
        -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' \
        2>/dev/null && log_success "Job $JOB parcheado" || true
    done
    kubectl patch deployment ingress-nginx-controller -n ingress-nginx --type=json \
      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' \
      2>/dev/null && log_success "Deployment ingress-nginx-controller parcheado"

    log_info "Esperando a que el Ingress Controller esté listo..."
    local retries=0
    until kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null | grep -q "Running"; do
      retries=$((retries + 1))
      [ $retries -ge 36 ] && log_error "El Ingress Controller no arrancó en 6 minutos."
      echo -n "."
      sleep 10
    done
    echo ""
    log_success "Ingress Controller está listo"
  fi

  log_info "Configurando Ingress Controller como LoadBalancer..."
  kubectl patch svc ingress-nginx-controller -n ingress-nginx \
    -p '{"spec":{"type":"LoadBalancer"}}' 2>/dev/null
  log_success "Ingress Controller configurado como LoadBalancer"
}

# ============================================================
# FUNCIÓN: Instalar kube-state-metrics
# Necesario para métricas kube_pod_*, kube_node_*, etc.
# ============================================================
install_kube_state_metrics() {
  if kubectl get deployment kube-state-metrics -n kube-system &>/dev/null; then
    log_success "kube-state-metrics ya está instalado"
    return
  fi

  log_info "Instalando kube-state-metrics..."

  local BASE_URL="https://raw.githubusercontent.com/kubernetes/kube-state-metrics/v2.10.0/examples/standard"

  curl -sL "$BASE_URL/cluster-role.yaml"         | kubectl apply -f - || log_error "Error aplicando ClusterRole de kube-state-metrics"
  curl -sL "$BASE_URL/cluster-role-binding.yaml" | kubectl apply -f - || log_error "Error aplicando ClusterRoleBinding de kube-state-metrics"
  curl -sL "$BASE_URL/service-account.yaml"      | kubectl apply -f - || log_error "Error aplicando ServiceAccount de kube-state-metrics"
  curl -sL "$BASE_URL/service.yaml"              | kubectl apply -f - || log_error "Error aplicando Service de kube-state-metrics"
  curl -sL "$BASE_URL/deployment.yaml" \
    | sed 's/@sha256:[a-f0-9]*//g' \
    | kubectl apply -f - || log_error "Error aplicando Deployment de kube-state-metrics"

  # Fuerza imagePullPolicy: Never para usar imagen local
  sleep 5
  kubectl patch deployment kube-state-metrics -n kube-system --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' \
    2>/dev/null && log_success "kube-state-metrics parcheado para usar imagen local"

  log_info "Esperando a que kube-state-metrics esté listo..."
  local retries=0
  until kubectl get pods -n kube-system -l app.kubernetes.io/name=kube-state-metrics 2>/dev/null | grep -q "Running"; do
    retries=$((retries + 1))
    [ $retries -ge 18 ] && log_error "kube-state-metrics no arrancó en 3 minutos."
    echo -n "."
    sleep 10
  done
  echo ""
  log_success "kube-state-metrics está listo"
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
# FUNCIÓN: Actualizar /etc/hosts automáticamente
# ============================================================
update_hosts() {
  log_info "Obteniendo IP externa del Ingress Controller..."

  local retries=0
  local EXTERNAL_IP=""
  until [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "<pending>" ]; do
    retries=$((retries + 1))
    [ $retries -ge 18 ] && log_error "No se asignó EXTERNAL-IP. Asegúrate de tener 'sudo minikube tunnel' corriendo."
    EXTERNAL_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    [ -z "$EXTERNAL_IP" ] && echo -n "." && sleep 5
  done
  echo ""
  log_success "EXTERNAL-IP obtenida: $EXTERNAL_IP"

  log_info "Actualizando /etc/hosts (requiere sudo)..."
  sudo sed -i '/wp-k8s\.local/d' /etc/hosts
  sudo sed -i '/grafana\.monitoring\.local/d' /etc/hosts
  sudo sed -i '/prometheus\.monitoring\.local/d' /etc/hosts

  echo "$EXTERNAL_IP wp-k8s.local" | sudo tee -a /etc/hosts > /dev/null
  echo "$EXTERNAL_IP grafana.monitoring.local" | sudo tee -a /etc/hosts > /dev/null
  echo "$EXTERNAL_IP prometheus.monitoring.local" | sudo tee -a /etc/hosts > /dev/null

  log_success "/etc/hosts actualizado correctamente"
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
  log_warn "Eliminando kube-state-metrics..."
  kubectl delete deployment kube-state-metrics -n kube-system --ignore-not-found=true 2>/dev/null
  kubectl delete service kube-state-metrics -n kube-system --ignore-not-found=true 2>/dev/null
  log_warn "Limpiando /etc/hosts..."
  sudo sed -i '/wp-k8s\.local/d' /etc/hosts
  sudo sed -i '/grafana\.monitoring\.local/d' /etc/hosts
  sudo sed -i '/prometheus\.monitoring\.local/d' /etc/hosts
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

# 2. Cargar imágenes en Minikube (incluye kube-state-metrics)
load_images
echo ""

# 3. Instalar Ingress Controller
install_ingress_controller
echo ""

# 4. Instalar kube-state-metrics
install_kube_state_metrics
echo ""

# 5. Metrics Server
install_metrics_server
echo ""

# 6. Namespaces
apply_file "00-namespace.yaml" "Namespaces (security, wordpress, databases, monitoring)"
sleep 2

# 7. Secrets
apply_file "01-secrets.yaml" "Secrets de MariaDB (databases + wordpress)"

# 8. ConfigMaps
apply_file "02-configmap.yaml" "ConfigMaps (mariadb-config + wordpress-config)"

# 9. PVCs
apply_file "03-pvc.yaml" "PersistentVolumeClaims (mariadb-pvc + wordpress-pvc)"

# 10. MariaDB
apply_file "04-mariadb.yaml" "Deployment + Service de MariaDB"
wait_for_deployment "databases" "mariadb" 120

# 11. Redis
apply_file "05-redis.yaml" "Deployment + Service de Redis"
wait_for_deployment "databases" "redis" 60

# 12. WordPress
apply_file "06-wordpress.yaml" "Deployment + Service de WordPress"
wait_for_deployment "wordpress" "wordpress" 120

# 13. NetworkPolicies
apply_file "07-network-policy.yaml" "NetworkPolicies (databases + wordpress)"

# 14. Ingress
apply_file "08-ingress.yaml" "Ingress (wp-k8s.local + monitoring.local)"

# 15. HPA
apply_file "09-hpa-wordpress.yaml" "HorizontalPodAutoscaler de WordPress"

# 16. Prometheus
apply_file "10-prometheus.yaml" "Prometheus (RBAC + ConfigMap + Deployment + Service)"
wait_for_deployment "monitoring" "prometheus" 120

# 17. Loki + Promtail
apply_file "11-loki.yaml" "Loki + Promtail (Deployment + DaemonSet)"
wait_for_deployment "monitoring" "loki" 120

# 18. Grafana
apply_file "12-grafana.yaml" "Grafana (Deployment + Service)"
wait_for_deployment "monitoring" "grafana" 120

# ============================================================
# TUNNEL Y /etc/hosts
# ============================================================
echo ""
log_warn "PASO FINAL: Abre una terminal nueva y ejecuta:"
echo ""
echo -e "   ${GREEN}sudo minikube tunnel${NC}"
echo ""
log_info "Esperando a que el tunnel asigne IP y actualizando /etc/hosts..."
echo ""

update_hosts

# ============================================================
# RESUMEN FINAL
# ============================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   ✅ Despliegue completado con éxito${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${BLUE}📌 URLs de acceso (mantén 'sudo minikube tunnel' activo):${NC}"
echo -e "   WordPress:  http://wp-k8s.local"
echo -e "   Grafana:    http://grafana.monitoring.local  (admin / admin123)"
echo -e "   Prometheus: http://prometheus.monitoring.local"
echo ""
echo -e "${BLUE}📌 Comandos útiles:${NC}"
echo -e "   Ver todos los pods:     kubectl get pods -A"
echo -e "   Ver estado del HPA:     kubectl get hpa -n wordpress"
echo -e "   Ver logs de WordPress:  kubectl logs -n wordpress -l app=wordpress -f"
echo -e "   Ver logs de MariaDB:    kubectl logs -n databases -l app=mariadb -f"
echo -e "   Deshacer todo:          ./deploy.sh --cleanup"
echo ""
