# Phase 2: 5G in Docker Compose (first test)

Open5GS core + OCUDU gNB + srsUE, connected over ZeroMQ (a simulated radio),
on the lab node. Purpose: prove the 5G works before moving it to Kubernetes,
so a 5G problem is never mixed up with a Kubernetes problem.

| Service | IP (network `ran`) | Built from |
|---|---|---|
| `5gc` Open5GS v2.7.6 | 10.53.1.2 | OCUDU `docker/open5gs` |
| `gnb` OCUDU gNB | 10.53.1.3 | `gnb/Dockerfile` (ZeroMQ only) over OCUDU `release_26_10` |
| `srsue` srsUE | 10.53.1.4 | `srsue/Dockerfile`, srsRAN 4G `release_25_10` |

Cell: PLMN 00101, TAC 7, band 3 FDD, 10 MHz, 15 kHz. Exact versions: `versions.yaml`.

## Build (on the node, as root)

```bash
git clone --depth 1 --branch release_26_10 https://gitlab.com/ocudu/ocudu.git /opt/handover/src/ocudu
cd /opt/handover/repo/lab/compose
docker buildx build --load -f gnb/Dockerfile -t handover/ocudu-gnb:release_26_10 /opt/handover/src/ocudu
docker compose build 5gc srsue
```

## Run and test

```bash
docker compose up -d
docker compose logs -f gnb          # wait for the N2 connection to the AMF
docker exec srsue ip addr show tun_srsue
docker exec srsue ping -c 4 -I tun_srsue 10.45.0.1
docker compose down
```

## Why our own gNB Dockerfile

OCUDU's `docker/Dockerfile` has no "gNB with ZeroMQ only" target: its `lean`
target builds only the CU (no radio), and its gNB targets compile UHD and/or
DPDK from source. `gnb/Dockerfile` follows OCUDU's recipe with those radios off,
and fails the build if the gNB is not linked to ZeroMQ. It also skips ROHC
(optional in OCUDU): on 31 Oct 2026 `rohc-lib.org` was unreachable and broke
OCUDU's own build.
