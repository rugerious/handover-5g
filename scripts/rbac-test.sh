#!/usr/bin/env bash
# What may the current kubeconfig user do? Compares `kubectl auth can-i` with
# what the daily operator (deploy/rbac/operator.yaml) should be allowed.
#   KUBECONFIG=~/.kube/handover.yaml scripts/rbac-test.sh
# Run it with the admin kubeconfig too: the "no" lines then FAIL, which shows
# what the daily user is kept away from.
set -u
pass=0; fail=0
check() {   # check <yes|no> <can-i arguments...>
  local want=$1; shift
  local got
  got=$(kubectl auth can-i "$@" 2>/dev/null | head -n1 | cut -d' ' -f1)
  got=${got:-error}
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); r=PASS; else fail=$((fail + 1)); r=FAIL; fi
  printf '%-4s  want %-3s got %-5s  %s\n' "$r" "$want" "$got" "$*"
}

kubectl auth whoami 2>/dev/null | sed -n '2,3p'
echo "--- read"
check yes list pods -A
check yes list nodes
check yes get pods --subresource=log -n core
check yes list applications.argoproj.io -n argocd
check yes get clustersecretstores.external-secrets.io
check no  get secrets -n core
check no  get secrets -n ran
check no  list secrets -A
echo "--- operate"
check yes patch deployments.apps -n ran
check yes patch deployments.apps -n core
check yes patch externalsecrets.external-secrets.io -n core
check yes create pods --subresource=exec -n ran
check yes create pods --subresource=portforward -n argocd
echo "--- kept away"
check no  create pods --subresource=exec -n core
check no  create pods --subresource=exec -n argocd
check no  delete deployments.apps -n ran
check no  delete pods -n core
check no  create pods -n default
check no  patch applications.argoproj.io -n argocd
check no  create clusterrolebindings.rbac.authorization.k8s.io
check no  impersonate users
echo "--- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
