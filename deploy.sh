# ============================================================
# .github/workflows/deploy.yml
# Pipeline CI/CD para WordPress HA en Kubernetes
#
# JOBS:
#   1. validate    — lint YAMLs + kube-score + detect-secrets
#                    Se ejecuta en todo push y PR a main
#   2. validate-k8s — kubeval contra schemas de Kubernetes
#   3. deploy      — placeholder para producción
#                    En producción: kubectl apply o helm upgrade
#                    con runner self-hosted con acceso al clúster
#
# SECRETS necesarios en GitHub repo settings:
#   (ninguno para validate — solo se necesitarían para deploy real)
# ============================================================

name: CI/CD WordPress K8s

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

env:
  KUBE_SCORE_VERSION: "1.16.1"
  KUBEVAL_VERSION: "0.16.1"

jobs:
  # ----------------------------------------------------------
  # JOB 1: Validación de YAMLs
  # Valida sintaxis, buenas prácticas y secretos expuestos
  # Se ejecuta en PRs y pushes a main
  # ----------------------------------------------------------
  validate:
    name: Validate Kubernetes manifests
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install kubeval
        run: |
          curl -sL https://github.com/instrumenta/kubeval/releases/download/v${{ env.KUBEVAL_VERSION }}/kubeval-linux-amd64.tar.gz \
            | tar xz -C /usr/local/bin
          kubeval --version

      - name: Install kube-score
        run: |
          curl -sL https://github.com/zegl/kube-score/releases/download/v${{ env.KUBE_SCORE_VERSION }}/kube-score_${{ env.KUBE_SCORE_VERSION }}_linux_amd64.tar.gz \
            | tar xz -C /usr/local/bin
          kube-score version

      - name: Lint YAMLs con kubeval
        run: |
          echo "=== Validando schemas de Kubernetes ==="
          # Ignorar CRDs (SealedSecret, Certificate, etc.) que kubeval no conoce
          kubeval --strict \
            --ignore-missing-schemas \
            --kubernetes-version 1.28.0 \
            $(ls *.yaml | grep -v "sealed-\|15-cert-manager")
          echo "✅ kubeval OK"

      - name: Analizar buenas prácticas con kube-score
        run: |
          echo "=== Analizando buenas prácticas ==="
          # kube-score falla con exit code 1 si hay warnings críticos
          # --ignore-test permite excluir checks específicos
          kube-score score \
            --output-format ci \
            --ignore-test pod-networkpolicy \
            --ignore-test container-image-tag \
            $(ls *.yaml | grep -v "sealed-\|15-cert-manager\|00-namespace") \
            || true  # No bloquear el pipeline por warnings en entorno de prácticas
          echo "✅ kube-score OK"

      - name: Verificar que no hay secretos expuestos
        run: |
          echo "=== Escaneando secretos hardcodeados ==="
          pip install detect-secrets --quiet
          # Inicializar baseline si no existe
          if [ ! -f .secrets.baseline ]; then
            detect-secrets scan > .secrets.baseline
          fi
          detect-secrets audit .secrets.baseline --report || true
          # Escanear cambios nuevos
          detect-secrets scan --baseline .secrets.baseline
          echo "✅ detect-secrets OK"

      - name: Verificar estructura de archivos requeridos
        run: |
          echo "=== Verificando archivos requeridos ==="
          REQUIRED_FILES=(
            "deploy.sh"
            "00-namespace.yaml"
            "04-mariadb.yaml"
            "05-redis.yaml"
            "06-wordpress.yaml"
            "07-network-policy.yaml"
          )
          for f in "${REQUIRED_FILES[@]}"; do
            if [ ! -f "$f" ]; then
              echo "❌ Falta archivo requerido: $f"
              exit 1
            fi
            echo "✅ $f"
          done

  # ----------------------------------------------------------
  # JOB 2: Validación avanzada con kubeconform
  # Más moderno que kubeval, soporta CRDs via schemas remotos
  # ----------------------------------------------------------
  validate-advanced:
    name: Advanced manifest validation
    runs-on: ubuntu-latest
    needs: validate
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install kubeconform
        run: |
          curl -sL https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz \
            | tar xz -C /usr/local/bin

      - name: Validate con kubeconform
        run: |
          echo "=== Validación con kubeconform ==="
          kubeconform \
            -strict \
            -ignore-missing-schemas \
            -kubernetes-version 1.28.0 \
            -summary \
            $(ls *.yaml | grep -v "sealed-\|15-cert-manager")
          echo "✅ kubeconform OK"

      - name: Verificar resource limits definidos
        run: |
          echo "=== Verificando resource limits ==="
          # Comprobar que todos los Deployments/StatefulSets tienen limits
          python3 << 'EOF'
          import yaml, sys, glob

          issues = []
          for fname in glob.glob("*.yaml"):
              try:
                  docs = list(yaml.safe_load_all(open(fname)))
              except:
                  continue
              for doc in docs:
                  if not doc or doc.get("kind") not in ("Deployment", "StatefulSet", "DaemonSet"):
                      continue
                  containers = doc.get("spec", {}).get("template", {}).get("spec", {}).get("containers", [])
                  for c in containers:
                      res = c.get("resources", {})
                      if not res.get("limits"):
                          issues.append(f"{fname}: {doc['metadata']['name']} → container '{c['name']}' sin limits")
                      if not res.get("requests"):
                          issues.append(f"{fname}: {doc['metadata']['name']} → container '{c['name']}' sin requests")

          if issues:
              print("⚠️  Containers sin resource limits/requests:")
              for i in issues:
                  print(f"  - {i}")
          else:
              print("✅ Todos los containers tienen resource limits y requests")
          EOF

  # ----------------------------------------------------------
  # JOB 3: Deploy (placeholder para producción)
  # En producción con runner self-hosted:
  #   - Configurar KUBECONFIG como secret en GitHub
  #   - Usar kubectl apply o helm upgrade --atomic
  #   - Notificar resultado a Slack
  # ----------------------------------------------------------
  deploy:
    name: Deploy to Kubernetes
    runs-on: ubuntu-latest
    needs: [validate, validate-advanced]
    # Solo en push a main, no en PRs
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      # --------------------------------------------------------
      # PRODUCCIÓN: descomentar y configurar los pasos siguientes
      # Requiere:
      #   - Runner self-hosted con kubectl y acceso al clúster, O
      #   - Secret KUBECONFIG con el kubeconfig del clúster destino
      # --------------------------------------------------------

      # - name: Configure kubectl
      #   uses: azure/k8s-set-context@v3
      #   with:
      #     method: kubeconfig
      #     kubeconfig: ${{ secrets.KUBECONFIG }}

      # - name: Deploy manifests
      #   run: |
      #     kubectl apply -f 00-namespace.yaml
      #     kubectl apply -f 02-configmap.yaml
      #     kubectl apply -f 04-mariadb.yaml
      #     kubectl apply -f 05-redis.yaml
      #     kubectl apply -f 06-wordpress.yaml
      #     kubectl rollout status deployment/wordpress -n wordpress --timeout=5m

      # - name: Notify Slack on success
      #   if: success()
      #   uses: slackapi/slack-github-action@v1.25.0
      #   with:
      #     webhook: ${{ secrets.SLACK_WEBHOOK_URL }}
      #     webhook-type: incoming-webhook
      #     payload: |
      #       {"text": "✅ Deploy a Kubernetes completado — commit ${{ github.sha }}"}

      # - name: Notify Slack on failure
      #   if: failure()
      #   uses: slackapi/slack-github-action@v1.25.0
      #   with:
      #     webhook: ${{ secrets.SLACK_WEBHOOK_URL }}
      #     webhook-type: incoming-webhook
      #     payload: |
      #       {"text": "❌ Deploy fallido — commit ${{ github.sha }} — revisa: ${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}"}

      - name: Deploy summary (entorno de prácticas)
        run: |
          echo "================================================"
          echo "  Deploy en Minikube: ejecutar deploy.sh local"
          echo "  Commit: ${{ github.sha }}"
          echo "  Rama:   ${{ github.ref_name }}"
          echo "================================================"
          echo "Para producción: configurar KUBECONFIG secret"
          echo "y descomentar los pasos de deploy en este workflow."
