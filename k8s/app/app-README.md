# app/

Capa de aplicación. Contiene el workload principal del proyecto: WordPress y su política de escalado automático en función de CPU y memoria.

| Archivo | Qué hace |
|---|---|
| `wordpress.yaml` | Deployment WordPress 6.4 — SecurityContext completo, Redis Sentinel, MinIO y OpenTelemetry configurados via env |
| `hpa-wordpress.yaml` | HorizontalPodAutoscaler — escala entre 2 y 5 réplicas (CPU >50%, Memoria >70%) |
