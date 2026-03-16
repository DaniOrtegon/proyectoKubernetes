# observability/

Capa de observabilidad. Despliega el stack completo de monitorización del proyecto: métricas con Prometheus, logs con Loki y trazas con Jaeger, todo integrado en Grafana como punto de acceso único.

| Archivo | Qué hace |
|---|---|
| `prometheus.yaml` | Prometheus + Alertmanager — métricas, SLOs y alertas a Slack |
| `grafana.yaml` | Grafana — dashboards y datasources provisionados automáticamente |
| `loki.yaml` | Loki + Promtail DaemonSet — logs centralizados con retención 31 días |
| `tracing.yaml` | Jaeger + OTel Collector DaemonSet — trazas distribuidas de WordPress |
