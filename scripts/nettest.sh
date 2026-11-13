#!/usr/bin/env bash
# Isolation test for step 3.4: from a throwaway pod, try to open TCP connections.
# OPEN = connected, BLOCKED = timed out or refused, ERROR (reason) = the probe
# itself failed. Needs permission to create pods (admin kubeconfig, see runbook).
# Nothing is left behind.
#
# The pod's answer is read from its logs after it finishes. `kubectl run --rm -i`
# (the first version) sometimes ended before attaching and lost the answer
# without any error (seen 13 Nov 2026: 1 probe in 4, exit code 0, empty output).
err=$(mktemp); trap 'rm -f "$err"' EXIT
probe() {  # namespace host port label
  local ns=$1 pod="nettest-$RANDOM$RANDOM" r=""
  : > "$err"
  if kubectl -n "$ns" run "$pod" --restart=Never --quiet --image=busybox:1.37.0 \
       -- sh -c "nc -w 3 $2 $3 </dev/null >/dev/null 2>&1 && echo OPEN || echo BLOCKED" >/dev/null 2>>"$err" &&
     kubectl -n "$ns" wait pod "$pod" --for=jsonpath='{.status.phase}'=Succeeded --timeout=90s >/dev/null 2>>"$err"; then
    r=$(kubectl -n "$ns" logs "$pod" 2>>"$err" | tail -n1)
  fi
  kubectl -n "$ns" delete pod "$pod" --ignore-not-found >/dev/null 2>&1
  printf '  %-34s %s\n' "$4" "${r:-ERROR ($(tail -n1 "$err"))}"
}
echo "from namespace default (a stranger):"
probe default open5gs-mongodb.core 27017   "-> MongoDB 27017"
probe default open5gs-amf-sbi.core 7777    "-> AMF SBI 7777"
echo "from namespace core (a pod with no role):"
probe core    open5gs-amf-sbi.core 7777    "-> AMF SBI 7777"
probe core    open5gs-mongodb.core 27017   "-> MongoDB 27017"
