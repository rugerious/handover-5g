#!/usr/bin/env bash
# Isolation test for step 3.4: from a throwaway pod, try to open TCP connections.
# OPEN = connected, BLOCKED = timed out or refused. Nothing is left behind.
probe() {  # namespace host port label
  local r
  r=$(kubectl -n "$1" run "nettest-$RANDOM" --rm -i --restart=Never --quiet \
      --image=busybox:1.37.0 -- sh -c "nc -w 3 $2 $3 </dev/null >/dev/null 2>&1 && echo OPEN || echo BLOCKED" 2>/dev/null | tail -1)
  printf '  %-34s %s\n' "$4" "${r:-ERROR}"
}
echo "from namespace default (a stranger):"
probe default open5gs-mongodb.core 27017   "-> MongoDB 27017"
probe default open5gs-amf-sbi.core 7777    "-> AMF SBI 7777"
echo "from namespace core (a pod with no role):"
probe core    open5gs-amf-sbi.core 7777    "-> AMF SBI 7777"
probe core    open5gs-mongodb.core 27017   "-> MongoDB 27017"
