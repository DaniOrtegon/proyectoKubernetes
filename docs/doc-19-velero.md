# DOC-19 — Backup completo del clúster con Velero (`19-velero.yaml`)

## Qué hace este archivo

Prepara la infraestructura necesaria para que Velero pueda operar en el clúster:

- **Job `velero-bucket-setup`**: crea el bucket `velero-backups` en MinIO antes de que se instale Velero. Es una precondición del proceso de instalación gestionado por `deploy.sh`.
- **NetworkPolicy `allow-velero-egress`**: define las reglas de egress para el namespace `velero`, permitiendo únicamente el tráfico necesario: MinIO (backups), API server (serialización de recursos) y DNS.

El grueso de la configuración de Velero (Schedule, BackupStorageLocation, credenciales) se gestiona via Helm en `deploy.sh`, no en este YAML. Este archivo solo prepara las dependencias de infraestructura.

## Conceptos de Kubernetes utilizados

**Velero** es una herramienta de backup y recuperación ante desastres para clústeres Kubernetes. A diferencia de los CronJobs de `18-backup.yaml` que hacen backups a nivel de aplicación (mysqldump, tar), Velero opera a nivel de clúster: serializa todos los recursos Kubernetes (Deployments, Services, ConfigMaps, Secrets, PVCs, etc.) de los namespaces seleccionados y los almacena en un backend de objetos (MinIO en este caso).

**CSI Volume Snapshots** — Velero puede crear snapshots de PVCs usando el mecanismo CSI (Container Storage Interface). En Minikube, esto requiere los addons `volumesnapshots` y `csi-hostpath-driver`. Los snapshots capturan el estado del disco en un punto del tiempo, complementando el backup de manifiestos YAML con datos reales de los volúmenes.

**`BackupStorageLocation`** — es el recurso de Velero que apunta al bucket S3 de MinIO. Se configura con las credenciales S3 y la URL de MinIO al instalar Velero via Helm. Una vez configurado, Velero puede listar backups disponibles con `velero backup get`.

**NetworkPolicy de egress** — en este proyecto, `07-network-policy.yaml` define políticas restrictivas para todos los namespaces. Velero necesita reglas explícitas porque: (1) accede a un namespace externo (`storage`/MinIO), (2) accede a la API server de Kubernetes desde dentro del clúster, y (3) necesita resolución DNS para las URLs internas.

**`namespace-mappings` en la restauración** — Velero soporta restaurar en un namespace diferente al original. Esto permite hacer restauraciones de prueba en un namespace aislado (`wordpress-restore`) sin afectar el entorno en producción, verificando que el backup es íntegro antes de una restauración real.

## Decisiones de diseño

La preparación del bucket se separa del despliegue de Velero en un Job porque Velero se instala via Helm (herramienta externa al clúster) y requiere que el bucket ya exista antes de la instalación. El orden es: MinIO → `minio-setup` Job → `velero-bucket-setup` Job → `helm install velero`.

La NetworkPolicy usa `app.kubernetes.io/name: velero` como selector porque ese es el label que aplica el chart oficial de Helm. Si se instala Velero de otra forma, el label puede ser diferente y la NetworkPolicy no aplicaría.

Se define egress hacia `0.0.0.0/0` en los puertos 443 y 6443 porque la IP de la API server varía entre entornos (en Minikube es la IP de la VM, en EKS es una IP del balanceador). Restringirlo a una IP concreta rompería la portabilidad del manifiesto.

## Dependencias

| Archivo | Relación |
|---|---|
| `16-minio.yaml` | MinIO debe estar operativo antes de ejecutar `velero-bucket-setup`; proporciona la instancia S3 |
| `00-namespace.yaml` | Crea el namespace `velero` donde Helm instala el operador |
| `07-network-policy.yaml` | Las NetworkPolicies globales del proyecto bloquean egress por defecto; este archivo añade las excepciones para Velero |
| `deploy.sh` | Gestiona el orden de instalación: aplica este YAML antes del `helm install velero` |

## Advertencias y puntos críticos

- Este archivo **no instala Velero**. Solo prepara el bucket y la NetworkPolicy. La instalación completa requiere: `helm install velero vmware-tanzu/velero --set configuration.backupStorageLocation...`. Consultar `deploy.sh` para los parámetros exactos.
- Los addons `minikube addons enable volumesnapshots` y `minikube addons enable csi-hostpath-driver` deben activarse antes de instalar Velero para que los snapshots de PVCs funcionen. Sin ellos, Velero hace backup de los manifiestos pero no de los datos en disco.
- La NetworkPolicy referencia el namespace `velero` asumiendo que el label `kubernetes.io/metadata.name: storage` existe en el namespace `storage`. Este label lo aplica Kubernetes automáticamente desde la versión 1.21; en versiones anteriores habría que añadirlo manualmente.
- Velero y los CronJobs de `18-backup.yaml` son estrategias complementarias, no alternativas. Los CronJobs hacen backups consistentes a nivel de aplicación (mysqldump es transaccional); Velero hace backups del estado del clúster completo. Para una recuperación ante desastres completa, ambas estrategias son necesarias.
- Con `suspend: false` en el Schedule de Velero (configurado en Helm), el primer backup se ejecuta a la 1:00 AM del día siguiente al despliegue. Para forzar un backup inmediato: `velero backup create manual-backup --include-namespaces wordpress,databases`.
