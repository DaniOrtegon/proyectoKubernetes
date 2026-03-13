# DOC-17 — Tracing distribuido: Jaeger + OpenTelemetry (`17-tracing.yaml`)

## Qué hace este archivo

Despliega el stack de trazabilidad distribuida del proyecto:

- **Jaeger all-in-one**: recibe, almacena (en memoria) y visualiza trazas distribuidas. UI accesible en el puerto 16686.
- **OTel Collector DaemonSet**: agente OpenTelemetry desplegado en cada nodo que recibe trazas de los pods y las reenvía a Jaeger. Expone los protocolos OTLP/gRPC (4317) y OTLP/HTTP (4318).
- **Services**: `jaeger-collector` para recepción, `jaeger-query` como alias para el datasource de Grafana, y `otel-collector` para recepción desde aplicaciones.

## Conceptos de Kubernetes utilizados

**OpenTelemetry (OTel)** es el estándar abierto para instrumentación de aplicaciones. Define protocolos (OTLP), SDKs y el Collector como componente de infraestructura. El Collector actúa como intermediario: desacopla las aplicaciones del backend de trazas (Jaeger), permitiendo cambiar el backend sin recompilar las aplicaciones.

**Pipeline de trazas en el OTel Collector** — la configuración del Collector define tres etapas:
- `receivers`: qué protocolos acepta (OTLP/gRPC y HTTP).
- `processors`: transformaciones aplicadas antes de exportar (`memory_limiter` evita OOM; `batch` agrupa spans para eficiencia).
- `exporters`: dónde enviar las trazas (Jaeger via OTLP/gRPC).

**`hostPort`** en los contenedores del DaemonSet expone los puertos del OTel Collector directamente en la interfaz de red del nodo. Esto permite que las aplicaciones en el mismo nodo envíen trazas a `localhost:4317` o `localhost:4318`, reduciendo latencia y simplificando la configuración del SDK.

**Dos Services para Jaeger** (`jaeger-collector` y `jaeger-query`) — aunque apuntan al mismo pod, la separación semántica es útil: `jaeger-collector` es el endpoint de recepción para el OTel Collector; `jaeger-query` es el endpoint para el datasource de Grafana. Esto permite gestionar el acceso a cada función de forma independiente con NetworkPolicies.

**Almacenamiento in-memory** (`SPAN_STORAGE_TYPE=memory`, `MEMORY_MAX_TRACES=10000`) — adecuado para desarrollo pero no persistente. Las trazas se pierden cuando el pod de Jaeger se reinicia. Para producción se usaría Elasticsearch o Cassandra.

## Decisiones de diseño

El OTel Collector se despliega como DaemonSet (uno por nodo) en lugar de un único Deployment centralizado. Esto reduce la latencia de envío de trazas (cada pod habla con el agente local) y distribuye la carga de procesamiento. La contrapartida es mayor consumo de recursos totales del clúster.

WordPress se instrumenta a través de un plugin OTel en lugar de modificar el código directamente. Esto mantiene el núcleo de WordPress sin cambios y hace la instrumentación opcional y configurable.

Se incluye un Service alias `jaeger-query` para el datasource de Grafana porque la UI de Jaeger y el endpoint de query comparten el mismo puerto (16686) en el modo all-in-one. El alias hace explícita la intención y facilita migraciones futuras a arquitecturas separadas (Jaeger Query + Jaeger Collector independientes).

## Dependencias

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | Crea el namespace `monitoring` |
| `12-grafana.yaml` | Grafana puede usar `jaeger-query:16686` como datasource de trazas |
| `06-wordpress.yaml` | WordPress instrumentado con plugin OTel envía trazas al `otel-collector:4317` |
| `07-network-policy.yaml` | Las NetworkPolicies deben permitir tráfico OTLP desde el namespace `wordpress` hacia `monitoring` |

## Advertencias y puntos críticos

- El almacenamiento in-memory de Jaeger limita el número de trazas a 10.000. En un entorno con alto volumen de requests, las trazas más antiguas se descartan automáticamente. No hay manera de recuperarlas.
- Los `hostPort` en el DaemonSet requieren que los puertos 4317 y 4318 estén libres en todos los nodos. Si otra aplicación usa esos puertos, el pod del OTel Collector no arrancará.
- `imagePullPolicy: Never` requiere que las imágenes `jaegertracing/all-in-one:1.52` y `otel/opentelemetry-collector-contrib:0.91.0` estén precargadas en Minikube.
- El `memory_limiter` del OTel Collector (`limit_mib: 128`) protege contra picos de volumen de trazas, pero si se supera el límite, el Collector empieza a descartar spans. Es recomendable monitorizar la métrica `otelcol_processor_dropped_spans_total`.
