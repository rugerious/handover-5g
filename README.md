# Handover: 5G Operations Lab
![terraform](https://github.com/rugerious/handover-5g/actions/workflows/terraform.yml/badge.svg) ![kpi-exporter image](https://github.com/rugerious/handover-5g/actions/workflows/kpi-exporter.yml/badge.svg) ![ran images](https://github.com/rugerious/handover-5g/actions/workflows/ran-images.yml/badge.svg)

> In RAN, a handover moves a call to a new cell without dropping it.
> This project is my handover from RAN to cloud.

A cloud-native 5G network (Open5GS core + OCUDU gNB with a simulated radio) running on Kubernetes in AWS, deployed by GitOps, with RAN KPI observability, automated acceptance testing and an AI ops assistant.

**The goal:** degrade a UE's radio on purpose → a model detects the KPI drop → an LLM explains it → the fix arrives as a pull request → a human approves → the KPIs recover → an acceptance report is published.

## Status

| Phase | What | Hours | Status |
|---|---|---|---|
| 0 | Foundations: repo, local Kubernetes (k3d), a fake gNB KPI exporter in a hardened container, CI publishing it to GHCR | 4–6 | ✅ 27 Oct 2026 |
| 1 | Infrastructure on AWS: Terraform state + OIDC pipeline, VPC, EC2 node, Ansible + k3s | 8–10 | ✅ 30 Oct 2026 (~7 h) |
| 2 | 5G workloads on Kubernetes: Open5GS (community Helm chart) + OCUDU gNB and srsUE over ZeroMQ (own Helm chart) | 12–16 | ✅ 10 Nov 2026 (~12 h) |
| 3 | GitOps with ArgoCD, secrets from AWS, default-deny NetworkPolicies | 7–9 | 🚧 3.4 default-deny NetworkPolicies, isolation tested |
| 4 | Observability: RAN KPI dashboards and alerts | 8–10 | ⏳ |
| — | **MVP:** one UE attached, deployed by GitOps, KPI dashboards live | **39–51** | |
| 5 | Multi-UE, a second cell and a radio degradation injector; automated acceptance with public reports | 12–16 | ⏳ |
| 6a | AI ops assistant: Isolation Forest detects, LLM explains, MCP tools (read / dry-run / open PR only), fix by pull request, incident in [CloudOps](https://github.com/rugerious/cloudops-aws-platform) | 13–17 | ⏳ |
| 6b | Energy savings: a model learns the daily traffic pattern; a human approves the sleep policy by PR, the controller applies it within limits and rolls back if KPIs drop | 6–8 | ⏳ |
| 7 | Demo video and write-up | 4–6 | ⏳ |
| | **Total** | **74–98** | |

Estimated effort is **74–98 hours** at 8–10 hours a week, about 9–11 weeks.

## What is built so far

**Delivery pipeline (no stored AWS keys)**
- Terraform state in S3: versioned, encrypted, HTTPS-only, with native locking.
- GitHub Actions gets short-lived AWS credentials through **OIDC**:
  - pull requests → `plan` with a **read-only** role that cannot read any other S3 object in the account;
  - merge to `main` → `apply` of exactly the planned change, **only after a human approves** the `production` environment.
- The apply role can manage only `handover-*` IAM resources and **cannot modify its own permissions**.
- Dependabot keeps actions, Python, Docker and Terraform dependencies current.
- GitHub **secret scanning, push protection** and **Dependabot security updates** are on.
- A **pre-commit hook** (`.githooks/pre-commit`) blocks any commit that adds the AWS account ID or other listed values. The values live outside the repo, so the hook itself reveals nothing. Every PR also carries a checklist (README, plan read, no identifiers).

**Network and node**
- One VPC and public subnet, **no NAT gateway** (it would cost more than the whole lab budget).
- The node's security group has **zero inbound rules**; outbound is limited to ports 80 and 443. Rejected traffic is recorded with VPC Flow Logs.
- `c7i.2xlarge` (8 vCPU) Ubuntu 24.04 node with an encrypted disk and **IMDSv2 only**.
- Shell access through **SSM Session Manager**: no SSH key, no open port.
- **Stops itself every night at 23:00** (EventBridge Scheduler), so a forgotten session costs one evening, not a month.
- Terraform ignores attributes that only *look* different while the node is stopped. A plan review caught it wanting to replace the node for that reason, before anything was applied.

**Operator access (no SSH, no access keys)**
- The laptop signs in with `aws login`: browser sign-in with MFA, temporary credentials that expire within 12 hours. No access key exists for this project.
- Ansible reaches the node through SSM. Files travel through a private S3 bucket (HTTPS only, no versioning, everything deleted after 1 day) using short-lived presigned links, so the node itself has no S3 permissions.

**Kubernetes (k3s) on the node**
- Installed by an **Ansible playbook over SSM**: k3s pinned to `v1.35.9+k3s1`, the SCTP kernel module (5G's N2 transport) loaded and persistent. Running it a second time changes nothing.
- **Secrets encrypted at rest**, admin kubeconfig readable by root only, no ingress or load balancer.
- The Kubernetes API is **not exposed**: `kubectl` on the laptop goes through an SSM port-forward that exists only while it's open.
- Daily start/stop, costs and rebuild steps are in the [runbook](docs/runbook.md). The kubeconfig comes from one playbook (`ansible/kubeconfig.yml`).

**5G lab (Phase 2)**
- Open5GS core, OCUDU gNB and srsUE over a ZeroMQ simulated radio on the node: **a UE attaches, gets an IP and pings the core** (1 Nov 2026, 0% loss).
- Three fixes, each found from logs and source code: OCUDU's CPU reservation (node moved to 8 vCPU), uplink failing at 10 MHz (now 20 MHz, as in the official example), and srsUE rejecting a multi-TAC Registration Accept (the core now serves one TAC). Details in [lab/compose](lab/compose/README.md).
- **RAN images built by CI:** `.github/workflows/ran-images.yml` builds the OCUDU gNB and srsUE at the commits pinned in `versions.yaml` and publishes them to GHCR on merge (pull requests only build). Portable CPU target (AVX2), so an image built on GitHub's machines also runs on the node.
- **5G core on k3s:** Open5GS 2.8 from the community Helm chart, one pod per network function (AMF, SMF, UPF, NRF, …) plus MongoDB; 5G SA only, AMF on a fixed address for the gNB, test subscriber loaded. Values in `deploy/core/`. MongoDB is pinned to 7.0: MongoDB 8 refuses to start on the node's kernel 7.0 (found from the pod's crash log).
- **5G RAN on k3s (our own Helm chart):** `charts/ran/` runs the OCUDU gNB and srsUE in one pod, linked by ZeroMQ over 127.0.0.1, with the images from GHCR. **The UE attaches to the core on k3s and pings it** (0% loss, 4 Nov 2026). The gNB waits 2 h before releasing an idle UE: srsUE cannot come back from idle, which first showed up as a ping that died 10 s after attach.
- **RAN on least privilege:** the gNB and UE no longer run `privileged`. Each container drops every Linux capability and adds back only what it needs: the gNB `SYS_NICE` (real-time radio threads); the UE `NET_ADMIN` and `SYS_NICE` (its tunnel interface) plus `NET_RAW` (ping, its test traffic), and the single device `/dev/net/tun`. Verified from inside the running processes (`CapEff`) and with attach + ping. The core's UPF still runs privileged as the community chart ships it (to review).

**GitOps (Phase 3)**
- **Argo CD on k3s** (chart 10.11.6, v3.5.6, pinned in `versions.yaml`): no SSO, no notifications, no ingress. Its web page is reached like the Kubernetes API, through the SSM tunnel with `kubectl port-forward`; nothing is exposed to the internet. The admin password goes straight to the clipboard, never on screen.
- **Git decides what runs:** an app of apps (`deploy/argocd/`) hands the 5G core (community chart + our values) and the RAN (our chart) to Argo CD. A merge to `main` is a deploy; a manual change in the cluster is put back to what Git says (self-heal). Argo CD adopted the running workloads without restarting them, and the UE kept pinging. `root.yaml` is the only manifest ever applied by hand.
- **A cluster identity AWS can verify (first step to secrets from AWS):** k3s signs its service-account tokens with a public issuer, `https://<id>.cloudfront.net`. The two documents AWS needs to check those tokens (the OIDC discovery and the cluster's public key) are served by CloudFront from a private S3 bucket that only CloudFront can read; the bucket itself answers 403. The old in-cluster issuer is still accepted, so running pods kept working through the change (apps Synced/Healthy, no failing pods).
- **An AWS role for one Kubernetes identity:** AWS IAM now trusts the cluster's tokens (an OIDC provider for the issuer above). The role `handover-eso` can be used only by the service account `external-secrets/handover-ssm-reader`, with tokens made for AWS STS; any other pod is refused. It can only read the lab's parameters (`/handover/*`) in SSM Parameter Store, decrypting them only through SSM, for 1 hour at a time. No access keys exist anywhere. The CI pipeline was allowed to manage this one provider and nothing else: it still cannot touch the GitHub provider it depends on.
- **SIM keys that nobody has seen:** new random K and OPc for the test SIM were generated straight into SSM Parameter Store as encrypted SecureStrings (`/handover/subscriber/<IMSI>/k`, `/opc`), never shown on screen or written to a file. The old values are the public srsRAN test keys, already in Git history, so moving them would have protected nothing.
- **External Secrets, deployed by Argo CD:** the operator (chart 2.13.0, pinned in `versions.yaml`) and one `ClusterSecretStore`, `aws-ssm`, which signs in to AWS with a token for `handover-ssm-reader` and the `handover-eso` role. It is usable only from the `core` and `ran` namespaces: a test from another namespace was refused, and a test from `core` received the key (format checked, value never printed). The service account is the only piece created outside Git, because its role annotation contains the account ID (see the runbook). Two fixes on the way: a folder renamed because `.gitignore` rightly blocks anything called `secrets/`, and a duplicate token audience that AWS refused (`Token audience contains more than one audience`).
- **The network runs on keys from AWS, none in Git:** the core loads the test subscriber with a small Job (`deploy/core-subscribers/`) that reads K and OPc from a Secret made by External Secrets; the UE (RAN chart 0.3.0) fills them into a config file that exists only in memory. Git holds only the parameter paths. **The UE attached and pinged with the new keys** (0% loss, 11 Nov 2026). On the way, the key change exposed an old hidden bug: the chart's populate had added the same subscriber on every start (7 copies), and the core read an old one, so the first attach failed with `MAC failure`. Found by comparing short fingerprints of the key in each place (database, both Secrets, the UE's file) without ever printing it; the Job now removes every copy and fails unless exactly one is left.
- **Default-deny networking for the 5G namespaces:** in `core` and `ran` nothing goes in or out unless a NetworkPolicy allows it (`deploy/network-policies/`, deployed by Argo CD). Open: DNS; SBI between the core functions (TCP 7777); MongoDB only from UDR, PCF and the subscriber job; N4 PFCP between SMF and UPF (UDP 8805); N2 from the gNB pod to the AMF (SCTP 38412); N3 between the gNB pod and the UPF (UDP 2152). Tested before merge: the gNB set up N2 over SCTP, the UE attached and pinged (0% loss), no core pod restarted. Isolation test (`scripts/nettest.sh`): before, any pod could reach MongoDB and the AMF; after, a pod from another namespace is blocked from both, and inside the core a pod with no role still reaches the AMF's SBI but not MongoDB.

## Planned architecture

- **RAN + core:** OCUDU gNB (Linux Foundation, formerly srsRAN Project) and srsUE over ZeroMQ, Open5GS 5G core, packaged with Helm, every version pinned in one manifest
- **Platform:** k3s on AWS EC2, built with Terraform and Ansible
- **Delivery:** ArgoCD (GitOps) and GitHub Actions with OIDC
- **Observability:** Prometheus and Grafana dashboards for RAN KPIs, with alerting
- **Acceptance:** pass/fail reports with KPI thresholds for every deployment, platform and radio fault injection, reports published on GitHub Pages
- **AI ops:** classic ML detects, an LLM explains, an MCP server exposes read, dry-run and open-PR tools; nothing is applied without a human merge

## Repository layout

| Path | What |
|---|---|
| `infra/` | Terraform: state backend, OIDC roles (`ci.tf`, bootstrap), network, compute, Ansible transfer bucket, k3s OIDC discovery (`oidc.tf`, CloudFront + private S3), External Secrets role (`eso.tf`) |
| `ansible/` | Inventory over SSM, the k3s playbook and the kubeconfig playbook |
| `docs/` | Runbook: daily routine, costs, rebuild |
| `lab/compose/` | Phase 2 first test: Open5GS + OCUDU gNB + srsUE over ZeroMQ in Docker Compose |
| `deploy/` | Kubernetes deployments: Helm values for the 5G core (`core/`) and Argo CD (`argocd/`), the AWS secret store (`secret-store/`), the subscriber loader (`core-subscribers/`), NetworkPolicies (`network-policies/`) |
| `charts/ran/` | Our Helm chart: OCUDU gNB + srsUE in one pod over ZeroMQ |
| `versions.yaml` | Every version the lab runs (OCUDU, srsUE, Open5GS, k3s, tools), pinned to exact commits |
| `apps/kpi-exporter/` | Fake gNB KPI exporter (Python, Dockerfile, Kubernetes manifests) |
| `labs/` | Kubernetes learning labs |
| `.github/` | CI workflows, Dependabot, pull request checklist |
| `scripts/` | `nettest.sh`: isolation test for the NetworkPolicies |
| `.githooks/` | Local git hooks (enable with `git config core.hooksPath .githooks`) |

## Acknowledgements

Inspired in part by public work in the OCUDU and srsRAN community, including NIST's O-RAN testbed automation and SUSE's OCUDU reference architecture.

Built with Claude (Anthropic) as a pair programmer. Every change was reviewed, tested on the node and merged by me.

## Licence

MIT for this repository's code and configuration. Open5GS (AGPL-3.0) and OCUDU (BSD-3-Clause) keep their own licences: this project uses their published software and does not copy their source, except one OCUDU config template (`lab/compose/open5gs/`), kept with its BSD-3-Clause header.
