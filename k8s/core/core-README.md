# core/

Fundamentos del clúster. Define los namespaces, credenciales, configuración no sensible, políticas de red, límites de recursos y presupuestos de interrupción. Debe aplicarse antes que cualquier otro bloque.

| Archivo | Qué hace |
|---|---|
| `namespace.yaml` | Crea todos los namespaces del proyecto |
| `secrets.yaml` | Credenciales de MariaDB, Redis y MinIO |
| `configmap.yaml` | Configuración no sensible de WordPress y MariaDB |
| `network-policy.yaml` | 19 políticas zero-trust entre namespaces |
| `resource-quota.yaml` | LimitRange y ResourceQuota para wordpress y databases |
| `pdb.yaml` | PodDisruptionBudget — mínimo 1 pod WordPress siempre disponible |
