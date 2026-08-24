#!/bin/bash
# Bring the whole stack up: k3s, MetalLB, ECK (Elasticsearch/Kibana/Fleet), Odosian, KubeVision.
# Safe to re-run — every step is idempotent and skips work that's already done.
set -euo pipefail

# Never run this with sudo/as root — it calls sudo itself where needed.
# Running the whole script as root makes every file it touches root-owned,
# breaking the next normal-user run (e.g. sed -i on metallb-pool.yaml).
if [ "$(id -u)" = "0" ]; then
  echo "Don't run this as root or with sudo — it calls sudo itself where needed." >&2
  echo "Run it as your normal user: ./up.sh" >&2
  exit 1
fi

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$STACK_DIR/.." && pwd)"
ODOSIAN_DIR="$REPO_ROOT/odosian"
K8S_DIR="$ODOSIAN_DIR/k8s"
ECK_CHART_DIR="$STACK_DIR/elastic-siem-chart"
CERTS_DIR="$ODOSIAN_DIR/certs"
KUBEVISION_DIR="$REPO_ROOT/kubevision"
ENGINE_DIR="$REPO_ROOT/odosian-ai-engine"
ENGINE_K8S_DIR="$ENGINE_DIR/k8s"

log() { echo -e "\n\033[1;36m==> $1\033[0m"; }

# --- Flags & KubeVision on/off ---------------------------------------------
# Usage: up.sh [--rebuild] [--with-kubevision | --no-kubevision]
REBUILD=0
KUBEVISION_CHOICE=""
for arg in "$@"; do
  case "$arg" in
    --rebuild) REBUILD=1 ;;
    --with-kubevision) KUBEVISION_CHOICE=1 ;;
    --no-kubevision) KUBEVISION_CHOICE=0 ;;
  esac
done

if [ -z "$KUBEVISION_CHOICE" ]; then
  if [ -n "${SKIP_KUBEVISION:-}" ]; then
    # Set by a caller (build.sh, update.sh) that already asked — don't ask again.
    [ "$SKIP_KUBEVISION" = "1" ] && KUBEVISION_CHOICE=0 || KUBEVISION_CHOICE=1
  elif [ -t 0 ] && [ -d "$KUBEVISION_DIR" ]; then
    read -rp "Build and deploy KubeVision too? [Y/n] " KV_ANS
    case "$KV_ANS" in
      [Nn]*) KUBEVISION_CHOICE=0 ;;
      *) KUBEVISION_CHOICE=1 ;;
    esac
  elif [ -t 0 ]; then
    echo "KubeVision source not found at $KUBEVISION_DIR — skipping (run 'stack/update.sh --with-kubevision' to pull it in first)."
    KUBEVISION_CHOICE=0
  else
    KUBEVISION_CHOICE=1
  fi
fi

if [ "$KUBEVISION_CHOICE" = "1" ] && [ ! -d "$KUBEVISION_DIR" ]; then
  echo "KubeVision source not found at $KUBEVISION_DIR — skipping (run 'stack/update.sh --with-kubevision' to pull it in first)."
  KUBEVISION_CHOICE=0
fi

if [ "$KUBEVISION_CHOICE" = "1" ]; then
  SKIP_KUBEVISION=0
else
  SKIP_KUBEVISION=1
fi

log "[1/10] Starting k3s"
sudo systemctl start k3s
# Safety net: if the kubeconfig is still root-only (0600) — e.g. k3s was
# installed by something other than build.sh's INSTALL_K3S_EXEC flag — every
# bare `kubectl` call below silently fails with permission denied.
sudo chmod 644 /etc/rancher/k3s/k3s.yaml 2>/dev/null || true
# Same idea for the `kubectl` command itself — k3s normally symlinks it
# automatically, but on a machine where that didn't happen (or the symlink
# got removed some other way) every kubectl call below fails with
# "command not found". The wait loop right after this used to swallow that
# silently (2>/dev/null) and just retry forever, which looks identical to
# "the node is taking forever to become Ready" even when it already is.
if ! command -v kubectl &>/dev/null; then
  echo "kubectl isn't on PATH — recreating the symlink k3s normally sets up automatically..."
  sudo ln -sf /usr/local/bin/k3s /usr/local/bin/kubectl
fi
echo "Waiting for node to be Ready..."
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 2; done
echo "k3s is up."

