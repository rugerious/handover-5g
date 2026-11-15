"""gNB KPI exporter for the Handover lab (Phase 4.3).

Reads the OCUDU gNB's JSON metrics from its remote control WebSocket and
publishes them in Prometheus format on :9100/metrics.

How the gNB reports (measured 15 Nov 2026, OCUDU release_26_10):
- the WebSocket server listens on the pod's loopback (127.0.0.1:8001) and sends
  nothing until a client sends {"cmd": "metrics_subscribe"};
- then one JSON message per layer per report period (1 s), each with a timestamp;
- DU counts (HARQ ACK/NACK, PRACH, Msg3...) are per report: we add them up into
  Prometheus counters so rate() works;
- CU-CP counts (RRC setups, PDU sessions) are running totals since the gNB
  started: exported as they are (a gNB restart resets them; rate() handles that).

Gauges (rates, MCS, CQI, SNR...) are only published while the last report is
fresh, so a stopped gNB shows as missing data and gnb_up 0, not as a frozen line.
UEs are labelled by the gNB's UE index, not the RNTI (a new RNTI on every attach
would create a new time series each time).
"""
import json
import os
import threading
import time

from prometheus_client import start_http_server
from prometheus_client.core import REGISTRY, CounterMetricFamily, GaugeMetricFamily
from websockets.sync.client import connect

WS_URL = os.getenv("GNB_WS_URL", "ws://127.0.0.1:8001")
PORT = int(os.getenv("PORT", "9100"))
STALE_SECONDS = float(os.getenv("STALE_SECONDS", "5"))
RETRY_SECONDS = float(os.getenv("RETRY_SECONDS", "2"))


