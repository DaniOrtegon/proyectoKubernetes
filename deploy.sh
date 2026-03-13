#!/bin/bash
# ============================================================
# deploy.sh - Script de despliegue para el proyecto Kubernetes
# Entorno: Minikube + Kubernetes v1.35 + StorageClass: standard
# ============================================================

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
  command -v kubectl &>/dev/null  || log_error "kubectl no encontrado."
  log_success "kubectl encontrado"
  command -v docker &>/dev/null   || log_error "docker no encontrado en el host."
  log_success "docker encontrado"
  command -v python3 &>/dev/null  || log_error "python3 no encontrado (necesario para cleanup)."
  log_success "python3 encontrado"
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
    "prom/alertmanager:v0.26.0"
    "grafana/grafana:10.2.3"
    "grafana/loki:2.9.3"
    "grafana/promtail:2.9.3"
    "registry.k8s.io/ingress-nginx/controller:v1.14.1"
    "registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.5"
    "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.10.0"
    "bitnami/sealed-secrets-controller:0.26.3"
    "minio/minio:latest"
    "minio/mc:latest"
    "busybox"
    "jaegertracing/all-in-one:1.52"
    "otel/opentelemetry-collector-contrib:0.91.0"
    "alpine:3.18"
    "ghcr.io/kedacore/keda:2.19.0"
    "ghcr.io/kedacore/keda-metrics-apiserver:2.19.0"
    "ghcr.io/kedacore/keda-admission-webhooks:2.19.0"
    "velero/velero:v1.12.4"
    "velero/velero-plugin-for-aws:v1.8.2"
    "quay.io/jetstack/cert-manager-controller:v1.14.4"
    "quay.io/jetstack/cert-manager-cainjector:v1.14.4"
    "quay.io/jetstack/cert-manager-webhook:v1.14.4"
    "quay.io/jetstack/cert-manager-startupapicheck:v1.14.4"
  )

  for IMAGE in "${IMAGES[@]}"; do
    if ! docker image inspect "$IMAGE" &>/dev/null; then
      log_info "Descargando en host: $IMAGE"
      docker pull "$IMAGE" || log_error "No se pudo descargar $IMAGE."
    else
      log_success "Ya existe en host: $IMAGE"
    fi
    if minikube image ls 2>/dev/null | grep -qF "$IMAGE"; then
      log_success "Ya existe en Minikube: $IMAGE"
    else
      log_info "Cargando en Minikube: $IMAGE"
      minikube image load "$IMAGE" && log_success "Cargada en Minikube: $IMAGE"
    fi
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
# ============================================================
install_kube_state_metrics() {
  if kubectl get deployment kube-state-metrics -n kube-system &>/dev/null; then
    log_success "kube-state-metrics ya está instalado"
    return
  fi

  log_info "Instalando kube-state-metrics..."
  local BASE_URL="https://raw.githubusercontent.com/kubernetes/kube-state-metrics/v2.10.0/examples/standard"

  curl -sL "$BASE_URL/cluster-role.yaml"         | kubectl apply -f - || log_error "Error ClusterRole kube-state-metrics"
  curl -sL "$BASE_URL/cluster-role-binding.yaml" | kubectl apply -f - || log_error "Error ClusterRoleBinding kube-state-metrics"
  curl -sL "$BASE_URL/service-account.yaml"      | kubectl apply -f - || log_error "Error ServiceAccount kube-state-metrics"
  curl -sL "$BASE_URL/service.yaml"              | kubectl apply -f - || log_error "Error Service kube-state-metrics"
  curl -sL "$BASE_URL/deployment.yaml" \
    | sed 's/@sha256:[a-f0-9]*//g' \
    | kubectl apply -f - || log_error "Error Deployment kube-state-metrics"

  sleep 5
  kubectl patch deployment kube-state-metrics -n kube-system --type=json \
    -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"}]' \
    2>/dev/null && log_success "kube-state-metrics parcheado para imagen local"

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
# FUNCIÓN: Instalar Sealed Secrets Controller
# ============================================================
install_sealed_secrets() {
  if kubectl get deployment sealed-secrets-controller -n kube-system &>/dev/null; then
    log_success "Sealed Secrets Controller ya está instalado"
    return
  fi

  local VERSION="0.26.3"

  # Asegurar imagen correcta en Minikube ANTES de aplicar el yaml
  log_info "Cargando imagen de Sealed Secrets en Minikube..."
  if ! minikube image ls 2>/dev/null | grep -qF "bitnami/sealed-secrets-controller:${VERSION}"; then
    docker pull bitnami/sealed-secrets-controller:${VERSION}       || log_error "No se pudo descargar la imagen de sealed-secrets."
    minikube image load bitnami/sealed-secrets-controller:${VERSION}       || log_error "No se pudo cargar la imagen en Minikube."
  fi
  log_success "Imagen bitnami/sealed-secrets-controller:${VERSION} disponible en Minikube"

  # Aplicar con imagePullPolicy: Never ya sustituido — evita race condition
  log_info "Instalando Sealed Secrets Controller v${VERSION}..."
  curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${VERSION}/controller.yaml"     | sed 's/imagePullPolicy: .*/imagePullPolicy: Never/g'     | kubectl apply -f -     || log_error "No se pudo instalar Sealed Secrets Controller."

  log_info "Esperando a que Sealed Secrets Controller esté listo..."
  local retries=0
  until kubectl get pods -n kube-system -l name=sealed-secrets-controller 2>/dev/null | grep -q "Running"; do
    retries=$((retries + 1))
    [ $retries -ge 18 ] && log_error "Sealed Secrets Controller no arrancó en 3 minutos."
    echo -n "."
    sleep 10
  done
  echo ""
  log_success "Sealed Secrets Controller está listo"
}

# ============================================================
# FUNCIÓN: Instalar cert-manager con Helm
# ============================================================
install_cert_manager() {
  if kubectl get deployment cert-manager -n cert-manager &>/dev/null; then
    log_success "cert-manager ya está instalado"
    return
  fi

  # Asegurar que las imágenes de cert-manager están en Minikube
  local CM_VERSION="v1.14.4"
  local CM_IMAGES=(
    "quay.io/jetstack/cert-manager-controller:${CM_VERSION}"
    "quay.io/jetstack/cert-manager-cainjector:${CM_VERSION}"
    "quay.io/jetstack/cert-manager-webhook:${CM_VERSION}"
    "quay.io/jetstack/cert-manager-startupapicheck:${CM_VERSION}"
  )
  for IMAGE in "${CM_IMAGES[@]}"; do
    if ! minikube image ls 2>/dev/null | grep -qF "$IMAGE"; then
      log_info "Cargando en Minikube: $IMAGE"
      docker pull "$IMAGE" || log_error "No se pudo descargar $IMAGE"
      minikube image load "$IMAGE" || log_error "No se pudo cargar $IMAGE en Minikube"
    else
      log_success "Ya en Minikube: $IMAGE"
    fi
  done

  # Instalar Helm si no está disponible
  if ! command -v helm &>/dev/null; then
    log_info "Helm no encontrado — instalando..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3       | bash       || log_error "No se pudo instalar Helm."
    log_success "Helm instalado: $(helm version --short)"
  else
    log_success "Helm ya disponible: $(helm version --short)"
  fi

  local VERSION="v1.14.4"
  log_info "Instalando cert-manager ${VERSION}..."

  # Añadir repo de Helm si no existe
  if ! helm repo list 2>/dev/null | grep -q "jetstack"; then
    helm repo add jetstack https://charts.jetstack.io       || log_error "No se pudo añadir el repo de Helm jetstack."
    helm repo update
  fi

  # Instalar cert-manager con sus CRDs
  helm install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --version ${VERSION} \
    --set installCRDs=true \
    --set global.leaderElection.namespace=cert-manager \
    --set image.pullPolicy=Never \
    --set webhook.image.pullPolicy=Never \
    --set cainjector.image.pullPolicy=Never \
    --set startupapicheck.image.pullPolicy=Never \
    || log_error "No se pudo instalar cert-manager."

  # Esperar a que los 3 pods de cert-manager estén listos
  log_info "Esperando a que cert-manager esté listo (puede tardar ~60s)..."
  local retries=0
  until [ "$(kubectl get pods -n cert-manager --field-selector=status.phase=Running 2>/dev/null | grep -c Running)" -ge 3 ]; do
    retries=$((retries + 1))
    [ $retries -ge 24 ] && log_error "cert-manager no arrancó en 4 minutos."
    echo -n "."
    sleep 10
  done
  echo ""
  log_success "cert-manager está listo"

  # Esperar a que el webhook de cert-manager esté realmente operativo
  # sleep fijo no es suficiente — hacemos un probe real hasta que responda
  log_info "Esperando a que el webhook de cert-manager esté operativo..."
  local retries=0
  until kubectl get pods -n cert-manager -l app.kubernetes.io/component=webhook         2>/dev/null | grep -q "Running"; do
    retries=$((retries + 1))
    [ $retries -ge 24 ] && log_error "Webhook de cert-manager no arrancó en 4 minutos."
    echo -n "."
    sleep 10
  done
  echo ""

  # Aunque el pod esté Running, el webhook puede tardar unos segundos más
  # en registrarse. Hacemos un probe con kubectl hasta que no falle.
  log_info "Verificando que el webhook acepta conexiones..."
  local probe_retries=0
  until kubectl auth can-i create certificates.cert-manager.io         --namespace kube-system &>/dev/null; do
    probe_retries=$((probe_retries + 1))
    [ $probe_retries -ge 12 ] && break  # máx 60s extra, luego intentamos igualmente
    echo -n "."
    sleep 5
  done
  echo ""
  sleep 5  # margen de seguridad final
  log_success "Webhook de cert-manager listo"
}

# ============================================================
# FUNCIÓN: Aplicar ClusterIssuers y Certificados TLS
# ============================================================
apply_cert_manager_config() {
  if kubectl get clusterissuer ca-issuer &>/dev/null; then
    log_success "ClusterIssuers ya están configurados"
    return
  fi

  log_info "Aplicando configuración de cert-manager (ClusterIssuers + Certificados)..."
  apply_file "15-cert-manager.yaml" "ClusterIssuers self-signed + Certificados TLS"

  # Esperar a que los certificados estén Ready
  log_info "Esperando a que los certificados TLS estén Ready..."
  local retries=0
  until kubectl get certificate wordpress-tls -n wordpress         -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; do
    retries=$((retries + 1))
    [ $retries -ge 18 ] && log_warn "Certificado wordpress-tls tardando más de lo esperado — continuando..."
    [ $retries -ge 18 ] && break
    echo -n "."
    sleep 10
  done
  echo ""
  log_success "Certificados TLS listos"
}

# ============================================================
# FUNCIÓN: Instalar kubeseal CLI
# ============================================================
install_kubeseal() {
  if command -v kubeseal &>/dev/null; then
    log_success "kubeseal ya está instalado: \$(kubeseal --version 2>&1)"
    return
  fi

  local VERSION="0.26.3"
  local ARCH="amd64"
  log_info "Instalando kubeseal CLI v\${VERSION}..."
  curl -sL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v\${VERSION}/kubeseal-\${VERSION}-linux-\${ARCH}.tar.gz" \
    | tar xz kubeseal \
    && sudo mv kubeseal /usr/local/bin/kubeseal \
    && sudo chmod +x /usr/local/bin/kubeseal \
    || log_error "No se pudo instalar kubeseal."

  log_success "kubeseal instalado: \$(kubeseal --version 2>&1)"
}

# ============================================================
# FUNCIÓN: Generar SealedSecrets si no existen ya
# ============================================================
generate_sealed_secrets() {
  local SEALED_FILES=(
    "sealed-mariadb-secret-databases.yaml"
    "sealed-mariadb-secret-wordpress.yaml"
    "sealed-redis-secret-databases.yaml"
    "sealed-redis-secret-wordpress.yaml"
  )

  # ----------------------------------------------------------
  # Detectar si los sealed secrets existentes son válidos
  # para la clave del clúster actual.
  # Estrategia: kubeseal --validate compara el certificado
  # embebido en el sealed secret con el del controlador actual.
  # Si la clave cambió (clúster nuevo o minikube delete) → regenerar.
  # ----------------------------------------------------------
  local all_exist=true
  for f in "${SEALED_FILES[@]}"; do
    [ ! -f "$f" ] && all_exist=false && break
  done

  if $all_exist; then
    log_info "SealedSecrets encontrados — verificando compatibilidad con este clúster..."

    # kubeseal --validate verifica que el sealed secret fue cifrado
    # con la misma clave pública que tiene el controlador actual.
    # Falla con exit code != 0 si la clave es diferente.
    if kubeseal --validate < sealed-mariadb-secret-databases.yaml &>/dev/null 2>&1; then
      log_success "SealedSecrets válidos para este clúster ✅ — reutilizando"
      return
    else
      log_warn "⚠️  SealedSecrets incompatibles con este clúster (clave diferente)"
      log_warn "   Esto ocurre al cambiar de máquina o tras 'minikube delete'"
      log_warn "   Haciendo backup y regenerando automáticamente..."
      local backup_dir="sealed-secrets-backup-$(date +%Y%m%d_%H%M%S)"
      mkdir -p "$backup_dir"
      for f in "${SEALED_FILES[@]}"; do
        [ -f "$f" ] && cp "$f" "$backup_dir/" && rm -f "$f"
      done
      log_info "Backup guardado en: $backup_dir/"
    fi
  fi

  log_info "Generando SealedSecrets con kubeseal..."

  kubectl create secret generic mariadb-secret \
    --namespace databases \
    --from-literal=mariadb-root-password='RootDB#2024!' \
    --from-literal=mariadb-user-password='WpUser#2024!' \
    --dry-run=client -o yaml \
    | kubeseal --format yaml > sealed-mariadb-secret-databases.yaml \
    || log_error "Error generando sealed-mariadb-secret-databases.yaml"
  log_success "sealed-mariadb-secret-databases.yaml generado"

  kubectl create secret generic mariadb-secret \
    --namespace wordpress \
    --from-literal=mariadb-user-password='WpUser#2024!' \
    --dry-run=client -o yaml \
    | kubeseal --format yaml > sealed-mariadb-secret-wordpress.yaml \
    || log_error "Error generando sealed-mariadb-secret-wordpress.yaml"
  log_success "sealed-mariadb-secret-wordpress.yaml generado"

  kubectl create secret generic redis-secret \
    --namespace databases \
    --from-literal=redis-password='Redis#2024!' \
    --dry-run=client -o yaml \
    | kubeseal --format yaml > sealed-redis-secret-databases.yaml \
    || log_error "Error generando sealed-redis-secret-databases.yaml"
  log_success "sealed-redis-secret-databases.yaml generado"

  kubectl create secret generic redis-secret \
    --namespace wordpress \
    --from-literal=redis-password='Redis#2024!' \
    --dry-run=client -o yaml \
    | kubeseal --format yaml > sealed-redis-secret-wordpress.yaml \
    || log_error "Error generando sealed-redis-secret-wordpress.yaml"
  log_success "sealed-redis-secret-wordpress.yaml generado"

  log_success "Todos los SealedSecrets generados"
  log_warn "IMPORTANTE: Haz backup de la clave privada del clúster:"
  log_warn "  kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-master-key-backup.yaml"
  log_warn "  Guarda ese fichero en lugar seguro y NUNCA lo subas al repo."
}

# ============================================================
# FUNCIÓN auxiliar: eliminar namespace de forma segura
# Solo fuerza finalizers si se atasca en Terminating.
# Nunca actúa sobre namespaces en phase Active.
# ============================================================
delete_namespace_safe() {
  local ns=$1
  local timeout=${2:-30}
  local elapsed=0

  kubectl get namespace "$ns" &>/dev/null || return 0
  kubectl delete namespace "$ns" --ignore-not-found=true 2>/dev/null || true

  while [ $elapsed -lt $timeout ]; do
    kubectl get namespace "$ns" &>/dev/null || return 0
    local phase
    phase=$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    [ -z "$phase" ] && return 0
    echo -n "."
    sleep 2
    elapsed=$((elapsed + 2))
  done

  # Forzar finalizers si sigue en Terminating
  local phase
  phase=$(kubectl get namespace "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [ "$phase" = "Terminating" ]; then
    log_warn "Namespace '$ns' atascado — forzando finalizers..."
    kubectl get namespace "$ns" -o json 2>/dev/null       | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null       | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
    # Confirmar borrado
    local retries=0
    while kubectl get namespace "$ns" &>/dev/null; do
      retries=$((retries + 1))
      if [ $retries -ge 10 ]; then
        log_warn "Namespace '$ns' persiste. Si el deploy está pillado, ejecuta en otra terminal:"
        echo ""
        echo "  kubectl get namespace $ns -o json \\"
        echo "    | python3 -c \"import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))\" \\"
        echo "    | kubectl replace --raw \"/api/v1/namespaces/$ns/finalize\" -f -"
        echo ""
        return 0
      fi
      sleep 2
    done
  fi
  return 0
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
# FUNCIÓN: Esperar a que un StatefulSet esté Ready
# ============================================================
wait_for_statefulset() {
  local namespace=$1
  local sts=$2
  local timeout=${3:-120}

  log_info "Esperando a que StatefulSet '$sts' esté Ready en namespace '$namespace'..."
  kubectl rollout status statefulset/$sts -n $namespace --timeout=${timeout}s \
    && log_success "StatefulSet $sts está Ready" \
    || log_error "StatefulSet $sts no arrancó en ${timeout}s. Revisa: kubectl describe pod -n $namespace"
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

# ============================================================
# FUNCIÓN: Instalar Velero con backend MinIO
# ============================================================

# ============================================================
# FUNCIÓN: Instalar KEDA
# ============================================================
install_keda() {
  log_info "Instalando KEDA..."

  # Añadir repo Helm de KEDA
  helm repo add kedacore https://kedacore.github.io/charts 2>/dev/null || true
  helm repo update kedacore 2>/dev/null || true

  # Crear namespace keda
  kubectl create namespace keda --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

  # Instalar KEDA
  helm upgrade --install keda kedacore/keda \
    --namespace keda \
    --set image.keda.pullPolicy=Never \
    --set image.metricsApiServer.pullPolicy=Never \
    --set image.webhooks.pullPolicy=Never \
    --timeout 5m \
    || log_warn "KEDA helm install falló — continuando sin KEDA"

  wait_for_deployment "keda" "keda-operator" 240 || log_warn "keda-operator tardó más de lo esperado — puede seguir arrancando en segundo plano"
  log_success "KEDA instalado ✅"
  log_info "  Ver ScaledObjects: kubectl get scaledobject -A"
}

install_velero() {
  log_info "Instalando Velero con backend MinIO..."

  # Activar addons CSI necesarios para snapshots de PVCs
  # Timeout de 30s por addon — si se cuelga continuamos sin snapshots de PVC
  # (Velero seguirá funcionando para objetos K8s, solo sin snapshot de volúmenes)
  log_info "Activando addons CSI de Minikube (timeout 120s cada uno)..."

  if timeout 120s minikube addons enable volumesnapshots &>/dev/null 2>&1; then
    log_success "Addon volumesnapshots activado"
  else
    log_warn "Addon volumesnapshots tardó demasiado — Velero funcionará sin snapshots de PVC"
  fi

  if timeout 120s minikube addons enable csi-hostpath-driver &>/dev/null 2>&1; then
    log_success "Addon csi-hostpath-driver activado"
  else
    log_warn "Addon csi-hostpath-driver tardó demasiado — continuando sin él"
    log_warn "  Para activarlo manualmente después: minikube addons enable csi-hostpath-driver"
  fi

  # Añadir repo Helm de Velero
  helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts 2>/dev/null || true
  helm repo update vmware-tanzu 2>/dev/null || true

  # Limpiar namespace velero si quedó en Terminating de un intento anterior
  if kubectl get namespace velero &>/dev/null 2>&1; then
    local phase
    phase=$(kubectl get namespace velero -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$phase" = "Terminating" ]; then
      log_warn "Namespace velero en Terminating — forzando limpieza..."
      # Forzar eliminación de finalizers directamente
      kubectl get namespace velero -o json 2>/dev/null         | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))"         | kubectl replace --raw "/api/v1/namespaces/velero/finalize" -f - 2>/dev/null || true
      # Esperar a que desaparezca (máx 30s)
      local i=0
      while kubectl get namespace velero &>/dev/null 2>&1 && [ $i -lt 15 ]; do
        echo -n "."
        sleep 2
        i=$((i+1))
      done
      echo ""
      log_success "Namespace velero eliminado"
    fi
  fi

  # Crear namespace velero limpio
  sleep 2
  kubectl create namespace velero --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null || true

  # Crear bucket velero-backups en MinIO
  log_info "Creando bucket velero-backups en MinIO..."
  kubectl delete job velero-bucket-setup -n storage --ignore-not-found=true 2>/dev/null || true
  apply_file "19-velero.yaml" "Velero — bucket setup + NetworkPolicy"
  if ! kubectl wait --for=condition=complete job/velero-bucket-setup -n storage --timeout=60s 2>/dev/null; then
    log_warn "Job velero-bucket-setup no completó — verifica: kubectl logs -n storage job/velero-bucket-setup"
  else
    log_success "Bucket velero-backups creado en MinIO"
  fi

  # Obtener credenciales MinIO
  MINIO_ACCESS_KEY=$(kubectl get secret minio-secret -n storage -o jsonpath='{.data.access-key}' | base64 -d 2>/dev/null || echo "minioadmin")
  MINIO_SECRET_KEY=$(kubectl get secret minio-secret -n storage -o jsonpath='{.data.secret-key}' | base64 -d 2>/dev/null || echo "Minio#2024!")
  MINIO_URL="http://minio.storage.svc.cluster.local:9000"

  # Instalar Velero via Helm apuntando a MinIO
  # Nota: desde v1.13 configuration.provider fue eliminado,
  # el provider se configura por separado en cada backupStorageLocation.
  # Usamos fichero de valores temporal para evitar problemas con caracteres especiales.
  cat > /tmp/velero-values.yaml << HELMEOF
credentials:
  secretContents:
    cloud: |
      [default]
      aws_access_key_id=${MINIO_ACCESS_KEY}
      aws_secret_access_key=${MINIO_SECRET_KEY}

configuration:
  backupStorageLocation:
    - name: minio
      provider: aws
      bucket: velero-backups
      default: true
      config:
        region: minio
        s3ForcePathStyle: "true"
        s3Url: "${MINIO_URL}"
  volumeSnapshotLocation:
    - name: minio
      provider: aws
      config:
        region: minio

initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.8.2
    imagePullPolicy: Never
    volumeMounts:
      - mountPath: /target
        name: plugins

image:
  repository: velero/velero
  tag: v1.12.4
  pullPolicy: Never

features: "EnableCSI"
HELMEOF

  helm upgrade --install velero vmware-tanzu/velero \
    --namespace velero \
    --version 5.2.0 \
    --values /tmp/velero-values.yaml \
    --set upgradeCRDs=false \
    --timeout 5m \
    || log_warn "Velero helm install falló — continuando sin Velero"

  rm -f /tmp/velero-values.yaml

  wait_for_deployment "velero" "velero" 120

  # Crear schedule diario a la 1:00 AM
  log_info "Creando schedule de backup diario (1:00 AM)..."
  velero schedule create wordpress-daily \
    --schedule="0 1 * * *" \
    --include-namespaces wordpress,databases \
    --ttl 720h \
    2>/dev/null \
    || log_warn "Schedule velero ya existe o no se pudo crear"

  log_success "Velero instalado — backups diarios a la 1:00 AM"
  log_info "  Ver backups:    velero backup get"
  log_info "  Ver schedules:  velero schedule get"
  log_info "  Backup manual:  velero backup create manual-backup --include-namespaces wordpress,databases"
}


# ============================================================
# FUNCIÓN: Configurar minikube tunnel como servicio systemd
# Se ejecuta automáticamente al arrancar la máquina
# ============================================================
setup_tunnel_service() {
  local SERVICE_FILE="/etc/systemd/system/minikube-tunnel.service"
  local CURRENT_USER=$(whoami)
  local CURRENT_HOME=$(eval echo ~$CURRENT_USER)
  local MINIKUBE_PATH=$(which minikube)

  log_info "Configurando minikube tunnel como servicio systemd..."

  # El servicio debe correr como el usuario actual (no root)
  # porque necesita acceder al kubeconfig en ~/.kube/config
  sudo tee "$SERVICE_FILE" > /dev/null << UNIT
[Unit]
Description=Minikube Tunnel
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=${CURRENT_USER}
Environment="HOME=${CURRENT_HOME}"
Environment="KUBECONFIG=${CURRENT_HOME}/.kube/config"
ExecStartPre=/bin/sleep 5
ExecStart=${MINIKUBE_PATH} tunnel
ExecStop=/usr/bin/pkill -f "minikube tunnel"
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

  # Recargar systemd, habilitar e iniciar el servicio
  sudo systemctl daemon-reload
  sudo systemctl enable minikube-tunnel.service
  sudo systemctl restart minikube-tunnel.service

  # Verificar que arrancó
  sleep 5
  if sudo systemctl is-active --quiet minikube-tunnel.service; then
    log_success "Servicio minikube-tunnel activo y habilitado al arranque ✅"
    log_info "  Ver estado:  sudo systemctl status minikube-tunnel"
    log_info "  Ver logs:    sudo journalctl -u minikube-tunnel -f"
    log_info "  Parar:       sudo systemctl stop minikube-tunnel"
  else
    log_warn "Servicio systemd no arrancó — lanzando tunnel en segundo plano..."
    nohup minikube tunnel > /tmp/minikube-tunnel.log 2>&1 &
    log_info "  Logs del tunnel: tail -f /tmp/minikube-tunnel.log"
    sleep 5
  fi
}

update_hosts() {
  log_info "Obteniendo IP externa del Ingress Controller..."

  local retries=0
  local EXTERNAL_IP=""
  until [ -n "$EXTERNAL_IP" ] && [ "$EXTERNAL_IP" != "<pending>" ]; do
    retries=$((retries + 1))
    [ $retries -ge 18 ] && log_error "No se asignó EXTERNAL-IP. Asegúrate de tener 'minikube tunnel' corriendo en otra terminal."
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
  sudo sed -i '/minio\.storage\.local/d' /etc/hosts
  sudo sed -i '/minio\.storage\.local/d' /etc/hosts

  echo "$EXTERNAL_IP wp-k8s.local"               | sudo tee -a /etc/hosts > /dev/null
  echo "$EXTERNAL_IP grafana.monitoring.local"    | sudo tee -a /etc/hosts > /dev/null
  echo "$EXTERNAL_IP prometheus.monitoring.local" | sudo tee -a /etc/hosts > /dev/null
  echo "$EXTERNAL_IP minio.storage.local"         | sudo tee -a /etc/hosts > /dev/null

  log_success "/etc/hosts actualizado correctamente"
}

# ============================================================
# FUNCIÓN: CLEANUP robusto (no se queda colgado en Terminating)
# ============================================================
cleanup() {
  echo ""
  echo -e "${RED}============================================================${NC}"
  echo -e "${RED}   CLEANUP - Eliminando todo el despliegue${NC}"
  echo -e "${RED}============================================================${NC}"
  echo ""

  # 0. Reiniciar Metrics Server para evitar "stale GroupVersion discovery"
  # que bloquea el borrado de namespaces con Terminating indefinido
  log_info "Reiniciando Metrics Server para limpiar API stale..."
  kubectl rollout restart deployment metrics-server -n kube-system 2>/dev/null || true
  sleep 10
  kubectl delete apiservice v1beta1.metrics.k8s.io --ignore-not-found=true 2>/dev/null || true
  sleep 5
  log_success "Metrics Server reiniciado"

  # 1. Bajar replicas a 0 para liberar PVCs antes de borrarlos
  log_info "Bajando replicas a 0 en todos los namespaces..."
  for ns in wordpress databases monitoring; do
    kubectl scale deployment  --all -n $ns --replicas=0 2>/dev/null || true
    kubectl scale statefulset --all -n $ns --replicas=0 2>/dev/null || true
  done
  sleep 5
  log_success "Replicas a 0"

  # 2. Eliminar PVCs (quitar finalizers primero)
  log_info "Eliminando PVCs..."
  for ns in wordpress databases monitoring; do
    for pvc in $(kubectl get pvc -n $ns -o name 2>/dev/null); do
      kubectl patch $pvc -n $ns -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
      kubectl delete $pvc -n $ns --grace-period=0 --force 2>/dev/null || true
    done
  done
  log_success "PVCs eliminados"

  # 3. Eliminar namespaces del proyecto
  log_info "Eliminando namespaces del proyecto..."
  for ns in wordpress databases monitoring security; do
    delete_namespace_safe "$ns" 20
  done
  echo ""
  log_success "Namespaces eliminados"

  # 4. Eliminar Ingress Controller
  log_info "Eliminando Ingress Controller..."
  delete_namespace_safe "ingress-nginx" 20
  echo ""
  log_success "Ingress Controller eliminado"

  # 5. Eliminar kube-state-metrics
  log_info "Eliminando kube-state-metrics..."
  kubectl delete deployment    kube-state-metrics -n kube-system --ignore-not-found=true 2>/dev/null || true
  kubectl delete service       kube-state-metrics -n kube-system --ignore-not-found=true 2>/dev/null || true
  kubectl delete serviceaccount kube-state-metrics -n kube-system --ignore-not-found=true 2>/dev/null || true
  kubectl delete clusterrole        kube-state-metrics --ignore-not-found=true 2>/dev/null || true
  kubectl delete clusterrolebinding kube-state-metrics --ignore-not-found=true 2>/dev/null || true
  log_success "kube-state-metrics eliminado"

  # 6. Eliminar Sealed Secrets Controller
  # NOTA: Los ficheros sealed-*.yaml NO se borran automáticamente.
  # Si haces 'minikube delete', bórralos manualmente antes del siguiente deploy.sh
  log_info "Eliminando Sealed Secrets Controller..."
  SS_VERSION="0.26.3"
  kubectl delete -f "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${SS_VERSION}/controller.yaml" \
    --ignore-not-found=true 2>/dev/null || true
  log_success "Sealed Secrets Controller eliminado"

  # 7. Eliminar ClusterRoles del proyecto
  log_info "Eliminando ClusterRoles y ClusterRoleBindings del proyecto..."
  kubectl delete clusterrole        prometheus --ignore-not-found=true 2>/dev/null || true
  kubectl delete clusterrolebinding prometheus --ignore-not-found=true 2>/dev/null || true
  kubectl delete clusterrole        promtail   --ignore-not-found=true 2>/dev/null || true
  kubectl delete clusterrolebinding promtail   --ignore-not-found=true 2>/dev/null || true
  log_success "ClusterRoles eliminados"

  # 8. Eliminar PersistentVolumes huérfanos
  log_info "Eliminando PersistentVolumes huérfanos..."
  for pv in $(kubectl get pv -o name 2>/dev/null); do
    kubectl patch $pv -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
    kubectl delete $pv --grace-period=0 --force 2>/dev/null || true
  done
  log_success "PersistentVolumes eliminados"

  # 9. Limpiar datos de Prometheus en Minikube (evita lockfile en redespliegue)
  log_info "Limpiando datos de Prometheus en Minikube..."
  minikube ssh "sudo rm -rf /tmp/hostpath-provisioner/monitoring/ 2>/dev/null; echo ok" 2>/dev/null || true
  log_success "Datos de Prometheus limpiados"

  # 10. Limpiar /etc/hosts
  log_info "Limpiando /etc/hosts..."
  sudo sed -i '/wp-k8s\.local/d' /etc/hosts
  sudo sed -i '/grafana\.monitoring\.local/d' /etc/hosts
  sudo sed -i '/prometheus\.monitoring\.local/d' /etc/hosts
  sudo sed -i '/minio\.storage\.local/d' /etc/hosts
  log_success "/etc/hosts limpiado"

  # 11. Esperar a que los namespaces desaparezcan (máx 30s, luego forzar)
  log_info "Verificando que los namespaces han desaparecido..."
  local TIMEOUT=30
  local ELAPSED=0
  while kubectl get namespaces 2>/dev/null | grep -qE "wordpress|databases|monitoring|security"; do
    if [ $ELAPSED -ge $TIMEOUT ]; then
      log_warn "Forzando finalizers en namespaces restantes..."
      for ns in wordpress databases monitoring security; do
        PHASE11=$(kubectl get namespace $ns -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [ "$PHASE11" = "Terminating" ]; then
          kubectl get namespace $ns -o json 2>/dev/null \
            | python3 -c "import sys,json; d=json.load(sys.stdin); d['spec']['finalizers']=[]; print(json.dumps(d))" 2>/dev/null \
            | kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
        fi
      done
      break
    fi
    echo -n "."
    sleep 2
    ELAPSED=$((ELAPSED + 2))
  done
  echo ""

  echo ""
  echo -e "${GREEN}============================================================${NC}"
  echo -e "${GREEN}   ✅ Cleanup completado${NC}"
  echo -e "${GREEN}============================================================${NC}"
  echo ""
  echo -e "${BLUE}Para volver a desplegar:${NC}  ./deploy.sh"
  echo -e "${BLUE}Para reset completo:${NC}      minikube stop && minikube delete && minikube start"
  echo ""
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

# set -e solo en el deploy (no en cleanup, donde los errores son esperados)
set -e

# 1. Verificaciones previas
check_requirements
echo ""

# 2. Cargar imágenes en Minikube
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

# 6. Sealed Secrets Controller
install_sealed_secrets
echo ""

# 7. kubeseal CLI
install_kubeseal
echo ""

# 8. cert-manager
install_cert_manager
echo ""

# 9. Namespaces
apply_file "00-namespace.yaml" "Namespaces (security, wordpress, databases, monitoring)"
sleep 2

# 10. Generar SealedSecrets (requiere namespaces y controller activos)
generate_sealed_secrets
echo ""

# 11. Aplicar SealedSecrets (el controller los descifra y crea los Secrets reales)
apply_file "sealed-mariadb-secret-databases.yaml" "SealedSecret MariaDB (databases)"
apply_file "sealed-mariadb-secret-wordpress.yaml"  "SealedSecret MariaDB (wordpress)"
apply_file "sealed-redis-secret-databases.yaml"    "SealedSecret Redis (databases)"
apply_file "sealed-redis-secret-wordpress.yaml"    "SealedSecret Redis (wordpress)"

# 12. ConfigMaps
apply_file "02-configmap.yaml" "ConfigMaps (mariadb-config + wordpress-config)"

# 13. PVCs
apply_file "03-pvc.yaml" "PersistentVolumeClaims (wordpress-pvc)"

# 14. MariaDB HA (primary + replica)
# Si existe un StatefulSet previo con spec diferente, hay que borrarlo antes
# (kubectl apply no puede cambiar campos inmutables como volumeClaimTemplates)
if kubectl get statefulset mariadb -n databases &>/dev/null; then
  CURRENT_REPLICAS=$(kubectl get statefulset mariadb -n databases -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [ "$CURRENT_REPLICAS" != "2" ]; then
    log_warn "StatefulSet mariadb existente con spec diferente — recreando..."
    kubectl delete statefulset mariadb -n databases --cascade=orphan 2>/dev/null || true
    sleep 5
  fi
fi
apply_file "04-mariadb.yaml" "MariaDB HA — StatefulSet (primary + replica)"
wait_for_statefulset "databases" "mariadb" 180

# Lanzar Job que configura la replicación una vez ambos pods están listos
log_info "Configurando replicación MariaDB..."
kubectl delete job mariadb-replication-setup -n databases --ignore-not-found=true 2>/dev/null || true
apply_file "04b-mariadb-replication-job.yaml" "Job de configuración de replicación MariaDB"
# Esperar a que el Job complete
if kubectl wait --for=condition=complete job/mariadb-replication-setup -n databases --timeout=120s 2>/dev/null; then
  log_success "Replicación MariaDB configurada"
else
  log_warn "El Job de replicación no completó en 120s — verifica con: kubectl logs -n databases job/mariadb-replication-setup"
fi

# 15. Redis HA con Sentinel
apply_file "05-redis.yaml" "Redis HA — StatefulSet (1 master + 2 replicas) + Sentinel sidecars"
wait_for_statefulset "databases" "redis" 120

# 16. MinIO (almacenamiento S3 para uploads WordPress)
apply_file "16-minio.yaml" "MinIO — almacenamiento S3 para uploads WordPress stateless"
wait_for_deployment "storage" "minio" 60

# Backup (CronJobs: MariaDB 2AM + Uploads 3AM + Limpieza domingos 4AM)
apply_file "18-backup.yaml" "CronJobs backup → MinIO (RPO: 24h, RTO: ~15min)"
log_info "Configurando buckets MinIO..."
kubectl delete job minio-setup -n storage --ignore-not-found=true 2>/dev/null || true
if kubectl wait --for=condition=complete job/minio-setup -n storage --timeout=60s 2>/dev/null; then
  log_success "Buckets MinIO creados"
else
  log_warn "Job minio-setup no completó — verifica con: kubectl logs -n storage job/minio-setup"
fi

# 17. WordPress
apply_file "06-wordpress.yaml" "Deployment + Service de WordPress"
wait_for_deployment "wordpress" "wordpress" 120

# 17. NetworkPolicies
apply_file "07-network-policy.yaml" "NetworkPolicies (databases + wordpress + monitoring)"

# 18. cert-manager ClusterIssuers + Certificados
apply_cert_manager_config
echo ""

# 19. Ingress (con TLS habilitado)
apply_file "08-ingress.yaml" "Ingress con TLS (wp-k8s.local + monitoring.local)"

# 20. HPA
# 21. KEDA — reemplaza el HPA por escalado basado en métricas de Prometheus
install_keda
# Si el ScaledObject ya existe, KEDA ya está gestionando el escalado → saltar
if kubectl get scaledobject wordpress-scaledobject -n wordpress &>/dev/null 2>&1; then
  log_success "KEDA ScaledObject ya existe — saltando"
else
  # Eliminar HPA anterior si existe — KEDA no puede coexistir con un HPA manual
  if kubectl get hpa wordpress-hpa -n wordpress &>/dev/null 2>&1; then
    log_info "Eliminando HPA anterior para que KEDA tome el control..."
    kubectl delete hpa wordpress-hpa -n wordpress 2>/dev/null || true
    log_success "HPA eliminado"
  fi
  apply_file "09-keda-wordpress.yaml" "KEDA ScaledObject WordPress (min:2 max:10, trigger: req/s + CPU)"
fi

# 21. PDB
apply_file "13-pdb.yaml" "PodDisruptionBudget de WordPress"

# 22. ResourceQuota + LimitRange
apply_file "14-resource-quota.yaml" "ResourceQuota y LimitRange"

# 23. Prometheus + Alertmanager
apply_file "10-prometheus.yaml" "Prometheus + Alertmanager (RBAC + ConfigMap + Deployment + Service)"
wait_for_deployment "monitoring" "prometheus" 120
wait_for_deployment "monitoring" "alertmanager" 60

# 24. Loki + Promtail
apply_file "11-loki.yaml" "Loki + Promtail (Deployment + DaemonSet)"
wait_for_deployment "monitoring" "loki" 120

# 25. Jaeger + OTel Collector (tracing distribuido)
apply_file "17-tracing.yaml" "Jaeger all-in-one + OTel Collector DaemonSet"
wait_for_deployment "monitoring" "jaeger" 60

# 26. Backup CronJobs (MariaDB + uploads → MinIO)
apply_file "18-backup.yaml" "CronJobs de backup — MariaDB y uploads a MinIO"

# 27. Grafana
apply_file "12-grafana.yaml" "Grafana (Deployment + Service)"
wait_for_deployment "monitoring" "grafana" 120

# 28. Velero — backup completo del clúster con MinIO como backend
install_velero


# ============================================================
# TUNNEL Y /etc/hosts
# ============================================================
echo ""
log_info "Esperando a que el tunnel asigne IP y actualizando /etc/hosts..."
echo ""

update_hosts

# ============================================================
# RESUMEN FINAL
# ============================================================
echo ""
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          ✅  Despliegue completado con éxito                    ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# --- Backups ---
echo -e "${BLUE}💾  Estrategia de backup${NC}"
echo ""
echo -e "    MariaDB dump    Diario a las 2:00 AM → MinIO (wordpress-backups/mariadb/)"
echo -e "    Uploads WP      Diario a las 3:00 AM → MinIO (wordpress-backups/uploads/)"
echo -e "    Limpieza        Domingos 4:00 AM → borra backups >30 días"
echo -e "    Velero          Diario a la 1:00 AM → snapshot completo del clúster"
echo -e "    RPO             ~24 horas  |  RTO  ~15 minutos"
echo ""
echo -e "    Ver backups Velero:    velero backup get"
echo -e "    Backup manual:        velero backup create manual --include-namespaces wordpress,databases"
echo -e "    Restaurar:            velero restore create --from-backup <nombre-backup>"
echo -e "    Restaurar en test:    velero restore create --from-backup <nombre> --namespace-mappings wordpress:wordpress-restore"
echo ""

# --- Arquitectura ---
echo -e "${BLUE}🏗️   Arquitectura desplegada${NC}"
echo ""
echo -e "    WordPress HA    2 réplicas (KEDA min:2 max:10) + PDB"
echo -e "    MariaDB HA      Primary + Replica con replicación activa"
echo -e "    Redis HA        1 master + 2 réplicas + 3 Sentinels"
echo -e "    MinIO           Almacenamiento S3 para uploads y backups"
echo -e "    Cert-manager    TLS self-signed automático"
echo -e "    Sealed Secrets  Secretos cifrados en el repositorio"
echo -e "    Prometheus      Métricas + SLOs + Alertmanager (Slack)"
echo -e "    Loki + Promtail Logs centralizados"
echo -e "    Grafana         Dashboards + datasources integrados"
echo -e "    Jaeger + OTel   Trazas distribuidas"
echo -e "    KEDA            Escalado por req/s (Prometheus) + CPU fallback"
echo -e "    Velero          Backup completo del clúster (diario 1:00 AM)"
echo -e "    NetworkPolicies 19 políticas de red"
echo ""

# --- URLs ---
echo -e "${BLUE}🌐  URLs de acceso${NC}"
echo -e "    Para acceder a las URLs abre una terminal nueva y ejecuta:"
echo -e "    ${GREEN}minikube tunnel${NC}"
echo ""
echo -e "    ${GREEN}WordPress${NC}   →  https://wp-k8s.local"
echo -e "                   HTTP redirige a HTTPS automáticamente"
echo ""
echo -e "    ${GREEN}Grafana${NC}     →  https://grafana.monitoring.local"
echo -e "                   usuario: admin  |  contraseña: admin123"
echo -e "                   Datasources: Prometheus + Loki + Jaeger"
echo ""
echo -e "    ${GREEN}Prometheus${NC}  →  https://prometheus.monitoring.local"
echo -e "                   Alertmanager incluido en el mismo pod"
echo ""
echo -e "    ${GREEN}MinIO${NC}       →  http://minio.storage.local"
echo -e "                   usuario: minioadmin  |  contraseña: Minio#2024!"
echo -e "                   Buckets: wordpress-uploads, wordpress-backups"
echo ""
echo -e "    ${GREEN}Jaeger${NC}      →  kubectl port-forward -n monitoring svc/jaeger-query 16686:16686"
echo -e "                   Luego abre: http://localhost:16686"
echo ""

# --- Comandos útiles ---
echo -e "${BLUE}🔧  Comandos útiles${NC}"
echo ""
echo -e "    Ver todos los pods:       kubectl get pods -A"
echo -e "    Estado del escalado:      kubectl get scaledobject -n wordpress"
echo -e "    Logs WordPress:           kubectl logs -n wordpress -l app=wordpress -f"
echo -e "    Logs MariaDB:             kubectl logs -n databases -l app=mariadb -f"
echo -e "    Logs Redis:               kubectl logs -n databases -l app=redis -f"
echo -e "    Estado replicación:       kubectl exec -n databases mariadb-1 -- mysql -u root -p'RootDB#2024!' -e 'SHOW SLAVE STATUS\G' 2>/dev/null | grep -E 'Running|Behind'"
echo -e "    Ver NetworkPolicies:      kubectl get networkpolicy -A"
echo -e "    Ver SealedSecrets:        kubectl get sealedsecret -A"
echo -e "    Ver certificados TLS:     kubectl get certificate -A"
echo -e "    Escalar WordPress:        kubectl scale deployment wordpress -n wordpress --replicas=3"
echo -e "    Deshacer todo:            ./deploy.sh --cleanup"
echo ""
