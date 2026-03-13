import { useState } from "react";

// ── DATA ────────────────────────────────────────────────────────────────────

const NAMESPACES = {
  wordpress: {
    color: "#3B82F6",
    glow: "#3B82F620",
    label: "wordpress",
    desc: "Capa de presentación — WordPress y su configuración",
    pods: [
      {
        id: "wordpress",
        name: "wordpress",
        kind: "Deployment",
        replicas: "2–5",
        image: "wordpress:6.4",
        icon: "🌐",
        desc: "CMS principal. Stateless: los uploads van a MinIO vía plugin WP Offload Media. Escala horizontalmente con HPA (CPU >50%, Memoria >70%). SecurityContext con runAsUser:33, readOnlyRootFilesystem y capabilities DROP ALL.",
        ports: [80],
        connects: ["mariadb", "redis-sentinel", "minio", "otel-collector"],
      },
    ],
  },
  databases: {
    color: "#F59E0B",
    glow: "#F59E0B20",
    label: "databases",
    desc: "Capa de datos — MariaDB HA + Redis Sentinel",
    pods: [
      {
        id: "mariadb-0",
        name: "mariadb-0",
        kind: "StatefulSet",
        replicas: "1 (Primary)",
        image: "mariadb:10.6",
        icon: "🗄️",
        desc: "Nodo PRIMARY de MariaDB. Gestiona escrituras y lecturas. Binary log habilitado (ROW format) para replicación asíncrona hacia mariadb-1. server-id=1. WordPress conecta siempre al Service 'mariadb' que apunta solo a este pod.",
        ports: [3306],
        connects: ["mariadb-1"],
      },
      {
        id: "mariadb-1",
        name: "mariadb-1",
        kind: "StatefulSet",
        replicas: "1 (Replica)",
        image: "mariadb:10.6",
        icon: "🗄️",
        desc: "Nodo REPLICA de MariaDB. Solo lectura (read-only=1). Recibe replicación asíncrona desde mariadb-0 via relay-log. Configurado por el Job 04b-mariadb-replication-job al desplegar. server-id=2.",
        ports: [3306],
        connects: [],
      },
      {
        id: "redis-0",
        name: "redis-0",
        kind: "StatefulSet",
        replicas: "1 (Master)",
        image: "redis:6.2-alpine",
        icon: "⚡",
        desc: "Master de Redis. Acepta escrituras. Cada pod lleva un sidecar Sentinel que monitoriza la salud del Redis local y se coordina con los otros 2 Sentinels para decidir failover automático (quorum=2).",
        ports: [6379, 26379],
        connects: ["redis-1", "redis-2"],
      },
      {
        id: "redis-1",
        name: "redis-1",
        kind: "StatefulSet",
        replicas: "1 (Replica)",
        image: "redis:6.2-alpine",
        icon: "⚡",
        desc: "Réplica 1 de Redis. Solo lectura. Replica datos del master vía replicaof. Sidecar Sentinel incluido. En caso de fallo del master, Sentinel promueve la réplica con mayor prioridad.",
        ports: [6379, 26379],
        connects: [],
      },
      {
        id: "redis-2",
        name: "redis-2",
        kind: "StatefulSet",
        replicas: "1 (Replica)",
        image: "redis:6.2-alpine",
        icon: "⚡",
        desc: "Réplica 2 de Redis. Solo lectura. Tercer nodo del quorum de Sentinel. Garantiza que siempre hay mayoría para decidir failover incluso si un nodo falla.",
        ports: [6379, 26379],
        connects: [],
      },
    ],
  },
  monitoring: {
    color: "#10B981",
    glow: "#10B98120",
    label: "monitoring",
    desc: "Observabilidad — Métricas, Logs, Trazas y Alertas",
    pods: [
      {
        id: "prometheus",
        name: "prometheus",
        kind: "Deployment",
        replicas: "1",
        image: "prom/prometheus:v2.48.0",
        icon: "📊",
        desc: "Recolecta métricas de todos los pods vía Kubernetes Service Discovery. Evalúa reglas de alerta cada 15s. Implementa SLOs con burn rate (99.9% disponibilidad, error budget 43min/mes). Retención 15 días en PVC de 10Gi.",
        ports: [9090],
        connects: ["alertmanager", "grafana"],
      },
      {
        id: "alertmanager",
        name: "alertmanager",
        kind: "Deployment",
        replicas: "1",
        image: "prom/alertmanager:v0.26.0",
        icon: "🚨",
        desc: "Recibe alertas de Prometheus y las enruta por severidad. Agrupa alertas relacionadas, aplica inhibición (si PodDown activo, suprime HighCPU del mismo pod) y envía a Slack via Incoming Webhook. Repeat interval: 12h.",
        ports: [9093],
        connects: [],
      },
      {
        id: "grafana",
        name: "grafana",
        kind: "Deployment",
        replicas: "1",
        image: "grafana/grafana:10.2.3",
        icon: "📈",
        desc: "Visualización central. Datasources provisionados como código: Prometheus (métricas) y Loki (logs). Dashboards predefinidos: Kubernetes Overview y WordPress K8s Project con variables de namespace. PVC 5Gi para persistencia.",
        ports: [3000],
        connects: ["prometheus", "loki", "jaeger"],
      },
      {
        id: "loki",
        name: "loki",
        kind: "Deployment",
        replicas: "1",
        image: "grafana/loki:2.9.3",
        icon: "📋",
        desc: "Agregación de logs indexada por labels (no por contenido). Schema v13 con TSDB. Retención 31 días. Solo recibe logs de Promtail y los sirve a Grafana. No expuesto al exterior — solo ClusterIP.",
        ports: [3100, 9096],
        connects: [],
      },
      {
        id: "promtail",
        name: "promtail",
        kind: "DaemonSet",
        replicas: "1/nodo",
        image: "grafana/promtail:2.9.3",
        icon: "🔍",
        desc: "Agente de logs desplegado en cada nodo. Lee /var/log y /var/lib/docker/containers del host. Enriquece cada log con metadata de Kubernetes (namespace, pod, container). Filtra solo namespaces relevantes del proyecto.",
        ports: [9080],
        connects: ["loki"],
      },
      {
        id: "jaeger",
        name: "jaeger",
        kind: "Deployment",
        replicas: "1",
        image: "jaegertracing/all-in-one:1.52",
        icon: "🔭",
        desc: "Recibe, almacena y visualiza trazas distribuidas. Modo all-in-one con almacenamiento in-memory (10.000 trazas). Acepta OTLP/gRPC (4317) y HTTP (4318). UI en puerto 16686. En producción se conectaría a Elasticsearch.",
        ports: [16686, 4317, 4318, 14268],
        connects: [],
      },
      {
        id: "otel-collector",
        name: "otel-collector",
        kind: "DaemonSet",
        replicas: "1/nodo",
        image: "otel/opentelemetry-collector-contrib:0.91.0",
        icon: "🔗",
        desc: "Pipeline de trazas: receivers OTLP → processors (memory_limiter + batch) → exporters hacia Jaeger. DaemonSet para latencia mínima — cada pod envía al agente local. Expone hostPort 4317/4318.",
        ports: [4317, 4318],
        connects: ["jaeger"],
      },
    ],
  },
  storage: {
    color: "#8B5CF6",
    glow: "#8B5CF620",
    label: "storage",
    desc: "Almacenamiento de objetos — MinIO S3-compatible",
    pods: [
      {
        id: "minio",
        name: "minio",
        kind: "Deployment",
        replicas: "1",
        image: "minio/minio:latest",
        icon: "🗃️",
        desc: "Servidor S3-compatible. Almacena uploads de WordPress (bucket: wordpress-uploads, acceso público lectura) y backups de MariaDB y uploads (bucket: wordpress-backups). API en 9000, consola en 9001. PVC 10Gi.",
        ports: [9000, 9001],
        connects: [],
      },
    ],
  },
  "cert-manager": {
    color: "#EC4899",
    glow: "#EC489920",
    label: "cert-manager",
    desc: "Gestión automática de certificados TLS",
    pods: [
      {
        id: "cert-manager",
        name: "cert-manager",
        kind: "Operator",
        replicas: "1",
        image: "cert-manager:latest",
        icon: "🔐",
        desc: "Operador que gestiona el ciclo de vida de certificados TLS. Cadena de confianza: selfsigned-issuer → CA raíz (RSA 4096) → ca-issuer → certificados wordpress-tls y monitoring-tls. Renovación automática 30 días antes de expirar.",
        ports: [],
        connects: [],
      },
    ],
  },
  velero: {
    color: "#F97316",
    glow: "#F9731620",
    label: "velero",
    desc: "Backup completo del clúster Kubernetes",
    pods: [
      {
        id: "velero",
        name: "velero",
        kind: "Deployment",
        replicas: "1",
        image: "velero:latest",
        icon: "💾",
        desc: "Backup completo de objetos K8s + snapshots de PVCs vía CSI. Schedule diario 1:00 AM (Europe/Madrid). Namespaces: wordpress + databases. Retención 30 días. Backend: MinIO bucket velero-backups. RTO ~15min.",
        ports: [],
        connects: ["minio"],
      },
    ],
  },
};

