# configmap.yaml — Documento de referencia

## ¿Qué hace este archivo?

Define los **ConfigMaps** del proyecto — objetos de Kubernetes que almacenan configuración no sensible en formato clave-valor. Los pods leen estos valores como variables de entorno al arrancar, sin necesidad de hardcodear nada en las imágenes Docker.

---

## ¿Qué es un ConfigMap?

Un ConfigMap separa la configuración del código. En lugar de construir una imagen Docker diferente para cada entorno (desarrollo, staging, producción), se usa la misma imagen y se cambia solo el ConfigMap. Esto sigue el principio de **12-factor app**: la configuración vive en el entorno, no en el código.

La diferencia clave con un Secret es que los ConfigMaps almacenan información **no sensible** — URLs, nombres de base de datos, emails. Nunca contraseñas ni tokens.

---

## ConfigMaps definidos

### `mariadb-config` (namespace: `databases`)

Configuración inicial de MariaDB. Cuando el contenedor arranca por primera vez, usa estos valores para crear automáticamente la base de datos y el usuario:

| Clave | Valor | Propósito |
|-------|-------|-----------|
| `MYSQL_DATABASE` | `wordpress_db` | Nombre de la BD que se crea al inicializar |
| `MYSQL_USER` | `wordpress_user` | Usuario no-root con acceso solo a `wordpress_db` |

La contraseña de `wordpress_user` no está aquí — viene del Secret `mariadb-secret` para mantener la separación entre configuración y credenciales.

### `wordpress-config` (namespace: `wordpress`)

Configuración de conexión y parámetros del sitio WordPress:

| Clave | Valor | Propósito |
|-------|-------|-----------|
| `WORDPRESS_DB_HOST` | `mariadb.databases.svc.cluster.local` | DNS interno del Service MariaDB |
| `WORDPRESS_DB_NAME` | `wordpress_db` | Debe coincidir con `mariadb-config` |
| `WORDPRESS_DB_USER` | `wordpress_user` | Debe coincidir con `mariadb-config` |
| `WORDPRESS_SITE_URL` | `http://wp-k8s.local` | URL pública del sitio |
| `WORDPRESS_ADMIN_EMAIL` | `admin@example.com` | Email del administrador |

---

## El DNS interno de Kubernetes

El valor `mariadb.databases.svc.cluster.local` es la dirección interna del Service `mariadb` dentro del clúster. Kubernetes resuelve este nombre automáticamente — siempre apunta al pod `mariadb-0` (el primary), independientemente de en qué nodo esté corriendo. Esto es lo que permite que WordPress encuentre la base de datos sin configurar IPs.

---

## Dependencias entre ConfigMaps

Los valores `MYSQL_DATABASE` y `MYSQL_USER` en `mariadb-config` deben coincidir exactamente con `WORDPRESS_DB_NAME` y `WORDPRESS_DB_USER` en `wordpress-config`. Si hay una discrepancia, WordPress mostrará el error **"Error establishing a database connection"** al arrancar.
