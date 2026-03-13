# DOC-15 — TLS con cert-manager (`15-cert-manager.yaml`)

## Qué hace este archivo

Configura la cadena de confianza TLS completa del clúster usando cert-manager con certificados self-signed. Define cinco recursos en orden de dependencia:

1. `ClusterIssuer` **selfsigned-issuer**: emisor bootstrap para crear la CA raíz.
2. `Certificate` **selfsigned-ca**: genera el par de claves de la CA raíz local.
3. `ClusterIssuer` **ca-issuer**: emisor principal que firma certificados usando la CA raíz.
4. `Certificate` **wordpress-tls**: certificado TLS para `wp-k8s.local`.
5. `Certificate` **monitoring-tls**: certificado TLS multi-SAN para Grafana y Prometheus.

## Conceptos de Kubernetes utilizados

**cert-manager** es un operador de Kubernetes que automatiza la gestión del ciclo de vida de certificados TLS: solicitud, emisión, almacenamiento en Secrets y renovación automática. Observa recursos `Certificate` e `Ingress` y actúa como agente entre la aplicación y la autoridad certificadora.

**ClusterIssuer vs Issuer** — un `Issuer` solo puede emitir certificados para el namespace en el que está creado. Un `ClusterIssuer` puede emitir certificados para cualquier namespace del clúster. En este proyecto se usa `ClusterIssuer` porque los certificados de WordPress (namespace `wordpress`) y monitoring (namespace `monitoring`) son emitidos por el mismo emisor.

**Cadena de confianza en dos pasos (bootstrap)** — el patrón usado es:
1. El `ClusterIssuer` `selfsigned-issuer` se auto-firma (sin CA externa). Se usa únicamente para crear la CA raíz.
2. El `Certificate` `selfsigned-ca` le pide a `selfsigned-issuer` un certificado marcado como `isCA: true`, que cert-manager almacena en el Secret `selfsigned-ca-secret` en el namespace `cert-manager`.
3. El `ClusterIssuer` `ca-issuer` usa ese Secret como su clave de firma. A partir de este punto, `ca-issuer` actúa como una CA privada del clúster.

**Integración con Ingress** — la anotación `cert-manager.io/cluster-issuer: "ca-issuer"` en un Ingress le indica a cert-manager que gestione automáticamente el certificado para los hosts de ese Ingress. cert-manager crea el `Certificate` correspondiente y almacena el resultado en el `secretName` especificado en el bloque `tls` del Ingress.

**Renovación automática** — los certificados tienen `duration: 8760h` (1 año) y `renewBefore: 720h` (30 días). cert-manager renueva el certificado automáticamente 30 días antes de su expiración, sin intervención manual y sin downtime.

## Decisiones de diseño

Se usa una CA raíz privada en lugar de certificados Let's Encrypt porque Minikube no es accesible desde internet, y Let's Encrypt requiere validación HTTP-01 o DNS-01 con un dominio público. La CA self-signed genera certificados técnicamente válidos para TLS, aunque no verificados por browsers.

El Secret de la CA raíz (`selfsigned-ca-secret`) se crea en el namespace `cert-manager` (no en `default`) porque los `ClusterIssuer` solo pueden leer Secrets del namespace donde está instalado cert-manager. Es un requisito técnico del operador.

La clave RSA de 4096 bits para la CA raíz es más grande de lo estrictamente necesario para un entorno local, pero es una buena práctica y el coste de generación solo se paga una vez.

## Dependencias

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | Crea los namespaces `cert-manager`, `wordpress` y `monitoring` |
| `08-ingress.yaml` | Referencia los Secrets `wordpress-tls` y `monitoring-tls` generados por este archivo |

## Advertencias y puntos críticos

- cert-manager debe instalarse en el clúster **antes** de aplicar este archivo. Normalmente se instala via Helm o con `kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/vX.Y.Z/cert-manager.yaml`.
- El orden de aplicación es crítico: `selfsigned-issuer` → `selfsigned-ca` → `ca-issuer` → Certificates. Si se aplica todo a la vez con `kubectl apply`, cert-manager puede intentar resolver `ca-issuer` antes de que el Secret `selfsigned-ca-secret` exista, quedando en estado `NotReady` temporalmente. Se resuelve solo tras unos segundos de reconciliación.
- Los certificados self-signed causan advertencias en browsers y herramientas que validan la cadena de confianza. Para confiar en ellos localmente, hay que importar el certificado de la CA raíz (`selfsigned-ca-secret`) en el almacén de certificados del sistema operativo o del browser.
- `renewBefore: 720h` (30 días) implica que cert-manager intentará renovar el certificado cuando queden 30 días de los 365. Si cert-manager no está operativo en ese momento, el certificado expirará. Monitorizar el estado de los recursos `Certificate` con `kubectl get certificates -A`.
