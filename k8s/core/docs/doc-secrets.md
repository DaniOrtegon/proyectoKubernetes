# secrets.yaml — Documento de referencia

## ¿Qué hace este archivo?

Define los **Secrets de Kubernetes** que contienen las credenciales del proyecto: contraseñas de MariaDB y Redis. Es un archivo de fallback para entornos donde Sealed Secrets no está disponible.

---

## ⚠️ Advertencia de seguridad

El base64 **no es cifrado**. Es simplemente una codificación que cualquiera puede revertir en segundos:

```bash
echo "Um9vdERCIzIwMjQh" | base64 -d
# RootDB#2026!
```

Este archivo **nunca debe subirse a un repositorio Git**. En el proyecto, los secrets reales se gestionan con **Sealed Secrets** — los archivos `sealed-*.yaml` que genera el `deploy.sh` — que sí están cifrados con la clave RSA del clúster y son seguros para guardar en el repositorio.

---

## Secrets definidos

| Secret | Namespace | Campos | Usado por |
|--------|-----------|--------|-----------|
| `mariadb-secret` | `databases` | `mariadb-root-password`, `mariadb-user-password` | StatefulSet MariaDB |
| `mariadb-secret` | `wordpress` | `mariadb-user-password` | Deployment WordPress |
| `redis-secret` | `databases` | `redis-password` | StatefulSet Redis + Sentinel |
| `redis-secret` | `wordpress` | `redis-password` | Deployment WordPress |

---

## ¿Por qué el mismo Secret en dos namespaces?

Kubernetes no permite que un pod referencie un Secret de otro namespace. Como WordPress vive en el namespace `wordpress` y MariaDB/Redis viven en `databases`, las credenciales necesitan existir en ambos namespaces. Por eso cada secret aparece duplicado.

La diferencia es que el `mariadb-secret` en el namespace `wordpress` solo incluye `mariadb-user-password` — WordPress no necesita la contraseña de root, que solo usa MariaDB internamente para la replicación y administración.

---

## Credenciales del proyecto

| Servicio | Usuario | Contraseña |
|----------|---------|------------|
| MariaDB root | `root` | `RootDB#2026!` |
| MariaDB WordPress | `wordpress` | `WpUser#2024!` |
| Redis | — | `Redis#2024!` |

---

## Relación con Sealed Secrets

En el flujo normal del proyecto este archivo no se aplica directamente. El `deploy.sh` genera automáticamente los `sealed-*.yaml` usando `kubeseal`, que cifra estos mismos valores con la clave pública del clúster. El controlador de Sealed Secrets descifra los valores al aplicarlos y crea los Secrets reales en Kubernetes. Este archivo existe como referencia y como alternativa para entornos de desarrollo sin Sealed Secrets instalado.