const FILES = [
  {
    id: "00",
    name: "00-namespace.yaml",
    icon: "📁",
    category: "Infraestructura",
    desc: "Crea todos los namespaces del proyecto: wordpress, databases, monitoring, storage, cert-manager, velero, security. Aplica labels kubernetes.io/metadata.name necesarias para que los namespaceSelector de las NetworkPolicies funcionen correctamente.",
    concepts: ["Namespace", "Labels"],
  },
  {
    id: "01",
    name: "01-secrets.yaml",
    icon: "🔑",
    category: "Seguridad",
    desc: "Define los Secrets de MariaDB (root + user password), Redis y MinIO en los namespaces que los necesitan. Los Secrets se duplican entre namespaces porque un pod solo puede referenciar Secrets de su propio namespace. Valores en base64.",
    concepts: ["Secret", "Opaque", "base64"],
  },
  {
    id: "02",
    name: "02-configmap.yaml",
    icon: "⚙️",
    category: "Configuración",
    desc: "ConfigMaps con datos no sensibles: host de MariaDB, nombre de BD, usuario y URL del sitio para WordPress; nombre de BD y usuario para MariaDB. Separa configuración de código y permite actualizarla sin reconstruir imágenes.",
    concepts: ["ConfigMap", "Separación config/código"],
  },
  {
    id: "03",
    name: "03-pvc.yaml",
    icon: "💿",
    category: "Almacenamiento",
    desc: "PersistentVolumeClaim de 2Gi para WordPress (core, plugins, themes). ReadWriteOnce — en Minikube con un solo nodo funciona con múltiples réplicas. MariaDB y Redis NO tienen PVC aquí: usan volumeClaimTemplates en sus StatefulSets.",
    concepts: ["PVC", "ReadWriteOnce", "StorageClass"],
  },
  {
    id: "04",
    name: "04-mariadb.yaml",
    icon: "🗄️",
    category: "Base de datos",
    desc: "StatefulSet de 2 réplicas para MariaDB HA. Un script de entrypoint detecta el ordinal del pod (0=PRIMARY, 1=REPLICA) y arranca con la configuración correcta. Service 'mariadb' apunta solo a mariadb-0 via label statefulset.kubernetes.io/pod-name.",
    concepts: ["StatefulSet", "Headless Service", "podAntiAffinity", "initContainers"],
  },
  {
    id: "04b",
    name: "04b-mariadb-replication-job.yaml",
    icon: "🔄",
    category: "Base de datos",
    desc: "Job de inicialización que configura la replicación MariaDB: espera a que ambos pods estén listos, crea el usuario 'replicator' en el primary, captura la posición del binary log y ejecuta CHANGE MASTER TO en la réplica. Se autoeliminan tras 5 minutos.",
    concepts: ["Job", "ttlSecondsAfterFinished", "Binary Log Replication"],
  },
  {
    id: "05",
    name: "05-redis.yaml",
    icon: "⚡",
    category: "Caché",
    desc: "StatefulSet de 3 pods Redis (1 master + 2 replicas) cada uno con un sidecar Sentinel. El script start-redis.sh detecta el ordinal para arrancar como master o replica. Quorum de Sentinel = 2, garantiza failover automático si el master falla.",
    concepts: ["StatefulSet", "Sidecar pattern", "Redis Sentinel", "Quorum"],
  },
  {
    id: "06",
    name: "06-wordpress.yaml",
    icon: "🌐",
    category: "Aplicación",
    desc: "Deployment de WordPress 6.4 con SecurityContext completo (runAsUser:33, readOnlyRootFilesystem, DROP ALL capabilities). Configura Redis Sentinel, MinIO S3 y OpenTelemetry via WORDPRESS_CONFIG_EXTRA. emptyDir para /tmp y /var/run/apache2.",
    concepts: ["Deployment", "SecurityContext", "podAntiAffinity", "startupProbe"],
  },
  {
    id: "07",
    name: "07-network-policy.yaml",
    icon: "🔒",
    category: "Seguridad",
    desc: "19 NetworkPolicies implementando modelo zero-trust: default-deny en todos los namespaces + políticas explícitas de allow. Cubre: WordPress↔MariaDB/Redis/MinIO/OTel, Prometheus scraping, Loki↔Promtail/Grafana, backups CronJobs, replicación MariaDB.",
    concepts: ["NetworkPolicy", "Zero-trust", "namespaceSelector", "podSelector"],
  },
  {
    id: "08",
    name: "08-ingress.yaml",
    icon: "🚪",
    category: "Red",
    desc: "Dos recursos Ingress NGINX: wordpress-ingress (wp-k8s.local, proxy-body-size 64m) y monitoring-ingress (grafana + prometheus con certificado multi-SAN). TLS forzado con cert-manager via anotación cluster-issuer.",
    concepts: ["Ingress", "IngressClass", "TLS termination", "Virtual hosting"],
  },
  {
    id: "09",
    name: "09-hpa-wordpress.yaml",
    icon: "📈",
    category: "Escalado",
    desc: "HorizontalPodAutoscaler v2 con dos métricas: CPU >50% y Memoria >70%. Rango 2–5 réplicas. Los techos están calibrados contra la ResourceQuota del namespace (5 pods × requests = dentro del límite de 2Gi).",
    concepts: ["HPA v2", "autoscaling/v2", "múltiples métricas", "Metrics Server"],
  },
  {
    id: "10",
    name: "10-prometheus.yaml",
    icon: "📊",
    category: "Observabilidad",
    desc: "Prometheus + Alertmanager completos. Service Discovery con RBAC para nodos, cAdvisor y pods. Reglas de alerta: PodDown, OOMKill, HighCPU, MariaDBDown. SLOs con burn rate multi-ventana (14.4x crítico, 3x warning). Slack como canal de notificación.",
    concepts: ["ClusterRole", "kubernetes_sd_configs", "relabeling", "SLO burn rate"],
  },
  {
    id: "11",
    name: "11-loki.yaml",
    icon: "📋",
    category: "Observabilidad",
    desc: "Loki con schema v13/TSDB y Promtail DaemonSet. Retención 31 días con compactor automático. Promtail monta hostPath del nodo y usa Service Discovery para enriquecer logs con metadata de pods. Filtra solo namespaces del proyecto.",
    concepts: ["DaemonSet", "hostPath", "ClusterRole", "log aggregation"],
  },
  {
    id: "12",
    name: "12-grafana.yaml",
    icon: "📉",
    category: "Observabilidad",
    desc: "Grafana con provisioning como código: datasources (Prometheus + Loki), proveedor de dashboards y dos dashboards JSON embebidos en ConfigMaps. subPath para montar ficheros individuales. Credenciales desde Secret.",
    concepts: ["Provisioning", "subPath volumeMount", "Dashboard as code"],
  },
  {
    id: "13",
    name: "13-pdb.yaml",
    icon: "🛡️",
    category: "Disponibilidad",
    desc: "PodDisruptionBudget para WordPress con minAvailable:1. Garantiza que kubectl drain y rolling updates nunca dejan el servicio sin pods. Solo protege contra disrupciones voluntarias — no contra fallos de nodo.",
    concepts: ["PodDisruptionBudget", "disrupciones voluntarias", "minAvailable"],
  },
  {
    id: "14",
    name: "14-resource-quota.yaml",
    icon: "⚖️",
    category: "Gobernanza",
    desc: "LimitRange + ResourceQuota para namespaces wordpress y databases. Valores calculados para soportar HPA maxReplicas:5. LimitRange asigna defaults a pods sin resources declarados. Aislamiento de recursos entre namespaces.",
    concepts: ["LimitRange", "ResourceQuota", "requests vs limits", "QoS"],
  },
  {
    id: "15",
    name: "15-cert-manager.yaml",
    icon: "🔐",
    category: "Seguridad",
    desc: "Cadena de confianza TLS self-signed en 5 pasos: selfsigned-issuer → CA raíz RSA 4096 → ca-issuer → certificados wordpress-tls y monitoring-tls (multi-SAN). Renovación automática 30 días antes de expirar. CA en namespace cert-manager.",
    concepts: ["ClusterIssuer", "Certificate", "SAN", "PKI chain"],
  },
  {
    id: "16",
    name: "16-minio.yaml",
    icon: "🗃️",
    category: "Almacenamiento",
    desc: "MinIO S3-compatible en namespace storage. Job de inicialización crea buckets wordpress-uploads (público lectura) y wordpress-backups. Secrets duplicados en namespaces storage y wordpress. Hace WordPress stateless respecto a media.",
    concepts: ["Object Storage", "S3 API", "Job init pattern", "stateless apps"],
  },
  {
    id: "17",
    name: "17-tracing.yaml",
    icon: "🔭",
    category: "Observabilidad",
    desc: "Jaeger all-in-one + OTel Collector DaemonSet. Pipeline: WordPress → OTel Collector (hostPort 4317/4318) → Jaeger (memoria, 10k trazas) → Grafana datasource. Dos Services para Jaeger: jaeger-collector y jaeger-query (alias para Grafana).",
    concepts: ["OpenTelemetry", "DaemonSet", "hostPort", "OTLP protocol"],
  },
  {
    id: "18",
    name: "18-backup.yaml",
    icon: "💿",
    category: "Backup",
    desc: "3 CronJobs: mariadb-backup (2AM, mysqldump + gzip → MinIO), wordpress-uploads-backup (3AM, tar.gz → MinIO), backup-cleanup (domingo 4AM, elimina >30 días). Job de restauración suspendido con instrucciones inline. RPO ~24h, RTO ~15min.",
    concepts: ["CronJob", "concurrencyPolicy", "ttlSecondsAfterFinished", "RPO/RTO"],
  },
  {
    id: "19",
    name: "19-velero.yaml",
    icon: "💾",
    category: "Backup",
    desc: "Velero backup completo: objetos K8s + snapshots CSI de PVCs. Backend MinIO (bucket velero-backups). Schedule diario 1AM. NetworkPolicy permite egress hacia MinIO:9000 y API K8s:6443. Restauración: velero restore create --from-backup.",
    concepts: ["Velero", "CSI snapshots", "NetworkPolicy egress", "cluster backup"],
  },
];

