#!/bin/bash
# ============================================================
# cleanup.sh - Desinstalador rápido del proyecto Kubernetes
# Elimina todo sin quedarse colgado en Terminating
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

echo ""
echo -e "${RED}============================================================${NC}"
echo -e "${RED}   CLEANUP - Eliminando todo el despliegue${NC}"
echo -e "${RED}============================================================${NC}"
echo ""

# ============================================================
# 1. Bajar replicas a 0 para liberar PVCs antes de borrarlos
# ============================================================
log_info "Bajando replicas a 0 en todos los namespaces..."
for ns in wordpress databases monitoring; do
  kubectl scale deployment --all -n $ns --replicas=0 2>/dev/null || true
  kubectl scale statefulset --all -n $ns --replicas=0 2>/dev/null || true
done
sleep 5
log_success "Replicas a 0"

# ============================================================
# 2. Eliminar PVCs (quitar finalizers primero)
# ============================================================
log_info "Eliminando PVCs (forzado)..."
for ns in wordpress databases monitoring; do
  for pvc in $(kubectl get pvc -n $ns -o name 2>/dev/null); do
    kubectl patch $pvc -n $ns -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete $pvc -n $ns --grace-period=0 --force 2>/dev/null || true
  done
done
log_success "PVCs eliminados"

# ============================================================
# 3. Quitar finalizers y forzar borrado de namespaces del proyecto
# ============================================================
log_info "Eliminando namespaces del proyecto..."
for ns in wordpress databases monitoring security; do
  # Quitar finalizers
  kubectl get namespace $ns -o json 2>/dev/null \
    | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
    | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true

  kubectl delete namespace $ns --grace-period=0 --force 2>/dev/null || true
done
log_success "Namespaces eliminados"

# ============================================================
# 4. Eliminar Ingress Controller
# Estrategia: kubectl delete primero. Solo forzar finalizers si
# se queda atascado en Terminating (nunca sobre namespace Active).
# ============================================================
log_info "Eliminando Ingress Controller..."
kubectl delete namespace ingress-nginx --ignore-not-found=true 2>/dev/null || true

INGRESS_TIMEOUT=20
INGRESS_ELAPSED=0
while true; do
  PHASE=$(kubectl get namespace ingress-nginx -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  [ -z "$PHASE" ] && break
  if [ "$PHASE" = "Terminating" ] && [ $INGRESS_ELAPSED -ge $INGRESS_TIMEOUT ]; then
    log_warn "ingress-nginx atascado en Terminating — forzando finalizers..."
    kubectl get namespace ingress-nginx -o json 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
      | kubectl replace --raw "/api/v1/namespaces/ingress-nginx/finalize" -f - 2>/dev/null || true
    break
  fi
  echo -n "."
  sleep 2
  INGRESS_ELAPSED=$((INGRESS_ELAPSED + 2))
done
echo ""
log_success "Ingress Controller eliminado"

# ============================================================
# 5. Eliminar kube-state-metrics
# ============================================================
log_info "Eliminando kube-state-metrics..."
kubectl delete deployment kube-state-metrics -n kube-system --ignore-not-found=true 2>/dev/null || true
kubectl delete service kube-state-metrics -n kube-system --ignore-not-found=true 2>/dev/null || true
kubectl delete serviceaccount kube-state-metrics -n kube-system --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrole kube-state-metrics --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrolebinding kube-state-metrics --ignore-not-found=true 2>/dev/null || true
log_success "kube-state-metrics eliminado"

# ============================================================
# 6. Eliminar Sealed Secrets Controller
# NOTA: Los ficheros sealed-*.yaml del proyecto NO se borran
# automáticamente porque están ligados a la clave del clúster.
# Si recreas el clúster (minikube delete), deberás borrarlos
# manualmente y regenerarlos con: ./deploy.sh
# ============================================================
log_info "Eliminando Sealed Secrets Controller..."
local VERSION="0.26.3"
kubectl delete -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${VERSION}/controller.yaml" \
  --ignore-not-found=true 2>/dev/null || true
log_success "Sealed Secrets Controller eliminado"

# ============================================================
# 7. Eliminar ClusterRoles y ClusterRoleBindings del proyecto
# ============================================================
log_info "Eliminando ClusterRoles y ClusterRoleBindings..."
kubectl delete clusterrole prometheus --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrolebinding prometheus --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrole promtail --ignore-not-found=true 2>/dev/null || true
kubectl delete clusterrolebinding promtail --ignore-not-found=true 2>/dev/null || true
log_success "ClusterRoles eliminados"

# ============================================================
# 8. Eliminar PersistentVolumes huérfanos
# ============================================================
log_info "Eliminando PersistentVolumes huérfanos..."
for pv in $(kubectl get pv -o name 2>/dev/null); do
  kubectl patch $pv -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
  kubectl delete $pv --grace-period=0 --force 2>/dev/null || true
done
log_success "PersistentVolumes eliminados"

# ============================================================
# 9. Limpiar datos de Prometheus en Minikube (lockfile)
# ============================================================
log_info "Limpiando datos de Prometheus en Minikube..."
minikube ssh "sudo rm -rf /tmp/hostpath-provisioner/monitoring/ 2>/dev/null; echo ok" 2>/dev/null || true
log_success "Datos de Prometheus limpiados"

# ============================================================
# 10. Limpiar /etc/hosts
# ============================================================
log_info "Limpiando /etc/hosts..."
sudo sed -i '/wp-k8s\.local/d' /etc/hosts
sudo sed -i '/grafana\.monitoring\.local/d' /etc/hosts
sudo sed -i '/prometheus\.monitoring\.local/d' /etc/hosts
log_success "/etc/hosts limpiado"

# ============================================================
# 11. Esperar a que los namespaces desaparezcan (máx 30s)
# ============================================================
log_info "Verificando que los namespaces han desaparecido..."
TIMEOUT=30
ELAPSED=0
while kubectl get namespaces 2>/dev/null | grep -qE "wordpress|databases|monitoring|security"; do
  if [ $ELAPSED -ge $TIMEOUT ]; then
    log_warn "Algunos namespaces siguen en Terminating — forzando finalizers..."
    for ns in wordpress databases monitoring security; do
      kubectl get namespace $ns -o json 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
        | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
    done
    break
  fi
  echo -n "."
  sleep 2
  ELAPSED=$((ELAPSED + 2))
done
echo ""
log_success "Namespaces eliminados"

# ============================================================
# RESUMEN
# ============================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   ✅ Cleanup completado${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${BLUE}Para volver a desplegar:${NC}"
echo -e "   ./deploy.sh"
echo ""
echo -e "${BLUE}Para reiniciar Minikube desde cero:${NC}"
echo -e "   minikube stop && minikube delete && minikube start"
echo ""
