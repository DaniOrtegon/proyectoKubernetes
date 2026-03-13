# DOC-04b — Job de Configuración de Replicación MariaDB

## ¿Qué hace este archivo?

Define un `Job` de Kubernetes que configura la replicación binlog asíncrona entre `mariadb-0` (primary) y `mariadb-1` (replica) una vez que ambos Pods del StatefulSet están operativos. El Job actúa como un script de bootstrapping de un solo uso: espera a que ambas instancias estén listas, crea el usuario de replicación, obtiene la posición del binary log del primary y configura la replica con `CHANGE MASTER TO / START SLAVE`. Se autoeliminará 5 minutos después de completar.

---

## Conceptos de Kubernetes utilizados

### Job (`batch/v1`)
Un `Job` garantiza que un Pod se ejecute hasta completar con éxito (código de salida 0). Es la primitiva correcta para tareas de inicialización únicas como la configuración de replicación. Sus características relevantes aquí son:

- **`restartPolicy: OnFailure`**: reinicia el contenedor si el script falla, permitiendo reintentos automáticos sin crear Pods adicionales.
- **`ttlSecondsAfterFinished: 300`**: el controlador TTL de Kubernetes elimina el Job y su Pod 5 minutos después de completar, manteniendo el namespace limpio.

### DNS estable del Service Headless
El Job accede a cada Pod de MariaDB por su FQDN completo:
```
mariadb-<ordinal>.mariadb-headless.databases.svc.cluster.local
```
Este DNS estable es posible gracias al Service headless definido en `04-mariadb.yaml`, permitiendo dirigirse individualmente a `mariadb-0` y `mariadb-1` desde un Pod externo.

### Polling de disponibilidad
El Job implementa un bucle `until` con `mysql ... -e "SELECT 1"` que reintenta cada 3 segundos. Es un patrón pragmático y autocontenido que no requiere herramientas adicionales ni coordinación externa con el StatefulSet.

---

## Flujo de ejecución (6 fases)

```
[1] Esperar a mariadb-0 (polling TCP/MySQL)
        ↓
[2] Esperar a mariadb-1 (polling TCP/MySQL)
        ↓
[3] Crear usuario 'replicator'@'%' en el primary con REPLICATION SLAVE
        ↓
[4] Capturar MASTER_LOG_FILE y MASTER_LOG_POS (SHOW MASTER STATUS)
        ↓
[5] CHANGE MASTER TO + START SLAVE en mariadb-1
        ↓
[6] Verificar estado con SHOW SLAVE STATUS\G (grep Running|Behind|Error)
```

---

## Decisiones de diseño

| Decisión | Justificación |
|---|---|
| Job en lugar de init container del StatefulSet | Separar la configuración de la replicación del arranque del StatefulSet permite re-ejecutar el Job de forma independiente sin reiniciar las instancias de base de datos. |
| `set -e` al inicio del script | Cualquier comando que falle aborta el script inmediatamente, activando `restartPolicy: OnFailure` y garantizando que el Job no finalice en un estado incorrecto silencioso. |
| `CREATE USER IF NOT EXISTS` | Hace el Job idempotente: si se re-ejecuta por un reinicio del contenedor, no falla al intentar crear un usuario ya existente. |
| `|| true` en el grep final | La verificación final es informativa, no bloqueante. Evita que grep aborte el script con `set -e` si no hay coincidencias, permitiendo que el Job complete con éxito aunque la salida del grep esté vacía. |
| Misma imagen que el StatefulSet (`mariadb:10.6`) | El cliente `mysql` viene incluido en la imagen oficial, eliminando la necesidad de una imagen custom o de instalar herramientas adicionales. |
| Credenciales via Secret | La contraseña de root se inyecta como variable de entorno desde `mariadb-secret`, nunca en texto plano en el YAML. |

---

## Dependencias con otros archivos

| Archivo | Relación |
|---|---|
| `00-namespace.yaml` | El namespace `databases` debe existir antes de crear el Job. |
| `01-secrets.yaml` | El Secret `mariadb-secret` con la clave `mariadb-root-password` debe existir. |
| `04-mariadb.yaml` | **Dependencia directa**: el StatefulSet, el Service headless y los Pods deben existir y estar en estado `Ready`. El Job reintentará automáticamente hasta que ambos Pods respondan. |
| `07-network-policy.yaml` | La política `allow-mariadb-replication` permite que el Pod del Job (con label `app: mariadb`) acceda al puerto 3306 de los Pods del StatefulSet. |

---

## Puntos a tener en cuenta

### Re-ejecución del Job
Si el Job se re-ejecuta (por ejemplo, para resetear la replicación tras un incidente), `STOP SLAVE` y `CHANGE MASTER TO` se ejecutan de nuevo desde la posición actual del primary. Este comportamiento es deliberado: permite re-sincronizar la replicación sin necesidad de intervención manual en los Pods.

### Verificación manual del estado
Tras la ejecución del Job, es recomendable verificar el estado de la replicación directamente:
```bash
kubectl exec -n databases mariadb-1 -- mysql -u root -p"${PASS}" -e "SHOW SLAVE STATUS\G" | grep -E "Running|Behind"
```
Los campos clave son `Slave_IO_Running: Yes` y `Slave_SQL_Running: Yes`.
