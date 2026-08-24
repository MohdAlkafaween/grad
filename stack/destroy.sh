#!/bin/bash
# Remove the deployed stack. By default this uninstalls the Elastic SIEM
# infrastructure (Elasticsearch, Kibana, Fleet Server, MetalLB, ECK operator)
# and stops Odosian + KubeVision, but PRESERVES their databases (Odosian's
# rules/coverage marks, KubeVision's saved topologies/settings) since there's
# no upstream copy of that data.
#
# Flags:
#   --full        also delete Odosian's and KubeVision's databases permanently
#   --reset-k3s   also wipe k3s itself back to a blank install
set -euo pipefail

FULL=false
RESET_K3S=false
for arg in "$@"; do
  case "$arg" in
    --full) FULL=true ;;
    --reset-k3s) RESET_K3S=true ;;
  esac
done

echo "This will remove the deployed Elastic SIEM stack (Elasticsearch, Kibana, Fleet Server, MetalLB, ECK operator) and stop Odosian + KubeVision."
if [ "$FULL" = true ]; then
  echo "  --full was passed: Odosian's database (rules, coverage marks, custom categories) and KubeVision's database (saved topologies, settings) will ALSO be permanently deleted."
fi
if [ "$RESET_K3S" = true ]; then
  echo "  --reset-k3s was passed: k3s itself will be wiped back to a blank install."
fi
read -r -p "Type 'destroy' to confirm: " CONFIRM
if [ "$CONFIRM" != "destroy" ]; then
  echo "Aborted. Nothing was changed."
  exit 1
fi

sudo systemctl start k3s 2>/dev/null || true
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 2; done

echo "Uninstalling Elastic SIEM stack..."
helm uninstall elastic-siem 2>/dev/null || true
helm uninstall elastic-operator -n elastic-system 2>/dev/null || true
helm uninstall elastic-operator-crds 2>/dev/null || true
helm uninstall metallb -n metallb-system 2>/dev/null || true
kubectl delete namespace elastic-system --ignore-not-found
kubectl delete namespace metallb-system --ignore-not-found

echo "Stopping Odosian and KubeVision..."
kubectl -n odosian scale deployment odosian --replicas=0 2>/dev/null || true
kubectl -n odosian scale deployment odosian-engine --replicas=0 2>/dev/null || true
kubectl -n kubevision scale deployment kubevision --replicas=0 2>/dev/null || true

if [ "$FULL" = true ]; then
  echo "Deleting Odosian and KubeVision namespaces and their databases..."
  kubectl delete namespace odosian --ignore-not-found
  kubectl delete namespace kubevision --ignore-not-found
fi

if [ "$RESET_K3S" = true ]; then
  echo "Resetting k3s to a blank install..."
  sudo systemctl stop k3s
  sudo rm -rf /var/lib/rancher/k3s /etc/rancher/k3s
  sudo systemctl start k3s
  echo "k3s reset. Run ~/stack/up.sh to redeploy everything from scratch."
fi

echo "Done."
