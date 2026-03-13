# DOC-16 — MinIO (`16-minio.yaml`)

## Qué hace este archivo

Despliega MinIO como sistema de almacenamiento de objetos compatible con la API S3 en el namespace `storage`. Proporciona:

- **Deployment de MinIO**: servidor S3 con PVC de 10Gi para almacenamiento de objetos.
- **Secrets de credenciales**: en los namespaces `storage` (para el servidor) y `wordpress` (para el plugin WP Offload Media).
- **Service ClusterIP**: expone la API S3 (puerto 9000) y la consola web (puerto 9001) internamente.
- **Job `minio-setup`**: ejecutado una sola vez tras el despliegue, crea los buckets `wordpress-uploads` y `wordpress-backups` con las políticas de acceso apropiadas.

## Conceptos de Kubernetes utilizados

**Patrón stateless para WordPress** — MinIO permite que los pods de WordPress sean completamente stateless en cuanto a media se refiere: los ficheros subidos van directamente a S3 (MinIO) en lugar de al PVC local. Esto es fundamental para el escalado horizontal con HPA, ya que todos los pods ven el mismo contenido independientemente del nodo en el que corran.

**Job para inicialización** — el `Job` `minio-setup` usa la imagen `minio/mc` (MinIO Client) para crear buckets y configurar políticas de acceso. El campo `ttlSecondsAfterFinished: 300` limpia el Job y sus pods automáticamente 5 minutos después de completarse, dejando el clúster limpio.

**Secrets duplicados en namespaces distintos** — las credenciales de MinIO existen como dos Secrets separados: uno en `storage` con las credenciales de root (para el servidor y jobs de administración) y otro en `wordpress` con las mismas credenciales pero en el formato esperado por el plugin WP Offload Media (`access-key`/`secret-key`). Esta separación sigue el principio de mínimo privilegio: WordPress solo necesita las claves de acceso, no las credenciales de administración.

**`imagePullPolicy: Never`** — indica a Kubernetes que no intente descargar la imagen de internet, usando únicamente la imagen local del nodo. Esto requiere haber cargado las imágenes en Minikube previamente (`minikube image load`), pero es la práctica correcta en entornos sin conexión o con registros privados.

## Decisiones de diseño

Se elige MinIO sobre otras alternativas (NFS compartido, CephFS) porque implementa la API S3 estándar, lo que hace la solución portable: en producción se podría sustituir por AWS S3, GCS o Azure Blob Storage cambiando solo las variables de entorno del plugin, sin modificar el código de WordPress.

El bucket `wordpress-uploads` se configura con acceso público de lectura (`mc anonymous set download`). Esto permite que los visitantes del sitio descarguen media directamente desde la URL de MinIO sin autenticación, comportamiento equivalente al directorio `wp-content/uploads` habitual.

La consola web de MinIO (puerto 9001) está disponible internamente pero no se expone via Ingress en este archivo. Para acceder temporalmente se puede usar `kubectl port-forward`.

## Dependencias

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | Crea el namespace `storage` |
| `06-wordpress.yaml` | WordPress consume el Secret `minio-secret` del namespace `wordpress` para el plugin S3 |
| `18-backup.yaml` | Los CronJobs de backup escriben en los buckets `wordpress-backups` de MinIO |
| `19-velero.yaml` | El Job `velero-bucket-setup` crea el bucket `velero-backups` en esta instancia de MinIO |

## Advertencias y puntos críticos

- Las credenciales `minioadmin` / `Minio#2024!` son valores por defecto conocidos públicamente. En producción deben sustituirse por credenciales generadas aleatoriamente y gestionadas via Sealed Secrets.
- MinIO se despliega con `replicas: 1` y un único PVC (`ReadWriteOnce`). No hay redundancia de datos: si el nodo o el PVC falla, los uploads de WordPress dejan de estar disponibles hasta que se restaure. Para HA se necesitaría MinIO en modo distribuido (mínimo 4 nodos).
- El bucket `wordpress-uploads` con acceso público permite que cualquiera descargue ficheros conociendo la URL. No se debe usar para documentos privados.
- El Job `minio-setup` usa `restartPolicy: OnFailure`. Si MinIO no está listo cuando el Job empieza, el Job falla y se reintenta automáticamente. Verificar con `kubectl logs -n storage job/minio-setup` si hay problemas en el primer despliegue.
