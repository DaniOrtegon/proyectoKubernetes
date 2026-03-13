# DOC-10 — Prometheus + Alertmanager (`10-prometheus.yaml`)

## Qué hace este archivo

Despliega el stack completo de recolección y alertado de métricas del clúster:

- **Prometheus**: base de datos time-series que scrapea métricas de nodos, pods, cAdvisor y kube-state-metrics. Almacena 15 días de datos en un PVC de 10Gi.
- **Alertmanager**: receptor de alertas de Prometheus que las enruta a canales configurables (Slack en este caso). Gestiona agrupación, inhibición y silenciado de alertas.
- **Reglas de alerta**: conjunto de alertas operacionales (PodDown, OOMKill, HighCPU) y reglas SLO (burn rate del error budget para el SLO de disponibilidad 99.9% de WordPress).

## Conceptos de Kubernetes utilizados

**RBAC para service discovery** — Prometheus necesita permisos de lectura sobre la API de Kubernetes para descubrir dinámicamente pods, endpoints y nodos. Se crea un `ClusterRole` con permisos mínimos (solo `get`, `list`, `watch`) vinculado a un `ServiceAccount` exclusivo mediante `ClusterRoleBinding`.

**Kubernetes Service Discovery (`kubernetes_sd_configs`)** — en lugar de mantener una lista estática de targets, Prometheus interroga la API de Kubernetes para descubrir automáticamente qué pods existen y cómo contactarlos. Utiliza los roles `node` y `pod`, y filtra targets mediante `relabel_configs`.

**Relabeling** — es el mecanismo que transforma las etiquetas de los metadatos de Kubernetes en labels de las métricas. Por ejemplo, la anotación `prometheus.io/scrape: "true"` en un pod le indica a Prometheus que debe scrapear ese pod, y `prometheus.io/port` sobreescribe el puerto de scraping.

**Rutas proxy a través de la API** — el acceso a cAdvisor y kubelet se realiza a través de `kubernetes.default.svc:443` como proxy. Esto evita abrir puertos directos en los nodos y centraliza la autenticación usando el token del ServiceAccount.

**SLOs y error budgets** — las reglas del grupo `wordpress-slos` implementan el método de burn rate multi-ventana de Google SRE. La métrica `wordpress:request_success_rate:5m` calcula la tasa de éxito en tiempo real, y las alertas se disparan cuando la tasa de consumo del error budget supera multiplicadores críticos (14.4x y 3x).

**Alertmanager routing** — el árbol de rutas (`route`) clasifica alertas por severidad y las dirige a receptores específicos. Las `inhibit_rules` evitan ruido: si ya hay una alerta crítica sobre un pod (PodDown), se suprimen las warnings del mismo pod.

## Decisiones de diseño

Prometheus se despliega como Deployment de 1 réplica porque no soporta clustering nativo. Para HA en producción se usaría Thanos o Cortex con almacenamiento externo, pero en Minikube esto añadiría complejidad innecesaria.

El almacenamiento de Alertmanager usa `emptyDir` intencionalmente: los silenciamientos y el estado de las alertas se pierden en reinicios, pero esto es aceptable en entorno de prácticas. En producción se montaría un PVC.

Las alertas de SLO con burn rate son más sofisticadas que simples umbrales de error rate. El burn rate alto (14.4x) se dispara rápido pero solo cuando el problema es grave; el burn rate moderado (3x) actúa como aviso temprano con un `for: 30m` para evitar falsos positivos.

## Dependencias

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | Crea el namespace `monitoring` |
| `08-ingress.yaml` | Expone el Service `prometheus:9090` al exterior |
| `12-grafana.yaml` | Grafana consume Prometheus como datasource principal |
| `09-keda-wordpress.yaml` | KEDA usa métricas de Prometheus para el escalado por requests/segundo |

## Advertencias y puntos críticos

- `kube-state-metrics` debe estar instalado en `kube-system` para que el job `kube-state-metrics` en la configuración de scraping funcione. Sin él, las alertas `PodDown`, `OOMKill` y los dashboards de Grafana no tendrán datos.
- La URL `CHANGE_ME_SLACK_WEBHOOK_URL` en la configuración de Alertmanager debe sustituirse antes de usar el sistema en entornos reales. Con la URL de placeholder, las notificaciones fallan silenciosamente.
- La retención de 15 días con 10Gi de PVC puede ser insuficiente en clústeres con alta cardinalidad de métricas. Si el disco se llena, Prometheus elimina bloques antiguos automáticamente, perdiendo histórico.
- El flag `--web.enable-lifecycle` permite recargar la configuración de Prometheus sin reiniciar el pod (via `curl -X POST http://prometheus:9090/-/reload`). Esto es conveniente pero también implica que cualquier pod con acceso a la red interna puede forzar una recarga.
