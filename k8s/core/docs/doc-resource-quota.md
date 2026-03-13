# LimitRange y ResourceQuota (`resource-quota.yaml`)

## Qué hace este archivo

Define dos tipos de controles de recursos para los namespaces `wordpress` y `databases`:

- **`LimitRange`**: establece valores de CPU/memoria por defecto y máximos para cada container del namespace. Se aplica automáticamente a pods que no declaren `resources`.
- **`ResourceQuota`**: establece un techo total de recursos que puede consumir el namespace en conjunto (suma de todos los pods).

## Conceptos de Kubernetes utilizados

**LimitRange** actúa en el nivel de objeto individual (Container, Pod, PVC). Sus funciones principales son: asignar `requests` y `limits` automáticamente a pods que no los declaren, e impedir que un único container reclame más recursos del máximo definido. El scheduler de Kubernetes requiere que todos los pods tengan `requests` para poder tomar decisiones de placement; el LimitRange garantiza que esto se cumpla incluso para pods mal configurados.

**ResourceQuota** actúa en el nivel de namespace y es la suma de todos los objetos. Cuando un pod nuevo se crearía excediendo la quota, la API lo rechaza con un error `403 Forbidden`. Esto protege el clúster frente a escalados descontrolados o bugs que creen pods en bucle.

La **interacción entre LimitRange y ResourceQuota** es directa: el LimitRange define los valores mínimos por pod, y la ResourceQuota define cuántos de esos pods pueden coexistir. Hay que calcular los valores de la quota teniendo en cuenta el `maxReplicas` del HPA multiplicado por los requests/limits del LimitRange.

**`requests` vs `limits`** — los `requests` son lo que el scheduler garantiza disponible en el nodo para el pod; los `limits` son el máximo que el pod puede usar antes de ser OOMKilled (memoria) o throttled (CPU). La ratio `limits/requests` determina cuánta sobreprovisión permite el clúster.

## Decisiones de diseño

Los valores de la ResourceQuota para `wordpress` están calculados explícitamente para soportar `maxReplicas: 5` del HPA: la suma de `requests.memory` para 5 réplicas (5 × 256Mi = 1.28Gi) cabe dentro del techo de 2Gi con margen. Esta calibración está documentada en los comentarios del archivo.

El namespace `databases` tiene una quota más generosa en CPU y memoria porque MariaDB y Redis son procesos con consumo de memoria relativamente alto y estable, a diferencia de WordPress que escala horizontalmente.

La separación en dos namespaces con quotas independientes implementa aislamiento de recursos: un pico de tráfico en WordPress no puede "robar" recursos de las bases de datos y viceversa.

## Dependencias

| Archivo | Relación |
|---|---|
| `wordpress.yaml` | Los `resources` declarados en el Deployment de WordPress deben ser coherentes con el LimitRange |
| `hpa-wordpress.yaml` | El `maxReplicas: 5` del HPA determina los techos necesarios en la ResourceQuota |
| `mariadb.yaml` | Los recursos de MariaDB deben caber dentro de la quota de `databases` |
| `redis.yaml` | Los recursos de Redis (1 master + 2 réplicas + 3 Sentinels) deben caber dentro de la quota de `databases` |

## Advertencias y puntos críticos

- Si la ResourceQuota es demasiado restrictiva, el HPA no podrá escalar: intentará crear el pod 5 y recibirá un error de quota. El síntoma es que el HPA muestra `FailedScale` en los eventos. La solución es ajustar los valores de la quota o los requests de los pods.
- El LimitRange define `max.memory: 1Gi`, pero la ResourceQuota de `wordpress` permite `limits.memory: 3Gi`. Esto es coherente: cada container individual no puede superar 1Gi, pero la suma de todos los containers del namespace puede llegar a 3Gi.
- Los Jobs y CronJobs de backup (`backup.yaml`) crean pods temporales en los namespaces `databases` y `storage`. Estos pods también computan contra la quota de su namespace. Si la quota de `pods: "10"` está cerca del límite durante un backup, el Job puede quedar en estado `Pending`.
- Cambiar los valores de una ResourceQuota existente es una operación no disruptiva (no afecta a pods en ejecución), pero reducir la quota por debajo del consumo actual no fuerza la terminación de pods; solo impide crear nuevos hasta que el consumo baje.
