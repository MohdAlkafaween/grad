#!/bin/bash
# Pull the latest Odosian and KubeVision source from their own repos, then
# optionally rebuild and redeploy. Use this after pushing changes to either
# repo — build.sh only clones them once; this is what syncs updates in.
set -euo pipefail

# Never run this with sudo/as root — it calls sudo itself (via up.sh) where
# needed. Running the whole script as root makes every file it touches
# (git pull/clone) root-owned, breaking the next normal-user run.
if [ "$(id -u)" = "0" ]; then
  echo "Don't run this as root or with sudo — it calls sudo itself where needed." >&2
  echo "Run it as your normal user: ./update.sh" >&2
  exit 1
fi

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$STACK_DIR/.." && pwd)"
ODOSIAN_DIR="$REPO_ROOT/odosian"
KUBEVISION_DIR="$REPO_ROOT/kubevision"
ENGINE_DIR="$REPO_ROOT/odosian-ai-engine"

ODOSIAN_REPO="https://github.com/MohdAlkafaween/odosian.git"
KUBEVISION_REPO="https://github.com/MohdAlkafaween/kubevision.git"
ENGINE_REPO="https://github.com/Hidra141/odosian-ai-engine.git"

log() { echo -e "\n\033[1;33m==> $1\033[0m"; }

pull_or_clone() {
  local dir="$1" repo="$2" name="$3"
  if [ -d "$dir/.git" ]; then
    echo "Pulling latest $name..."
    git -C "$dir" pull --ff-only
  elif [ -d "$dir" ]; then
    echo "$dir exists but isn't a git checkout — skipping $name (pull manually or remove it and re-run)."
  else
    echo "$name not present locally — cloning..."
    git clone --quiet "$repo" "$dir"
  fi
}

log "Odosian"
pull_or_clone "$ODOSIAN_DIR" "$ODOSIAN_REPO" "odosian"

log "Odosian AI Engine"
pull_or_clone "$ENGINE_DIR" "$ENGINE_REPO" "odosian-ai-engine"

log "KubeVision"
if [ -d "$KUBEVISION_DIR" ] || [ "${1:-}" = "--with-kubevision" ]; then
  pull_or_clone "$KUBEVISION_DIR" "$KUBEVISION_REPO" "kubevision"
else
  echo "Not installed locally — skipping (run with --with-kubevision to pull it in)."
fi

echo
read -rp "Rebuild images and redeploy now? [y/N] " ans
case "$ans" in
  # up.sh decides whether to build/deploy KubeVision itself — if
  # --with-kubevision/--no-kubevision wasn't passed here, it'll ask.
  [Yy]*) bash "$STACK_DIR/up.sh" --rebuild "${1:-}" ;;
  *) echo "Skipped. Run 'stack/up.sh --rebuild' whenever you're ready to deploy the update." ;;
esac
