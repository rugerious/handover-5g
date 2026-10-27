# Handover: 5G Operations Lab
![kpi-exporter image](https://github.com/rugerious/handover-5g/actions/workflows/kpi-exporter.yml/badge.svg)

> In RAN, a handover moves a call to a new cell without dropping it.
> This project is my handover from RAN to cloud.

A cloud-native 5G network (Open5GS core + OCUDU gNB with a simulated radio) running on Kubernetes, deployed by GitOps, with KPI observability, automated acceptance testing and an AI ops assistant that proposes fixes for human approval.

## Status

✅ **Phase 0: Foundations** done (27 Oct 2026): repo, local Kubernetes (k3d), a fake gNB KPI exporter in a hardened container, and CI that builds it and publishes it to GHCR. Next: **Phase 1, AWS infrastructure**.

## Planned architecture

- **RAN + core:** OCUDU gNB and srsUE over ZeroMQ, Open5GS 5G core, packaged with Helm
- **Platform:** k3s on AWS EC2, built with Terraform and Ansible, no SSH (SSM only), zero inbound ports
- **Delivery:** ArgoCD (GitOps) and GitHub Actions with OIDC (no stored AWS keys)
- **Observability:** Prometheus and Grafana dashboards for RAN KPIs, with alerting
- **Acceptance:** automated pass/fail reports per deployment, plus fault injection
- **AI ops:** an assistant that detects KPI degradation, opens a pull request with a fix and raises an incident in [CloudOps](https://github.com/rugerious/cloudops-aws-platform); a human merges

## Roadmap

| Phase | What | Status |
|---|---|---|
| 0 | Foundations: repo, local Kubernetes, first container image and CI | ✅ |
| 1 | Infrastructure: VPC, EC2, Terraform, Ansible, k3s | ⏳ |
| 2 | 5G workloads on Kubernetes | ⏳ |
| 3 | GitOps with ArgoCD | ⏳ |
| 4 | Observability: RAN KPI dashboards and alerts | ⏳ |
| 5 | Automated acceptance and fault injection | ⏳ |
| 6 | AI ops assistant | ⏳ |
| 7 | Demo video and write-up | ⏳ |

## Licence

MIT for this repository's code and configuration. Open5GS (AGPL-3.0) and OCUDU (BSD-3-Clause) keep their own licences: this project uses their published software and does not copy their source.
