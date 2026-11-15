"""Tests for the gNB KPI exporter, run during the image build (see Dockerfile).

testdata/sample.jsonl holds real messages captured from the lab gNB on
15 Nov 2026: two cell reports, one CU-CP report and one buffer_pool report.
"""
import json
import pathlib
import unittest

from prometheus_client import CollectorRegistry, generate_latest

from app import GnbMetrics

SAMPLE = pathlib.Path(__file__).parent / "testdata" / "sample.jsonl"


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def scrape(metrics):
    registry = CollectorRegistry()
    registry.register(metrics)
    return generate_latest(registry).decode()


def value(text, line_start):
    for line in text.splitlines():
        if line.startswith(line_start):
            return float(line.rsplit(" ", 1)[1])
    raise AssertionError(f"no line starting with {line_start!r} in:\n{text}")


class ExporterTest(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.m = GnbMetrics(clock=self.clock)
        for line in SAMPLE.read_text().splitlines():
            self.m.handle(line)

    def test_harq_counts_add_up_across_reports(self):
        out = scrape(self.m)
        # reports 1 and 2: DL ACK 10 + 12, UL ACK 26 + 29, no NACKs
        self.assertEqual(value(out, 'gnb_ue_harq_total{direction="dl",pci="1",result="ack",ue="0"}'), 22)
        self.assertEqual(value(out, 'gnb_ue_harq_total{direction="ul",pci="1",result="ack",ue="0"}'), 55)
        self.assertEqual(value(out, 'gnb_ue_harq_total{direction="dl",pci="1",result="nack",ue="0"}'), 0)

    def test_gauges_show_the_latest_report(self):
        out = scrape(self.m)
        self.assertEqual(value(out, "gnb_up "), 1)
        self.assertEqual(value(out, 'gnb_cell_ues{pci="1"}'), 1)
        self.assertEqual(value(out, 'gnb_ue_bitrate_bits_per_second{direction="dl",pci="1",ue="0"}'), 52768)
        self.assertEqual(value(out, 'gnb_ue_mcs{direction="dl",pci="1",ue="0"}'), 28)
        self.assertEqual(value(out, 'gnb_ue_cqi{pci="1",ue="0"}'), 15)

    def test_cucp_running_totals(self):
        out = scrape(self.m)
        self.assertEqual(value(out, 'gnb_rrc_connection_establishments_total{result="successful"}'), 1)
        self.assertEqual(value(out, 'gnb_pdu_session_setups_total{result="successful"}'), 1)
        self.assertEqual(value(out, 'gnb_pdu_session_setups_total{result="failed"}'), 0)
        self.assertEqual(value(out, 'gnb_ngap_amf_connected{amf="open5gs-amf"}'), 1)

    def test_stale_reports_hide_gauges_but_keep_counters(self):
        self.clock.now += 60
        out = scrape(self.m)
        self.assertEqual(value(out, "gnb_up "), 0)
        self.assertNotIn("gnb_ue_bitrate_bits_per_second{", out)
        self.assertNotIn("gnb_ngap_amf_connected{", out)
        self.assertEqual(value(out, 'gnb_ue_harq_total{direction="dl",pci="1",result="ack",ue="0"}'), 22)

    def test_unknown_and_broken_messages_are_counted_not_fatal(self):
        self.m.handle("not json")
        self.m.handle(json.dumps([1, 2]))
        out = scrape(self.m)
        self.assertEqual(value(out, 'gnb_exporter_messages_total{type="buffer_pool"}'), 1)
        self.assertEqual(value(out, 'gnb_exporter_messages_total{type="not_json"}'), 2)
        self.assertEqual(value(out, 'gnb_exporter_messages_total{type="cells"}'), 2)


if __name__ == "__main__":
    unittest.main()
