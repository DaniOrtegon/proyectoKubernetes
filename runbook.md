# RUNBOOK — WordPress HA en Kubernetes
**Proyecto:** KubeNet — WordPress HA en Minikube  
**Versión:** 1.1  
**Entorno:** Minikube + Kubernetes v1.35

> ⚠️ **Nota de seguridad:** Este runbook no contiene credenciales en texto plano.  
> Todos los comandos leen las contraseñas directamente desde los Kubernetes Secrets del clúster.

---

## Cómo leer credenciales del clúster

Los comandos de este runbook usan este patrón para no exponer contraseñas:

```bash
# Leer contraseña de root de MariaDB
MARIADB_ROOT_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.root-password}' | base64 -d)

# Leer contraseña del usuario replicador
MARIADB_REPL_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.replication-password}' | base64 -d)

# Leer contraseña de Redis
REDIS_PASS=$(kubectl get secret redis-secret -n databases \
  -o jsonpath='{.data.password}' | base64 -d)
```

Ejecuta el bloque correspondiente antes de los pasos de cada sección.

---

## Índice

1. [Prometheus — Lockfile corrupto](#1-prometheus--lockfile-corrupto)
2. [Namespace atascado en Terminating](#2-namespace-atascado-en-terminating)
3. [Sealed Secrets inválidos](#3-sealed-secrets-inválidos)
4. [MariaDB — Replicación rota](#4-mariadb--replicación-rota)
5. [Redis Sentinel — Master no disponible](#5-redis-sentinel--master-no-disponible)
6. [Velero — Restauración ante desastre](#6-velero--restauración-ante-desastre)

---

## 1. Prometheus — Lockfile corrupto

**Síntoma**
```bash
kubectl get pods -n monitoring
# prometheus-xxxx   0/1   CrashLoopBackOff

kubectl logs -n monitoring deployment/prometheus | grep -i lock
# level=error msg="opening storage failed" err="lock file already exists"
```

**Impacto**  
Monitoreo ciego — sin métricas, sin alertas durante la incidencia. El Alertmanager tampoco funciona.

**RTO objetivo:** < 5 minutos

---

**Paso 1 — Confirmar el problema**
```bash
kubectl logs -n monitoring deployment/prometheus | grep -i lock
```
Si aparece `lock file already exists` → continúa con el paso 2.

**Paso 2 — Escalar a 0 (libera el lock)**
```bash
kubectl scale deployment prometheus -n monitoring --replicas=0
kubectl wait --for=delete pod -l app=prometheus -n monitoring --timeout=60s
```

**Paso 3 — Eliminar el lockfile**
```bash
kubectl run fix-lock --image=busybox --restart=Never -n monitoring \
  --overrides='{
    "spec": {
      "volumes": [{"name":"data","persistentVolumeClaim":{"claimName":"prometheus-pvc"}}],
      "containers": [{
        "name": "fix",
        "image": "busybox",
        "command": ["rm","-f","/prometheus/lock"],
        "volumeMounts": [{"name":"data","mountPath":"/prometheus"}]
      }]
    }
  }'

kubectl wait --for=condition=complete pod/fix-lock -n monitoring --timeout=30s
kubectl delete pod fix-lock -n monitoring
```

**Paso 4 — Restaurar Prometheus**
```bash
kubectl scale deployment prometheus -n monitoring --replicas=1
kubectl wait --for=condition=ready pod -l app=prometheus -n monitoring --timeout=120s
```

**Paso 5 — Verificar**
```bash
kubectl get pods -n monitoring
curl -s http://prometheus.monitoring.local/-/ready
# Esperado: "Prometheus Server is Ready."
```

**Causa raíz habitual**  
El pod fue terminado forzosamente (OOM, node restart) sin liberar el lock. No es un bug — es el comportamiento esperado del mecanismo de protección de Prometheus.

---

## 2. Namespace atascado en Terminating

**Síntoma**
```bash
kubectl get ns
# velero   Terminating   10m
```
El namespace lleva varios minutos en `Terminating` sin completar.

**Impacto**  
No se puede recrear el namespace ni desplegar los recursos que dependen de él.

**RTO objetivo:** < 2 minutos

---

**Paso 1 — Confirmar que está atascado**
```bash
kubectl get namespace <NAMESPACE> -o jsonpath='{.status.phase}'
# Esperado: Terminating
```

**Paso 2 — Forzar eliminación de finalizers**
```bash
kubectl get namespace <NAMESPACE> -o json \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
d['spec']['finalizers'] = []
print(json.dumps(d))
" \
  | kubectl replace --raw "/api/v1/namespaces/<NAMESPACE>/finalize" -f -
```

**Paso 3 — Verificar**
```bash
kubectl get ns <NAMESPACE>
# Esperado: Error from server (NotFound) — el namespace ya no existe
```

**Causa raíz habitual**  
Recursos con finalizers (Velero, cert-manager) que no pudieron completar su limpieza antes de que se eliminase el controlador correspondiente.

---

## 3. Sealed Secrets inválidos

**Síntoma**
```bash
./deploy.sh
# [WARN] SealedSecrets incompatibles con este clúster (clave diferente)
```
O bien los pods arrancan pero fallan por contraseñas incorrectas:
```bash
kubectl logs -n databases mariadb-0 | grep -i "access denied\|password"
```

**Impacto**  
MariaDB, Redis y WordPress no pueden arrancar — los Secrets no contienen las credenciales correctas.

**RTO objetivo:** < 10 minutos (tiempo de regeneración)

---

**Paso 1 — Confirmar el problema**
```bash
kubeseal --validate < sealed-mariadb-secret-databases.yaml
# Si falla → los sealed secrets son inválidos para este clúster
```

**Paso 2 — Hacer backup de los sealed secrets actuales**
```bash
mkdir sealed-secrets-backup-$(date +%Y%m%d)
cp sealed-*.yaml sealed-secrets-backup-$(date +%Y%m%d)/
```

**Paso 3 — Eliminar los sealed secrets antiguos**
```bash
rm sealed-*.yaml
```

**Paso 4 — Regenerar con la clave del clúster actual**
```bash
source ./deploy.sh && generate_sealed_secrets
```

**Paso 5 — Aplicar y verificar**
```bash
kubectl apply -f sealed-mariadb-secret-databases.yaml
kubectl apply -f sealed-mariadb-secret-wordpress.yaml
kubectl apply -f sealed-redis-secret-databases.yaml
kubectl apply -f sealed-redis-secret-wordpress.yaml

kubectl get secret mariadb-secret -n databases
kubectl get secret redis-secret -n databases
# Esperado: los secrets existen con TYPE=Opaque
```

**Paso 6 — Reiniciar pods afectados**
```bash
kubectl rollout restart deployment/wordpress -n wordpress
kubectl rollout restart statefulset/mariadb -n databases
kubectl rollout restart statefulset/redis -n databases
```

**Causa raíz habitual**  
El clúster fue recreado (`minikube delete`) o se cambió de máquina. El Sealed Secrets Controller genera una clave RSA única por clúster — los secrets cifrados con la clave anterior no se pueden descifrar.

**Prevención**  
Hacer backup de la clave maestra tras el primer despliegue:
```bash
kubectl get secret -n kube-system \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > sealed-secrets-master-key-backup.yaml
# ⚠️ NUNCA subir este archivo al repositorio — añadirlo a .gitignore
```

---

## 4. MariaDB — Replicación rota

**Síntoma**
```bash
# Leer credenciales del clúster antes de continuar
MARIADB_ROOT_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.root-password}' | base64 -d)

kubectl exec -n databases mariadb-1 -- \
  mysql -u root -p"${MARIADB_ROOT_PASS}" -e 'SHOW SLAVE STATUS\G' 2>/dev/null \
  | grep -E 'Running|Behind|Error'
# Slave_IO_Running: No
# Slave_SQL_Running: No
# Last_Error: ...
```

**Impacto**  
La réplica no está sincronizada. Reads en la réplica devuelven datos desactualizados. Si el primary cae, hay riesgo de pérdida de datos.

**RTO objetivo:** < 15 minutos

---

**Paso 0 — Leer credenciales del clúster**
```bash
MARIADB_ROOT_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.root-password}' | base64 -d)

MARIADB_REPL_PASS=$(kubectl get secret mariadb-secret -n databases \
  -o jsonpath='{.data.replication-password}' | base64 -d)
```

**Paso 1 — Verificar estado de la replicación**
```bash
kubectl exec -n databases mariadb-1 -- \
  mysql -u root -p"${MARIADB_ROOT_PASS}" -e 'SHOW SLAVE STATUS\G' 2>/dev/null \
  | grep -E 'Slave_IO|Slave_SQL|Seconds_Behind|Last_Error'
```

**Paso 2 — Verificar que el primary está accesible**
```bash
kubectl exec -n databases mariadb-1 -- \
  mysql -u root -p"${MARIADB_ROOT_PASS}" \
  -h mariadb-0.mariadb-headless.databases.svc.cluster.local \
  -e 'SELECT 1' 2>/dev/null
# Esperado: 1
```

**Paso 3 — Reiniciar la replicación**
```bash
kubectl exec -n databases mariadb-1 -- \
  mysql -u root -p"${MARIADB_ROOT_PASS}" 2>/dev/null << SQL
STOP SLAVE;
RESET SLAVE;
CHANGE MASTER TO
  MASTER_HOST='mariadb-0.mariadb-headless.databases.svc.cluster.local',
  MASTER_USER='replicator',
  MASTER_PASSWORD='${MARIADB_REPL_PASS}',
  MASTER_AUTO_POSITION=1;
START SLAVE;
SQL
```

**Paso 4 — Verificar que la replicación está activa**
```bash
kubectl exec -n databases mariadb-1 -- \
  mysql -u root -p"${MARIADB_ROOT_PASS}" -e 'SHOW SLAVE STATUS\G' 2>/dev/null \
  | grep -E 'Slave_IO|Slave_SQL|Seconds_Behind'
# Esperado:
# Slave_IO_Running: Yes
# Slave_SQL_Running: Yes
# Seconds_Behind_Master: 0
```

**Paso 5 — Si el paso 3 no funciona: relanzar el Job de replicación**
```bash
kubectl delete job mariadb-replication-setup -n databases --ignore-not-found=true
kubectl apply -f 04b-mariadb-replication-job.yaml
kubectl wait --for=condition=complete job/mariadb-replication-setup \
  -n databases --timeout=120s
```

**Causa raíz habitual**  
Reinicio del pod primary sin que la réplica pueda reconectarse, o network partition temporal entre los pods.

---

## 5. Redis Sentinel — Master no disponible

**Síntoma**
```bash
kubectl logs -n wordpress -l app=wordpress | grep -i redis
# Redis connection failed: No master found

kubectl exec -n databases redis-0 -- \
  redis-cli -p 26379 sentinel master mymaster
# (error) ERR No such master with that name
```

**Impacto**  
WordPress no puede usar la caché Redis. Las sesiones pueden verse afectadas. Mayor carga en MariaDB.

**RTO objetivo:** < 10 minutos

---

**Paso 0 — Leer credenciales del clúster**
```bash
REDIS_PASS=$(kubectl get secret redis-secret -n databases \
  -o jsonpath='{.data.password}' | base64 -d)
```

**Paso 1 — Ver estado del Sentinel**
```bash
for i in 0 1 2; do
  echo "=== redis-$i sentinel info ==="
  kubectl exec -n databases redis-$i -c sentinel -- \
    redis-cli -p 26379 sentinel masters 2>/dev/null || echo "No disponible"
done
```

**Paso 2 — Ver estado de los pods Redis**
```bash
kubectl get pods -n databases -l app=redis
kubectl logs -n databases redis-0 -c redis | tail -20
```

**Paso 3 — Identificar qué pod actúa como master**
```bash
for i in 0 1 2; do
  echo -n "redis-$i role: "
  kubectl exec -n databases redis-$i -c redis -- \
    redis-cli -a "${REDIS_PASS}" role 2>/dev/null | head -1
done
```

**Paso 4 — Reiniciar el StatefulSet si ningún pod responde**
```bash
kubectl rollout restart statefulset/redis -n databases
kubectl rollout status statefulset/redis -n databases --timeout=120s
```

**Paso 5 — Verificar que Sentinel detecta el master**
```bash
kubectl exec -n databases redis-0 -c sentinel -- \
  redis-cli -p 26379 sentinel master mymaster 2>/dev/null \
  | grep -E "name|ip|port|flags"
# Esperado: flags: master
```

**Paso 6 — Reiniciar WordPress para reconectar**
```bash
kubectl rollout restart deployment/wordpress -n wordpress
kubectl rollout status deployment/wordpress -n wordpress --timeout=120s
```

**Causa raíz habitual**  
Los 3 Sentinels no alcanzan quorum (necesitan 2 de 3) durante un reinicio simultáneo de pods o network partition.

---

## 6. Velero — Restauración ante desastre

**Escenario**  
Pérdida total del namespace `wordpress` o `databases`. Se necesita restaurar desde el último backup de Velero.

**RTO objetivo:** < 20 minutos

---

**Paso 1 — Ver backups disponibles**
```bash
velero backup get
# NAME                          STATUS     ERRORS   WARNINGS   CREATED                         EXPIRES
# wordpress-daily-20240315      Completed  0        0          2024-03-15 01:00:00 +0000 UTC   29d
```

**Paso 2 — Verificar el contenido del backup**
```bash
velero backup describe wordpress-daily-20240315 --details
```

**Paso 3a — Restauración completa**
```bash
velero restore create \
  --from-backup wordpress-daily-20240315 \
  --wait
```

**Paso 3b — Restauración en namespace de prueba (sin afectar producción)**
```bash
velero restore create \
  --from-backup wordpress-daily-20240315 \
  --namespace-mappings wordpress:wordpress-restore \
  --namespace-mappings databases:databases-restore \
  --wait
```

**Paso 4 — Verificar estado de la restauración**
```bash
velero restore get
# Esperado: STATUS = Completed

kubectl get pods -n wordpress
kubectl get pods -n databases
```

**Paso 5 — Verificar WordPress**
```bash
kubectl wait --for=condition=ready pod -l app=wordpress -n wordpress --timeout=120s
curl -sk https://wp-k8s.local | grep -i wordpress
```

**Paso 6 — Limpiar namespace de prueba (si se usó 3b)**
```bash
kubectl delete namespace wordpress-restore --ignore-not-found=true
kubectl delete namespace databases-restore --ignore-not-found=true
```

**Backup manual antes de operaciones de riesgo**
```bash
velero backup create pre-maintenance \
  --include-namespaces wordpress,databases \
  --wait
```

**Causa raíz habitual**  
Error humano, fallo de nodo, corrupción de datos. Velero captura el estado completo del clúster incluyendo PVCs, por lo que la restauración incluye tanto la configuración como los datos.

---

## Referencia rápida

| Problema | Síntoma clave | Runbook |
|----------|--------------|---------|
| Prometheus no arranca | `CrashLoopBackOff` + `lock file exists` | §1 |
| Namespace no se borra | `Terminating` durante minutos | §2 |
| Pods sin contraseñas | `Access denied` en MariaDB/Redis | §3 |
| Réplica MariaDB parada | `Slave_IO_Running: No` | §4 |
| WordPress sin caché | `No master found` en Redis | §5 |
| Pérdida de datos/pods | Namespace borrado o corrupto | §6 |
