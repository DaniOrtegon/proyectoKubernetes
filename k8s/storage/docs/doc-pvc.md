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
Indica que el volumen solo puede montarse con permisos de escritura desde **un único nodo** simultáneamente. En Minikube (clúster de un solo nodo), todas las réplicas del Deployment de WordPress residen en el mismo nodo, por lo que comparten el volumen sin conflicto. Es la elección correcta para el entorno objetivo del proyecto.

Para un despliegue en producción multi-nodo, la evolución natural sería adoptar `ReadWriteMany` con una StorageClass compatible (NFS, CephFS, EFS) o externalizar los uploads completamente a MinIO con el plugin `wp-offload-media`, lo cual encaja con el stack ya definido en `16-minio.yaml`.

### StorageClass: `standard`
La StorageClass `standard` de Minikube usa un aprovisionador `hostPath` que mapea el volumen a un directorio en el sistema de ficheros del nodo. Es el aprovisionador estándar del entorno de desarrollo y garantiza compatibilidad inmediata sin configuración adicional.

### VolumeMode: Filesystem
El volumen se presenta al contenedor como un sistema de ficheros POSIX montado en una ruta, que es el modo requerido por WordPress para acceder a su directorio `wp-content`.

---

## Decisiones de diseño

| Decisión | Justificación |
|---|---|
| Solo un PVC (WordPress) | MariaDB gestiona su propio almacenamiento con `volumeClaimTemplates` dentro del StatefulSet (`04-mariadb.yaml`), que genera PVCs individuales por réplica automáticamente. Definir aquí un PVC para MariaDB sería un recurso huérfano que consumiría cuota innecesariamente. |
| 2 GiB para WordPress | Suficiente para un entorno de desarrollo y demostración con uploads típicos. El tamaño cubre plugins, temas y medios sin sobredimensionar el entorno Minikube. |
| `standard` como StorageClass | Es la StorageClass disponible por defecto en Minikube, garantizando que el archivo funciona en el entorno objetivo sin requerir configuración adicional. |
| `ReadWriteOnce` | Correcto para Minikube (single-node). Todas las réplicas de WordPress comparten el mismo nodo y pueden montar el volumen simultáneamente sin conflicto. |

---

## Dependencias con otros archivos

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | Crea el namespace `wordpress` donde se define este PVC. Debe existir antes de aplicar este archivo. |
| `06-wordpress.yaml` | El Deployment de WordPress referencia este PVC por su nombre (`wordpress-pvc`) en `spec.volumes[].persistentVolumeClaim.claimName`. Sin el PVC, el Deployment no puede arrancar. |
| `14-resource-quota.yaml` | Si define cuotas de almacenamiento en el namespace, este PVC las consume. El tamaño de 2 GiB está dimensionado para encajar dentro de los límites del entorno. |
| `04-mariadb.yaml` | **No depende** de este PVC. El StatefulSet de MariaDB genera sus propios PVCs automáticamente. |

---

## Puntos a tener en cuenta

### Orden de aplicación
Este archivo debe aplicarse **antes** que `06-wordpress.yaml`. Si el PVC no existe cuando se crea el Deployment, los Pods quedarán en `Pending` hasta que el PVC sea provisionado.

### Ciclo de vida del PVC
Por defecto, la `reclaimPolicy` de la StorageClass `standard` en Minikube es `Delete`, lo que significa que el PV y los datos se eliminan automáticamente al borrar el PVC. Este comportamiento es el adecuado para el entorno de desarrollo: una limpieza completa con `kubectl delete -f 03-pvc.yaml` elimina también los datos asociados sin dejar recursos huérfanos.

### Evolución hacia stateless
La arquitectura del proyecto ya contempla MinIO (`16-minio.yaml`) como destino para los uploads. La configuración `AS3CF_SETTINGS` en `06-wordpress.yaml` apunta a MinIO como almacén de objetos. En la evolución natural del proyecto hacia un diseño completamente stateless, este PVC dejaría de ser necesario para los uploads una vez activado `remove-local-file: true` en el plugin WP Offload Media.
