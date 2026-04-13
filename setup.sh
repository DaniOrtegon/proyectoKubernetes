#!/bin/bash
# ============================================================
# setup.sh — Configuración inicial de contraseñas
#
# Lee el archivo .env y propaga las contraseñas a:
#   - redis.yaml       (ConfigMap con requirepass/masterauth/sentinel)
#   - minio.yaml       (Secret stringData)
#   - grafana.yaml     (Secret base64)
#   - deploy.sh        (generate_sealed_secrets con las passwords correctas)
#
# USO:
#   cp .env.example .env
#   nano .env          # edita las contraseñas
#   ./setup.sh         # aplica los cambios
#   ./deploy.sh        # despliega
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
echo -e "${BLUE}   KubeNet — Configuración de contraseñas${NC}"
echo -e "${BLUE}============================================================${NC}"
echo ""

# ============================================================
# 1. Cargar .env
# ============================================================
ENV_FILE="$(dirname "$0")/.env"

if [ ! -f "$ENV_FILE" ]; then
  log_warn "No se encontró el archivo .env"
  log_info "Creando .env a partir de .env.example..."
  cp "$(dirname "$0")/.env.example" "$ENV_FILE"
  echo ""
  echo -e "${YELLOW}  Edita el archivo .env con tus contraseñas y vuelve a ejecutar setup.sh:${NC}"
  echo -e "  ${GREEN}nano .env${NC}"
  echo -e "  ${GREEN}./setup.sh${NC}"
  echo ""
  exit 0
fi