log "[2/10] Starting buildkitd"
sudo systemctl start buildkitd

log "[3/10] MetalLB"
if ! helm status metallb -n metallb-system &>/dev/null; then
  helm repo add metallb https://metallb.github.io/metallb 2>/dev/null || true
  helm repo update metallb >/dev/null
  kubectl create namespace metallb-system 2>/dev/null || true
  helm install metallb metallb/metallb -n metallb-system \
    --set controller.resources.requests.memory=64Mi \
    --set controller.resources.requests.cpu=50m \
    --set controller.resources.limits.memory=128Mi \
    --set speaker.resources.requests.memory=64Mi \
    --set speaker.resources.requests.cpu=50m \
    --set speaker.resources.limits.memory=128Mi
  echo "Waiting for MetalLB pods..."
  # Same race as the ECK operator wait fixed earlier: `wait --all` targets
  # whatever pods exist *right now* — if helm install just returned and the
  # controller/speaker pods haven't been scheduled yet, this fails instantly
  # with "no matching resources found" instead of waiting for them to
  # appear. rollout status targets the Deployment/DaemonSet by name, which
  # helm creates synchronously, so it correctly waits for their pods to be
  # created and become ready instead of racing them.
  kubectl -n metallb-system rollout status deployment/metallb-controller --timeout=120s
  kubectl -n metallb-system rollout status daemonset/metallb-speaker --timeout=120s
else
  echo "MetalLB already installed."
fi
if ! kubectl get ipaddresspool falcon-pool -n metallb-system &>/dev/null; then
  echo "Applying MetalLB IP pool (retrying if the webhook isn't up yet)..."
  for i in $(seq 1 15); do
    if kubectl apply -f "$STACK_DIR/metallb-pool.yaml" 2>/tmp/metallb-pool-apply.err; then
      break
    fi
    if [ "$i" = 15 ]; then
      cat /tmp/metallb-pool-apply.err >&2
      echo "MetalLB webhook never became reachable — see error above." >&2
      exit 1
    fi
    sleep 2
  done
fi

echo "Waiting for Traefik to get a LoadBalancer IP..."
for i in $(seq 1 30); do
  TRAEFIK_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
  [ -n "$TRAEFIK_IP" ] && break
  sleep 2
done

log "[4/10] ECK operator"
if ! helm status elastic-operator-crds &>/dev/null; then
  helm repo add elastic https://helm.elastic.co 2>/dev/null || true
  helm repo update elastic >/dev/null
  helm install elastic-operator-crds elastic/eck-operator-crds
else
  echo "ECK CRDs already installed."
fi
if ! helm status elastic-operator -n elastic-system &>/dev/null; then
  kubectl create namespace elastic-system 2>/dev/null || true
  helm install elastic-operator elastic/eck-operator -n elastic-system \
    --set installCRDs=false \
    --set resources.requests.memory=256Mi --set resources.requests.cpu=100m \
    --set resources.limits.memory=512Mi --set resources.limits.cpu=500m
  # `kubectl wait -l selector` needs a matching pod to already exist — it
  # errors immediately with "no matching resources found" instead of
  # waiting for one to be created. The operator is a StatefulSet named
  # "elastic-operator" (Helm creates that object synchronously as part of
  # install, so it's always there by now); `rollout status` targets it by
  # name and correctly waits for its pod to be created AND become ready.
  echo "Waiting for the ECK operator to be ready..."
  kubectl -n elastic-system rollout status statefulset/elastic-operator --timeout=180s
else
  echo "ECK operator already installed."
fi

log "[5/10] Elastic SIEM stack (Elasticsearch, Kibana, Fleet Server)"
if [ ! -f "$ECK_CHART_DIR/values.local.yaml" ]; then
  echo "First run — generating a Kibana encryption key (kept local, never committed)..."
  cat > "$ECK_CHART_DIR/values.local.yaml" <<EOF
kibana:
  encryptionKey: "$(openssl rand -base64 24)"
EOF
fi
if ! helm status elastic-siem &>/dev/null; then
  helm install elastic-siem "$ECK_CHART_DIR" -f "$ECK_CHART_DIR/values.local.yaml"
else
  echo "elastic-siem release already installed."
fi

