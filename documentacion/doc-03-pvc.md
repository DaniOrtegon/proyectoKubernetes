# DOC-03 — PersistentVolumeClaim (PVC) de WordPress

## ¿Qué hace este archivo?

Define un único `PersistentVolumeClaim` llamado `wordpress-pvc` en el namespace `wordpress`. Su función es solicitar al clúster un volumen persistente de 2 GiB para almacenar el contenido dinámico de WordPress: uploads de medios, temas instalados y plugins. Sin este PVC, cualquier reinicio o reprogramación de un Pod de WordPress destruiría todo el contenido subido por los usuarios.

---

## Conceptos de Kubernetes utilizados

### PersistentVolumeClaim (PVC)
Un PVC es una **solicitud de almacenamiento** por parte de un usuario o carga de trabajo. Kubernetes lo resuelve buscando un `PersistentVolume` (PV) que cumpla los requisitos (tamaño, modo de acceso, StorageClass). En Minikube, el aprovisionador dinámico crea el PV automáticamente al recibir el PVC.

El ciclo de vida es:
```
PVC creado → StorageClass activa aprovisionador → PV creado y enlazado → Pod monta el PV vía PVC
```

### AccessMode: ReadWriteOnce (RWO)
Indica que el volumen solo puede montarse con permisos de escritura desde **un único nodo** simultáneamente. Kubernetes no impide que múltiples Pods en el **mismo nodo** monten el volumen, lo que hace que funcione correctamente en Minikube (clúster de un solo nodo). En un clúster multi-nodo, los Pods programados en nodos distintos que intenten montar este PVC quedarán bloqueados en estado `Pending`.

### StorageClass: `standard`
La StorageClass `standard` de Minikube usa un aprovisionador `hostPath`, que mapea el volumen a un directorio en el sistema de archivos del nodo. Es adecuado para desarrollo/pruebas pero **no ofrece redundancia ni replicación de datos**.

### VolumeMode: Filesystem
El volumen se presenta al contenedor como un sistema de archivos POSIX montado en una ruta. La alternativa `Block` (dispositivo de bloque sin formato) no es compatible con WordPress.

---

## Decisiones de diseño

| Decisión | Justificación |
|---|---|
| Solo un PVC (WordPress) | MariaDB gestiona su propio almacenamiento con `volumeClaimTemplates` dentro del StatefulSet (`04-mariadb.yaml`), que genera PVCs individuales por réplica automáticamente. Crear un PVC de MariaDB aquí sería un recurso huérfano que consumiría cuota innecesariamente. |
| 2 GiB para WordPress | Suficiente para un entorno de desarrollo/demostración con uploads típicos. En producción debería dimensionarse según el volumen de contenido esperado. |
| `standard` como StorageClass | Es la única StorageClass disponible por defecto en Minikube. Sin un proveedor de almacenamiento externo configurado, es la opción correcta para el entorno objetivo. |
| `ReadWriteOnce` | Funcional en Minikube (single-node). Se documenta explícitamente la limitación para evitar sorpresas al migrar a producción. |

---

## Dependencias con otros archivos

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | Crea el namespace `wordpress` donde se define este PVC. Debe existir antes de aplicar este archivo. |
| `06-wordpress.yaml` | El Deployment de WordPress referencia este PVC por su nombre (`wordpress-pvc`) en `spec.volumes[].persistentVolumeClaim.claimName`. Sin el PVC, el Deployment no puede arrancar. |
| `14-resource-quota.yaml` | Si define cuotas de almacenamiento en el namespace, este PVC las consume. Verificar que 2 GiB no supere el límite configurado. |
| `04-mariadb.yaml` | **No depende** de este PVC. El StatefulSet de MariaDB genera sus propios PVCs automáticamente. |

---

## Advertencias y puntos críticos

### ⚠️ ReadWriteOnce bloquea el escalado multi-nodo
Con KEDA configurado para escalar WordPress hasta 10 réplicas, si alguna réplica se programa en un nodo diferente al que tiene montado el volumen, quedará en `Pending` indefinidamente. En Minikube esto no ocurre (un solo nodo), pero es el **principal bloqueante** para llevar este diseño a producción sin modificaciones.

**Solución recomendada para producción:**
- Usar `ReadWriteMany` con una StorageClass compatible (NFS, CephFS, AWS EFS, Azure Files).
- O, preferiblemente, externalizar los uploads a MinIO/S3 con el plugin `wp-offload-media`, eliminando la dependencia del volumen compartido.

### ⚠️ StorageClass `hostPath` no es tolerante a fallos
El aprovisionador `hostPath` de Minikube almacena datos en el nodo local. Si el nodo falla, los datos se pierden. No usar en producción.

### ℹ️ El PVC persiste aunque se elimine el Deployment
Por defecto, la `reclaimPolicy` de la StorageClass `standard` en Minikube es `Delete`, lo que significa que el PV (y los datos) se eliminarán automáticamente al borrar el PVC. Verificar la política antes de realizar operaciones de mantenimiento.

### ℹ️ Orden de aplicación
Este archivo debe aplicarse **antes** que `06-wordpress.yaml`. Si el PVC no existe cuando se crea el Deployment, los Pods quedarán en `Pending` hasta que el PVC sea provisionado.
