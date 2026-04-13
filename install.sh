#!/bin/bash
# ============================================================
# install.sh — Instalación de dependencias para KubeNet
# Distro: Ubuntu / Debian
#
# Instala:
#   - Docker
#   - kubectl
#   - Minikube
#   - Helm
#
# USO:
#   chmod +x install.sh
#   ./install.sh
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

echo ""
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}   KubeNet — Instalación de dependencias${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ============================================================
# Verificar que es Ubuntu/Debian
# ============================================================
if ! command -v apt-get &>/dev/null; then
  log_error "Este script requiere Ubuntu o Debian (apt-get no encontrado)."
fi

# ============================================================
# Verificar que no se ejecuta como root
# ============================================================
if [ "$EUID" -eq 0 ]; then
  log_error "No ejecutes este script como root. Usa tu usuario normal — se pedirá sudo cuando sea necesario."
fi

# ============================================================
# 1. Docker
# ============================================================
install_docker() {
  if command -v docker &>/dev/null; then
    log_success "Docker ya está instalado: $(docker --version)"
    return
  fi

  log_info "Instalando Docker..."
  sudo apt-get update -q
  sudo apt-get install -y -q ca-certificates curl gnupg lsb-release

  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

  sudo apt-get update -q
  sudo apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Añadir el usuario actual al grupo docker para no necesitar sudo
  sudo usermod -aG docker "$USER"

  log_success "Docker instalado: $(docker --version)"
  log_warn "IMPORTANTE: Para usar Docker sin sudo, cierra sesión y vuelve a entrar (o ejecuta: newgrp docker)"
}

# ============================================================
# 2. kubectl
# ============================================================
install_kubectl() {
  if command -v kubectl &>/dev/null; then
    log_success "kubectl ya está instalado: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
    return
  fi

  log_info "Instalando kubectl..."
  local KUBECTL_VERSION
  KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)

  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl

  log_success "kubectl instalado: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
}

# ============================================================
# 3. Minikube
# ============================================================
install_minikube() {
  if command -v minikube &>/dev/null; then
    log_success "Minikube ya está instalado: $(minikube version --short)"
    return
  fi

  log_info "Instalando Minikube..."
  curl -fsSLo /tmp/minikube "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64"
  sudo install -o root -g root -m 0755 /tmp/minikube /usr/local/bin/minikube
  rm -f /tmp/minikube

  log_success "Minikube instalado: $(minikube version --short)"
}

# ============================================================
# 4. Helm
# ============================================================
install_helm() {
  if command -v helm &>/dev/null; then
    log_success "Helm ya está instalado: $(helm version --short)"
    return
  fi

  log_info "Instalando Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

  log_success "Helm instalado: $(helm version --short)"
}

# ============================================================
# MAIN
# ============================================================
install_docker
echo ""
install_kubectl
echo ""
install_minikube
echo ""
install_helm
echo ""

# ============================================================
# RESUMEN
# ============================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   ✅  Dependencias instaladas correctamente${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  ${GREEN}✓${NC} Docker     $(docker --version 2>/dev/null || echo 'instalado — reinicia sesión para activar')"
echo -e "  ${GREEN}✓${NC} kubectl    $(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"
echo -e "  ${GREEN}✓${NC} Minikube   $(minikube version --short 2>/dev/null)"
echo -e "  ${GREEN}✓${NC} Helm       $(helm version --short 2>/dev/null)"
echo ""
echo -e "${YELLOW}  Si acabas de instalar Docker, cierra sesión y vuelve a entrar antes de continuar.${NC}"
echo -e "${YELLOW}  Esto es necesario para que tu usuario pueda usar Docker sin sudo.${NC}"
echo ""
echo -e "${BLUE}  Siguiente paso → configura las contraseñas:${NC}"
echo -e "  ${GREEN}./setup.sh${NC}"
echo ""
