"""Fake gNB KPI exporter for the Handover lab.

Publishes simulated RAN KPIs in Prometheus format on :9100/metrics.
Replaced in Phase 4 by a real exporter reading OCUDU gNB metrics.
"""
import os
import random
import time

from prometheus_client import Counter, Gauge, start_http_server

CELL_ID = os.getenv("CELL_ID", "lab-cell-1")
PORT = int(os.getenv("PORT", "9100"))
INTERVAL = float(os.getenv("INTERVAL_SECONDS", "5"))

ues = Gauge("gnb_registered_ues", "UEs registered on the cell", ["cell"])
dl = Gauge("gnb_dl_throughput_mbps", "Downlink throughput in Mbit/s", ["cell"])
ul = Gauge("gnb_ul_throughput_mbps", "Uplink throughput in Mbit/s", ["cell"])
attempts = Counter("gnb_attach_attempts", "Attach attempts", ["cell"])
successes = Counter("gnb_attach_success", "Successful attaches", ["cell"])


def tick():
    ues.labels(CELL_ID).set(random.randint(1, 8))
    dl.labels(CELL_ID).set(round(random.uniform(20, 45), 1))
    ul.labels(CELL_ID).set(round(random.uniform(5, 12), 1))
    n = random.randint(0, 3)
    attempts.labels(CELL_ID).inc(n)
    successes.labels(CELL_ID).inc(sum(random.random() < 0.98 for _ in range(n)))


if __name__ == "__main__":
    start_http_server(PORT)
    print(f"KPI exporter for {CELL_ID} on :{PORT}/metrics", flush=True)
    while True:
        tick()
        time.sleep(INTERVAL)
