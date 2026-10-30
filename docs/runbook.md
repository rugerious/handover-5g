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
3. **Open the tunnel to the Kubernetes API** in a separate tab, and leave it open:
   ```bash
   aws ssm start-session --target i-01a352f99cc22979b \
     --document-name AWS-StartPortForwardingSession \
     --parameters 'portNumber=6443,localPortNumber=16443'
   ```
4. **Point kubectl at the lab** (this tab only; other tabs stay on the local k3d cluster):
   ```bash
   export KUBECONFIG=~/.kube/handover.yaml
   kubectl get nodes
   ```
   No kubeconfig yet, or the node was rebuilt? `cd ansible && ansible-playbook kubeconfig.yml`

## End

1. Close the tunnel: **Ctrl+C** in its tab.
2. **Stop the node** (the disk keeps everything):
   ```bash
   aws ec2 stop-instances --instance-ids i-01a352f99cc22979b --output text --query 'StoppingInstances[].CurrentState.Name'
   ```
   Safety net: EventBridge Scheduler stops it every night at 23:00 London time anyway.

## Costs

- Node running: about $0.23/hour (m7i.xlarge) plus $0.005/hour for its public IP.
- Disk: about $3.50/month, charged even while the node is stopped.
- Budget `handover-monthly`: $30, email alerts at 40% and 100% (actual) and 100% (forecast).

## Rebuild from scratch

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook k3s.yml          # SCTP + k3s, safe to run again
ansible-playbook kubeconfig.yml   # kubeconfig on the laptop
```
Ansible needs `ansible-core` with `boto3` and `botocore[crt]` in the same environment
(`pipx install ansible-core && pipx inject ansible-core boto3 "botocore[crt]"`) and the AWS Session Manager plugin.
