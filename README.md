# Handover: 5G Operations Lab
![terraform](https://github.com/rugerious/handover-5g/actions/workflows/terraform.yml/badge.svg) ![kpi-exporter image](https://github.com/rugerious/handover-5g/actions/workflows/kpi-exporter.yml/badge.svg)

> In RAN, a handover moves a call to a new cell without dropping it.
> This project is my handover from RAN to cloud.

A cloud-native 5G network (Open5GS core + OCUDU gNB with a simulated radio) running on Kubernetes in AWS, deployed by GitOps, with RAN KPI observability, automated acceptance testing and an AI ops assistant.

**The goal:** degrade a UE's radio on purpose → a model detects the KPI drop → an LLM explains it → the fix arrives as a pull request → a human approves → the KPIs recover → an acceptance report is published.

## Status

| Phase | What | Hours | Status |
|---|---|---|---|
| 0 | Foundations: repo, local Kubernetes (k3d), a fake gNB KPI exporter in a hardened container, CI publishing it to GHCR | 4–6 | ✅ 27 Oct 2026 |
| 1 | Infrastructure on AWS: Terraform state + OIDC pipeline, VPC, EC2 node, Ansible + k3s | 8–10 | 🚧 1.1–1.4 done (k3s running) |
| 2 | 5G workloads on Kubernetes: Open5GS + OCUDU gNB (official Helm chart) + srsUE over ZeroMQ | 12–16 | ⏳ |
| 3 | GitOps with ArgoCD, secrets from AWS, default-deny NetworkPolicies | 7–9 | ⏳ |
| 4 | Observability: RAN KPI dashboards and alerts | 8–10 | ⏳ |
| — | **MVP:** one UE attached, deployed by GitOps, KPI dashboards live | **39–51** | |
| 5 | Multi-UE + radio degradation injector; automated acceptance with public reports | 11–14 | ⏳ |
| 6 | AI ops assistant: Isolation Forest detects, LLM explains, MCP tools (read / dry-run / open PR only), fix by pull request, incident in [CloudOps](https://github.com/rugerious/cloudops-aws-platform) | 13–17 | ⏳ |
| 7 | Demo video and write-up | 4–6 | ⏳ |
| | **Total** | **67–88** | |

Estimated effort is **67–88 hours** at 8–10 hours a week, about 8–10 weeks. That includes about 6 hours added on 28 Oct 2026 after reviewing 14 OCUDU community projects (multi-UE, radio degradation, NetworkPolicies, public reports, MCP tools).

## What is built so far

**Delivery pipeline (no stored AWS keys)**
- Terraform state in S3: versioned, encrypted, HTTPS-only, with native locking.
- GitHub Actions gets short-lived AWS credentials through **OIDC**:
  - pull requests → `plan` with a **read-only** role that cannot read any other S3 object in the account;
  - merge to `main` → `apply` of exactly the planned change, **only after a human approves** the `production` environment.
- The apply role can manage only `handover-*` IAM resources and **cannot modify its own permissions**.
- Dependabot keeps actions, Python, Docker and Terraform dependencies current.
- A **pre-commit hook** (`.githooks/pre-commit`) blocks any commit that adds the AWS account ID or other listed values. The values live outside the repo, so the hook itself reveals nothing. Every PR also carries a checklist (README, plan read, no identifiers).

**Network and node**
- One VPC and public subnet, **no NAT gateway** (it would cost more than the whole lab budget).
- The node's security group has **zero inbound rules**; outbound is limited to ports 80 and 443. Rejected traffic is recorded with VPC Flow Logs.
- `m7i.xlarge` Ubuntu 24.04 node with an encrypted disk and **IMDSv2 only**.
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

## Planned architecture

- **RAN + core:** OCUDU gNB (Linux Foundation, formerly srsRAN Project) and srsUE over ZeroMQ, Open5GS 5G core, packaged with Helm, every version pinned in one manifest
- **Platform:** k3s on AWS EC2, built with Terraform and Ansible
- **Delivery:** ArgoCD (GitOps) and GitHub Actions with OIDC
- **Observability:** Prometheus and Grafana dashboards for RAN KPIs, with alerting
- **Acceptance:** pass/fail reports with KPI thresholds for every deployment, platform and radio fault injection, reports published on GitHub Pages
- **AI ops:** classic ML detects, an LLM explains, an MCP server exposes read, dry-run and open-PR tools; nothing is applied without a human merge

Several ideas come from projects in the OCUDU and srsRAN community (NIST O-RAN Testbed Automation, Tiny_Twin-OCUDU, the OCUDU dApp platform, SUSE's OCUDU reference architecture).

## Repository layout

| Path | What |
|---|---|
| `infra/` | Terraform: state backend, OIDC roles (`ci.tf`, bootstrap), network, compute, Ansible transfer bucket |
| `ansible/` | Inventory over SSM and the k3s playbook |
| `apps/kpi-exporter/` | Fake gNB KPI exporter (Python, Dockerfile, Kubernetes manifests) |
| `labs/` | Kubernetes learning labs |
| `.github/` | CI workflows, Dependabot, pull request checklist |
| `.githooks/` | Local git hooks (enable with `git config core.hooksPath .githooks`) |

## Licence

MIT for this repository's code and configuration. Open5GS (AGPL-3.0) and OCUDU (BSD-3-Clause) keep their own licences: this project uses their published software and does not copy their source.
