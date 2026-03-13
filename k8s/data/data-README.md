# data/

Capa de datos. Despliega y configura las bases de datos del proyecto: MariaDB en modo primary/replica y Redis con Sentinel para alta disponibilidad y failover automático.

| Archivo | Qué hace |
|---|---|
| `mariadb.yaml` | StatefulSet MariaDB — primary (mariadb-0) + replica (mariadb-1) |
| `mariadb-replication-job.yaml` | Job que configura la replicación entre primary y replica |
| `redis.yaml` | StatefulSet Redis — 1 master + 2 replicas + 3 Sentinels sidecar |
