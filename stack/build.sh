#!/bin/bash
# Fresh-machine bootstrap: installs everything this stack needs (k3s, helm,
# nerdctl, buildkit), pulls Odosian and KubeVision source from their own
# GitHub repos, then brings the whole stack up via up.sh.
#
# Meant to be handed to someone who has never set this machine up before —
# just clone THIS repo (which only contains stack/, including this script
# and the bundled elastic-siem-chart/) and run stack/build.sh. Odosian and
# KubeVision live in their own repos and get cloned as siblings of stack/
# the first time you run this.
#
# KubeVision is optional. Answer the prompt, or skip it with a flag:
#   ./build.sh --with-kubevision
#   ./build.sh --no-kubevision
set -euo pipefail

# Never run this with sudo/as root — it calls sudo itself for the handful of
# commands that actually need root (systemctl, apt, writing to /etc). Running
# the whole script as root instead makes every file it touches (git clone,
# the repo checkout itself, etc.) root-owned, so the very next normal-user
# run fails with "Permission denied" on those files.
if [ "$(id -u)" = "0" ]; then
  echo "Don't run this as root or with sudo — it calls sudo itself where needed." >&2
  echo "Run it as your normal user: ./build.sh" >&2
  exit 1
fi

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$STACK_DIR/.." && pwd)"
ODOSIAN_DIR="$REPO_ROOT/odosian"
KUBEVISION_DIR="$REPO_ROOT/kubevision"
ENGINE_DIR="$REPO_ROOT/odosian-ai-engine"
ECK_CHART_DIR="$STACK_DIR/elastic-siem-chart"

ODOSIAN_REPO="https://github.com/MohdAlkafaween/odosian.git"
KUBEVISION_REPO="https://github.com/MohdAlkafaween/kubevision.git"
ENGINE_REPO="https://github.com/Hidra141/odosian-ai-engine.git"

NERDCTL_VERSION="2.3.5"
BUILDKIT_VERSION="0.31.2"

log() { echo -e "\n\033[1;35m==> $1\033[0m"; }
err() { echo -e "\033[1;31mERROR: $1\033[0m" >&2; }

if [ ! -d "$ECK_CHART_DIR" ]; then
  err "Missing $ECK_CHART_DIR — this looks like an incomplete checkout of the grad repo."
  exit 1
fi

log "[0/7] Base packages (curl, openssl, python3, git)"
if ! command -v curl &>/dev/null || ! command -v openssl &>/dev/null || ! command -v python3 &>/dev/null || ! command -v git &>/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl openssl ca-certificates python3 git
else
  echo "Already present."
fi

log "[1/7] Odosian / AI Engine / KubeVision source"
if [ -d "$ODOSIAN_DIR" ]; then
  echo "odosian/ already present."
else
  echo "Cloning odosian..."
  git clone --quiet "$ODOSIAN_REPO" "$ODOSIAN_DIR"
fi

# Not optional like KubeVision — Odosian's AI features expect this engine to
# be reachable, so it's always cloned and deployed alongside Odosian.
if [ -d "$ENGINE_DIR" ]; then
  echo "odosian-ai-engine/ already present."
else
  echo "Cloning odosian-ai-engine..."
  git clone --quiet "$ENGINE_REPO" "$ENGINE_DIR"
fi

WITH_KUBEVISION=""
for arg in "$@"; do
  case "$arg" in
    --with-kubevision) WITH_KUBEVISION="yes" ;;
    --no-kubevision) WITH_KUBEVISION="no" ;;
  esac
done
if [ -z "$WITH_KUBEVISION" ]; then
  read -rp "Build and deploy KubeVision too? [y/N] " ans
  case "$ans" in
    [Yy]*) WITH_KUBEVISION="yes" ;;
    *) WITH_KUBEVISION="no" ;;
  esac
fi
if [ "$WITH_KUBEVISION" = "yes" ]; then
  if [ -d "$KUBEVISION_DIR" ]; then
    echo "kubevision/ already present."
  else
    echo "Cloning kubevision..."
    git clone --quiet "$KUBEVISION_REPO" "$KUBEVISION_DIR"
  fi
fi
echo "KubeVision: $WITH_KUBEVISION"

log "[2/7] k3s"
if ! command -v k3s &>/dev/null; then
  echo "Installing k3s..."
  # k3s writes its kubeconfig root-only (0600) by default, so plain `kubectl`
  # fails with "permission denied" for any non-root user unless KUBECONFIG
  # points somewhere else — which only works in shells that actually sourced
  # the .bashrc line below. Making the file itself world-readable means
  # kubectl just works everywhere, regardless of shell/session state.
  curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