log_info "Cargando contraseñas desde .env..."
# Carga el .env ignorando líneas comentadas o vacías.
# Las contraseñas pueden contener # — NO se quitan los comentarios inline
# porque las passwords del proyecto usan # como carácter (ej: RootDB#2026!)
while IFS='=' read -r key value; do
  # Ignorar líneas vacías o que empiezan por #
  [[ "$key" =~ ^[[:space:]]*#.*$ || -z "$key" ]] && continue
  # Trim de espacios al inicio y al final del valor
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  export "$key=$value"
done < "$ENV_FILE"

# Verificar que las variables obligatorias están definidas
REQUIRED_VARS=(
  MARIADB_ROOT_PASSWORD
  MARIADB_USER_PASSWORD
  REDIS_PASSWORD
  MINIO_ROOT_USER
  MINIO_ROOT_PASSWORD
  GRAFANA_ADMIN_USER
  GRAFANA_ADMIN_PASSWORD
)

for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var}" ]; then
    log_error "La variable $var está vacía en .env. Revisa el archivo."
  fi
done

log_success "Contraseñas cargadas correctamente"
echo ""

# ============================================================
# FUNCIÓN: reemplazar un valor en un archivo YAML/SH de forma segura
# Usa un delimitador alternativo (|) para evitar conflictos con / en passwords
# ============================================================
replace_in_file() {
  local file="$1"
  local pattern="$2"
  local replacement="$3"
  # Escapar caracteres especiales del replacement para sed
  local escaped
  escaped=$(printf '%s\n' "$replacement" | sed 's/[[\.*^$()+?{|]/\\&/g')
  sed -i "s|${pattern}|${escaped}|g" "$file"
}

# ============================================================
# 2. Parchear redis.yaml
# Sustituye la contraseña hardcodeada en el ConfigMap de Redis
# ============================================================
REDIS_YAML="$(dirname "$0")/k8s/data/redis.yaml"
log_info "Parcheando redis.yaml..."

# Hacemos backup si no existe ya
[ ! -f "${REDIS_YAML}.bak" ] && cp "$REDIS_YAML" "${REDIS_YAML}.bak"

# Extraer la contraseña actual del backup para reemplazarla
CURRENT_REDIS_PASS=$(grep -m1 'requirepass ' "${REDIS_YAML}.bak" | awk '{print $2}')

if [ -n "$CURRENT_REDIS_PASS" ] && [ "$CURRENT_REDIS_PASS" != "$REDIS_PASSWORD" ]; then
  # Reemplazar todas las ocurrencias de la contraseña anterior por la nueva
  sed -i "s|requirepass ${CURRENT_REDIS_PASS}|requirepass ${REDIS_PASSWORD}|g" "$REDIS_YAML"
  sed -i "s|masterauth ${CURRENT_REDIS_PASS}|masterauth ${REDIS_PASSWORD}|g" "$REDIS_YAML"
  sed -i "s|sentinel auth-pass mymaster ${CURRENT_REDIS_PASS}|sentinel auth-pass mymaster ${REDIS_PASSWORD}|g" "$REDIS_YAML"
  sed -i "s|redis-cli -a '${CURRENT_REDIS_PASS}'|redis-cli -a '${REDIS_PASSWORD}'|g" "$REDIS_YAML"
  log_success "redis.yaml actualizado"
elif [ "$CURRENT_REDIS_PASS" = "$REDIS_PASSWORD" ]; then
  log_success "redis.yaml ya tiene la contraseña correcta — sin cambios"
else
  log_warn "No se encontró la contraseña anterior en redis.yaml — verifica manualmente"
fi

# ============================================================
# 3. Parchear minio.yaml
# Sustituye las credenciales de MinIO en los Secrets stringData
# ============================================================
MINIO_YAML="$(dirname "$0")/k8s/storage/minio.yaml"
log_info "Parcheando minio.yaml..."

[ ! -f "${MINIO_YAML}.bak" ] && cp "$MINIO_YAML" "${MINIO_YAML}.bak"

# Leer valores actuales del backup
CURRENT_MINIO_USER=$(grep -m1 'root-user:' "${MINIO_YAML}.bak" | awk '{print $2}')
CURRENT_MINIO_PASS=$(grep -m1 'root-password:' "${MINIO_YAML}.bak" | awk '{print $2}')

# Reemplazar usuario root
if [ -n "$CURRENT_MINIO_USER" ]; then
  sed -i "s|root-user: ${CURRENT_MINIO_USER}|root-user: ${MINIO_ROOT_USER}|g" "$MINIO_YAML"
fi
# Reemplazar contraseña root
if [ -n "$CURRENT_MINIO_PASS" ]; then
  sed -i "s|root-password: ${CURRENT_MINIO_PASS}|root-password: ${MINIO_ROOT_PASSWORD}|g" "$MINIO_YAML"
fi
# Reemplazar access-key y secret-key (usan los mismos valores en este proyecto)
CURRENT_ACCESS=$(grep -m1 'access-key:' "${MINIO_YAML}.bak" | awk '{print $2}')
CURRENT_SECRET=$(grep -m1 'secret-key:' "${MINIO_YAML}.bak" | awk '{print $2}')
[ -n "$CURRENT_ACCESS" ] && sed -i "s|access-key: ${CURRENT_ACCESS}|access-key: ${MINIO_ROOT_USER}|g" "$MINIO_YAML"
[ -n "$CURRENT_SECRET" ] && sed -i "s|secret-key: ${CURRENT_SECRET}|secret-key: ${MINIO_ROOT_PASSWORD}|g" "$MINIO_YAML"

log_success "minio.yaml actualizado"

# ============================================================
# 4. Parchear grafana.yaml
# El secret de Grafana usa base64 directamente en el YAML
# ============================================================
GRAFANA_YAML="$(dirname "$0")/k8s/observability/grafana.yaml"
log_info "Parcheando grafana.yaml..."

[ ! -f "${GRAFANA_YAML}.bak" ] && cp "$GRAFANA_YAML" "${GRAFANA_YAML}.bak"

GRAFANA_USER_B64=$(echo -n "$GRAFANA_ADMIN_USER"     | base64)
GRAFANA_PASS_B64=$(echo -n "$GRAFANA_ADMIN_PASSWORD" | base64)

# Leer valores actuales del backup
CURRENT_USER_B64=$(grep 'admin-user:'     "${GRAFANA_YAML}.bak" | awk '{print $2}')
CURRENT_PASS_B64=$(grep 'admin-password:' "${GRAFANA_YAML}.bak" | awk '{print $2}')

[ -n "$CURRENT_USER_B64" ] && sed -i "s|admin-user: ${CURRENT_USER_B64}|admin-user: ${GRAFANA_USER_B64}|g" "$GRAFANA_YAML"
[ -n "$CURRENT_PASS_B64" ] && sed -i "s|admin-password: ${CURRENT_PASS_B64}|admin-password: ${GRAFANA_PASS_B64}|g" "$GRAFANA_YAML"

log_success "grafana.yaml actualizado"

# ============================================================
# 5. Parchear deploy.sh
# Sustituye las contraseñas hardcodeadas en generate_sealed_secrets()
# y en los mensajes del resumen final
# ============================================================
DEPLOY_SH="$(dirname "$0")/deploy.sh"
log_info "Parcheando deploy.sh..."

[ ! -f "${DEPLOY_SH}.bak" ] && cp "$DEPLOY_SH" "${DEPLOY_SH}.bak"

# Leer valores actuales del backup
CURRENT_MARIADB_ROOT=$(grep -m1 "mariadb-root-password='" "${DEPLOY_SH}.bak" | sed "s/.*mariadb-root-password='\\([^']*\\)'.*/\\1/")
CURRENT_MARIADB_USER=$(grep -m1 "mariadb-user-password='" "${DEPLOY_SH}.bak" | sed "s/.*mariadb-user-password='\\([^']*\\)'.*/\\1/")
CURRENT_REDIS_IN_SH=$(grep -m1 "redis-password='" "${DEPLOY_SH}.bak" | sed "s/.*redis-password='\\([^']*\\)'.*/\\1/")

# MariaDB root
[ -n "$CURRENT_MARIADB_ROOT" ] && \
  sed -i "s|mariadb-root-password='${CURRENT_MARIADB_ROOT}'|mariadb-root-password='${MARIADB_ROOT_PASSWORD}'|g" "$DEPLOY_SH"

# MariaDB user (múltiples ocurrencias)
[ -n "$CURRENT_MARIADB_USER" ] && \
  sed -i "s|mariadb-user-password='${CURRENT_MARIADB_USER}'|mariadb-user-password='${MARIADB_USER_PASSWORD}'|g" "$DEPLOY_SH"

# Redis
[ -n "$CURRENT_REDIS_IN_SH" ] && \
  sed -i "s|redis-password='${CURRENT_REDIS_IN_SH}'|redis-password='${REDIS_PASSWORD}'|g" "$DEPLOY_SH"

# Actualizar también los mensajes del resumen final (echo con contraseñas en texto)
CURRENT_MINIO_SUMMARY=$(grep "minioadmin.*Minio" "${DEPLOY_SH}.bak" | grep -o "contraseña: [^'\"]*" | head -1 | sed 's/contraseña: //')
if [ -n "$CURRENT_MINIO_SUMMARY" ]; then
  sed -i "s|contraseña: ${CURRENT_MINIO_SUMMARY}|contraseña: ${MINIO_ROOT_PASSWORD}|g" "$DEPLOY_SH"
fi

# Actualizar contraseña en el comando de ejemplo de replicación del resumen
CURRENT_ROOT_ECHO=$(grep "mysql -u root -p'" "${DEPLOY_SH}.bak" | head -1 | sed "s/.*-p'\\([^']*\\)'.*/\\1/")
[ -n "$CURRENT_ROOT_ECHO" ] && \
  sed -i "s|-p'${CURRENT_ROOT_ECHO}'|-p'${MARIADB_ROOT_PASSWORD}'|g" "$DEPLOY_SH"

log_success "deploy.sh actualizado"

# ============================================================
# 6. Añadir .env al .gitignore si no está ya
# ============================================================
GITIGNORE="$(dirname "$0")/.gitignore"
if [ ! -f "$GITIGNORE" ] || ! grep -q "^\.env$" "$GITIGNORE"; then
  echo ".env" >> "$GITIGNORE"
  echo "*.bak" >> "$GITIGNORE"
  echo "sealed-secrets-backup-*/" >> "$GITIGNORE"
  log_success ".env añadido a .gitignore"
fi

# ============================================================
# RESUMEN
# ============================================================
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}   ✅  Configuración completada${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "  Archivos actualizados:"
echo -e "    ${GREEN}✓${NC} k8s/data/redis.yaml"
echo -e "    ${GREEN}✓${NC} k8s/storage/minio.yaml"
echo -e "    ${GREEN}✓${NC} k8s/observability/grafana.yaml"
echo -e "    ${GREEN}✓${NC} deploy.sh"
echo ""
echo -e "  Los archivos originales tienen copia de seguridad en ${YELLOW}*.bak${NC}"
echo ""
echo -e "${BLUE}  Siguiente paso → despliega el proyecto:${NC}"
echo -e "  ${GREEN}./deploy.sh${NC}"
echo ""
