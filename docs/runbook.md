# Runbook: daily lab routine

How to start a working session on the Handover lab and how to end it.
Everything runs from WSL Ubuntu on the laptop. No SSH, no open ports, no access keys.

## Start

1. **Sign in to AWS** (temporary credentials, up to 12 hours, MFA in the browser):
   ```bash
   aws sts get-caller-identity --query Arn --output text | sed 's/.*:\([^:]*\)$/\1/' \
     || aws login --remote
   ```
2. **Start the node** and wait until SSM sees it:
   ```bash
   aws ec2 start-instances --instance-ids i-01a352f99cc22979b --output text --query 'StartingInstances[].CurrentState.Name'
   aws ec2 wait instance-running --instance-ids i-01a352f99cc22979b
   aws ssm describe-instance-information --filters "Key=InstanceIds,Values=i-01a352f99cc22979b" \
     --query 'InstanceInformationList[].PingStatus' --output text   # repeat until: Online
   ```
3. **Open the tunnel to the Kubernetes API** in the background (one tab is enough; it closes after 20 min idle, just run it again):
   ```bash
   nohup aws ssm start-session --target i-01a352f99cc22979b --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["6443"],"localPortNumber":["16443"]}' > /tmp/tunnel.log 2>&1 < /dev/null &
   sleep 8 && cat /tmp/tunnel.log    # expect: Waiting for connections...
   ```
4. **Point kubectl at the lab** (this tab only; other tabs stay on the local k3d cluster):
   ```bash
   export KUBECONFIG=~/.kube/handover.yaml
   kubectl get nodes
   ```
   This is the daily user, `rugerious-desktop`: a personal certificate valid 45 days, with only
   the permissions in `deploy/rbac/operator.yaml` (read all but Secrets, logs, restarts, RAN exec,
   Argo CD port-forward). No kubeconfig yet, `x509: certificate has expired`, or the node was rebuilt?
   `cd ~/handover-5g/ansible && ansible-playbook kubeconfig.yml && cd ..` (it renews the
   certificate when less than 7 days are left, otherwise it changes nothing).
5. **Argo CD web page** (optional), through the same tunnel; then open https://localhost:8080 (user `admin`, password in the password manager):
   ```bash
   nohup kubectl -n argocd port-forward svc/argocd-server 8080:443 > /tmp/argocd-pf.log 2>&1 < /dev/null &
   ```

## End

1. Close the tunnel and the Argo CD port-forward: `pkill -f AWS-StartPortForwardingSession; pkill -f 'port-forward svc/argocd-server'`
2. **Stop the node** (the disk keeps everything):
   ```bash
   aws ec2 stop-instances --instance-ids i-01a352f99cc22979b --output text --query 'StoppingInstances[].CurrentState.Name'
   ```
   Safety net: EventBridge Scheduler stops it every night at 23:00 London time anyway.

## Admin access (break glass)

Only for rebuild steps 2 to 5 below or a fix the daily user is not allowed to make.
The admin key of k3s never leaves the node. Instead, the playbook makes a **1-hour certificate**
for `rugerious-desktop-admin`, which is admin only because of `deploy/rbac/break-glass.yaml`:
```bash
cd ~/handover-5g/ansible && ansible-playbook kubeconfig.yml -e admin=true && cd ..
export KUBECONFIG=~/.kube/handover-admin.yaml && kubectl auth whoami
# ... the admin work ...
export KUBECONFIG=~/.kube/handover.yaml       # back to the daily user
```
After an hour the file stops working; run the playbook again if more time is needed.
The other way in is a shell on the node through SSM: `sudo k3s kubectl ...`.

## New laptop

Everything the lab needs lives in GitHub, AWS and the node; the laptop only holds tools and
its own certificates. On a new machine: install the tools (versions in `versions.yaml`),
`aws login`, `gh auth login`, clone the repo, then give the machine its own device name:
add a copy of the `desktop` bindings in `deploy/rbac/` with the new name (PR, merge), and run
`ansible-playbook kubeconfig.yml -e device=<name>` (and `-e admin=true -e device=<name>` once
its break-glass binding exists).

## Lost or stolen laptop

Client certificates cannot be revoked, but they open nothing without a binding. Delete that
device's bindings in `deploy/rbac/` (both files) and merge: Argo CD removes them within minutes
and the laptop's certificates stop working, even though they have not expired (45 days daily,
1 hour admin). Then sign out of AWS and GitHub sessions on that machine from their websites.

## Costs

- Node running: about $0.40/hour (c7i.2xlarge, 8 vCPU) plus $0.005/hour for its public IP.
- Disk: about $3.50/month, charged even while the node is stopped.
- Budget `handover-monthly`: $30, email alerts at 40% and 100% (actual) and 100% (forecast).

## Rebuild from scratch

Use this when the node is new or k3s was reinstalled. Every block runs in the **LAPTOP tab**
(WSL Ubuntu, in `~/handover-5g`, on an up-to-date `main`), with the AWS sign-in and the tunnel
from *Start* above. The order matters: each step needs the one before. Steps 2 to 5 run as
**admin** (the daily user gets its permissions from Argo CD, which arrives in step 4); steps 6
to 8 run as the daily user.

If the node itself was replaced (new instance), its ID changes: update it in this runbook
(`terraform -chdir=infra output`) before using the *Start* commands.