// ── COMPONENTS ───────────────────────────────────────────────────────────────

const ns_colors = {
  wordpress: { bg: "#1E3A5F", border: "#3B82F6", text: "#93C5FD", accent: "#3B82F6" },
  databases: { bg: "#3D2B0A", border: "#F59E0B", text: "#FCD34D", accent: "#F59E0B" },
  monitoring: { bg: "#0A2E1F", border: "#10B981", text: "#6EE7B7", accent: "#10B981" },
  storage: { bg: "#2D1B69", border: "#8B5CF6", text: "#C4B5FD", accent: "#8B5CF6" },
  "cert-manager": { bg: "#4A0E2E", border: "#EC4899", text: "#F9A8D4", accent: "#EC4899" },
  velero: { bg: "#431407", border: "#F97316", text: "#FDBA74", accent: "#F97316" },
};

function PodCard({ pod, nsColor, selected, onClick }) {
  return (
    <button
      onClick={onClick}
      style={{
        background: selected ? nsColor.accent + "22" : "#0D1117",
        border: `1px solid ${selected ? nsColor.accent : "#2A3441"}`,
        borderRadius: 8,
        padding: "10px 12px",
        cursor: "pointer",
        textAlign: "left",
        transition: "all 0.2s",
        width: "100%",
        boxShadow: selected ? `0 0 12px ${nsColor.accent}44` : "none",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
        <span style={{ fontSize: 18 }}>{pod.icon}</span>
        <div>
          <div style={{ color: nsColor.text, fontSize: 13, fontWeight: 600, fontFamily: "'JetBrains Mono', monospace" }}>
            {pod.name}
          </div>
          <div style={{ color: "#64748B", fontSize: 11, marginTop: 2 }}>
            {pod.kind} · {pod.replicas}
          </div>
        </div>
      </div>
    </button>
  );
}

function DetailPanel({ item, type, onClose, nsColor }) {
  if (!item) return null;
  const color = nsColor || { accent: "#3B82F6", text: "#93C5FD", bg: "#1E3A5F" };

  return (
    <div style={{
      position: "fixed",
      right: 0, top: 0, bottom: 0,
      width: 380,
      background: "#0D1117",
      borderLeft: `1px solid ${color.accent}44`,
      zIndex: 100,
      overflowY: "auto",
      padding: 24,
      boxShadow: `-8px 0 32px ${color.accent}22`,
    }}>
      <button onClick={onClose} style={{
        background: "none", border: "1px solid #2A3441", color: "#64748B",
        padding: "4px 10px", borderRadius: 6, cursor: "pointer", marginBottom: 20,
        fontSize: 12,
      }}>← cerrar</button>

      <div style={{ fontSize: 32, marginBottom: 12 }}>{item.icon}</div>
      <div style={{ color: color.accent, fontSize: 11, fontFamily: "'JetBrains Mono', monospace", marginBottom: 6, textTransform: "uppercase", letterSpacing: 2 }}>
        {type === "pod" ? item.kind : item.category}
      </div>
      <div style={{ color: "#E2E8F0", fontSize: 20, fontWeight: 700, marginBottom: 16, lineHeight: 1.3 }}>
        {item.name}
      </div>

      {item.image && (
        <div style={{ background: "#161B22", border: "1px solid #2A3441", borderRadius: 6, padding: "8px 12px", marginBottom: 16 }}>
          <div style={{ color: "#64748B", fontSize: 10, marginBottom: 4, textTransform: "uppercase", letterSpacing: 1 }}>Image</div>
          <div style={{ color: "#7DD3FC", fontSize: 12, fontFamily: "'JetBrains Mono', monospace" }}>{item.image}</div>
        </div>
      )}

      <div style={{ color: "#94A3B8", fontSize: 13, lineHeight: 1.7, marginBottom: 20 }}>
        {item.desc}
      </div>

      {item.ports && item.ports.length > 0 && (
        <div style={{ marginBottom: 16 }}>
          <div style={{ color: "#64748B", fontSize: 10, textTransform: "uppercase", letterSpacing: 1, marginBottom: 8 }}>Puertos</div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
            {item.ports.map(p => (
              <span key={p} style={{
                background: color.accent + "22", border: `1px solid ${color.accent}44`,
                color: color.text, borderRadius: 4, padding: "2px 8px", fontSize: 12,
                fontFamily: "'JetBrains Mono', monospace",
              }}>{p}</span>
            ))}
          </div>
        </div>
      )}

      {item.connects && item.connects.length > 0 && (
        <div style={{ marginBottom: 16 }}>
          <div style={{ color: "#64748B", fontSize: 10, textTransform: "uppercase", letterSpacing: 1, marginBottom: 8 }}>Conecta con</div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
            {item.connects.map(c => (
              <span key={c} style={{
                background: "#161B22", border: "1px solid #2A3441",
                color: "#94A3B8", borderRadius: 4, padding: "2px 8px", fontSize: 12,
                fontFamily: "'JetBrains Mono', monospace",
              }}>{c}</span>
            ))}
          </div>
        </div>
      )}

      {item.concepts && (
        <div>
          <div style={{ color: "#64748B", fontSize: 10, textTransform: "uppercase", letterSpacing: 1, marginBottom: 8 }}>Conceptos K8s</div>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
            {item.concepts.map(c => (
              <span key={c} style={{
                background: "#1E293B", border: "1px solid #334155",
                color: "#94A3B8", borderRadius: 4, padding: "2px 8px", fontSize: 11,
              }}>{c}</span>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

// ── DIAGRAM TAB ───────────────────────────────────────────────────────────────

const ARCH_NODES = [
  { id: "user", label: "Usuario", icon: "👤", x: 50, y: 180, color: "#64748B" },
  { id: "ingress", label: "NGINX Ingress", icon: "🚪", x: 170, y: 180, color: "#3B82F6", ns: "kube-system" },
  { id: "wordpress", label: "WordPress\n2–5 pods", icon: "🌐", x: 330, y: 120, color: "#3B82F6", ns: "wordpress" },
  { id: "mariadb", label: "MariaDB\nPrimary+Replica", icon: "🗄️", x: 330, y: 260, color: "#F59E0B", ns: "databases" },
  { id: "redis", label: "Redis Sentinel\n1M+2R+3S", icon: "⚡", x: 490, y: 260, color: "#F59E0B", ns: "databases" },
  { id: "minio", label: "MinIO\nS3 Storage", icon: "🗃️", x: 490, y: 120, color: "#8B5CF6", ns: "storage" },
  { id: "prometheus", label: "Prometheus\n+ Alertmanager", icon: "📊", x: 650, y: 120, color: "#10B981", ns: "monitoring" },
  { id: "grafana", label: "Grafana", icon: "📈", x: 650, y: 220, color: "#10B981", ns: "monitoring" },
  { id: "loki", label: "Loki\n+ Promtail", icon: "📋", x: 650, y: 320, color: "#10B981", ns: "monitoring" },
  { id: "jaeger", label: "Jaeger\n+ OTel", icon: "🔭", x: 790, y: 180, color: "#10B981", ns: "monitoring" },
  { id: "velero", label: "Velero\nBackup", icon: "💾", x: 790, y: 320, color: "#F97316", ns: "velero" },
  { id: "certmgr", label: "cert-manager\nTLS", icon: "🔐", x: 170, y: 320, color: "#EC4899", ns: "cert-manager" },
];

const ARCH_EDGES = [
  { from: "user", to: "ingress", label: "HTTPS" },
  { from: "ingress", to: "wordpress", label: "HTTP/80" },
  { from: "ingress", to: "grafana", label: "HTTP/3000" },
  { from: "wordpress", to: "mariadb", label: "3306" },
  { from: "wordpress", to: "redis", label: "Sentinel\n26379" },
  { from: "wordpress", to: "minio", label: "S3/9000" },
  { from: "prometheus", to: "wordpress", label: "scrape" },
  { from: "prometheus", to: "mariadb", label: "scrape" },
  { from: "grafana", to: "prometheus", label: "query" },
  { from: "grafana", to: "loki", label: "query" },
  { from: "grafana", to: "jaeger", label: "traces" },
  { from: "wordpress", to: "jaeger", label: "OTLP" },
  { from: "velero", to: "minio", label: "backup" },
  { from: "certmgr", to: "ingress", label: "TLS certs" },
];

function DiagramTab({ onSelectNode }) {
  const [hovered, setHovered] = useState(null);
  const W = 900, H = 440;
  const nodeMap = Object.fromEntries(ARCH_NODES.map(n => [n.id, n]));

  return (
    <div style={{ overflowX: "auto" }}>
      <div style={{ color: "#64748B", fontSize: 12, marginBottom: 12, textAlign: "center" }}>
        Haz clic en cualquier componente para ver detalles
      </div>
      <svg width={W} height={H} style={{ display: "block", margin: "0 auto" }}>
        <defs>
          <marker id="arrow" markerWidth="8" markerHeight="8" refX="6" refY="3" orient="auto">
            <path d="M0,0 L0,6 L8,3 z" fill="#334155" />
          </marker>
        </defs>

        {/* Edges */}
        {ARCH_EDGES.map((e, i) => {
          const f = nodeMap[e.from], t = nodeMap[e.to];
          if (!f || !t) return null;
          const mx = (f.x + t.x) / 2, my = (f.y + t.y) / 2;
          return (
            <g key={i}>
              <line
                x1={f.x + 55} y1={f.y + 28} x2={t.x + 55} y2={t.y + 28}
                stroke="#2A3441" strokeWidth={1.5} strokeDasharray="4 3"
                markerEnd="url(#arrow)"
              />
              <text x={mx + 55} y={my + 24} fill="#475569" fontSize={9}
                textAnchor="middle" fontFamily="monospace">
                {e.label?.split("\n").map((l, li) => (
                  <tspan key={li} x={mx + 55} dy={li === 0 ? 0 : 11}>{l}</tspan>
                ))}
              </text>
            </g>
          );
        })}

        {/* Nodes */}
        {ARCH_NODES.map(node => {
          const isHov = hovered === node.id;
          return (
            <g key={node.id} style={{ cursor: "pointer" }}
              onClick={() => onSelectNode(node)}
              onMouseEnter={() => setHovered(node.id)}
              onMouseLeave={() => setHovered(null)}>
              <rect x={node.x} y={node.y} width={110} height={56}
                rx={8}
                fill={isHov ? node.color + "22" : "#0D1117"}
                stroke={isHov ? node.color : "#2A3441"}
                strokeWidth={isHov ? 2 : 1}
              />
              {isHov && <rect x={node.x} y={node.y} width={110} height={56}
                rx={8} fill="none" stroke={node.color} strokeWidth={1}
                opacity={0.3}
                style={{ filter: `blur(4px)` }} />}
              <text x={node.x + 12} y={node.y + 20} fontSize={18}>{node.icon}</text>
              {node.label.split("\n").map((l, li) => (
                <text key={li} x={node.x + 55} y={node.y + 32 + li * 13}
                  fill={isHov ? node.color : "#94A3B8"}
                  fontSize={li === 0 ? 10 : 9}
                  fontWeight={li === 0 ? 600 : 400}
                  textAnchor="middle"
                  fontFamily={li === 0 ? "inherit" : "monospace"}>
                  {l}
                </text>
              ))}
              {node.ns && (
                <text x={node.x + 55} y={node.y + 68}
                  fill={node.color} fontSize={8} textAnchor="middle" opacity={0.6}>
                  {node.ns}
                </text>
              )}
            </g>
          );
        })}
      </svg>

      {/* Legend */}
      <div style={{ display: "flex", gap: 20, justifyContent: "center", marginTop: 16, flexWrap: "wrap" }}>
        {[
          { color: "#3B82F6", label: "wordpress" },
          { color: "#F59E0B", label: "databases" },
          { color: "#10B981", label: "monitoring" },
          { color: "#8B5CF6", label: "storage" },
          { color: "#EC4899", label: "cert-manager" },
          { color: "#F97316", label: "velero" },
        ].map(({ color, label }) => (
          <div key={label} style={{ display: "flex", alignItems: "center", gap: 6 }}>
            <div style={{ width: 10, height: 10, borderRadius: 2, background: color }} />
            <span style={{ color: "#64748B", fontSize: 11, fontFamily: "monospace" }}>{label}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── FILES TAB ────────────────────────────────────────────────────────────────

function FilesTab({ onSelectFile }) {
  const [filter, setFilter] = useState("Todos");
  const categories = ["Todos", ...Array.from(new Set(FILES.map(f => f.category)))];
  const filtered = filter === "Todos" ? FILES : FILES.filter(f => f.category === filter);

  const catColors = {
    "Infraestructura": "#64748B", "Seguridad": "#EC4899", "Configuración": "#F59E0B",
    "Almacenamiento": "#8B5CF6", "Base de datos": "#F59E0B", "Caché": "#EF4444",
    "Aplicación": "#3B82F6", "Red": "#06B6D4", "Escalado": "#10B981",
    "Observabilidad": "#10B981", "Disponibilidad": "#3B82F6", "Gobernanza": "#64748B",
    "Backup": "#F97316",
  };

  return (
    <div>
      {/* Filter bar */}
      <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 20 }}>
        {categories.map(c => (
          <button key={c} onClick={() => setFilter(c)} style={{
            background: filter === c ? "#1E293B" : "transparent",
            border: `1px solid ${filter === c ? "#3B82F6" : "#2A3441"}`,
            color: filter === c ? "#7DD3FC" : "#64748B",
            borderRadius: 6, padding: "4px 12px", cursor: "pointer", fontSize: 12,
            transition: "all 0.15s",
          }}>{c}</button>
        ))}
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(340px, 1fr))", gap: 12 }}>
        {filtered.map(file => (
          <button key={file.id} onClick={() => onSelectFile(file)} style={{
            background: "#0D1117", border: "1px solid #1E293B",
            borderRadius: 10, padding: 16, cursor: "pointer", textAlign: "left",
            transition: "all 0.15s",
          }}
            onMouseEnter={e => { e.currentTarget.style.borderColor = catColors[file.category] || "#3B82F6"; e.currentTarget.style.background = "#161B22"; }}
            onMouseLeave={e => { e.currentTarget.style.borderColor = "#1E293B"; e.currentTarget.style.background = "#0D1117"; }}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 8 }}>
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{ fontSize: 20 }}>{file.icon}</span>
                <span style={{ color: "#E2E8F0", fontSize: 13, fontWeight: 600, fontFamily: "'JetBrains Mono', monospace" }}>
                  {file.name}
                </span>
              </div>
              <span style={{
                background: (catColors[file.category] || "#3B82F6") + "22",
                color: catColors[file.category] || "#3B82F6",
                border: `1px solid ${catColors[file.category] || "#3B82F6"}44`,
                borderRadius: 4, padding: "2px 8px", fontSize: 10, whiteSpace: "nowrap",
              }}>{file.category}</span>
            </div>
            <div style={{ color: "#64748B", fontSize: 12, lineHeight: 1.6 }}>
              {file.desc.length > 120 ? file.desc.slice(0, 120) + "…" : file.desc}
            </div>
          </button>
        ))}
      </div>
    </div>
  );
}

// ── NAMESPACES TAB ───────────────────────────────────────────────────────────

function NamespacesTab({ onSelectPod }) {
  const [expanded, setExpanded] = useState(Object.keys(NAMESPACES).reduce((a, k) => ({ ...a, [k]: true }), {}));

  const toggle = (k) => setExpanded(p => ({ ...p, [k]: !p[k] }));

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
      {Object.entries(NAMESPACES).map(([nsKey, ns]) => {
        const colors = ns_colors[nsKey] || { bg: "#1E293B", border: "#334155", text: "#94A3B8", accent: "#64748B" };
        const isOpen = expanded[nsKey];
        return (
          <div key={nsKey} style={{
            border: `1px solid ${colors.border}44`,
            borderRadius: 12,
            overflow: "hidden",
            background: colors.bg + "88",
          }}>
            {/* Header */}
            <button onClick={() => toggle(nsKey)} style={{
              width: "100%", background: "none", border: "none", cursor: "pointer",
              padding: "14px 20px", display: "flex", alignItems: "center", justifyContent: "space-between",
              borderBottom: isOpen ? `1px solid ${colors.border}33` : "none",
            }}>
              <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
                <div style={{
                  width: 8, height: 8, borderRadius: "50%", background: colors.accent,
                  boxShadow: `0 0 8px ${colors.accent}`,
                }} />
                <span style={{ color: colors.text, fontSize: 15, fontWeight: 700, fontFamily: "'JetBrains Mono', monospace" }}>
                  namespace/{nsKey}
                </span>
                <span style={{ color: "#475569", fontSize: 12 }}>{ns.desc}</span>
              </div>
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{
                  background: colors.accent + "22", color: colors.accent,
                  border: `1px solid ${colors.accent}44`, borderRadius: 4,
                  padding: "2px 8px", fontSize: 11,
                }}>{ns.pods.length} pod{ns.pods.length !== 1 ? "s" : ""}</span>
                <span style={{ color: "#475569", fontSize: 14 }}>{isOpen ? "▲" : "▼"}</span>
              </div>
            </button>

            {/* Pods grid */}
            {isOpen && (
              <div style={{ padding: "16px 20px", display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(200px, 1fr))", gap: 10 }}>
                {ns.pods.map(pod => (
                  <button key={pod.id} onClick={() => onSelectPod(pod, colors)} style={{
                    background: "#0D1117",
                    border: `1px solid ${colors.border}44`,
                    borderRadius: 8, padding: "12px 14px",
                    cursor: "pointer", textAlign: "left",
                    transition: "all 0.15s",
                  }}
                    onMouseEnter={e => { e.currentTarget.style.borderColor = colors.accent; e.currentTarget.style.background = colors.accent + "11"; }}
                    onMouseLeave={e => { e.currentTarget.style.borderColor = colors.border + "44"; e.currentTarget.style.background = "#0D1117"; }}>
                    <div style={{ fontSize: 22, marginBottom: 6 }}>{pod.icon}</div>
                    <div style={{ color: colors.text, fontSize: 12, fontWeight: 600, fontFamily: "'JetBrains Mono', monospace", marginBottom: 4 }}>
                      {pod.name}
                    </div>
                    <div style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
                      <span style={{
                        background: colors.accent + "22", color: colors.accent,
                        borderRadius: 3, padding: "1px 6px", fontSize: 10,
                      }}>{pod.kind}</span>
                      <span style={{
                        background: "#1E293B", color: "#64748B",
                        borderRadius: 3, padding: "1px 6px", fontSize: 10,
                      }}>{pod.replicas}</span>
                    </div>
                    {pod.ports && pod.ports.length > 0 && (
                      <div style={{ marginTop: 6, color: "#475569", fontSize: 10, fontFamily: "monospace" }}>
                        :{pod.ports.join(", :")}
                      </div>
                    )}
                  </button>
                ))}
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ── MAIN APP ─────────────────────────────────────────────────────────────────

export default function App() {
  const [tab, setTab] = useState("diagram");
  const [selected, setSelected] = useState(null);
  const [selectedType, setSelectedType] = useState(null);
  const [selectedNsColor, setSelectedNsColor] = useState(null);

  const handleSelectPod = (pod, nsColor) => {
    setSelected(pod);
    setSelectedType("pod");
    setSelectedNsColor(nsColor);
  };

  const handleSelectFile = (file) => {
    setSelected(file);
    setSelectedType("file");
    setSelectedNsColor({ accent: "#3B82F6", text: "#93C5FD", bg: "#1E3A5F" });
  };

  const handleSelectNode = (node) => {
    // Find matching pod data
    const nsKey = node.ns;
    const ns = NAMESPACES[nsKey];
    if (ns) {
      const pod = ns.pods.find(p => p.id === node.id || p.name === node.id);
      if (pod) {
        handleSelectPod(pod, ns_colors[nsKey]);
        return;
      }
    }
    // Fallback: show node info
    setSelected({ ...node, name: node.label.replace("\n", " "), desc: `Componente ${node.label} del namespace ${node.ns || "sistema"}`, image: null, ports: [], connects: [] });
    setSelectedType("pod");
    setSelectedNsColor({ accent: node.color, text: node.color, bg: "#1E293B" });
  };

  const tabs = [
    { id: "diagram", label: "Arquitectura", icon: "🗺️" },
    { id: "files", label: "Archivos", icon: "📄" },
    { id: "namespaces", label: "Namespaces", icon: "📦" },
  ];

  return (
    <div style={{
      minHeight: "100vh",
      background: "#060B12",
      fontFamily: "'Inter', -apple-system, sans-serif",
      color: "#E2E8F0",
      paddingRight: selected ? 380 : 0,
      transition: "padding-right 0.3s",
    }}>
      {/* Header */}
      <div style={{
        borderBottom: "1px solid #1E293B",
        padding: "16px 28px",
        display: "flex",
        alignItems: "center",
        gap: 16,
        background: "#0D1117",
      }}>
        <div style={{
          width: 36, height: 36, borderRadius: 8,
          background: "linear-gradient(135deg, #3B82F6, #8B5CF6)",
          display: "flex", alignItems: "center", justifyContent: "center",
          fontSize: 18,
        }}>⎈</div>
        <div>
          <div style={{ fontSize: 16, fontWeight: 700, color: "#F8FAFC", letterSpacing: "-0.3px" }}>
            KubeNet
          </div>
          <div style={{ fontSize: 11, color: "#475569", fontFamily: "monospace" }}>
            WordPress HA · Minikube · 7 namespaces · 19 NetworkPolicies
          </div>
        </div>

        <div style={{ marginLeft: "auto", display: "flex", gap: 4 }}>
          {tabs.map(t => (
            <button key={t.id} onClick={() => setTab(t.id)} style={{
              background: tab === t.id ? "#1E293B" : "transparent",
              border: `1px solid ${tab === t.id ? "#3B82F6" : "transparent"}`,
              color: tab === t.id ? "#7DD3FC" : "#64748B",
              borderRadius: 8, padding: "8px 16px", cursor: "pointer",
              fontSize: 13, fontWeight: tab === t.id ? 600 : 400,
              display: "flex", alignItems: "center", gap: 6,
              transition: "all 0.15s",
            }}>
              <span>{t.icon}</span> {t.label}
            </button>
          ))}
        </div>
      </div>

      {/* Stats bar */}
      <div style={{
        display: "flex", gap: 0, borderBottom: "1px solid #1E293B",
        background: "#0D1117",
      }}>
        {[
          { label: "Namespaces", val: "7", color: "#3B82F6" },
          { label: "Workloads", val: "14", color: "#10B981" },
          { label: "Archivos YAML", val: "20", color: "#F59E0B" },
          { label: "NetworkPolicies", val: "19", color: "#EC4899" },
          { label: "Certificados TLS", val: "2", color: "#8B5CF6" },
          { label: "CronJobs", val: "3", color: "#F97316" },
        ].map(s => (
          <div key={s.label} style={{
            flex: 1, padding: "10px 20px", borderRight: "1px solid #1E293B",
            textAlign: "center",
          }}>
            <div style={{ color: s.color, fontSize: 20, fontWeight: 800, fontFamily: "monospace" }}>{s.val}</div>
            <div style={{ color: "#475569", fontSize: 10, marginTop: 2 }}>{s.label}</div>
          </div>
        ))}
      </div>

      {/* Content */}
      <div style={{ padding: "24px 28px" }}>
        {tab === "diagram" && (
          <DiagramTab onSelectNode={handleSelectNode} />
        )}
        {tab === "files" && (
          <FilesTab onSelectFile={handleSelectFile} />
        )}
        {tab === "namespaces" && (
          <NamespacesTab onSelectPod={handleSelectPod} />
        )}
      </div>

      {/* Detail panel */}
      {selected && (
        <DetailPanel
          item={selected}
          type={selectedType}
          nsColor={selectedNsColor}
          onClose={() => setSelected(null)}
        />
      )}
    </div>
  );
}
