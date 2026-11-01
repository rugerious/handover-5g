# Phase 2: 5G in Docker Compose (first test)

Open5GS core + OCUDU gNB + srsUE, connected over ZeroMQ (a simulated radio),
on the lab node. Purpose: prove the 5G works before moving it to Kubernetes,
so a 5G problem is never mixed up with a Kubernetes problem.

**Status: working.** On 1 Nov 2026 the UE attached, got IP `10.45.1.2` and
pinged the core with 0% loss (20–38 ms).

| Service | IP (network `ran`) | Built from |
|---|---|---|
| `5gc` Open5GS v2.7.6 | 10.53.1.2 | OCUDU `docker/open5gs` + our `open5gs/open5gs-5gc.yml.in` |
| `gnb` OCUDU gNB | 10.53.1.3 | `gnb/Dockerfile` (ZeroMQ only) over OCUDU `release_26_10` |
| `srsue` srsUE | shares the gNB's network | `srsue/Dockerfile`, srsRAN 4G `release_25_10` |

Cell: PLMN 00101, TAC 7, band 3 FDD, 20 MHz, 15 kHz. Exact versions: `versions.yaml`.
The node needs **8 vCPU** (see below).

## Build (on the node, as root)

```bash
git clone --depth 1 --branch release_26_10 https://gitlab.com/ocudu/ocudu.git /opt/handover/src/ocudu
cd /opt/handover/repo/lab/compose
docker buildx build --load -f gnb/Dockerfile -t handover/ocudu-gnb:release_26_10 /opt/handover/src/ocudu
docker compose build 5gc srsue
```

## Run and test

Start in order (core, gNB, then UE):

```bash
docker compose up -d 5gc gnb && sleep 12 && docker compose up -d srsue && sleep 25
docker logs srsue 2>&1 | grep -E 'PDU Session|RRC'   # expect: IP: 10.45.1.2
docker exec srsue ping -c 5 -I tun_srsue 10.45.1.1   # the core's gateway
docker compose down
```

## What it took to attach (1 Nov 2026)

Three separate problems, found in this order:

1. **CPU.** OCUDU keeps 3 CPUs spare for the system. On 4 vCPU the gNB gets a
   single worker thread and the radio stalls before the cell starts
   (OCUDU issue #571).
   Fix: the node moved to `c7i.2xlarge` (8 vCPU).
2. **Uplink at 10 MHz.** The UE reached RRC Connected and authenticated, but its
   larger uplink messages failed CRC, so NAS Security Mode Complete never
   reached the core. Fix: use the official example's 20 MHz / 23.04 Msps.
3. **NAS decoding.** The core's Registration Accept listed TACs 7, 8 and 9
   (OCUDU's config serves 8 and 9 for another example). srsUE's decoder accepts
   a tracking-area list with one TAC only, so the UE dropped the message and
   the gNB released it. Fix: `open5gs/open5gs-5gc.yml.in` is OCUDU's template
   with TACs 8 and 9 removed, mounted over the image's copy; the container
   renders it at start.

## Why our own gNB Dockerfile

OCUDU's `docker/Dockerfile` has no "gNB with ZeroMQ only" target: its `lean`
target builds only the CU (no radio), and its gNB targets compile UHD and/or
DPDK from source. `gnb/Dockerfile` follows OCUDU's recipe with those radios off,
and fails the build if the gNB is not linked to ZeroMQ. It also skips ROHC
(optional in OCUDU): on 31 Oct 2026 `rohc-lib.org` was unreachable and broke
OCUDU's own build.