class GnbMetrics:
    """Latest gNB reports plus counters built from them; read by Prometheus on scrape."""

    def __init__(self, clock=time.monotonic):
        self.clock = clock
        self.lock = threading.Lock()
        self.connected = 0
        self.messages = {}        # message type -> count
        self.cells = None         # latest "cells" report
        self.cells_at = None
        self.cucp = None          # latest "cu-cp" report
        self.cucp_at = None
        self.harq = {}            # (pci, ue, direction, result) -> total
        self.cell_counts = {}     # (pci, name) -> total

    # --- input --------------------------------------------------------------
    def handle(self, text):
        try:
            msg = json.loads(text)
        except ValueError:
            self._count("not_json")
            return
        if not isinstance(msg, dict):
            self._count("not_json")
            return
        kind = next((k for k in msg if k != "timestamp"), "empty")
        with self.lock:
            self.messages[kind] = self.messages.get(kind, 0) + 1
            if kind == "cells":
                self._add_cells(msg["cells"])
            elif kind == "cu-cp":
                self.cucp = msg["cu-cp"]
                self.cucp_at = self.clock()

    def _count(self, kind):
        with self.lock:
            self.messages[kind] = self.messages.get(kind, 0) + 1

    def _add(self, table, key, value):
        table[key] = table.get(key, 0) + (value or 0)

    def _add_cells(self, cells):
        self.cells = cells
        self.cells_at = self.clock()
        for cell in cells:
            cm = cell.get("cell_metrics", {})
            pci = str(cm.get("pci", ""))
            for name, value in (
                ("prach_preambles", cm.get("total_prach_preambles")),
                ("msg3_ok", cm.get("msg3_nof_ok")),
                ("msg3_nok", cm.get("msg3_nof_nok")),
                ("failed_pdcch", sum(cm.get(k, 0) for k in (
                    "failed_dl_pdcch", "failed_ul_pdcch",
                    "failed_common_dl_pdcch", "failed_common_ul_pdcch"))),
                ("late_harqs", cm.get("late_dl_harqs", 0) + cm.get("late_ul_harqs", 0)),
                ("error_indications", cm.get("error_indication_count")),
            ):
                self._add(self.cell_counts, (pci, name), value)
            for ue in cell.get("ue_list", []):
                key = (str(ue.get("pci", pci)), str(ue.get("ue", "")))
                for d in ("dl", "ul"):
                    self._add(self.harq, key + (d, "ack"), ue.get(f"{d}_nof_ok"))
                    self._add(self.harq, key + (d, "nack"), ue.get(f"{d}_nof_nok"))

    def fresh(self, at):
        return at is not None and self.clock() - at <= STALE_SECONDS

    # --- output (called by prometheus_client on every scrape) ---------------
    def collect(self):
        with self.lock:
            yield from self._exporter_metrics()
            yield from self._du_metrics()
            yield from self._cucp_metrics()

    def _exporter_metrics(self):
        g = GaugeMetricFamily("gnb_exporter_websocket_connected",
                              "1 while the exporter is subscribed to the gNB's metrics")
        g.add_metric([], self.connected)
        yield g
        c = CounterMetricFamily("gnb_exporter_messages",
                                "gNB metrics messages received, by type", labels=["type"])
        for kind, n in sorted(self.messages.items()):
            c.add_metric([kind], n)
        yield c
        up = GaugeMetricFamily("gnb_up", "1 when a cell report arrived in the last few seconds")
        up.add_metric([], 1 if self.fresh(self.cells_at) else 0)
        yield up

    def _du_metrics(self):
        harq = CounterMetricFamily("gnb_ue_harq", "HARQ results per UE (BLER = nack / (ack + nack))",
                                   labels=["pci", "ue", "direction", "result"])
        for key, n in sorted(self.harq.items()):
            harq.add_metric(list(key), n)
        yield harq
        names = {
            "prach_preambles": "PRACH preambles detected",
            "msg3_ok": "Msg3 (random access step 3) received OK",
            "msg3_nok": "Msg3 (random access step 3) failed",
            "failed_pdcch": "PDCCH allocations the scheduler could not make (DL + UL, common + dedicated)",
            "late_harqs": "HARQ feedback that arrived too late (DL + UL)",
            "error_indications": "Error indications",
        }
        for name, help_text in names.items():
            c = CounterMetricFamily(f"gnb_cell_{name}", help_text, labels=["pci"])
            for (pci, n), v in sorted(self.cell_counts.items()):
                if n == name:
                    c.add_metric([pci], v)
            yield c

        if not self.fresh(self.cells_at):
            return
        ues = GaugeMetricFamily("gnb_cell_ues", "UEs connected to the cell", labels=["pci"])
        lat = GaugeMetricFamily("gnb_cell_scheduler_latency_microseconds",
                                "Scheduler decision latency in the last report", labels=["pci", "stat"])
        rate = GaugeMetricFamily("gnb_ue_bitrate_bits_per_second", "Scheduled bit rate per UE",
                                 labels=["pci", "ue", "direction"])
        mcs = GaugeMetricFamily("gnb_ue_mcs", "Modulation and coding scheme index per UE",
                                labels=["pci", "ue", "direction"])
        cqi = GaugeMetricFamily("gnb_ue_cqi", "Channel quality indicator reported by the UE (0-15)",
                                labels=["pci", "ue"])
        snr = GaugeMetricFamily("gnb_ue_pusch_snr_db", "Uplink (PUSCH) SNR measured by the gNB",
                                labels=["pci", "ue"])
        for cell in self.cells:
            cm = cell.get("cell_metrics", {})
            pci = str(cm.get("pci", ""))
            ue_list = cell.get("ue_list", [])
            ues.add_metric([pci], len(ue_list))
            for stat, field in (("avg", "average_latency"), ("max", "max_latency")):
                if cm.get(field) is not None:
                    lat.add_metric([pci, stat], cm[field])
            for ue in ue_list:
                labels = [str(ue.get("pci", pci)), str(ue.get("ue", ""))]
                for d in ("dl", "ul"):
                    if ue.get(f"{d}_brate") is not None:
                        rate.add_metric(labels + [d], ue[f"{d}_brate"])
                    if ue.get(f"{d}_mcs") is not None:
                        mcs.add_metric(labels + [d], ue[f"{d}_mcs"])
                if ue.get("cqi") is not None:
                    cqi.add_metric(labels, ue["cqi"])
                if ue.get("pusch_snr_db") is not None:   # null when the UE sent nothing
                    snr.add_metric(labels, ue["pusch_snr_db"])
        yield from (ues, lat, rate, mcs, cqi, snr)

    def _cucp_metrics(self):
        if self.cucp is None:
            return
        rrc = CounterMetricFamily("gnb_rrc_connection_establishments",
                                  "RRC connection setups since the gNB started (all causes)",
                                  labels=["result"])
        conns = GaugeMetricFamily("gnb_rrc_connections", "RRC connected UEs in the last report",
                                  labels=["stat"])
        amf = GaugeMetricFamily("gnb_ngap_amf_connected", "1 while the N2 link to the AMF is up",
                                labels=["amf"])
        pdu = CounterMetricFamily("gnb_pdu_session_setups",
                                  "PDU session setups since the gNB started", labels=["result"])
        totals = {"attempted": 0, "successful": 0}
        mean = peak = 0
        for du in self.cucp.get("rrcs", {}).get("du", []):
            est = du.get("rrc_connection_establishment", {})
            totals["attempted"] += sum(est.get("attempted_rrc_connection_establishments", {}).values())
            totals["successful"] += sum(est.get("successful_rrc_connection_establishments", {}).values())
            num = du.get("rrc_connection_number", {})
            mean += num.get("mean_nof_rrc_connections", 0)
            peak += num.get("max_nof_rrc_connections", 0)
        for result, n in totals.items():
            rrc.add_metric([result], n)
        sessions = {"requested": 0, "successful": 0, "failed": 0}
        for link in self.cucp.get("ngaps", {}).get("ngap", []):
            amf.add_metric([str(link.get("amf_name", ""))], 1 if link.get("connected") else 0)
            pm = link.get("pdu_session_management", {})
            sessions["requested"] += pm.get("nof_pdu_sessions_requested_to_setup", 0)
            sessions["successful"] += pm.get("nof_pdu_sessions_successfully_setup", 0)
            sessions["failed"] += sum(pm.get("nof_pdu_sessions_failed_to_setup", {}).values())
        for result, n in sessions.items():
            pdu.add_metric([result], n)
        yield rrc
        yield pdu
        if self.fresh(self.cucp_at):
            conns.add_metric(["mean"], mean)
            conns.add_metric(["max"], peak)
            yield conns
            yield amf


def run(metrics):
    """Subscribe to the gNB and feed every message to `metrics`; reconnect forever."""
    while True:
        try:
            with connect(WS_URL, open_timeout=5, max_size=None) as ws:
                ws.send(json.dumps({"cmd": "metrics_subscribe"}))
                metrics.connected = 1
                print(f"subscribed to {WS_URL}", flush=True)
                for text in ws:
                    metrics.handle(text)
        except Exception as e:  # gNB not up yet, or restarted: try again
            print(f"websocket: {type(e).__name__}: {e}; retry in {RETRY_SECONDS:.0f} s", flush=True)
        metrics.connected = 0
        time.sleep(RETRY_SECONDS)


if __name__ == "__main__":
    gnb = GnbMetrics()
    REGISTRY.register(gnb)
    start_http_server(PORT)
    print(f"gNB KPI exporter on :{PORT}/metrics, reading {WS_URL}", flush=True)
    run(gnb)
