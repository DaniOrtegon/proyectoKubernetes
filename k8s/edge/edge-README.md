# edge/

Borde de entrada del sistema. Gestiona todo lo que conecta usuarios externos con la aplicación interna: enrutamiento HTTP/HTTPS y certificados TLS automáticos.

| Archivo | Qué hace |
|---|---|
| `ingress.yaml` | NGINX Ingress para WordPress, Grafana y Prometheus — TLS forzado, redirect HTTP→HTTPS |
| `cert-manager.yaml` | Cadena de confianza TLS self-signed: CA raíz → ca-issuer → certificados wordpress-tls y monitoring-tls |
