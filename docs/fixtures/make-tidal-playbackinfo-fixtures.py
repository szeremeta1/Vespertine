#!/usr/bin/env python3
# Vespertine: regenerates the fabricated TIDAL playbackinfo fixtures (manifests are base64 in the real responses).
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Usage: docs/fixtures/make-tidal-playbackinfo-fixtures.py [output-dir]
# Default output: Packages/VespertineKit/Tests/VespertineTidalTests/Fixtures/playbackinfo
# Everything here is invented: no real track IDs, hosts or tokens.
import base64
import json
import os
import sys

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "..", "Packages/VespertineKit/Tests/VespertineTidalTests/Fixtures/playbackinfo")
os.makedirs(out, exist_ok=True)


def info(quality, mime, manifest, bit_depth=None, sample_rate=None, mode="STEREO"):
    body = {
        "trackId": 100001,
        "assetPresentation": "FULL",
        "audioMode": mode,
        "audioQuality": quality,
        "manifestMimeType": mime,
        "manifestHash": "fabricated-hash",
        "manifest": base64.b64encode(manifest.encode("utf-8")).decode("ascii"),
        "albumReplayGain": -8.1,
        "albumPeakAmplitude": 1.0,
        "trackReplayGain": -7.9,
        "trackPeakAmplitude": 0.98,
    }
    if bit_depth:
        body["bitDepth"] = bit_depth
    if sample_rate:
        body["sampleRate"] = sample_rate
    return body


def bts(codecs, mime, encryption, url):
    manifest = {"mimeType": mime, "codecs": codecs, "encryptionType": encryption, "urls": [url]}
    if encryption != "NONE":
        manifest["keyId"] = "fabricated-key-id"
    return json.dumps(manifest)


def mpd(codecs, rate, protection=False):
    protection_xml = '<ContentProtection schemeIdUri="urn:uuid:fabricated"/>' if protection else ""
    return f"""<?xml version='1.0' encoding='UTF-8'?>
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" profiles="urn:mpeg:dash:profile:isoff-live:2011" type="static" minBufferTime="PT3.000S" mediaPresentationDuration="PT4M30.5S">
  <Period id="0">
    <AdaptationSet id="0" contentType="audio" mimeType="audio/mp4" segmentAlignment="true">
      {protection_xml}
      <Representation id="0" codecs="{codecs}" bandwidth="4800000" audioSamplingRate="{rate}">
        <AudioChannelConfiguration schemeIdUri="urn:mpeg:mpegB:cicp:ChannelConfiguration" value="2"/>
        <SegmentTemplate timescale="{rate}" initialization="https://fake-cdn.example/mediatracks/abc/0.mp4" media="https://fake-cdn.example/mediatracks/abc/$Number$.mp4" startNumber="1">
          <SegmentTimeline>
            <S d="176400" r="49"/>
            <S d="88200"/>
          </SegmentTimeline>
        </SegmentTemplate>
      </Representation>
    </AdaptationSet>
  </Period>
</MPD>
"""


fixtures = {
    "bts-flac.json": info("LOSSLESS", "application/vnd.tidal.bts",
                          bts("flac", "audio/flac", "NONE", "https://fake-cdn.example/audio/track.flac"), 16, 44100),
    "bts-encrypted.json": info("HIGH", "application/vnd.tidal.bts",
                               bts("aac", "audio/mp4", "OLD_AES", "https://fake-cdn.example/audio/track.mp4"), None, None),
    "dash-hires.json": info("HI_RES_LOSSLESS", "application/dash+xml", mpd("flac", 192000), 24, 192000),
    "dash-aac.json": info("HIGH", "application/dash+xml", mpd("mp4a.40.2", 44100)),
}
for name, body in fixtures.items():
    with open(os.path.join(out, name), "w") as handle:
        json.dump(body, handle, indent=2)
        handle.write("\n")
