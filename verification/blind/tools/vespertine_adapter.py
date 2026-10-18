"""Vespertine behind the blind interface (stub/vblind.py), so the tester's suite can run against it.

The framing calls go to Vespertine's own Swift code through the bridge's `serve` test (bridge/Tests/BridgeExport):
dop_pack -> DoP.pack, ac3_burst / eac3_burst / dts_burst -> IEC61937.*, eac3_group -> EAC3Grouper. The framers
check their own input; their refusals come back as DoPError / BurstError. Vespertine has no receiver side, so
dop_unpack and parse_bursts raise NotApplicable, and so does a frame its parser rejects handed to the grouper (it
can never reach it); tests that end in NotApplicable are reported as not applicable, not as failures.

If VBLIND_REF_PARSER names a reference module, parse_bursts / dop_unpack are taken from it instead (to read
Vespertine's output with an independent parser); results from that mode are labelled as such.

Env: VBLIND_BRIDGE = path of verification/blind/bridge (default: next to this file's parent).
"""
from __future__ import annotations

import atexit
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


class DoPError(ValueError):
    pass


class BurstError(ValueError):
    pass


class NotApplicable(Exception):
    """Vespertine has no code for this, or can never receive this input."""


@dataclass(frozen=True)
class Burst:
    offset: int
    data_type: int
    data_type_dependent: int
    error_flag: int
    bitstream_number: int
    length_code: int
    payload: bytes


_BRIDGE = Path(os.environ.get("VBLIND_BRIDGE", Path(__file__).resolve().parent.parent / "bridge"))
_conn = None


def _call(req: dict) -> dict:
    global _conn
    if _conn is None:
        d = tempfile.mkdtemp(prefix="vblind-serve-")
        os.mkfifo(f"{d}/req")
        os.mkfifo(f"{d}/resp")
        proc = subprocess.Popen(["swift", "test", "--skip-build", "--filter", "BridgeExport.serve"], cwd=_BRIDGE,
                                env=dict(os.environ, BLIND_SERVE=d), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        w = open(f"{d}/req", "w", buffering=1)
        r = open(f"{d}/resp", "r")
        _conn = (proc, w, r)
        atexit.register(lambda: (w.close(), proc.wait(30)))
    _, w, r = _conn
    w.write(json.dumps(req) + "\n")
    line = r.readline()
    if not line:
        raise RuntimeError("bridge closed")
    resp = json.loads(line)
    if "error" in resp:
        raise RuntimeError("bridge: " + resp["error"])
    if "refused" in resp:
        raise (DoPError if req["op"] == "dop_pack" else BurstError)(resp["refused"])
    return resp


def _words(h: str) -> list[int]:
    return [int(h[i:i + 4], 16) for i in range(0, len(h), 4)]


def dop_pack(dsd: list[bytes], first_marker: int = 0x05) -> list[list[int]]:
    if not 0 <= first_marker <= 0xFF:
        raise NotApplicable("a marker is one byte")
    return _call({"op": "dop_pack", "planes": [bytes(p).hex() for p in dsd], "first_marker": first_marker})["frames"]


def ac3_burst(frame: bytes) -> list[int]:
    return _words(_call({"op": "ac3_burst", "frame": bytes(frame).hex()})["words"])


def eac3_burst(frames: list[bytes]) -> list[int]:
    return _words(_call({"op": "eac3_burst", "frames": [bytes(f).hex() for f in frames]})["words"])


def eac3_group(frames: list[bytes]) -> list[list[int]]:
    resp = _call({"op": "eac3_group", "frames": [bytes(f).hex() for f in frames]})
    if resp.get("unparsed"):
        raise NotApplicable("a frame Vespertine's parser rejects never reaches its grouper")
    return resp["groups"]


def dts_burst(frame: bytes) -> list[int]:
    return _words(_call({"op": "dts_burst", "frame": bytes(frame).hex()})["words"])


_ref = None
if os.environ.get("VBLIND_REF_PARSER"):
    p = Path(os.environ["VBLIND_REF_PARSER"]).resolve()
    sys.path.insert(0, str(p.parent))
    spec = importlib.util.spec_from_file_location("vblind_ref_parser", p)
    _ref = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = _ref
    spec.loader.exec_module(_ref)


def dop_unpack(frames):
    if _ref is None:
        raise NotApplicable("Vespertine has no DoP unpacker (it only sends DoP)")
    try:
        return _ref.dop_unpack(frames)
    except _ref.DoPError as e:          # the reference's refusal, under this module's exception type
        raise DoPError(str(e)) from e


def parse_bursts(words):
    if _ref is None:
        raise NotApplicable("Vespertine has no IEC 61937 parser (it only sends bursts)")
    try:
        return _ref.parse_bursts(words)
    except _ref.BurstError as e:
        raise BurstError(str(e)) from e
