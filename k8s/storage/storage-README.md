# storage/

Capa de persistencia. Gestiona volúmenes de Kubernetes, almacenamiento de objetos S3-compatible y estrategia de backup. Hace que WordPress sea stateless respecto a los uploads.

| Archivo | Qué hace |
|---|---|
| `pvc.yaml` | PersistentVolumeClaim de 2Gi para WordPress |
| `minio.yaml` | Servidor S3-compatible para uploads y backups |
| `backup.yaml` | 3 CronJobs: backup MariaDB, backup uploads, limpieza >30 días |
| `velero.yaml` | Backup completo del clúster (objetos K8s + snapshots PVC) |