echo "Waiting for Elasticsearch and Kibana to be healthy..."
ESH="" KBH=""
for i in $(seq 1 90); do
  ESH=$(kubectl get elasticsearch es-cluster -o jsonpath='{.status.health}' 2>/dev/null || echo "")
  KBH=$(kubectl get kibana es-kibana -o jsonpath='{.status.health}' 2>/dev/null || echo "")
  # yellow is normal/expected for a single-node ES cluster (unassigned replica shards)
  if { [ "$ESH" = "green" ] || [ "$ESH" = "yellow" ]; } && [ "$KBH" = "green" ]; then break; fi
  sleep 5
done
if { [ "$ESH" != "green" ] && [ "$ESH" != "yellow" ]; } || [ "$KBH" != "green" ]; then
  echo "WARNING: Elasticsearch/Kibana did not become healthy within the timeout. Continuing anyway — check 'kubectl get elasticsearch,kibana' manually."
fi

ELASTIC_PW=$(kubectl get secret es-cluster-es-elastic-user -o jsonpath='{.data.elastic}' 2>/dev/null | base64 -d || echo "")
KB_IP=$(kubectl get svc es-kibana-kb-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

# CR status can report healthy slightly before Kibana's own HTTP listener is
# actually reachable through the LoadBalancer (especially right after a cold
# restart) — confirm real reachability before touching its API.
KIBANA_UP=false
if [ -n "$ELASTIC_PW" ] && [ -n "$KB_IP" ]; then
  echo "Confirming Kibana is actually reachable..."
  for i in $(seq 1 30); do
    STATUS=$(curl -s -k -o /dev/null -w "%{http_code}" -m 5 -u "elastic:${ELASTIC_PW}" "https://${KB_IP}:5601/api/status" || echo "000")
    if [ "$STATUS" = "200" ]; then KIBANA_UP=true; break; fi
    sleep 5
  done
fi

if [ "$KIBANA_UP" = true ]; then
  set +e  # this bootstrap block is best-effort: never let a transient API hiccup abort the whole deploy

  # Bootstrap Fleet Server policy if this is a fresh cluster that doesn't have it yet.
  POLICY_STATUS=$(curl -s -k -o /dev/null -w "%{http_code}" -m 10 -u "elastic:${ELASTIC_PW}" \
    "https://${KB_IP}:5601/api/fleet/agent_policies/eck-fleet-server" -H 'kbn-xsrf: true')
  if [ "$POLICY_STATUS" != "200" ]; then
    echo "Bootstrapping Fleet Server policy (fresh cluster)..."
    curl -s -k -u "elastic:${ELASTIC_PW}" -X POST "https://${KB_IP}:5601/api/fleet/setup" \
      -H 'kbn-xsrf: true' -H 'Content-Type: application/json' >/dev/null
    curl -s -k -u "elastic:${ELASTIC_PW}" -X POST "https://${KB_IP}:5601/api/fleet/agent_policies?sys_monitoring=false" \
      -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
      -d '{"id":"eck-fleet-server","name":"Fleet Server Policy","namespace":"default","description":"Policy for ECK Fleet Server","monitoring_enabled":[],"is_default_fleet_server":true}' >/dev/null
    FS_VERSION=$(curl -s -k -u "elastic:${ELASTIC_PW}" "https://${KB_IP}:5601/api/fleet/epm/packages/fleet_server" -H 'kbn-xsrf: true' | python3 -c "import json,sys; print(json.load(sys.stdin)['item']['version'])" 2>/dev/null)
    if [ -n "$FS_VERSION" ]; then
      curl -s -k -u "elastic:${ELASTIC_PW}" -X POST "https://${KB_IP}:5601/api/fleet/epm/packages/fleet_server/${FS_VERSION}" \
        -H 'kbn-xsrf: true' -H 'Content-Type: application/json' -d '{"force":true}' >/dev/null
      curl -s -k -u "elastic:${ELASTIC_PW}" -X POST "https://${KB_IP}:5601/api/fleet/package_policies" \
        -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
        -d "{\"name\":\"fleet-server-integration\",\"policy_ids\":[\"eck-fleet-server\"],\"package\":{\"name\":\"fleet_server\",\"version\":\"${FS_VERSION}\"},\"inputs\":{\"fleet_server-fleet-server\":{\"enabled\":true,\"streams\":{}}}}" >/dev/null
    fi
  fi

  # Bootstrap detection rule content if this is a fresh cluster with no rules installed yet.
  RULE_TOTAL=$(curl -s -k -u "elastic:${ELASTIC_PW}" -m 10 "https://${KB_IP}:5601/api/detection_engine/rules/_find?per_page=1" -H 'kbn-xsrf: true' | python3 -c "import json,sys; print(json.load(sys.stdin).get('total',0))" 2>/dev/null)
  if [ "${RULE_TOTAL:-0}" = "0" ]; then
    echo "Installing prebuilt Elastic detection rules (fresh cluster)..."
    curl -s -k -u "elastic:${ELASTIC_PW}" -X POST "https://${KB_IP}:5601/api/detection_engine/index" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' >/dev/null
    SDE_VERSION=$(curl -s -k -u "elastic:${ELASTIC_PW}" "https://${KB_IP}:5601/api/fleet/epm/packages/security_detection_engine" -H 'kbn-xsrf: true' | python3 -c "import json,sys; print(json.load(sys.stdin)['item']['version'])" 2>/dev/null)
    if [ -n "$SDE_VERSION" ]; then
      curl -s -k -u "elastic:${ELASTIC_PW}" -X POST "https://${KB_IP}:5601/api/fleet/epm/packages/security_detection_engine/${SDE_VERSION}" \
        -H 'kbn-xsrf: true' -H 'Content-Type: application/json' -d '{"force":true}' >/dev/null
      curl -s -k -u "elastic:${ELASTIC_PW}" -X PUT "https://${KB_IP}:5601/api/detection_engine/rules/prepackaged" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' >/dev/null
    fi
  fi

  set -e
else
  echo "WARNING: Kibana wasn't reachable — skipping Fleet/rules bootstrap check this run. Re-run up.sh if this was a fresh cluster."
fi

log "[6/10] Odosian container image"
if ! sudo k3s ctr -n k8s.io images ls -q 2>/dev/null | grep -q "^docker.io/library/odosian:latest$"; then
  echo "Building image (no cached image found)..."
  sudo nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
    build --buildkit-host unix:///run/buildkit/buildkitd.sock -t odosian:latest "$ODOSIAN_DIR"
else
  echo "Odosian image already built. Pass --rebuild to force a rebuild."
fi
if [ "$REBUILD" = "1" ]; then
  echo "Rebuilding image..."
  sudo nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
    build --buildkit-host unix:///run/buildkit/buildkitd.sock -t odosian:latest "$ODOSIAN_DIR"
  kubectl -n odosian rollout restart deployment/odosian 2>/dev/null || true
fi

log "[6.5/10] Odosian AI Engine container image"
if [ -f "$ENGINE_DIR/Dockerfile" ]; then
  if ! sudo k3s ctr -n k8s.io images ls -q 2>/dev/null | grep -q "^docker.io/library/odosian-ai-engine:latest$"; then
    echo "Building engine image (no cached image found)..."
    sudo nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
      build --buildkit-host unix:///run/buildkit/buildkitd.sock -t odosian-ai-engine:latest "$ENGINE_DIR"
  else
    echo "Engine image already built. Pass --rebuild to force a rebuild."
  fi
  if [ "$REBUILD" = "1" ]; then
    echo "Rebuilding engine image..."
    sudo nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
      build --buildkit-host unix:///run/buildkit/buildkitd.sock -t odosian-ai-engine:latest "$ENGINE_DIR"
    kubectl -n odosian rollout restart deployment/odosian-engine 2>/dev/null || true
  fi
elif [ -d "$ENGINE_DIR" ]; then
  echo "odosian-ai-engine/ has no Dockerfile yet — skipping engine build until it does."
else
  echo "odosian-ai-engine/ not found — skipping engine build."
fi

log "[7/10] Odosian namespace, secrets, storage"
if [ ! -f "$K8S_DIR/secret.local.yaml" ]; then
  echo "First run — generating a JWT secret (kept local, never committed)..."
  sed "s/REPLACE_WITH_SECURE_RANDOM_STRING/$(openssl rand -hex 48)/" \
    "$K8S_DIR/secret.yaml" > "$K8S_DIR/secret.local.yaml"
  echo "  odosian/k8s/secret.local.yaml created — edit it to add real SMTP/AI keys later."
fi
FIRST_DEPLOY=false
if ! kubectl get namespace odosian &>/dev/null; then
  FIRST_DEPLOY=true
fi

kubectl apply -f "$K8S_DIR/namespace.yaml"
kubectl apply -f "$K8S_DIR/secret.local.yaml"
kubectl apply -f "$K8S_DIR/configmap.yaml"
kubectl apply -f "$K8S_DIR/pvc.yaml"

if [ "$FIRST_DEPLOY" = true ] && [ -f "$ODOSIAN_DIR/dev.db" ]; then
  echo "First deploy — migrating your existing rule database into the cluster..."
  kubectl apply -f "$STACK_DIR/db-migrate-pod.yaml"
  kubectl -n odosian wait --for=condition=Ready pod/db-migrate --timeout=60s
  kubectl -n odosian cp "$ODOSIAN_DIR/dev.db" db-migrate:/data/odosian.db
  kubectl -n odosian exec db-migrate -- chmod 666 /data/odosian.db
  kubectl -n odosian delete pod db-migrate --wait=false
fi

log "[8/10] Odosian TLS + ingress"
if ! kubectl -n odosian get secret odosian-tls &>/dev/null; then
  echo "Generating self-signed TLS certificate for odosian.local / ${TRAEFIK_IP:-<pending>}..."
  mkdir -p "$CERTS_DIR"
  SAN="DNS:odosian.local"
  [ -n "${TRAEFIK_IP:-}" ] && SAN="${SAN},IP:${TRAEFIK_IP}"
  openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout "$CERTS_DIR/odosian-tls.key" -out "$CERTS_DIR/odosian-tls.crt" -days 825 \
    -subj "/CN=odosian.local" -addext "subjectAltName=${SAN}" 2>/dev/null
  kubectl -n odosian create secret tls odosian-tls \
    --cert="$CERTS_DIR/odosian-tls.crt" --key="$CERTS_DIR/odosian-tls.key"
fi

if [ -f "$ENGINE_K8S_DIR/deployment.yaml" ] && [ -f "$ENGINE_K8S_DIR/service.yaml" ]; then
  log "[7.5/10] Odosian AI Engine deployment"
  # The engine's manifests ship with no namespace set — -n odosian puts them
  # in the same namespace as Odosian itself rather than needing the manifests
  # to hardcode it.
  kubectl apply -n odosian -f "$ENGINE_K8S_DIR/deployment.yaml"
  kubectl apply -n odosian -f "$ENGINE_K8S_DIR/service.yaml"
  kubectl -n odosian rollout status deployment/odosian-engine --timeout=120s
elif [ -d "$ENGINE_DIR" ]; then
  echo "odosian-ai-engine/k8s/ manifests not present yet — skipping engine deployment until they are."
fi

kubectl apply -f "$K8S_DIR/deployment.yaml"
kubectl apply -f "$K8S_DIR/service.yaml"
kubectl apply -f "$K8S_DIR/ingress.yaml"
kubectl -n odosian scale deployment odosian --replicas=1 2>/dev/null || true
kubectl -n odosian rollout status deployment/odosian --timeout=300s

log "[9/10] KubeVision"
KV_IP=""
if [ "${SKIP_KUBEVISION:-0}" = "1" ]; then
  echo "Skipping KubeVision (not selected)."
else
  if ! sudo k3s ctr -n k8s.io images ls -q 2>/dev/null | grep -q "^docker.io/library/kubevision:latest$"; then
    echo "Building image (no cached image found)..."
    sudo nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
      build --buildkit-host unix:///run/buildkit/buildkitd.sock -t kubevision:latest "$KUBEVISION_DIR"
  else
    echo "KubeVision image already built. Pass --rebuild to force a rebuild of everything."
  fi
  if [ "$REBUILD" = "1" ]; then
    sudo nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
      build --buildkit-host unix:///run/buildkit/buildkitd.sock -t kubevision:latest "$KUBEVISION_DIR"
    kubectl -n kubevision rollout restart deployment/kubevision 2>/dev/null || true
  fi

  if ! kubectl get namespace kubevision &>/dev/null; then
    kubectl create namespace kubevision
  fi

  if [ ! -f "$KUBEVISION_DIR/chart/values.local.yaml" ]; then
    echo "First run — generating a NextAuth secret (kept local, never committed)..."
    cat > "$KUBEVISION_DIR/chart/values.local.yaml" <<EOF
image:
  repository: kubevision
  tag: latest
  pullPolicy: Never

service:
  type: LoadBalancer
  port: 80

env:
  NEXTAUTH_SECRET: "$(openssl rand -hex 32)"
EOF
  fi

  # KubeVision used to share Traefik's IP via hostname-based Ingress
  # (kubevision.local), which needed a manual /etc/hosts entry. It now gets its
  # own MetalLB LoadBalancer IP instead, so it's reachable directly with no
  # hostname/DNS setup. Clean up leftovers from the old approach if present.
  kubectl -n kubevision delete secret kubevision-tls --ignore-not-found >/dev/null 2>&1 || true

  helm upgrade --install kubevision "$KUBEVISION_DIR/chart" -n kubevision -f "$KUBEVISION_DIR/chart/values.local.yaml"
  kubectl -n kubevision rollout status deployment/kubevision --timeout=300s

  echo "Waiting for KubeVision to get a LoadBalancer IP..."
  for i in $(seq 1 30); do
    KV_IP=$(kubectl -n kubevision get svc kubevision -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    [ -n "$KV_IP" ] && break
    sleep 2
  done

  # KubeVision has no seeded account of its own — the first person to hit
  # /register becomes its one and only admin, and the password is bcrypt-hashed
  # (unrecoverable). Seed a known default admin the first time there are zero
  # users, so there's always a working login to report below. If an account
  # already exists (yours, or a previously-seeded default), leave it alone and
  # just report its email — we can't know/print a password we didn't set.
  KV_SEED_OUT=$(kubectl -n kubevision exec deploy/kubevision -- node -e "
const Database = require('better-sqlite3');
const bcrypt = require('bcryptjs');
const db = new Database('/app/data/kubevision.db');
const count = db.prepare('SELECT COUNT(*) as c FROM User').get().c;
if (count === 0) {
  const hash = bcrypt.hashSync('Admin@123!', 12);
  const id = 'seed' + Date.now().toString(36) + Math.random().toString(36).slice(2, 12);
  const now = new Date().toISOString().replace('Z', '+00:00');
  db.prepare('INSERT INTO User (id, email, name, passwordHash, role, createdAt, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)')
    .run(id, 'admin@kubevision.local', 'Admin', hash, 'admin', now, now);
  console.log('SEEDED');
} else {
  console.log('EXISTS:' + db.prepare('SELECT email FROM User LIMIT 1').get().email);
}
" 2>/dev/null || echo "ERR")

  if [[ "$KV_SEED_OUT" == SEEDED* ]]; then
    KV_LOGIN_LINE="KubeVision login: admin@kubevision.local / Admin@123!"
  elif [[ "$KV_SEED_OUT" == EXISTS:* ]]; then
    KV_LOGIN_LINE="KubeVision login: already configured (${KV_SEED_OUT#EXISTS:}) — use your existing password"
  else
    KV_LOGIN_LINE="KubeVision login: unavailable (couldn't reach the database yet)"
  fi
fi

log "[10/10] Stack is up"
ES_IP=$(kubectl get svc es-cluster-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
KB_IP=$(kubectl get svc es-kibana-kb-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
FS_IP=$(kubectl get svc fleet-server-agent-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
TRAEFIK_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
ELASTIC_PW=$(kubectl get secret es-cluster-es-elastic-user -o jsonpath='{.data.elastic}' 2>/dev/null | base64 -d || echo "unavailable")

if [ "${SKIP_KUBEVISION:-0}" = "1" ]; then
  KV_LINE="KubeVision:     not installed (skipped)"
  KV_LOGIN_LINE="KubeVision login: not installed (skipped)"
else
  KV_LINE="KubeVision:     http://${KV_IP:-pending}/"
fi

cat <<EOF

Odosian:        https://${TRAEFIK_IP}/   (self-signed cert — accept the browser warning)
${KV_LINE}
Kibana:         https://${KB_IP}:5601   (user: elastic / pw: ${ELASTIC_PW})
Elasticsearch:  https://${ES_IP}:9200
Fleet Server:   https://${FS_IP}:8220

Odosian login:  admin@odosian.com / Admin@123!
${KV_LOGIN_LINE}

Run '~/stack/status.sh' anytime to see this again.
EOF
