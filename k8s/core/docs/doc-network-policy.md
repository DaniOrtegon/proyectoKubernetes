# NetworkPolicies (Segmentación de Red)

## ¿Qué hace este archivo?

Define 19 `NetworkPolicy` distribuidas en cuatro namespaces (`wordpress`, `databases`, `storage`, `monitoring`) que implementan un modelo de seguridad **default-deny con permisos explícitos**. Cada política controla qué Pods pueden comunicarse entre sí y en qué puertos, aislando los componentes del stack y limitando el radio de explosión ante un posible compromiso de seguridad.

---

## Conceptos de Kubernetes utilizados

### NetworkPolicy y el modelo de evaluación
Las `NetworkPolicy` son aditivas: si un Pod no tiene ninguna política que lo seleccione, permite todo el tráfico por defecto. En cuanto existe al menos una política que selecciona un Pod para un tipo de tráfico (Ingress o Egress), solo se permite el tráfico explícitamente declarado. El modelo implementado aquí es:

```
default-deny (políticas 4, 5, 13) → bloquea todo el namespace
         ↓
allow-* (resto de políticas) → abre solo los flujos necesarios
```

### AND vs OR en los selectores `from`/`to`
Este es el punto más crítico de la sintaxis de NetworkPolicies:

```yaml
# AND: el origen debe cumplir AMBAS condiciones simultáneamente (más restrictivo)
- from:
  - namespaceSelector: {matchLabels: {name: wordpress}}
    podSelector: {matchLabels: {app: wordpress}}

# OR: el origen puede cumplir CUALQUIERA de las condiciones (menos restrictivo)
- from:
  - namespaceSelector: {matchLabels: {name: wordpress}}
  - podSelector: {matchLabels: {app: wordpress}}
```

El archivo usa consistentemente el formato AND (mismo elemento de lista) en las políticas cross-namespace (1, 2, 3, 14), garantizando la doble restricción: origen correcto **y** namespace correcto.

### `podSelector: {}` (vacío)
En el campo `spec.podSelector`, `{}` significa "aplica a todos los Pods del namespace". Se usa en las políticas default-deny (4, 5, 13) y en las políticas de Prometheus scrape (6, 7) para afectar a todos los Pods sin distinción.

---

## Mapa de flujos permitidos

| Origen | Destino | Puerto | Política |
|---|---|---|---|
| `wordpress/app=wordpress` | `databases/app=mariadb` | 3306 | 1 + 3 |
| `wordpress/app=wordpress` | `databases/app=redis` | 6379 | 2 + 3 |
| `wordpress/app=wordpress` | `databases/app=redis` | 26379 | 3 |
| `wordpress/app=wordpress` | `storage/app=minio` | 9000 | 3 + 14 |
| `wordpress/app=wordpress` | `monitoring/app=otel-collector` | 4317/4318 | 15 |
| `monitoring/app=prometheus` | `wordpress/*` | 80 | 6 |
| `monitoring/app=prometheus` | `databases/*` | 9104 | 7 |
| `monitoring/app=prometheus` | `monitoring/app=alertmanager` | 9093 | 9 |
| `monitoring/app=promtail` | `monitoring/app=loki` | 3100 | 8 |
| `monitoring/app=grafana` | `monitoring/app=loki` | 3100/9096 | 8 |
| `monitoring/app=grafana` | `monitoring/app=jaeger` | 16686 | 16 |
| `monitoring/app=otel-collector` | `monitoring/app=jaeger` | 4317/4318/14268 | 16 |
| `databases/app=mariadb` | `databases/app=mariadb` | 3306 | 12 |
| `databases/app=mariadb-backup` | `databases/app=mariadb` | 3306 | 17 |
| `databases/app=mariadb-backup` | `storage/*` | 9000 | 17 |
| `wordpress/app=wordpress-backup` | `storage/*` | 9000 | 18 |
| `storage/app=backup-cleanup` | `storage/app=minio` | 9000 | 19 |
| Todos los namespaces | kube-dns | 53 TCP+UDP | 4, 5, 12, 13, 17, 18, 19 |

---

## Decisiones de diseño

| Decisión | Justificación |
|---|---|
| Default-deny como base | Fuerza a documentar explícitamente cada flujo de red. Reduce la superficie de ataque: un Pod comprometido no puede comunicarse libremente con el resto del clúster. |
| DNS siempre permitido en Egress | Sin DNS, los Pods no pueden resolver FQDNs internos. Es una excepción universal y aceptada que no compromete el modelo de seguridad. |
| Políticas separadas por dirección (Ingress/Egress) | Permite razonar sobre los flujos desde ambos extremos, creando una restricción doble que refuerza el aislamiento. |
| Políticas para los CronJobs de backup (17, 18, 19) | Los Jobs de backup necesitan acceso cross-namespace (databases/wordpress → storage). Las políticas dedicadas mantienen el principio de mínimo privilegio: solo los Pods de backup pueden cruzar hacia MinIO. |
| Sentinel y Redis cubiertos en políticas separadas | El puerto 26379 (Sentinel) se permite explícitamente en la política 3, cubriendo el protocolo de descubrimiento de master que usa el plugin Redis Object Cache de WordPress. |
| Políticas 17, 18, 19 por label de CronJob | El uso de labels específicos (`app: mariadb-backup`, `app: wordpress-backup`, `app: backup-cleanup`) permite aplicar el principio de mínimo privilegio a los Jobs de mantenimiento sin afectar al resto de Pods del namespace. |

---

## Puntos a tener en cuenta

### Etiquetas de namespace requeridas (Kubernetes < 1.21)
Las políticas cross-namespace usan `kubernetes.io/metadata.name`, que Kubernetes añade automáticamente desde la versión 1.21. En versiones anteriores, es necesario añadir estas etiquetas manualmente:
```bash
kubectl label namespace wordpress kubernetes.io/metadata.name=wordpress
kubectl label namespace databases kubernetes.io/metadata.name=databases
kubectl label namespace storage kubernetes.io/metadata.name=storage
kubectl label namespace monitoring kubernetes.io/metadata.name=monitoring
```

### Verificación de conectividad
Tras aplicar las políticas, es recomendable verificar los flujos críticos:
```bash
# WordPress → MariaDB
kubectl exec -n wordpress deploy/wordpress -- nc -zv mariadb.databases.svc.cluster.local 3306

# WordPress → Redis Sentinel
kubectl exec -n wordpress deploy/wordpress -- nc -zv redis-sentinel.databases.svc.cluster.local 26379

# Listar todas las políticas activas
kubectl get networkpolicy -A
```

### Integración con el Ingress Controller
La política 3 permite Ingress al puerto 80 desde cualquier origen, garantizando compatibilidad con cualquier Ingress Controller desplegado en el clúster (nginx, Traefik, etc.) independientemente de su namespace. Este diseño prioriza la compatibilidad con el entorno Minikube, donde el Ingress Controller varía según la configuración del addon.

### Cobertura del namespace `monitoring`
Las políticas 8, 9 y 16 cubren los flujos internos más críticos del stack de observabilidad. El namespace `monitoring` opera con un modelo de confianza mayor dado que sus componentes (Prometheus, Grafana, Loki, Jaeger) son herramientas de infraestructura gestionadas internamente, con acceso limitado a los namespaces de aplicación mediante las políticas de scrape.
