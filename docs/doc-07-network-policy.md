# DOC-07 — NetworkPolicies (Segmentación de Red)

## ¿Qué hace este archivo?

Define 19 `NetworkPolicy` distribuidas en cuatro namespaces (`wordpress`, `databases`, `storage`, `monitoring`) que implementan un modelo de seguridad **default-deny con permisos explícitos**. Cada política controla qué Pods pueden comunicarse entre sí y en qué puertos, aislando los componentes del stack y limitando el radio de explosión ante un posible compromiso de seguridad.

---

## Conceptos de Kubernetes utilizados

### NetworkPolicy y el modelo de evaluación
Las `NetworkPolicy` son aditivas: si un Pod no tiene ninguna política que lo seleccione, **permite todo el tráfico** (permisivo por defecto). En cuanto existe al menos una política que selecciona un Pod para un tipo de tráfico (Ingress o Egress), solo se permite el tráfico explícitamente declarado en esa política o en cualquier otra que también lo seleccione.

El modelo implementado aquí es:
```
default-deny (políticas 4, 5, 13) → bloquea todo el namespace
         ↓
allow-* (resto de políticas) → abre solo los flujos necesarios
```

### AND vs OR en los selectores `from`/`to`
Este es el punto más confuso de las NetworkPolicies y el archivo lo usa correctamente:

```yaml
# AND: el origen debe cumplir AMBAS condiciones simultáneamente
- from:
  - namespaceSelector: {matchLabels: {name: wordpress}}
    podSelector: {matchLabels: {app: wordpress}}

# OR: el origen puede cumplir CUALQUIERA de las dos condiciones
- from:
  - namespaceSelector: {matchLabels: {name: wordpress}}
  - podSelector: {matchLabels: {app: wordpress}}
```

La diferencia es sutil pero crítica: el formato AND (mismo elemento de lista) es más restrictivo y es el usado en las políticas 1, 2, 3, 14. El formato OR (elementos separados) abriría el tráfico a todos los Pods del namespace **o** a todos los Pods con ese label en cualquier namespace.

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
| DNS siempre permitido en Egress | Sin DNS, los Pods no pueden resolver FQDNs internos (`mariadb.databases.svc.cluster.local`). Es una excepción aceptable y universal. |
| Políticas separadas por dirección (Ingress/Egress) | Permite razonar sobre los flujos desde ambos extremos: la política 1 controla quién llega a MariaDB; la política 3 controla desde dónde puede salir WordPress. La combinación de ambas crea una restricción doble. |
| Políticas para los CronJobs de backup (17, 18, 19) | Los Jobs de backup necesitan acceso cross-namespace (databases → storage). Sin estas políticas, los dumps de MariaDB no podrían subirse a MinIO. |
| Sentinel y Redis en políticas separadas | El puerto 26379 (Sentinel) se permite en la política 3 (Egress de WordPress) además del puerto 6379, cubriendo la necesidad del plugin Redis Object Cache de conectarse primero a Sentinel para descubrir el master. |

---

## Advertencias y puntos críticos

### ⚠️ Nombre duplicado en políticas 6 y 7
Ambas políticas se llaman `allow-prometheus-scrape` pero están en namespaces distintos (`wordpress` y `databases`). Esto es válido en Kubernetes (los nombres son namespace-scoped), pero puede causar confusión al listar políticas con `kubectl get networkpolicy -A` y al referenciarlas en documentación o scripts. Se recomienda usar nombres distintos: `allow-prometheus-scrape-wordpress` y `allow-prometheus-scrape-databases`.

### ⚠️ La política 6 usa el puerto 80 para scraping de Prometheus
El scraping de métricas de Prometheus en WordPress se define en el puerto 80. Si WordPress expone métricas en una ruta especial (como `/metrics`) en el puerto 80, esto es correcto. Sin embargo, la práctica habitual es exponer métricas en un puerto dedicado (p. ej. 9113 con `apache_exporter` o `php-fpm_exporter`). Verificar que existe un exporter activo en el puerto configurado; de lo contrario, la política permite acceso a la aplicación WordPress desde Prometheus sin utilidad real.

### ⚠️ La política 7 (puerto 9104) requiere mysqld_exporter desplegado
El puerto 9104 es el de `mysqld_exporter`, pero el archivo `04-mariadb.yaml` no incluye este sidecar. La política abre el puerto pero no hay nada escuchando en él. Añadir `mysqld_exporter` como sidecar en el StatefulSet de MariaDB para que esta política tenga efecto.

### ⚠️ La política 14 permite acceso desde todos los Pods del namespace `storage`
El bloque `from: namespaceSelector: storage` sin `podSelector` permite que **cualquier Pod del namespace `storage`** acceda a MinIO en los puertos 9000 y 9001. Si en el futuro se despliegan otros componentes en `storage`, tendrían acceso a MinIO automáticamente. Añadir `podSelector: {matchLabels: {app: minio-setup}}` para restringirlo al Job específico.

### ⚠️ Faltan políticas para el namespace `monitoring` (default-deny)
El archivo incluye políticas para `monitoring` (8, 9, 16) pero no define un `default-deny` para ese namespace. Sin él, todos los Pods de `monitoring` pueden comunicarse libremente con cualquier destino. Para consistencia con el modelo de seguridad, añadir:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-monitoring
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
  egress:
  - ports:
    - port: 53
      protocol: UDP
```

### ⚠️ Numeración con huecos (10, 11 ausentes)
El archivo declara 19 políticas pero los números saltan del 9 al 12. Esto sugiere que se eliminaron o fusionaron políticas durante el desarrollo. No afecta al funcionamiento, pero sí a la trazabilidad. Documentar en el RUNBOOK qué cubría cada número eliminado.

### ⚠️ El Ingress Controller no está cubierto explícitamente
La política 3 permite Ingress al puerto 80 desde cualquier origen (`from` vacío). En producción, esto debería restringirse al namespace del Ingress Controller (p. ej. `ingress-nginx`) para evitar que Pods arbitrarios del clúster puedan llamar directamente a WordPress en el puerto 80.

### ℹ️ Las políticas se evalúan de forma independiente y aditiva
Si un Pod tiene múltiples políticas que lo seleccionan para el mismo tipo de tráfico (Ingress o Egress), el tráfico se permite si **cualquiera** de las políticas lo autoriza. No hay prioridades ni orden de evaluación.

### ℹ️ Verificación de conectividad tras aplicar las políticas
```bash
# Verificar que WordPress puede conectar a MariaDB
kubectl exec -n wordpress deploy/wordpress -- nc -zv mariadb.databases.svc.cluster.local 3306

# Verificar que tráfico no permitido está bloqueado
kubectl exec -n wordpress deploy/wordpress -- nc -zv redis.databases.svc.cluster.local 6379  # debe fallar si no está en política

# Listar todas las políticas activas
kubectl get networkpolicy -A
```