else
  echo "k3s already installed."
fi
sudo systemctl enable --now k3s
echo "Waiting for node to be Ready..."
until sudo k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 2; done
echo "k3s is up."

# Safety net for k3s installs that predate the flag above (or were installed
# by some other means) — always make sure the kubeconfig is readable.
sudo chmod 644 /etc/rancher/k3s/k3s.yaml 2>/dev/null || true

mkdir -p "$HOME/.kube"
if [ ! -f "$HOME/.kube/config" ]; then
  sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
  sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
fi
export KUBECONFIG="$HOME/.kube/config"
if ! grep -qs "KUBECONFIG=$HOME/.kube/config" "$HOME/.bashrc"; then
  echo "export KUBECONFIG=$HOME/.kube/config" >> "$HOME/.bashrc"
  echo "Added KUBECONFIG to ~/.bashrc — open a new shell (or 'source ~/.bashrc') after this finishes."
fi

log "[3/7] Helm"
if ! command -v helm &>/dev/null; then
  echo "Installing Helm..."
  curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "Helm already installed."
fi

ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
case "$ARCH" in
  amd64|x86_64) PKG_ARCH="amd64" ;;
  arm64|aarch64) PKG_ARCH="arm64" ;;
  *) err "Unsupported architecture: $ARCH"; exit 1 ;;
esac

log "[4/7] nerdctl (builds container images against k3s's containerd)"
if ! command -v nerdctl &>/dev/null; then
  echo "Installing nerdctl v${NERDCTL_VERSION}..."
  curl -sfL -o /tmp/nerdctl.tar.gz \
    "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-${NERDCTL_VERSION}-linux-${PKG_ARCH}.tar.gz"
  sudo tar -C /usr/local/bin -xzf /tmp/nerdctl.tar.gz nerdctl
  rm -f /tmp/nerdctl.tar.gz
else
  echo "nerdctl already installed."
fi

log "[5/7] buildkit"
if ! command -v buildkitd &>/dev/null; then
  echo "Installing buildkit v${BUILDKIT_VERSION}..."
  curl -sfL -o /tmp/buildkit.tar.gz \
    "https://github.com/moby/buildkit/releases/download/v${BUILDKIT_VERSION}/buildkit-v${BUILDKIT_VERSION}.linux-${PKG_ARCH}.tar.gz"
  sudo tar -C /usr/local -xzf /tmp/buildkit.tar.gz
  rm -f /tmp/buildkit.tar.gz
else
  echo "buildkit already installed."
fi

if [ ! -f /etc/systemd/system/buildkitd.service ]; then
  echo "Wiring buildkitd to k3s's containerd..."
  sudo tee /etc/systemd/system/buildkitd.service >/dev/null <<'UNIT'
[Unit]
Description=BuildKit daemon (using k3s containerd)
After=k3s.service
Requires=k3s.service

[Service]
ExecStart=/usr/local/bin/buildkitd --addr unix:///run/buildkit/buildkitd.sock --containerd-worker=true --containerd-worker-addr=/run/k3s/containerd/containerd.sock --containerd-worker-namespace=k8s.io --oci-worker=false
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
fi
sudo systemctl enable --now buildkitd

log "[6/7] MetalLB IP pool"
echo "MetalLB hands out real IPs on your LAN for Odosian/Kibana/KubeVision."
echo "Pick a small range of IPs your router will NEVER assign via DHCP."
DEFAULT_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')
if [ -n "$DEFAULT_IP" ]; then
  BASE=$(echo "$DEFAULT_IP" | cut -d. -f1-3)
  SUGGESTED="${BASE}.240-${BASE}.250"
else
  SUGGESTED="192.168.1.240-192.168.1.250"
fi
read -rp "MetalLB IP range [${SUGGESTED}]: " NEWRANGE
NEWRANGE="${NEWRANGE:-$SUGGESTED}"
sed -E -i "s#^([[:space:]]*-[[:space:]]*)[0-9]{1,3}(\.[0-9]{1,3}){3}-[0-9]{1,3}(\.[0-9]{1,3}){3}[[:space:]]*\$#\1${NEWRANGE}#" \
  "$STACK_DIR/metallb-pool.yaml"
echo "MetalLB pool set to ${NEWRANGE}."

log "[7/7] Bringing the stack up"
if [ "$WITH_KUBEVISION" = "yes" ]; then
  export SKIP_KUBEVISION=0
else
  export SKIP_KUBEVISION=1
fi
bash "$STACK_DIR/up.sh"

echo -e "\nDone. Before real use, edit odosian/k8s/secret.local.yaml with your own SMTP/AI keys, then re-run this script or ~/stack/up.sh --rebuild."
