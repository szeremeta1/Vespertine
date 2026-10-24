#!/usr/bin/env python3
"""Unit tests for evidence.py: the parsers, the signal-path comparison, the segment resolver and the report's
MEASURED/UNVERIFIED split. Synthetic inputs only (no pack, no FFmpeg, no audio device), so CI runs them on Linux.

    python3 verification/studio/test_evidence.py
"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import evidence  # noqa: E402


class Parsers(unittest.TestCase):
    def test_ffprobe(self):
        text = json.dumps({"streams": [{"codec_type": "audio", "codec_name": "flac", "channels": 6, "channel_layout": "5.1(side)",
                                        "sample_rate": "48000", "bits_per_raw_sample": "24", "sample_fmt": "s32"}],
                           "format": {"format_name": "flac", "duration": "6.500000"}})
        p = evidence.parse_ffprobe(text)
        self.assertEqual(p, {"codec": "flac", "channels": 6, "layout": "5.1(side)", "rate": 48000, "bits": 24,
                             "container": "flac", "duration": 6.5, "audio_streams": 1})

    def test_ffprobe_no_audio(self):
        self.assertEqual(evidence.parse_ffprobe(json.dumps({"streams": [{"codec_type": "video"}], "format": {}}))["audio_streams"], 0)
        self.assertIsNone(evidence.parse_ffprobe("not json"))

    def test_afinfo(self):
        text = ("File:           x.caf\nFile type ID:   caff\nNum Tracks:     1\n----\n"
                "Data format:     6 ch,  48000 Hz, Int24\n"
                "Channel layout: 5.1 (L R C LFE Ls Rs)\nestimated duration: 6.500000 sec\n")
        self.assertEqual(evidence.parse_afinfo(text), {"type": "caff", "channels": 6, "rate": 48000.0, "format": "Int24",
                                                       "layout": "5.1 (L R C LFE Ls Rs)", "duration": 6.5})

    def test_afinfo_refused(self):
        self.assertIsNone(evidence.parse_afinfo("AudioFileOpen failed ('typ?')\n"))

    def test_probe_channels(self):
        self.assertEqual(evidence.parse_probe_channels("a b.flac: 6 ch · SFBAudioEngine FLAC · layout 5.1 (L R C LFE Ls Rs)"),
                         {"opened": True, "channels": 6, "decoder": "SFBAudioEngine FLAC", "layout": "5.1 (L R C LFE Ls Rs)"})
        self.assertEqual(evidence.parse_probe_channels("bad.rf64: The file is not a valid MP3 file."),
                         {"opened": False, "error": "The file is not a valid MP3 file."})


def path_row(**over):
    row = {"file": "/x/5.1.flac", "pid": 4242,
           "source": {"codec": "FLAC", "channels": 6, "rate": 48000, "bits": 24, "encoding": "pcm"},
           "computed": {"mode": "pcm", "rate": 48000, "bits": 24, "channels": 2, "device_channels": 2},
           "engine": {"state": "playing",
                      "plan": {"mode": "pcm", "rate": 48000, "bits": 24, "channels": 2, "device_channels": 2},
                      "applied": {"rate": 48000, "bits": 32, "integer": False, "virtual_channels": 2, "exclusive": True}},
           "readback": {"rate": 48000, "bits": 32, "integer": False, "channels": 2, "hog_pid": 4242}}
    for k, v in over.items():
        row[k] = v
    return row


class SignalPath(unittest.TestCase):
    def test_match(self):
        r = evidence.compare_signal_path(path_row())
        self.assertEqual(r["verdict"], "MATCH", r)
        self.assertTrue(all(c["ok"] for c in r["checks"].values()))

    def test_rate_mismatch(self):
        row = path_row(readback={"rate": 44100, "bits": 32, "integer": False, "channels": 2, "hog_pid": 4242})
        r = evidence.compare_signal_path(row)
        self.assertEqual(r["verdict"], "MISMATCH")
        self.assertFalse(r["checks"]["rate"]["ok"])

    def test_hog_mismatch(self):
        row = path_row(readback={"rate": 48000, "bits": 32, "integer": False, "channels": 2, "hog_pid": -1})
        r = evidence.compare_signal_path(row)
        self.assertFalse(r["checks"]["exclusive"]["ok"])

    def test_channels_narrower_than_stream(self):
        row = path_row(readback={"rate": 48000, "bits": 32, "integer": False, "channels": 1, "hog_pid": 4242})
        self.assertFalse(evidence.compare_signal_path(row)["checks"]["channels"]["ok"])

    def test_planner_disagrees(self):
        row = path_row(computed={"mode": "pcm", "rate": 96000, "bits": 24, "channels": 2, "device_channels": 2})
        r = evidence.compare_signal_path(row)
        self.assertFalse(r["checks"]["planner"]["ok"])
        self.assertEqual(r["verdict"], "MISMATCH")

    def test_no_path(self):
        row = path_row(engine={"state": "stopped", "error": "boom"})
        self.assertEqual(evidence.compare_signal_path(row)["verdict"], "NO-PATH")

    def test_refused_before_play(self):
        self.assertEqual(evidence.compare_signal_path({"file": "/x.iso", "error": "inspect: nope"})["verdict"], "NOT-OPENED")


class Segments(unittest.TestCase):
    names = ["2.0-1_channel_ID-48000.json", "2.0-1_channel_ID-96000.json", "5.1-1_channel_ID-48000.json",
             "5.1-1_channel_ID-96000.json", "5.1side-1_channel_ID-48000.json", "5.1side-2_pink_noise_walk-48000.json",
             "7.1-1_channel_ID-48000.json", "7.1wideside-1_channel_ID-48000.json", "3.1-channel_ID-48000-dsd.json",
             "ac3_1-0_+_LFE-1_channel_ID-48000.json", "ac3_1-0_mono-1_channel_ID-48000.json", "quad-1_channel_ID-48000.json",
             "lcrs-1_channel_ID-48000.json", "22.2-1_channel_ID-48000.json", "5.1-4_polarity_and_phase-48000.json"]
    layouts = {"ac3_1-0_+_LFE-1_channel_ID-48000.json": "ac3 1-0 + LFE", "ac3_1-0_mono-1_channel_ID-48000.json": "ac3 1-0 mono"}

    def r(self, rel, rate=48000):
        return evidence.resolve_segments(rel, rate, self.names, self.layouts)

    def test_layout_folders(self):
        self.assertEqual(self.r("01 Layouts/01 2.0 stereo/2.0 stereo - 1 channel ID.wav"), "2.0-1_channel_ID-48000.json")
        self.assertEqual(self.r("01 Layouts/09 5.1 side/5.1 side - 1 channel ID.flac"), "5.1side-1_channel_ID-48000.json")
        self.assertEqual(self.r("01 Layouts/09 5.1 side/5.1 side - 2 pink noise walk.flac"), "5.1side-2_pink_noise_walk-48000.json")
        self.assertEqual(self.r("01 Layouts/08 5.1 back/5.1 back - 4 polarity and phase.wav"), "5.1-4_polarity_and_phase-48000.json")
        self.assertEqual(self.r("01 Layouts/04 4.0 quad/4.0 quad - 1 channel ID.caf"), "quad-1_channel_ID-48000.json")
        self.assertEqual(self.r("01 Layouts/05 4.0 LCRS/4.0 LCRS - 1 channel ID.caf"), "lcrs-1_channel_ID-48000.json")
        self.assertEqual(self.r("01 Layouts/20 22.2/22.2 - 1 channel ID.caf"), "22.2-1_channel_ID-48000.json")

    def test_rates_fall_back_to_48k(self):
        self.assertEqual(self.r("02 Rates and depths (5.1 and 7.1 channel ID)/5.1/5.1 channel ID - 96 kHz 24-bit.wav", 96000),
                         "5.1-1_channel_ID-96000.json")
        self.assertEqual(self.r("02 Rates and depths (5.1 and 7.1 channel ID)/7.1/7.1 channel ID - 192 kHz 24-bit.wav", 192000),
                         "7.1-1_channel_ID-48000.json")

    def test_wide_side_container(self):
        self.assertEqual(self.r("03 Containers and codecs (5.1 and 7.1 channel ID, 48 kHz)/7.1/7.1 wide-side channel ID - ALAC.m4a"),
                         "7.1wideside-1_channel_ID-48000.json")

    def test_dsd(self):
        self.assertEqual(self.r("05 DSD multichannel/3.1 (L R C LFE) channel ID - DSD64.dff", 2822400), "3.1-channel_ID-48000-dsd.json")

    def test_ac3_modes(self):
        self.assertEqual(self.r("04 Dolby and DTS (FFmpeg encoders)/AC-3 (Dolby Digital)/Every channel mode (acmod x LFE)/08 AC-3 mode 1-0 + LFE.ac3"),
                         "ac3_1-0_+_LFE-1_channel_ID-48000.json")
        self.assertEqual(self.r("04 Dolby and DTS (FFmpeg encoders)/AC-3 (Dolby Digital)/Every channel mode (acmod x LFE)/01 AC-3 mode 1-0.ac3"),
                         "ac3_1-0_mono-1_channel_ID-48000.json")

    def test_unknown(self):
        self.assertIsNone(self.r("08 Real music (your favourites, local use only)/Album/01 Song.flac"))


class FormatClass(unittest.TestCase):
    def test_classes(self):
        self.assertEqual(evidence.classify_open("01 Layouts/a.flac", {"opened": True}, 0), "OPENS")
        self.assertEqual(evidence.classify_open("07 Should fail gracefully/t.flac", {"opened": False}, 0), "REFUSED-EXPECTED")
        self.assertEqual(evidence.classify_open("03 x/5.1 - Matroska FLAC.mka", {"opened": False}, 0), "KNOWN-GAP")
        self.assertEqual(evidence.classify_open("03 x/5.1.rf64", {"opened": False}, 0), "CANNOT-OPEN")
        self.assertEqual(evidence.classify_open("03 x/5.1.flac", None, 139), "CRASH")


class Report(unittest.TestCase):
    def test_split(self):
        with tempfile.TemporaryDirectory() as d:
            env = {"machine": "dormhub", "macos": "27.0", "commit": "abc", "date": "2026-10-23"}
            files = [{"rel": "01 Layouts/a.flac", "sha256": "aa", "expected_sha256": "aa", "sha_ok": True,
                      "ffprobe": {"channels": 2, "rate": 48000}, "vsh": {"opened": True, "channels": 2}, "open_class": "OPENS",
                      "manifest": {"channels": 2, "rate": 48000}}]
            chid = [{"rel": "01 Layouts/a.flac", "decoder": "FF", "ok": True}, {"rel": "01 Layouts/a.flac", "decoder": "CA", "ok": False}]
            checks = [{"name": "swift test", "status": "PASS", "note": "Test run with 10 tests passed"},
                      {"name": "HardwareAuditTests", "status": "SKIP", "note": "no multichannel hardware"}]
            ev = evidence.build_evidence(env, files=files, chid=chid, checks=checks, signal=[], render=[], captures=[])
            claims = {c["id"]: c for c in ev["claims"]}
            self.assertEqual(claims["library-integrity"]["status"], "MEASURED")
            self.assertEqual(claims["source-routing"]["status"], "MEASURED")
            self.assertEqual(claims["source-routing"]["fail"], 1)
            self.assertEqual(claims["signal-path-readback"]["status"], "UNVERIFIED")
            self.assertEqual(claims["engine-routing-render"]["status"], "UNVERIFIED")
            self.assertEqual(claims["swift-test"]["status"], "MEASURED")
            self.assertIn("HardwareAuditTests", [c["id"] for c in ev["claims"] if c["status"] == "UNVERIFIED"])
            # every claim names the file that backs it, or why there is none
            for c in ev["claims"]:
                self.assertTrue(c.get("evidence") or c.get("reason"), c)
            md = evidence.render_markdown(ev)
            self.assertIn("## MEASURED", md)
            self.assertIn("## UNVERIFIED", md)
            self.assertLess(md.index("## MEASURED"), md.index("## UNVERIFIED"))
            # a skipped check is never reported as measured
            measured = md[md.index("## MEASURED"):md.index("## UNVERIFIED")]
            self.assertNotIn("HardwareAuditTests", measured)

    def test_measured_failure_stays_measured(self):
        env = {"machine": "m", "macos": "27", "commit": "c", "date": "d"}
        checks = [{"name": "swift test", "status": "FAIL", "note": "exit 1"}]
        ev = evidence.build_evidence(env, files=[], chid=[], checks=checks, signal=[], render=[], captures=[])
        c = {c["id"]: c for c in ev["claims"]}["swift-test"]
        self.assertEqual((c["status"], c["result"]), ("MEASURED", "FAIL"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