**1. k3s and the kubeconfig** (Ansible over SSM):
```bash
cd ~/handover-5g/ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook k3s.yml          # SCTP + k3s, safe to run again
ansible-playbook kubeconfig.yml                 # daily kubeconfig (no permissions until step 4)
ansible-playbook kubeconfig.yml -e admin=true   # 1-hour admin kubeconfig + its binding
# Optional, only for the Docker Compose lab (Phase 2.1): ansible-playbook docker.yml
cd ~/handover-5g
export KUBECONFIG=~/.kube/handover-admin.yaml   # admin for steps 2 to 5
```
Ansible needs `ansible-core` with `boto3` and `botocore[crt]` in the same environment
(`pipx install ansible-core && pipx inject ansible-core boto3 "botocore[crt]"`) and the AWS Session Manager plugin.

**2. Publish the cluster's new signing key.** A new k3s install makes a new service-account
signing key. AWS checks the tokens of External Secrets against the copy in `infra/oidc/jwks.json`,
so an old copy means no secrets, no subscriber and no attach.
```bash
kubectl get --raw /openid/v1/jwks > infra/oidc/jwks.json
git diff --stat infra/oidc/jwks.json   # nothing: same key, skip to step 3
```
If the file changed: branch, commit, PR as usual. The CI plan must show exactly one change
(`aws_s3_object.k3s_oidc_jwks`); merge and approve the apply. CloudFront does not cache these
files, so AWS sees the new key as soon as the apply finishes.

**3. Argo CD** (Helm, the one install not done by Argo CD itself; version from `versions.yaml`):
```bash
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null; helm repo update argo
helm upgrade --install argocd argo/argo-cd --version 10.11.6 \
  -n argocd --create-namespace -f deploy/argocd/values.yaml
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m
```
Admin password: straight to the Windows clipboard, never on screen. Save it in the password
manager, then delete the secret that holds it:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d | clip.exe
# paste into the password manager first, then:
kubectl -n argocd delete secret argocd-initial-admin-secret
```

**4. Hand everything else to Git** (the only manifest ever applied by hand):
```bash
kubectl apply -f deploy/argocd/root.yaml
until kubectl get ns external-secrets >/dev/null 2>&1; do sleep 10; done; echo "External Secrets namespace is there"
```

**5. External Secrets service account** (once per cluster, after Argo CD has installed External Secrets).
Its annotation holds the role ARN, which contains the account ID, so it is kept out of Git.
The ARN goes from Terraform straight into the cluster without being printed:
```bash
ROLE_ARN=$(terraform -chdir=infra output -raw eso_role_arn) && \
kubectl -n external-secrets create serviceaccount handover-ssm-reader --dry-run=client -o yaml | kubectl apply -f - && \
kubectl -n external-secrets annotate serviceaccount handover-ssm-reader eks.amazonaws.com/role-arn="$ROLE_ARN" --overwrite && \
unset ROLE_ARN
kubectl get clustersecretstore aws-ssm    # expect: Valid  ReadWrite  True
```

From here on, the daily user is enough (Argo CD has applied `deploy/rbac/`):
```bash
export KUBECONFIG=~/.kube/handover.yaml && scripts/rbac-test.sh   # expect: 0 failed
```

**6. SIM keys in SSM Parameter Store.** They live in AWS, not in the cluster, so a rebuild
normally finds them already there. This block creates only what is missing (random values,
never shown) and leaves existing keys alone, because changing them means the old ones in the
core and the UE no longer match until both re-read them:
```bash
for p in k opc; do
  name=/handover/subscriber/001010123456780/$p
  if aws ssm get-parameter --name "$name" --query Parameter.Name --output text >/dev/null 2>&1; then
    echo "$name: exists, kept"
  else
    aws ssm put-parameter --name "$name" --type SecureString --value "$(openssl rand -hex 16)" \
      --tags Key=Project,Value=handover --query Version --output text >/dev/null && echo "$name: created"
  fi
  # format check without printing the value: expect 1
  aws ssm get-parameter --name "$name" --with-decryption --query Parameter.Value --output text | grep -cE '^[0-9a-f]{32}$'
done
```

**7. Make External Secrets read now** (instead of waiting up to an hour for its next refresh):
```bash
kubectl annotate externalsecret -A --all force-sync=$(date +%s) --overwrite
kubectl get externalsecret -A    # expect: SecretSynced  True
```

**8. Check the lab:**
```bash
kubectl -n argocd get applications              # expect 6 apps: Synced  Healthy
kubectl -n ran exec deploy/ran -c srsue -- sh -c 'ip -br addr | grep tun'   # expect tun_srsue 10.45.0.x
kubectl -n ran exec deploy/ran -c srsue -- ping -c 5 10.45.0.1               # expect 0% packet loss
```
No `tun_srsue` means the UE never got a session, and the ping then fails with 100% loss.
After a node start this is usually the known boot race: the RAN is ready before the core's
database-backed functions (seen with the UDR up to 67 s later), the UE is turned away once and
does not try again. Restart the RAN, give the UE 30 s to register, and check again
(if the first attach after the restart also fails, run it once more):
```bash
kubectl -n ran rollout restart deploy/ran && kubectl -n ran rollout status deploy/ran --timeout=3m
sleep 30
kubectl -n ran exec deploy/ran -c srsue -- sh -c 'ip -br addr | grep tun'
kubectl -n ran exec deploy/ran -c srsue -- ping -c 5 10.45.0.1
```
