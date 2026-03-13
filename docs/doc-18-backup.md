# DOC-18 — Backup y Recuperación ante Desastres (`18-backup.yaml`)

## Qué hace este archivo

Implementa la estrategia de backup a nivel de aplicación mediante tres `CronJob`s y un `Job` de restauración manual:

- **`mariadb-backup`** (diario 2:00 AM): genera un `mysqldump` de todas las bases de datos de MariaDB, lo comprime con gzip y lo sube a MinIO (`wordpress-backups/mariadb/`).
- **`wordpress-uploads-backup`** (diario 3:00 AM): comprime el directorio `wp-content/uploads` del PVC de WordPress y lo sube a MinIO (`wordpress-backups/uploads/`).
- **`backup-cleanup`** (domingo 4:00 AM): elimina de MinIO los ficheros de backup con más de 30 días de antigüedad.
- **`mariadb-restore-manual`** (Job suspendido): plantilla lista para restaurar un backup específico de MariaDB bajo demanda.

## Conceptos de Kubernetes utilizados

**CronJob** es el recurso de Kubernetes para ejecutar Jobs en una programación temporal (formato cron). Cada ejecución crea un nuevo `Job`, que a su vez crea uno o más pods. Los campos `successfulJobsHistoryLimit` y `failedJobsHistoryLimit` controlan cuántos Jobs históricos se conservan para poder inspeccionar logs.

**`concurrencyPolicy: Forbid`** evita que se lance una nueva ejecución si la anterior todavía está en curso. Esto es fundamental para backups: dos ejecuciones concurrentes podrían producir backups corruptos o inconsistentes.

**`timeZone: "Europe/Madrid"`** especifica la zona horaria del cron schedule. Sin este campo, Kubernetes interpreta el schedule en UTC. Con él, las 2:00 AM corresponden a las 2:00 AM hora española, alineando el backup con las horas de menor tráfico.

**`suspend: true` en el Job de restauración** — el Job de restauración está marcado como suspendido para que no se ejecute automáticamente al aplicar el YAML. Para restaurar hay que editar el campo `suspend: false` y reaplicar el manifiesto. Este patrón es más seguro que un Job activo que podría ejecutarse por error.

**`--single-transaction` en mysqldump** — esta opción usa una transacción InnoDB para garantizar la consistencia del dump sin bloquear las tablas. Permite hacer el backup mientras la base de datos está en producción recibiendo escrituras, lo cual es esencial para un entorno de alta disponibilidad.

**Volumen del PVC de WordPress en el backup de uploads** — el CronJob `wordpress-uploads-backup` monta el mismo PVC que usan los pods de WordPress (`wordpress-pvc`) en modo `readOnly: true`. Esto garantiza que el backup no puede corromper los datos aunque haya un bug en el script.

## Decisiones de diseño

Se usa `curl` para subir a MinIO en lugar del cliente `mc`, porque `curl` está disponible en la imagen `mariadb:10.6` sin necesidad de instalarlo. El protocolo S3 compatible con MinIO acepta PUT requests HTTP directos con autenticación básica.

La limpieza de backups antiguos se ejecuta semanalmente (no diariamente) para minimizar el riesgo de eliminar el último backup disponible ante un fallo del CronJob de creación. Si el backup del martes falla y la limpieza corre el miércoles, aún quedan los backups de los días anteriores.

La estrategia documenta RTO ~15 minutos y RPO ~24 horas. Esto es coherente con un backup diario: en el peor caso se pierde un día de datos. Para RPO menor se necesitaría replicación continua (MariaDB GTID replication hacia un servidor externo o Velero con backups más frecuentes).

## Dependencias

| Archivo | Relación |
|---|---|
| `16-minio.yaml` | Destino de todos los backups; los buckets `wordpress-backups` deben existir antes de la primera ejecución |
| `04-mariadb.yaml` | Define el Secret `mariadb-secret` con `mariadb-root-password`, requerido por el CronJob de backup |
| `03-pvc.yaml` | Define el PVC `wordpress-pvc` montado por el CronJob de uploads |
| `01-secrets.yaml` | El Secret `minio-secret` en los namespaces `databases` y `wordpress` debe existir con las claves `access-key`/`secret-key` |

## Advertencias y puntos críticos

- El Job de restauración tiene `BACKUP_FILE: "CHANGE_ME.sql.gz"`. Si se activa (`suspend: false`) sin cambiar este valor, el script detecta el placeholder y termina con error mostrando los backups disponibles. Es una salvaguarda intencional.
- Los CronJobs de backup y limpieza usan `imagePullPolicy: Never`. Las imágenes `mariadb:10.6`, `alpine:3.18` y `minio/mc:latest` deben estar precargadas en Minikube.
- El CronJob `wordpress-uploads-backup` monta el PVC de WordPress, que es `ReadWriteOnce`. Si todos los pods de WordPress están en el mismo nodo (lo habitual en Minikube), el montaje adicional del CronJob en ese mismo nodo no genera conflicto. En un clúster multinodo podría haber un `Multi-Attach` error si el PVC y el pod del CronJob están en nodos distintos.
- Los backups se suben sin cifrado a MinIO. En producción, los datos sensibles de la base de datos deberían cifrarse antes de subirse al objeto de almacenamiento.
