# PodDisruptionBudget (`13-pdb.yaml`)

## Qué hace este archivo

Define un `PodDisruptionBudget` (PDB) para el Deployment de WordPress que garantiza que, durante cualquier operación de mantenimiento voluntaria del clúster, siempre permanezca disponible al menos 1 pod del servicio.

## Conceptos de Kubernetes utilizados

**PodDisruptionBudget** es un recurso de política que establece el número mínimo de pods que deben permanecer disponibles durante **disrupciones voluntarias** (también llamadas presupuesto de interrupción). Las disrupciones voluntarias incluyen: vaciado de nodos (`kubectl drain`), actualizaciones de nodos, rolling updates de Deployments y migraciones de pods.

El PDB **no protege** frente a fallos involuntarios como crashes de nodos, OOMKills o errores de la aplicación. Para esos casos existen `livenessProbe`, `readinessProbe` y replicas mínimas en el HPA.

Kubernetes consulta el PDB antes de ejecutar cualquier operación que implique terminar pods de forma voluntaria. Si la operación reduciría el número de pods disponibles por debajo de `minAvailable`, Kubernetes rechaza la operación y espera hasta que haya pods suficientes.

**`minAvailable: 1`** significa que el clúster puede terminar todos los pods de WordPress excepto uno. Con `minReplicas: 2` en el HPA, esto permite que durante un `kubectl drain` se elimine un pod y quede otro activo, sin bloquear la operación de mantenimiento indefinidamente.

## Decisiones de diseño

Se usa `minAvailable: 1` en lugar de `maxUnavailable: 1` porque la semántica es más intuitiva en este contexto: siempre debe haber al menos 1 pod disponible, independientemente del número total de réplicas en ese momento.

Definir el PDB como un recurso independiente (en lugar de incrustarlo en el Deployment) permite aplicarlo sin modificar el manifiesto del Deployment y facilita su gestión en pipelines CI/CD.

## Dependencias

| Archivo | Relación |
|---|---|
| `wordpress.yaml` | Define el Deployment `wordpress` cuyos pods selecciona este PDB via `matchLabels: app: wordpress` |
| `hpa-wordpress.yaml` | El HPA mantiene un mínimo de 2 réplicas, lo que hace el PDB efectivo; con 1 réplica el PDB bloquearía cualquier drain |

## Advertencias y puntos críticos

- Si el HPA escala el Deployment a `minReplicas: 2` y el PDB exige `minAvailable: 1`, siempre habrá margen para terminar 1 pod en mantenimiento. Pero si por alguna razón el Deployment queda con 1 sola réplica disponible (pod en CrashLoop, por ejemplo), un `kubectl drain` quedará bloqueado hasta que el pod se recupere.
- El PDB solo aplica a disrupciones voluntarias gestionadas por la API de Kubernetes. Un proceso externo que mate el pod directamente (por ejemplo, un nodo que se apaga sin `drain`) no respeta el PDB.
- En Minikube de un solo nodo, el PDB es esencialmente una documentación de intención: con un único nodo, hacer `kubectl drain` siempre bloqueará si hay pods con PDB, ya que no hay otro nodo donde reprogramarlos.
