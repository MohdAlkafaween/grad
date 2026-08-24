#!/bin/bash
set -uo pipefail

echo "=== k3s ==="
if systemctl is-active --quiet k3s; then
  echo "active"
else
  echo "Stack is powered down. Run ~/stack/up.sh to bring it up."
  exit 0
fi

echo
echo "=== Nodes ==="
kubectl get nodes 2>/dev/null

echo
echo "=== Elastic SIEM ==="
kubectl get elasticsearch,kibana,agent 2>/dev/null

echo
echo "=== Odosian ==="
kubectl -n odosian get pods,svc 2>/dev/null

echo
echo "=== Odosian AI Engine ==="
kubectl -n odosian get pods -l app=odosian-engine 2>/dev/null

echo
echo "=== KubeVision ==="
kubectl -n kubevision get pods,svc 2>/dev/null

ES_IP=$(kubectl get svc es-cluster-es-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
KB_IP=$(kubectl get svc es-kibana-kb-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
FS_IP=$(kubectl get svc fleet-server-agent-http -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
TRAEFIK_IP=$(kubectl get svc traefik -n kube-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
KV_IP=$(kubectl -n kubevision get svc kubevision -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
ELASTIC_PW=$(kubectl get secret es-cluster-es-elastic-user -o jsonpath='{.data.elastic}' 2>/dev/null | base64 -d || echo "")

echo
echo "=== Access ==="
echo "Odosian:        https://${TRAEFIK_IP:-pending}/"
echo "AI Engine:      http://odosian-engine:8000 (internal, ClusterIP — not reachable from outside the cluster)"
echo "KubeVision:     http://${KV_IP:-pending}/"
echo "Kibana:         https://${KB_IP:-pending}:5601   (elastic / ${ELASTIC_PW:-unavailable})"
echo "Elasticsearch:  https://${ES_IP:-pending}:9200"
echo "Fleet Server:   https://${FS_IP:-pending}:8220"
