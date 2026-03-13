# DOC-09 — HorizontalPodAutoscaler WordPress (`09-hpa-wordpress.yaml`)

## Qué hace este archivo

Define un `HorizontalPodAutoscaler` (HPA) que escala automáticamente el Deployment `wordpress` en el namespace `wordpress` entre 2 y 5 réplicas en función del uso de CPU y memoria de los pods activos.

## Conceptos de Kubernetes utilizados

**HorizontalPodAutoscaler (HPA)** es un controlador de bucle cerrado que, periódicamente (por defecto cada 15 segundos), consulta las métricas de los pods objetivo y ajusta el campo `spec.replicas` del Deployment para mantener el uso medio de recursos cerca del umbral configurado.

La fórmula que usa el HPA para calcular el número de réplicas deseado es:

```
réplicas_deseadas = ceil(réplicas_actuales × (uso_actual / umbral))
```

**API `autoscaling/v2`** permite definir múltiples métricas simultáneas. El HPA toma el máximo entre todas las métricas: si CPU dice "escalar a 3" y memoria dice "escalar a 4", el resultado final es 4. Esto garantiza que el sistema reacciona ante cualquier tipo de presión de recursos.

**Metrics Server** es el proveedor de métricas requerido por el HPA. Recolecta datos de CPU y memoria directamente del kubelet de cada nodo y los expone a través de la API `metrics.k8s.io`. Sin él, el HPA se queda en estado `Unknown` y no actúa.

## Decisiones de diseño

**Mínimo de 2 réplicas** garantiza alta disponibilidad: si un nodo falla o se drena para mantenimiento, siempre queda al menos una réplica activa sirviendo tráfico. Esto se complementa con el `PodDisruptionBudget` de `13-pdb.yaml`.

**Máximo de 5 réplicas** está calibrado para mantenerse dentro de los límites del `ResourceQuota` del namespace (`14-resource-quota.yaml`). Con 5 réplicas y los requests declarados (100m CPU, 256Mi memoria por pod), el namespace consume exactamente 500m CPU y 1.28Gi memoria en requests, dentro del techo de 1 CPU y 2Gi definido en la quota.

**Umbral de CPU al 50%** es conservador para WordPress, que puede tener picos de CPU durante la renderización de páginas con plugins pesados. Un umbral bajo asegura que el escalado ocurre antes de que los usuarios noten degradación.

**Umbral de memoria al 70%** es más permisivo porque PHP-FPM consume memoria de forma relativamente estable. La memoria no se libera con el mismo dinamismo que la CPU, por lo que un umbral bajo generaría escalados innecesarios.

## Dependencias

| Archivo | Relación |
|---|---|
| `06-wordpress.yaml` | Define el Deployment `wordpress` que este HPA controla |
| `14-resource-quota.yaml` | Los limits del HPA deben estar dentro de la ResourceQuota del namespace |
| `13-pdb.yaml` | Trabaja en coordinación: el PDB garantiza disponibilidad mínima durante los scale-downs |

## Advertencias y puntos críticos

- El HPA requiere que los pods tengan `resources.requests` declarados. Sin requests, las métricas de porcentaje de utilización no se pueden calcular y el HPA entra en estado de error.
- En Minikube, Metrics Server debe activarse explícitamente: `minikube addons enable metrics-server`. Se puede verificar con `kubectl top pods -n wordpress`.
- El tiempo de estabilización por defecto del HPA para scale-down es 5 minutos. Esto evita oscilaciones (flapping) pero significa que tras un pico de tráfico el sistema tarda varios minutos en reducir réplicas.
- El HPA de `autoscaling/v2` con múltiples métricas puede entrar en conflicto con KEDA si ambos gestionan el mismo Deployment. En este proyecto, el archivo `09-keda-wordpress.yaml` reemplaza al HPA nativo para el escalado por requests/segundo. Solo uno de los dos debe estar activo en producción.
