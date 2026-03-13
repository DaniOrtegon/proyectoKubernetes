# DOC-08 — Ingress con TLS (`08-ingress.yaml`)

## Qué hace este archivo

Define dos recursos `Ingress` que exponen servicios del clúster al exterior mediante el controlador NGINX Ingress:

- **`wordpress-ingress`** (namespace `wordpress`): expone WordPress en el hostname `wp-k8s.local` con TLS y redirección forzada HTTP → HTTPS.
- **`monitoring-ingress`** (namespace `monitoring`): expone Grafana en `grafana.monitoring.local` y Prometheus en `prometheus.monitoring.local`, ambos bajo el mismo certificado TLS multi-SAN.

## Conceptos de Kubernetes utilizados

**Ingress** es un recurso de API que gestiona el acceso HTTP/HTTPS externo a los servicios del clúster. A diferencia de un `Service` de tipo `NodePort` o `LoadBalancer`, el Ingress permite enrutamiento basado en hostname y path, terminación TLS y redirecciones, todo desde un único punto de entrada.

**IngressClass** (`ingressClassName: nginx`) selecciona qué controlador de Ingress debe procesar este recurso. En Minikube se activa con `minikube addons enable ingress`. Sin esta referencia, el recurso queda huérfano si hay más de un controlador instalado.

**Anotaciones NGINX** controlan el comportamiento del controlador sin necesidad de modificar la configuración global del servidor. Las más relevantes aquí son:
- `proxy-body-size: "64m"` — necesario para que WordPress permita subir media de hasta 64 MB.
- `ssl-redirect` y `force-ssl-redirect` — garantizan que cualquier request HTTP recibe un `308 Permanent Redirect` a HTTPS.

**TLS con cert-manager** — la anotación `cert-manager.io/cluster-issuer: "ca-issuer"` delega la gestión del certificado al operador cert-manager (definido en `15-cert-manager.yaml`). cert-manager observa el campo `tls[].secretName` del Ingress, solicita el certificado al ClusterIssuer y almacena el par cert/key en un Secret. El controlador NGINX carga ese Secret automáticamente.

## Decisiones de diseño

El stack de monitoring se expone en el mismo clúster de Ingress que WordPress por simplicidad operativa en Minikube. En producción, el acceso a Prometheus y Grafana debería restringirse a través de autenticación básica o estar detrás de una VPN, ya que ambos exponen información sensible del clúster.

Se reutiliza un único Secret `monitoring-tls` para Grafana y Prometheus usando un certificado con dos SANs. Esto reduce el número de recursos a gestionar y simplifica la renovación automática.

El `proxy-body-size` de 64 MB es coherente con el límite de subida configurado en el `php.ini` del contenedor WordPress. Ambos valores deben mantenerse sincronizados.

## Dependencias

| Archivo | Relación |
|---|---|
| `06-wordpress.yaml` | Define el Service `wordpress:80` referenciado en las rules |
| `10-prometheus.yaml` | Define el Service `prometheus:9090` |
| `12-grafana.yaml` | Define el Service `grafana:3000` |
| `15-cert-manager.yaml` | Provisiona el ClusterIssuer `ca-issuer` y los Certificates `wordpress-tls` y `monitoring-tls` |
| `00-namespace.yaml` | Crea los namespaces `wordpress` y `monitoring` |

## Advertencias y puntos críticos

- Los hostnames `wp-k8s.local`, `grafana.monitoring.local` y `prometheus.monitoring.local` son dominios locales. Para que funcionen hay que añadir la IP de Minikube (`minikube ip`) al fichero `/etc/hosts` del host.
- cert-manager debe estar instalado y el ClusterIssuer `ca-issuer` debe estar en estado `Ready` antes de aplicar este archivo. Si no, el Secret TLS no se crea y el Ingress sirve sin cifrado.
- El certificado generado por `ca-issuer` es self-signed y no está verificado por ninguna CA pública; el navegador mostrará una advertencia de seguridad. En producción se sustituiría por un issuer de Let's Encrypt.
- Si se aumenta `proxy-body-size` en el Ingress, también debe actualizarse `upload_max_filesize` y `post_max_size` en el ConfigMap de PHP de WordPress para mantener la coherencia.
