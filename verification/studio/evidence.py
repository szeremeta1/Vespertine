#!/usr/bin/env python3
"""Studio evidence: per-file captures and a report that separates what was measured from what was not.

studio-suite.sh runs these steps into one results folder (results/<timestamp>/), each writing JSON lines under
evidence/; `report` then turns everything found there into evidence.json and REPORT.md.

  evidence.py files   --library DIR --out OUT [--probe BIN] [--jobs N]
        every file: size, SHA-256 (against the pack's SHA256SUMS.txt and MANIFEST.csv), and for audio files the raw
        ffprobe JSON, afinfo text and `vespertine-probe channels` line           -> evidence/files.jsonl, sha256.txt
  evidence.py chid    --library DIR --out OUT [--python PY] [--jobs N]
        verify_chid.py on every channel-ID / pink-walk / polarity file the segments resolve, with FFmpeg (FF) and,
        where Core Audio opens the file, with afconvert (CA); compared with the pack's own recorded result
                                                                                 -> evidence/chid-source.jsonl
  evidence.py render-list  --out OUT                          channel-ID files for the offline engine render
  evidence.py render-check --library DIR --out OUT [--python PY]
        verify_chid.py --coreaudio on each CAF StudioRoutingTests rendered      -> evidence/render-check.jsonl
  evidence.py config-list  --out OUT                          files for StudioDeviceConfigTests
  evidence.py config-check --out OUT
        planned output format vs Core Audio after the engine's configuration step, per file (no audio)
                                                                                 -> evidence/device-config-checked.jsonl
  evidence.py signal-check --out OUT
        computed signal path vs engine vs Core Audio readback, per file, from `vespertine-probe signal-path`
                                                                                 -> evidence/signal-path-checked.jsonl
  evidence.py captures --library DIR --out OUT --runs DIR [DIR...] [--python PY]
        re-runs verify_chid.py on device captures made by chid-capture.sh        -> evidence/captures.jsonl
  evidence.py report  --out OUT                                                  -> evidence.json, REPORT.md

Rules the report follows: a claim is MEASURED only when a file in the results folder backs it (named in the claim);
anything skipped, not attempted or not possible on this machine is UNVERIFIED with the reason. A measured failure is
still MEASURED (result FAIL). Names of files in the pack's real-music and real-disc folders are not printed in
REPORT.md (evidence.json keeps them; the folder stays local).
"""
import argparse
import concurrent.futures as cf
import csv
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

AUDIO_EXT = {'.flac', '.wav', '.caf', '.aif', '.aiff', '.aifc', '.m4a', '.mp4', '.mka', '.mkv', '.ac3', '.ec3', '.eac3',
             '.thd', '.mlp', '.dts', '.dtshd', '.dsf', '.dff', '.wv', '.opus', '.ogg', '.mp3', '.tta', '.ape', '.iso',
             '.aac', '.mpc', '.wma', '.rf64', '.w64'}
TOOLS = '10 Tools (for Claude)'
PRIVATE = ('08 Real music', '09 Real discs')
EV = 'evidence'


# ------------------------------------------------------------------ parsers (pure)

def parse_ffprobe(text):
    """The first audio stream and the container, from `ffprobe -show_streams -show_format -of json`. None: not JSON."""
    try:
        d = json.loads(text)
    except (ValueError, TypeError):
        return None
    audio = [s for s in d.get('streams', []) if s.get('codec_type') == 'audio']
    fmt = d.get('format', {})
    out = {'audio_streams': len(audio)}
    if not audio:
        return out
    s = audio[0]
    bits = s.get('bits_per_raw_sample') or s.get('bits_per_sample')
    out.update({'codec': s.get('codec_name'), 'channels': int(s.get('channels', 0)), 'layout': s.get('channel_layout', ''),
                'rate': int(s.get('sample_rate', 0)), 'bits': int(bits) if bits and str(bits) != '0' else None,
                'container': fmt.get('format_name'), 'duration': float(fmt['duration']) if fmt.get('duration') else None})
    return out


def parse_afinfo(text):
    """afinfo's view of a file (Core Audio's file reader). None: Core Audio could not open it."""
    m = re.search(r'Data format:\s+(\d+) ch,\s+([\d.]+) Hz,\s*(.*)', text or '')
    if not m:
        return None
    t = re.search(r'File type ID:\s+(\S+)', text)
    lay = re.search(r'Channel layout:\s*(.*)', text)
    dur = re.search(r'estimated duration:\s*([\d.]+)', text)
    return {'type': t.group(1) if t else None, 'channels': int(m.group(1)), 'rate': float(m.group(2)),
            'format': m.group(3).strip(), 'layout': lay.group(1).strip() if lay else None,
            'duration': float(dur.group(1)) if dur else None}


def parse_probe_channels(line, name=None):
    """One line of `vespertine-probe channels FILE`: '<name>: 6 ch · <decoder> · layout <layout>' or '<name>: <error>'."""
    line = (line or '').strip()
    if name and line.startswith(name + ': '):
        rest = line[len(name) + 2:]
    else:
        rest = line.split(': ', 1)[1] if ': ' in line else line
    m = re.match(r'^(\d+) ch · (.*) · layout (.*)$', rest)
    if m:
        return {'opened': True, 'channels': int(m.group(1)), 'decoder': m.group(2), 'layout': m.group(3)}
    return {'opened': False, 'error': rest}


def parse_manifest_routing(text):
    """'FF PASS [stereo]; CA FAIL [...]' -> {'FF': 'PASS', 'CA': 'FAIL'}."""
    return {m.group(1): m.group(2) for m in re.finditer(r'\b(FF|CA) (PASS|FAIL)\b', text or '')}


def classify_open(rel, vsh, returncode):
    """The suite's format-check classes for one file."""
    if returncode is not None and (returncode < 0 or returncode >= 128):
        return 'CRASH'
    if vsh and vsh.get('opened'):
        return 'OPENS'
    if '07 Should fail gracefully/' in rel or 'should be refused' in rel:
        return 'REFUSED-EXPECTED'
    if rel.lower().endswith('.mka'):
        return 'KNOWN-GAP'
    return 'CANNOT-OPEN'


# ------------------------------------------------------------------ channel-ID segments

LAYOUT_FOLDERS = {'01': '2.0', '02': '2.1', '03': '3.0', '04': 'quad', '05': 'lcrs', '06': '5.0', '07': '5.0side',
                  '08': '5.1', '09': '5.1side', '10': '6.1', '11': '7.1', '12': '7.1wide', '13': '7.1wideside', '14': '8.1',
                  '15': '5.1.2', '16': '5.1.4', '17': '7.1.2', '18': '7.1.4', '19': '9.1.6', '20': '22.2'}
SIGNALS = (('channel id', '1_channel_ID', 'channel_ID'), ('pink noise walk', '2_pink_noise_walk', 'pink_noise_walk'))
# Not routing signals: polarity-and-phase files sound on channel pairs at once, which verify_chid.py's rule (one loud
# channel per segment) can't judge; the pack records no routing result for them either.
NOT_ROUTING = ('polarity and phase',)
# Folders whose files hold channel-ID content without saying so in the name (MANIFEST.csv notes; the pack's own routing record)
CHID_CONTENT = ('04 Dolby and DTS', '06 Edge cases/1 Channel masks', '06 Edge cases/7 Tags and artwork')


def _layout_key(rel):
    parts = rel.split('/')
    name = parts[-1].lower()
    if parts[0] == '01 Layouts' and len(parts) > 2:
        return LAYOUT_FOLDERS.get(parts[1][:2])
    if 'wide-side' in name:
        return '7.1wideside'
    m = re.search(r'(?<![\d.])(\d\.\d(?:\.\d)?)(?![\d.])', parts[-1]) or (re.search(r'(?<![\d.])(\d\.\d)(?![\d.])', parts[-2]) if len(parts) > 1 else None)
    if not m:
        return None
    key = m.group(1)
    if key in ('4.0',):
        return 'lcrs' if 'lcrs' in name else 'quad'
    return key


def resolve_segments(rel, rate, names, layouts=None):
    """The segments file (a name from `names`) that describes `rel` (path relative to the pack), or None.
    `layouts` maps a segments file name to its 'layout' field (needed only for the AC-3 channel modes)."""
    name = rel.split('/')[-1].lower()
    if any(k in name for k in NOT_ROUTING):
        return None
    signal = next((s for s in SIGNALS if s[0] in name), None)
    names = set(names)
    m = re.search(r'mode (\d-\d)( \+ lfe)?', name)
    if m and 'ac-3' in name:
        want_lfe = bool(m.group(2))
        for n, lay in sorted((layouts or {}).items()):
            if n in names and lay.startswith('ac3 ' + m.group(1)) and (('+ LFE' in lay) == want_lfe):
                return n
        return None
    if signal is None and rel.startswith(CHID_CONTENT):
        signal = SIGNALS[0]
    if signal is None:
        return None
    key = _layout_key(rel)
    if key is None:
        return None
    ext = os.path.splitext(name)[1]
    if ext in ('.dsf', '.dff') or 'dsd64' in name or 'dsd128' in name:
        if signal[2] is None:
            return None
        n = f'{key}-{signal[2]}-48000-dsd.json'
        return n if n in names else None
    for r in (int(rate or 48000), 48000):
        n = f'{key}-{signal[1]}-{r}.json'
        if n in names:
            return n
    return None


def segment_index(seg_dir):
    names = sorted(n for n in os.listdir(seg_dir) if n.endswith('.json'))
    layouts = {}
    for n in names:
        try:
            layouts[n] = json.load(open(os.path.join(seg_dir, n))).get('layout', '')
        except (OSError, ValueError):
            pass
    return names, layouts


# ------------------------------------------------------------------ signal path vs Core Audio readback (pure)

def compare_signal_path(row):
    """Checks one `vespertine-probe signal-path` row: the plan FormatPlanner computes from the file and the device
    alone, the plan and applied format the engine reports while playing, and what Core Audio reports for the device
    (read by the probe itself, not taken from the engine)."""
    out = {'file': row.get('file'), 'checks': {}}
    if 'engine' not in row:
        out['verdict'] = 'NOT-OPENED'
        out['error'] = row.get('error')
        return out
    eng = row['engine']
    plan, applied, hw, comp = eng.get('plan'), eng.get('applied'), row.get('readback') or {}, row.get('computed') or {}
    if not plan or not applied:
        out['error'] = eng.get('error')
        out['verdict'] = 'IO-NOT-STARTED' if 'did not start' in (eng.get('error') or '') else 'NO-PATH'
        return out
    c = out['checks']

    def chk(key, ok, expected, got):
        c[key] = {'ok': bool(ok), 'expected': expected, 'got': got}

    keys = ('mode', 'rate', 'bits', 'channels', 'device_channels')
    chk('planner', all(comp.get(k) == plan.get(k) for k in keys), {k: comp.get(k) for k in keys}, {k: plan.get(k) for k in keys})
    rate = hw.get('rate')
    chk('rate', rate is not None and abs(rate - plan['rate']) < 0.5 and abs(rate - applied['rate']) < 0.5,
        plan['rate'], rate)
    chk('bits', hw.get('bits') == applied.get('bits') and bool(hw.get('integer')) == bool(applied.get('integer')),
        [applied.get('bits'), 'int' if applied.get('integer') else 'float'], [hw.get('bits'), 'int' if hw.get('integer') else 'float'])
    chans = hw.get('channels')
    chk('channels', chans is not None and chans == applied.get('virtual_channels') and chans >= plan['device_channels'],
        f">= {plan['device_channels']} (applied {applied.get('virtual_channels')})", chans)
    hog_is_us = hw.get('hog_pid') == row.get('pid')
    chk('exclusive', bool(applied.get('exclusive')) == hog_is_us, 'hog = probe' if applied.get('exclusive') else 'no hog',
        'hog = probe' if hog_is_us else f"hog pid {hw.get('hog_pid')}")
    out['verdict'] = 'MATCH' if all(v['ok'] for v in c.values()) else 'MISMATCH'
    return out


def compare_configuration(row):
    """Checks one StudioDeviceConfigTests row: the plan FormatPlanner makes for the file on this device, against what
    Core Audio reports after the engine's own configuration step (exclusive access, DeviceControl.apply). No I/O runs."""
    out = {'file': row.get('file'), 'checks': {}}
    comp, hw = row.get('computed'), row.get('readback')
    if not comp or not hw:
        out['verdict'] = 'NOT-CHECKED'
        out['error'] = row.get('error')
        return out
    c = out['checks']

    def chk(key, ok, expected, got):
        c[key] = {'ok': bool(ok), 'expected': expected, 'got': got}
    chk('apply', not row.get('apply_error'), 'configured', row.get('apply_error') or 'configured')
    rate = hw.get('rate')
    chk('rate', rate is not None and abs(rate - comp['rate']) < 0.5, comp['rate'], rate)
    chk('bits', hw.get('bits') == comp.get('bits'), comp.get('bits'), [hw.get('bits'), 'int' if hw.get('integer') else 'float'])
    chk('channels', (hw.get('channels') or 0) >= comp['device_channels'], f">= {comp['device_channels']}", hw.get('channels'))
    if row.get('exclusive_requested', True):
        chk('exclusive', row.get('hogged') and hw.get('hog_pid') == row.get('pid'), 'hog = this process',
            'hog = this process' if hw.get('hog_pid') == row.get('pid') else f"hog pid {hw.get('hog_pid')}")
    out['verdict'] = 'MATCH' if all(v['ok'] for v in c.values()) else 'MISMATCH'
    return out


# ------------------------------------------------------------------ voice placement in a render (pure)

# Where a channel-ID voice (FFmpeg's speaker name, as in the segments) may land, in Vespertine's short channel names.
# Core Audio has two 7.1 conventions (back = Lrs/Rrs and side = Ls/Rs, or back = Ls/Rs and side = Lsd/Rsd), so the
# back and side pairs each accept both; two voices on the same output are caught separately (SHARED).
EXPECT = {'FL': {'L'}, 'FR': {'R'}, 'FC': {'C', 'M'}, 'LFE': {'LFE'}, 'LFE2': {'LFE'}, 'BL': {'Ls', 'Lrs'}, 'BR': {'Rs', 'Rrs'},
          'SL': {'Ls', 'Lsd'}, 'SR': {'Rs', 'Rsd'}, 'BC': {'Cs'}, 'FLC': {'Lc'}, 'FRC': {'Rc'}, 'WL': {'Lw'}, 'WR': {'Rw'},
          'FLW': {'Lw'}, 'FRW': {'Rw'}, 'SDL': {'Lsd'}, 'SDR': {'Rsd'}, 'TC': {'Top', 'Ctm'}, 'TFL': {'Ltf'}, 'TFR': {'Rtf'},
          'TFC': {'Ctf'}, 'TBL': {'Ltr'}, 'TBR': {'Rtr'}, 'TBC': {'Ctr'}, 'TSL': {'Lts'}, 'TSR': {'Rts'}}
NEG_INF = float('-inf')


def _unlabelled(label):
    return label in (None, '', '·', '?') or str(label).isdigit()


def judge_placement(voices, levels, labels, src_levels=None, lossy=False):
    """voices: [(speaker, position in the file)] per segment; levels: per segment, the level (dB) of every output;
    labels: each output's channel name. A voice is right when it is loud on exactly one output (every other output at
    least 60 dB down, 15 for lossy codecs), that output carries its speaker's name (or, unlabelled, its position), no
    other voice shares it, and its level is the source's (within 0.5 dB, 1.5 for lossy and DSD)."""
    floor, tol = (15, 1.5) if lossy else (60, 0.5)
    # One surround pair only: back and side name the same speakers (verify_chid.py's rule too).
    pairs = [p for p in (('Ls', 'Rs'), ('Lsd', 'Rsd'), ('Lrs', 'Rrs')) if p[0] in labels or p[1] in labels]
    surround = {'Ls', 'Rs', 'Lsd', 'Rsd', 'Lrs', 'Rrs'}
    one_pair = len(pairs) == 1
    out = []
    for i, ((name, pos), lev) in enumerate(zip(voices, levels)):
        loud = max(range(len(lev)), key=lambda c: lev[c])
        level = lev[loud]
        v = {'voice': name, 'out': loud + 1, 'label': labels[loud] if loud < len(labels) else '?',
             'level': round(level, 1) if level != NEG_INF else None, 'issues': []}
        if level == NEG_INF or level < -60:
            v.update({'out': None, 'label': None, 'issues': ['LOST']})
            out.append(v)
            continue
        also = [c + 1 for c in range(len(lev)) if c != loud and lev[c] > level - floor]
        if also:
            v['issues'].append('SPREAD')
            v['also'] = also
        want = set(EXPECT.get(name, {name}))
        if one_pair and want & surround:
            left = name in ('BL', 'SL')
            want |= {x for x in surround if x.startswith('L') == left}
        placed = (pos is not None and loud == pos) if _unlabelled(v['label']) else v['label'] in want
        if not placed:
            v['issues'].append('MOVED')
        src = src_levels[i] if src_levels and i < len(src_levels) else None
        if src is not None and src != NEG_INF:
            d = level - src
            v['gain_db'] = round(d, 1)
            if abs(d) > tol:
                v['issues'].append(f'GAIN {d:.1f} dB')
        out.append(v)
    seen = {}
    for v in out:
        if v['out'] is not None:
            seen.setdefault(v['out'], []).append(v)
    for group in seen.values():
        if len(group) > 1:
            for v in group:
                v['issues'].append('SHARED')
    return {'ok': all(not v['issues'] for v in out), 'voices': out}


def placement_summary(r):
    """The problems in one line: 'SL on out 7 (Lrs) -3.0 dB; LFE lost'."""
    parts = []
    for v in r['voices']:
        iss = v['issues']
        if not iss:
            continue
        if 'LOST' in iss:
            parts.append(f"{v['voice']} lost")
            continue
        bits = [f"{v['voice']} on out {v['out']} ({v['label']})"]
        if 'SPREAD' in iss:
            bits.append(f"also on out {', '.join(map(str, v.get('also', [])))}")
        if any(x.startswith('GAIN') for x in iss):
            bits.append(f"{v['gain_db']:+.1f} dB")
        if 'SHARED' in iss:
            bits.append('shared')
        parts.append(' '.join(bits))
    return '; '.join(parts)


# ------------------------------------------------------------------ report (pure)

def _private(rel):
    return (rel or '').startswith(PRIVATE)


def show(rel, idx=None):
    """A path as REPORT.md may print it."""
    if _private(rel):
        top = rel.split('/')[0]
        return f'{top}/<name withheld{f" #{idx}" if idx is not None else ""}>{os.path.splitext(rel)[1]}'
    return rel


def _claim(cid, statement, rows, ok_fn, evidence_files, reason_if_none):
    if not rows:
        return {'id': cid, 'statement': statement, 'status': 'UNVERIFIED', 'reason': reason_if_none}
    passed = sum(1 for r in rows if ok_fn(r))
    failed = len(rows) - passed
    return {'id': cid, 'statement': statement, 'status': 'MEASURED', 'result': 'PASS' if failed == 0 else 'FAIL',
            'total': len(rows), 'pass': passed, 'fail': failed, 'evidence': evidence_files}


STANDING_UNVERIFIED = [
    ('multichannel-device-routing', 'Vespertine sends each channel of a multichannel file to the matching output channel of a real device',
     'needs a multichannel capture path (a loopback with >= the layout\'s channels, or an interface looped back) and a capture made with it'),
    ('dac-receiver-output', 'Playback through a multichannel DAC, interface or receiver behaves as the signal path says',
     'no such hardware measured in this run'),
    ('bitstream-receiver', 'Dolby/DTS bitstream (IEC 61937) reaches a receiver untouched',
     'never auto-run: needs a receiver, a human present and STUDIO_ALLOW_BITSTREAM'),
    ('dop-dac', 'DSD over DoP reaches a DoP-capable DAC bit-exact', 'needs a DAC confirmed DoP-capable'),
    ('listening', 'A listener hears each channel-ID voice from the matching speaker', 'no listening test in this run'),
    ('app-ui', 'The app\'s Signal Path panel shows these values', 'the app UI is not exercised by this suite'),
]


def build_evidence(env, files, chid, checks, signal, render, captures, config=(), extra_unverified=()):
    claims = []
    hashed = [f for f in files if f.get('sha256')]
    listed = [f for f in hashed if f.get('expected_sha256')]
    claims.append(_claim('library-integrity', 'Every test file is byte-identical to the pack as built (SHA-256 vs SHA256SUMS.txt / MANIFEST.csv)',
                         listed, lambda f: f.get('sha_ok'), [f'{EV}/files.jsonl', f'{EV}/sha256.txt'], 'no files hashed in this run'))
    audio = [f for f in files if f.get('ffprobe') is not None or f.get('vsh') is not None]

    def agrees(f):
        ff, v, man = f.get('ffprobe') or {}, f.get('vsh') or {}, f.get('manifest') or {}
        if not v.get('opened'):
            return True   # refused files are judged by format-open
        ch = {x for x in (ff.get('channels'), v.get('channels'), man.get('channels')) if x}
        return len(ch) <= 1
    claims.append(_claim('format-identification', 'For every file Vespertine opens, its channel count matches FFmpeg and the pack manifest',
                         audio, agrees, [f'{EV}/files.jsonl'], 'no audio files inspected in this run'))
    claims.append(_claim('format-open', 'Vespertine opens every valid file, refuses the broken ones cleanly and never crashes',
                         audio, lambda f: f.get('open_class') in ('OPENS', 'REFUSED-EXPECTED', 'KNOWN-GAP'),
                         [f'{EV}/files.jsonl'], 'no audio files inspected in this run'))
    for c in claims:
        if c['id'] == 'format-open' and c['status'] == 'MEASURED':
            counts = {}
            for f in audio:
                counts[f.get('open_class')] = counts.get(f.get('open_class'), 0) + 1
            c['classes'] = counts
    ran = [r for r in chid if r.get('ok') is not None]
    per_file = {}
    for r in ran:
        per_file[r['rel']] = per_file.get(r['rel'], False) or bool(r['ok'])
    claims.append(_claim('source-routing', 'Each channel-ID test file carries every voice on the channel its layout labels, '
                         'confirmed by at least one independent decoder (FFmpeg, or Core Audio where it opens the file)',
                         [{'rel': k, 'ok': v} for k, v in sorted(per_file.items())], lambda r: r['ok'],
                         [f'{EV}/chid-source.jsonl'], 'verify_chid.py was not run on the source files'))
    for c in claims:
        if c['id'] == 'source-routing' and c['status'] == 'MEASURED':
            for dec in ('FF', 'CA'):
                rows = [r for r in ran if r.get('decoder') == dec]
                c[dec] = {'total': len(rows), 'pass': sum(1 for r in rows if r['ok'])}
            rep = [r for r in ran if r.get('manifest')]
            c['matches_pack_record'] = {'total': len(rep), 'same': sum(1 for r in rep if r['manifest'] == ('PASS' if r['ok'] else 'FAIL'))}
    rran = [r for r in render if r.get('ok') is not None]
    render_files = [f'{EV}/render-check.jsonl', 'render/render.jsonl', 'render-test.log']
    claims.append(_claim('decoder-labels', "Vespertine's own decoder delivers each voice of each channel-ID file alone on one channel that carries "
                         "its speaker's name (or, unlabelled, its position), at the source's level (its decoded output, checked offline)", [r for r in rran if r.get('variant') == 'decoder'], lambda r: r.get('ok'),
                         render_files, 'StudioRoutingTests render not run in this run'))
    claims.append(_claim('engine-routing-render', "Vespertine's multichannel converter, set up as the engine sets it up for a discrete N-channel output "
                         "with no speaker layout configured, puts each voice alone on one output that carries its speaker's name, at the "
                         "source's level (offline; ends where the device I/O begins)", [r for r in rran if r.get('variant') != 'decoder'],
                         lambda r: r.get('ok'), render_files, 'StudioRoutingTests render not run in this run'))
    dev = env.get('signal_device')
    on = f' ({dev})' if dev else ''
    cfg = [r for r in config if r.get('verdict') in ('MATCH', 'MISMATCH')]
    claims.append(_claim('device-configuration-readback', 'For each file, the output format Vespertine plans (rate, bit depth, channels, exclusive access) '
                         f'is what Core Audio reports once the engine has configured the device{on}; no audio played',
                         cfg, lambda r: r.get('verdict') == 'MATCH', [f'{EV}/device-config.jsonl', f'{EV}/device-config-checked.jsonl', 'config-test.log'],
                         'StudioDeviceConfigTests not run (needs a virtual output device such as Vespertine Loopback)'))
    sp = [r for r in signal if r.get('verdict') in ('MATCH', 'MISMATCH', 'NO-PATH')]
    blocked = [r for r in signal if r.get('verdict') == 'IO-NOT-STARTED']
    reason = ('vespertine-probe signal-path not run (needs a virtual output device such as Vespertine Loopback)' if not blocked else
              f"the engine's audio I/O could not start in this process ({blocked[0].get('error')}); "
              'consistent with a process that has no Microphone permission on a device that also has inputs. '
              f"Evidence: {EV}/signal-path.jsonl, signal-path.log")
    claims.append(_claim('signal-path-readback', 'While playing, the signal path the engine reports (format, rate, bit depth, channels, exclusive) '
                         f'is what Core Audio reports for the device{on}', sp, lambda r: r.get('verdict') == 'MATCH',
                         [f'{EV}/signal-path.jsonl', f'{EV}/signal-path-checked.jsonl'], reason))
    cap = [r for r in captures if r.get('ok') is not None]
    claims.append(_claim('device-routing-capture', 'A real capture of what Vespertine sent to a Core Audio device has every voice on the right channel',
                         cap, lambda r: r.get('ok'), [f'{EV}/captures.jsonl'] + sorted({r['capture'] for r in cap if r.get('capture')}),
                         'no device capture in this run (chid-capture.sh)'))
    for r in checks:
        name, status, note = r.get('name'), r.get('status'), r.get('note', '')
        cid = 'swift-test' if name == 'swift test' else name
        if status in ('PASS', 'FAIL'):
            claims.append({'id': cid, 'statement': f'{name}: {note}', 'status': 'MEASURED', 'result': status,
                           'evidence': [r.get('log')] if r.get('log') else ['checks.tsv']})
        elif status == 'SKIP':
            claims.append({'id': cid, 'statement': name, 'status': 'UNVERIFIED', 'reason': note or 'skipped'})
    have = {c['id'] for c in claims}
    measured_capture = any(c['id'] == 'device-routing-capture' and c['status'] == 'MEASURED' and
                           any(r.get('channels', 2) > 2 for r in cap) for c in claims)
    for cid, statement, reason in list(STANDING_UNVERIFIED) + [tuple(x) for x in extra_unverified]:
        if cid in have or (cid == 'multichannel-device-routing' and measured_capture):
            continue
        claims.append({'id': cid, 'statement': statement, 'status': 'UNVERIFIED', 'reason': reason})
    return {'schema': 1, 'generated': datetime.datetime.now().isoformat(timespec='seconds'), 'environment': env, 'claims': claims}


def _fails(ev_rows, key='ok'):
    return [r for r in ev_rows if r.get(key) is False]


def render_markdown(ev, details=None, limit=40):
    """REPORT.md: MEASURED first (each with the files behind it), then UNVERIFIED (each with the reason)."""
    env = ev['environment']
    details = details or {}
    L = ['# Vespertine studio evidence report', '',
         f"Generated {ev['generated']} by verification/studio/evidence.py. Every MEASURED line below is backed by the files it names, "
         'in this results folder; anything not measured here is listed under UNVERIFIED with the reason. '
         'A SKIP is never a pass.', '', '## Environment', '']
    for k in ('machine', 'model', 'macos', 'arch', 'swift', 'commit', 'branch', 'version', 'date', 'library', 'signal_device', 'devices'):
        if env.get(k):
            L.append(f'- {k}: {env[k]}')
    L += ['', '## MEASURED', '']
    measured = [c for c in ev['claims'] if c['status'] == 'MEASURED']
    for c in measured:
        res = c.get('result', '')
        counts = f" ({c['pass']}/{c['total']} pass)" if 'total' in c else ''
        L.append(f"- **{res}** `{c['id']}`: {c['statement']}{counts}")
        for k in ('FF', 'CA'):
            if k in c:
                L.append(f"  - {k} decoder: {c[k]['pass']}/{c[k]['total']} pass")
        if 'matches_pack_record' in c:
            m = c['matches_pack_record']
            L.append(f"  - same result as the pack's own MANIFEST.csv record: {m['same']}/{m['total']}")
        if 'classes' in c:
            L.append('  - ' + ', '.join(f'{k}: {v}' for k, v in sorted(c['classes'].items())))
        for line in details.get(c['id'], [])[:limit]:
            L.append(f'  - {line}')
        if len(details.get(c['id'], [])) > limit:
            L.append(f"  - ... {len(details[c['id']]) - limit} more in the evidence files")
        if c.get('evidence'):
            L.append('  - evidence: ' + ', '.join(f'`{e}`' for e in c['evidence'] if e))
    if not measured:
        L.append('- nothing was measured in this run')
    L += ['', '## UNVERIFIED', '', 'Not measured in this run. None of these may be stated as fact from this report.', '']
    for c in ev['claims']:
        if c['status'] == 'UNVERIFIED':
            L.append(f"- `{c['id']}`: {c['statement']}. Why: {c.get('reason', '')}")
    L += ['', '## Checking this report', '',
          '- `evidence.json` holds every claim with its counts; `evidence/*.jsonl` hold one row per file or check, with the raw '
          'ffprobe JSON, afinfo text and probe output.',
          '- `results-sha256.txt` lists the SHA-256 of every file in this folder (`shasum -a 256 -c results-sha256.txt`).',
          '- `evidence/sha256.txt` lists the SHA-256 of every test file (`cd <library> && shasum -a 256 -c .../sha256.txt`).',
          f'- Files in {" and ".join(PRIVATE)} are named in evidence.json only, never here.', '']
    return '\n'.join(L)


# ------------------------------------------------------------------ I/O steps

def run(cmd, timeout=120, **kw):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL, **kw)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return None, '', f'timeout after {timeout} s'
    except OSError as e:
        return None, '', str(e)


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def pack_root(library):
    """The folder holding SHA256SUMS.txt: the library itself, or the pack inside it."""
    if os.path.exists(os.path.join(library, 'SHA256SUMS.txt')):
        return library
    for n in sorted(os.listdir(library)):
        if os.path.exists(os.path.join(library, n, 'SHA256SUMS.txt')):
            return os.path.join(library, n)
    return None


def load_manifest(pack):
    sums, manifest = {}, {}
    if not pack:
        return sums, manifest
    p = os.path.join(pack, 'SHA256SUMS.txt')
    if os.path.exists(p):
        for line in open(p, encoding='utf-8'):
            if '  ' in line:
                h, rel = line.rstrip('\n').split('  ', 1)
                sums[rel.lstrip('./')] = h
    p = os.path.join(pack, 'MANIFEST.csv')
    if os.path.exists(p):
        for r in csv.DictReader(open(p, encoding='utf-8')):
            manifest[r['path']] = r
    return sums, manifest


def ev_dir(out):
    d = os.path.join(out, EV)
    os.makedirs(d, exist_ok=True)
    return d


def write_jsonl(path, rows):
    with open(path, 'w', encoding='utf-8') as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + '\n')


def read_jsonl(path):
    if not os.path.exists(path):
        return []
    rows = []
    for line in open(path, encoding='utf-8'):
        line = line.strip()
        if line.startswith('{'):
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    return rows


def _int(v):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return None


def inspect_file(library, pack, rel_lib, sums, manifest, probe):
    path = os.path.join(library, rel_lib)
    rel = os.path.relpath(path, pack) if pack and os.path.abspath(path).startswith(os.path.abspath(pack) + os.sep) else rel_lib
    row = {'rel': rel, 'path': path, 'size': os.path.getsize(path), 'sha256': sha256(path)}
    exp = sums.get(rel) or (manifest.get(rel) or {}).get('sha256')
    if exp:
        row['expected_sha256'] = exp
        row['sha_ok'] = exp == row['sha256']
    m = manifest.get(rel)
    if m:
        row['manifest'] = {'codec': m.get('codec'), 'channels': _int(m.get('channels')), 'rate': _int(m.get('rate')),
                           'layout': m.get('layout'), 'routing': parse_manifest_routing(m.get('routing'))}
    ext = os.path.splitext(path)[1].lower()
    if ext not in AUDIO_EXT or TOOLS in rel:
        return row
    rc, so, se = run(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', path], timeout=120)
    row['ffprobe'] = parse_ffprobe(so)
    row['ffprobe_raw'] = so if rc == 0 else (se or so)[-2000:]
    rc, so, se = run(['afinfo', path], timeout=120) if shutil.which('afinfo') else (None, '', 'afinfo not available')
    row['afinfo'] = parse_afinfo(so)
    row['afinfo_raw'] = (so + se)[-4000:]
    if probe:
        rc, so, se = run([probe, 'channels', path], timeout=120)
        line = (so.strip().splitlines() or [''])[-1]
        row['vsh'] = parse_probe_channels(line, os.path.basename(path)) if rc is not None and 0 <= rc < 128 else None
        row['vsh_raw'] = (so + se)[-2000:]
        row['vsh_rc'] = rc
        row['open_class'] = classify_open(rel, row['vsh'], rc if rc is not None else 255)
        ff_ch = (row.get('ffprobe') or {}).get('channels')
        if (row.get('vsh') or {}).get('opened') and ff_ch and row['vsh'].get('channels') != ff_ch:
            # Vespertine sees a different channel count than FFmpeg: record what it actually decodes from the file
            rc, so, se = run([probe, 'analyze', path], timeout=900)
            row['vsh_analyze_raw'] = (so + se)[-2000:]
    return row


def step_files(a):
    library = os.path.abspath(a.library)
    pack = pack_root(library)
    sums, manifest = load_manifest(pack)
    rels = []
    for root, dirs, names in os.walk(library):
        dirs.sort()
        for n in sorted(names):
            if n == '.DS_Store' or n.startswith('._'):
                continue
            rels.append(os.path.relpath(os.path.join(root, n), library))
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        rows = list(pool.map(lambda r: inspect_file(library, pack, r, sums, manifest, a.probe), rels))
    d = ev_dir(a.out)
    write_jsonl(os.path.join(d, 'files.jsonl'), rows)
    with open(os.path.join(d, 'sha256.txt'), 'w', encoding='utf-8') as f:
        for r in rows:
            f.write(f"{r['sha256']}  {r['rel']}\n")
    listed = [r for r in rows if 'sha_ok' in r]
    print(f"files: {len(rows)} hashed ({sum(1 for r in listed if r['sha_ok'])}/{len(listed)} match the pack's list); "
          f"{sum(1 for r in rows if 'ffprobe' in r)} audio files inspected -> {d}/files.jsonl")
    return 0 if all(r['sha_ok'] for r in listed) else 1


def verify_cmd(py, tool, seg, path, coreaudio=False, lossy=False):
    cmd = [py, tool, seg, path, '--verbose'] + (['--coreaudio'] if coreaudio else []) + (['--lossy'] if lossy else [])
    rc, so, se = run(cmd, timeout=600)
    first = next((l for l in so.splitlines() if l.startswith(('PASS', 'FAIL'))), '')
    m = re.match(r'^(PASS|FAIL)\s+(FF|CA)\s+.*\[(.*)\]\s*$', first)
    return {'ok': (first.startswith('PASS')) if first else None, 'rc': rc, 'layout': m.group(3) if m else None,
            'output': so[-3000:], 'stderr': se[-1000:]}


def tools_dir(library):
    pack = pack_root(library)
    return os.path.join(pack, TOOLS) if pack else None


def step_chid(a):
    library = os.path.abspath(a.library)
    pack = pack_root(library)
    tdir = tools_dir(library)
    if not tdir or not os.path.exists(os.path.join(tdir, 'verify_chid.py')):
        print('no verify_chid.py in the pack'); return 2
    names, layouts = segment_index(os.path.join(tdir, 'segments'))
    files = read_jsonl(os.path.join(a.out, EV, 'files.jsonl'))
    jobs = []
    for f in files:
        if f.get('ffprobe') is None or TOOLS in f['rel']:
            continue
        rate = (f.get('ffprobe') or {}).get('rate') or (f.get('manifest') or {}).get('rate')
        seg = resolve_segments(f['rel'], rate, names, layouts)
        if not seg:
            continue
        routing = (f.get('manifest') or {}).get('routing') or {}
        lossy = (f.get('ffprobe') or {}).get('codec') in ('aac', 'opus', 'vorbis', 'ac3', 'eac3', 'dts', 'mp3')
        jobs.append((f, seg, 'FF', routing.get('FF'), lossy))
        if f.get('afinfo'):
            jobs.append((f, seg, 'CA', routing.get('CA'), lossy))

    def one(job):
        f, seg, dec, rec, lossy = job
        r = verify_cmd(a.python, os.path.join(tdir, 'verify_chid.py'), os.path.join(tdir, 'segments', seg), f['path'], dec == 'CA')
        if lossy and r['ok'] is False:
            # the pack builder's rule for lossy codecs: 15 dB separation instead of 60 (verify_chid.py --lossy)
            r = verify_cmd(a.python, os.path.join(tdir, 'verify_chid.py'), os.path.join(tdir, 'segments', seg), f['path'], dec == 'CA', True)
            r['lossy_rule'] = True
        return {'rel': f['rel'], 'path': f['path'], 'segments': seg, 'decoder': dec, 'manifest': rec, **r}
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        rows = list(pool.map(one, jobs))
    write_jsonl(os.path.join(ev_dir(a.out), 'chid-source.jsonl'), rows)
    print(f"chid: {len(rows)} decodes of {len({r['rel'] for r in rows})} files, {sum(1 for r in rows if r['ok'])} PASS")
    return 0


def step_render_list(a):
    files = read_jsonl(os.path.join(a.out, EV, 'files.jsonl'))
    chid = read_jsonl(os.path.join(a.out, EV, 'chid-source.jsonl'))
    want = sorted({r['path'] for r in chid})
    vsh_ok = {f['path'] for f in files if (f.get('vsh') or {}).get('opened')}
    sel = [p for p in want if p in vsh_ok]
    os.makedirs(os.path.join(a.out, 'render'), exist_ok=True)
    with open(os.path.join(a.out, 'render', 'list.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(sel) + ('\n' if sel else ''))
    print(f'render list: {len(sel)} files Vespertine opens, of {len(want)} with segments')
    return 0


def read_caf_float(path):
    """(samples as float32 [frames, channels], rate) from a float32 interleaved CAF as StudioRoutingTests writes it."""
    import numpy as np
    import struct
    d = open(path, 'rb').read()
    pos, rate, nch, data = 8, None, None, None
    while pos + 12 <= len(d):
        cid, size = d[pos:pos + 4], struct.unpack('>q', d[pos + 4:pos + 12])[0]
        body = d[pos + 12: pos + 12 + size] if size >= 0 else d[pos + 12:]
        if cid == b'desc':
            rate = struct.unpack('>d', body[:8])[0]
            nch = struct.unpack('>I', body[24:28])[0]
        elif cid == b'data':
            data = body[4:]
        pos += 12 + (size if size >= 0 else len(d))
    x = np.frombuffer(data[:len(data) // (4 * nch) * 4 * nch], '<f4').reshape(-1, nch)
    return x, rate


def _lowpass_48k(x, rate):
    """DSD-to-PCM rates carry ultrasonic noise that swamps quiet channels: resample to 48 kHz with FFmpeg, as verify_chid.py does."""
    import numpy as np
    n = x.shape[1]
    p = subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-f', 'f32le', '-ar', str(int(rate)), '-ac', str(n), '-i', '-',
                        '-af', 'aresample=48000', '-f', 'f32le', '-acodec', 'pcm_f32le', '-'],
                       input=np.ascontiguousarray(x).tobytes(), capture_output=True, check=True)
    return np.frombuffer(p.stdout, '<f4').reshape(-1, n), 48000


def segment_levels(x, rate, segments):
    """Per segment: every channel's RMS level in dB over the segment (50 ms in from each end)."""
    import numpy as np
    out = []
    for _, t0, t1 in segments:
        a, b = int((t0 + 0.05) * rate), int((t1 - 0.05) * rate)
        seg = x[a:b].astype(np.float64)
        rms = np.sqrt(np.mean(np.square(seg), axis=0)) if len(seg) else np.zeros(x.shape[1])
        out.append([float(20 * np.log10(v)) if v > 0 else NEG_INF for v in rms])
    return out


def decode_ffmpeg_f32(path):
    """(samples, rate) of a source file decoded by FFmpeg; DSD and rates above 192 kHz low-passed to 48 kHz."""
    import numpy as np
    pr = json.loads(subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_entries', 'stream=channels,sample_rate',
                                    '-of', 'json', path], capture_output=True, text=True).stdout)['streams'][0]
    n, rate = int(pr['channels']), int(pr['sample_rate'])
    af = []
    if rate > 192000 or path.lower().endswith(('.dsf', '.dff')):
        af, rate = ['-af', 'aresample=48000'], 48000
    raw = subprocess.run(['ffmpeg', '-nostdin', '-v', 'error', '-i', path, '-map', '0:a:0'] + af + ['-f', 'f32le', '-acodec', 'pcm_f32le', '-'],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, '<f4').reshape(-1, n), rate


LOSSY_CODECS = ('aac', 'opus', 'vorbis', 'ac3', 'eac3', 'dts', 'mp3')


def step_render_check(a):
    library = os.path.abspath(a.library)
    tdir = tools_dir(library)
    chid = read_jsonl(os.path.join(a.out, EV, 'chid-source.jsonl'))
    files = {f['path']: f for f in read_jsonl(os.path.join(a.out, EV, 'files.jsonl'))}
    seg_of = {r['path']: r['segments'] for r in chid}
    rel_of = {r['path']: r['rel'] for r in chid}
    rendered = read_jsonl(os.path.join(a.out, 'render', 'render.jsonl'))
    src_cache = {}

    def source_levels(path, segs):
        if path not in src_cache:
            try:
                x, rate = decode_ffmpeg_f32(path)
                src_cache[path] = [max(l) if l else None for l in segment_levels(x, rate, segs)]
            except Exception as e:    # noqa: BLE001 - recorded, not fatal
                src_cache[path] = None
        return src_cache[path]

    def one(r):
        out = {'rel': rel_of.get(r.get('file'), r.get('file')), 'file': r.get('file'), 'render': r.get('out'), 'variant': r.get('variant'),
               'plan': r.get('plan'), 'route_layout': r.get('route_layout'), 'decoder_layout': r.get('decoder_layout'),
               'decoder': r.get('decoder')}
        if r.get('error') or not r.get('out'):
            out.update({'ok': False, 'error': r.get('error') or 'no render'})
            return out
        seg_name = seg_of.get(r['file'])
        if not seg_name:
            out.update({'ok': None, 'error': 'no segments'})
            return out
        seg = json.load(open(os.path.join(tdir, 'segments', seg_name)))
        segs = seg['segments']
        voices = [(lab.split()[0], seg['channels'].index(lab.split()[0]) if lab.split()[0] in seg['channels'] else None) for lab, _, _ in segs]
        try:
            x, rate = read_caf_float(r['out'])
            if rate > 192000:
                x, rate = _lowpass_48k(x, rate)
                out['resampled_for_check'] = 48000
            levels = segment_levels(x, rate, segs)
        except Exception as e:    # noqa: BLE001
            out.update({'ok': False, 'error': f'could not measure the render: {e}'})
            return out
        codec = ((files.get(r['file']) or {}).get('ffprobe') or {}).get('codec') or ''
        dsd = codec.startswith('dsd') or r['file'].lower().endswith(('.dsf', '.dff'))
        lossy = codec in LOSSY_CODECS or dsd
        res = judge_placement(voices, levels, r.get('route_layout') or [], source_levels(r['file'], segs), lossy=lossy)
        out.update({'segments': seg_name, 'sha256': sha256(r['out']), 'ok': res['ok'], 'placement': res['voices'],
                    'summary': placement_summary(res), 'tolerance': 'lossy/DSD (15 dB, 1.5 dB)' if lossy else 'lossless (60 dB, 0.5 dB)'})
        return out
    with cf.ThreadPoolExecutor(max_workers=a.jobs) as pool:
        rows = list(pool.map(one, rendered))
    write_jsonl(os.path.join(ev_dir(a.out), 'render-check.jsonl'), rows)
    for v in ('decoder', 'discrete'):
        rr = [r for r in rows if r.get('variant') == v]
        print(f"render check ({v}): {sum(1 for r in rr if r.get('ok'))}/{len(rr)} exact")
    return 0


def step_signal_check(a):
    rows = read_jsonl(os.path.join(a.out, EV, 'signal-path.jsonl'))
    out = []
    for r in rows:
        c = compare_signal_path(r)
        c['source'] = r.get('source')
        c['status_line'] = (r.get('engine') or {}).get('status')
        out.append(c)
    write_jsonl(os.path.join(ev_dir(a.out), 'signal-path-checked.jsonl'), out)
    counts = {}
    for c in out:
        counts[c['verdict']] = counts.get(c['verdict'], 0) + 1
    print('signal path:', ', '.join(f'{k} {v}' for k, v in sorted(counts.items())))
    return 0


def step_config_check(a):
    rows = read_jsonl(os.path.join(a.out, EV, 'device-config.jsonl'))
    out = []
    for r in rows:
        c = compare_configuration(r)
        c['source'] = r.get('source')
        c['computed'] = r.get('computed')
        c['readback'] = r.get('readback')
        out.append(c)
    write_jsonl(os.path.join(ev_dir(a.out), 'device-config-checked.jsonl'), out)
    counts = {}
    for c in out:
        counts[c['verdict']] = counts.get(c['verdict'], 0) + 1
    print('device configuration:', ', '.join(f'{k} {v}' for k, v in sorted(counts.items())))
    return 0


def step_config_list(a):
    files = read_jsonl(os.path.join(a.out, EV, 'files.jsonl'))
    sel = [f['path'] for f in files if (f.get('vsh') or {}).get('opened')]
    with open(os.path.join(a.out, EV, 'config-list.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(sel) + ('\n' if sel else ''))
    print(f'configuration list: {len(sel)} files Vespertine opens')
    return 0


def step_captures(a):
    library = os.path.abspath(a.library)
    tdir = tools_dir(library)
    rows = []
    for run_dir in a.runs:
        cap = os.path.join(run_dir, 'capture.wav')
        log = os.path.join(run_dir, 'run.log')
        if not os.path.exists(cap):
            continue
        text = open(log, encoding='utf-8', errors='replace').read() if os.path.exists(log) else ''
        m = re.search(r'"?(\S+-1_channel_ID-\d+\.json)', text)
        seg = None
        lm = re.search(r'layout (.+?) needs (\d+) channels', text)
        if lm:
            key = LAYOUT_FOLDERS.get(lm.group(1)[:2])
            seg = f'{key}-1_channel_ID-48000.json' if key else None
        seg = seg or (m.group(1).split('/')[-1] if m else None)
        # keep the capture with the report: copy the run folder (WAVs, logs) into captures/<run name>/
        dest = os.path.join(a.out, 'captures', os.path.basename(os.path.normpath(run_dir)))
        if not os.path.abspath(run_dir).startswith(os.path.abspath(a.out)):
            shutil.copytree(run_dir, dest, dirs_exist_ok=True)
            cap = os.path.join(dest, 'capture.wav')
        r = {'run': run_dir, 'capture': os.path.relpath(cap, a.out) if os.path.abspath(cap).startswith(os.path.abspath(a.out)) else cap,
             'sha256': sha256(cap), 'segments': seg, 'channels': int(lm.group(2)) if lm else None,
             'original_result': next((l for l in text.splitlines() if l.startswith('RESULT')), None)}
        if seg:
            r.update(verify_cmd(a.python, os.path.join(tdir, 'verify_chid.py'), os.path.join(tdir, 'segments', seg), cap))
            # Negative control: the same capture with its first two channels swapped must FAIL, or the check proves nothing.
            with tempfile.TemporaryDirectory() as t:
                swapped = os.path.join(t, 'swapped.wav')
                n = r.get('channels') or 2
                pan = '|'.join([f'c0=c1', f'c1=c0'] + [f'c{i}=c{i}' for i in range(2, n)])
                rc, so, se = run(['ffmpeg', '-nostdin', '-v', 'error', '-y', '-i', cap, '-af', f'pan={n}c|{pan}', '-c:a', 'pcm_f32le', swapped])
                if rc == 0:
                    neg = verify_cmd(a.python, os.path.join(tdir, 'verify_chid.py'), os.path.join(tdir, 'segments', seg), swapped)
                    r['negative_control'] = {'swapped': 'channels 1 and 2', 'ok': neg['ok'], 'fails_as_it_should': neg['ok'] is False}
        rows.append(r)
    write_jsonl(os.path.join(ev_dir(a.out), 'captures.jsonl'), rows)
    print(f"captures: {len(rows)} re-verified, {sum(1 for r in rows if r.get('ok'))} PASS")
    return 0


def read_checks(out):
    p = os.path.join(out, 'checks.tsv')
    rows = []
    if os.path.exists(p):
        for line in open(p, encoding='utf-8'):
            parts = line.rstrip('\n').split('\t')
            if len(parts) >= 3 and parts[0] != 'name':
                rows.append({'name': parts[0], 'status': parts[1], 'note': parts[2], 'log': parts[3] if len(parts) > 3 and parts[3] else None})
    return rows


def details_for(files, chid, render, signal, config=()):
    d = {}
    idx = {}

    def nm(rel):
        if _private(rel):
            idx.setdefault(rel, len(idx) + 1)
            return show(rel, idx[rel])
        return rel
    d['library-integrity'] = [f"mismatch: {nm(f['rel'])}" for f in files if f.get('sha_ok') is False]
    d['format-open'] = [f"{f.get('open_class')}: {nm(f['rel'])}: {(f.get('vsh') or {}).get('error', '')}".rstrip(': ')
                        for f in files if f.get('open_class') in ('CANNOT-OPEN', 'CRASH')]
    d['format-identification'] = []
    for f in files:
        ff, v, man = f.get('ffprobe') or {}, f.get('vsh') or {}, f.get('manifest') or {}
        if v.get('opened'):
            ch = {x for x in (ff.get('channels'), v.get('channels'), man.get('channels')) if x}
            if len(ch) > 1:
                dec = re.search(r'\[decoded ([\d.]+) s\]', f.get('vsh_analyze_raw') or '')
                d['format-identification'].append(f"{nm(f['rel'])}: FFmpeg {ff.get('channels')} ch {ff.get('codec')}, Vespertine {v.get('channels')} ch "
                                                  f"via {v.get('decoder')}{f' (decodes {dec.group(1)} s)' if dec else ''}, manifest {man.get('channels')} ch")
    confirmed = {r['rel'] for r in chid if r.get('ok')}
    d['source-routing'] = [f"no decoder confirms: {nm(rel)}" for rel in sorted({r['rel'] for r in chid if r.get('ok') is not None} - confirmed)]
    d['source-routing'] += [f"{r['decoder']} FAIL{' (the pack recorded ' + r['manifest'] + ')' if r.get('manifest') else ''}: {nm(r['rel'])} [{r.get('layout')}]"
                            for r in chid if r.get('ok') is False]
    for variant, cid in (('decoder', 'decoder-labels'), ('discrete', 'engine-routing-render')):
        # the same problem in many files (every 7.1 rate, every container) is one line: count, problem, an example
        groups = {}
        for r in render:
            if r.get('ok') is False and (r.get('variant') or 'discrete') == variant:
                groups.setdefault(r.get('error') or r.get('summary') or '?', []).append(r)
        d[cid] = [f"{len(rows)} file{'s' if len(rows) > 1 else ''}: {problem} (e.g. {nm(rows[0]['rel'])})"
                  for problem, rows in sorted(groups.items(), key=lambda kv: (-len(kv[1]), kv[0]))]
    d['device-configuration-readback'] = []
    for r in config:
        if r.get('verdict') == 'MISMATCH':
            bad = ', '.join(f"{k} expected {v['expected']} got {v['got']}" for k, v in r.get('checks', {}).items() if not v['ok'])
            d['device-configuration-readback'].append(f"MISMATCH: {nm(r.get('rel'))}: {bad}")
    d['signal-path-readback'] = []
    for r in signal:
        if r.get('verdict') != 'MATCH':
            bad = ', '.join(f"{k} expected {v['expected']} got {v['got']}" for k, v in r.get('checks', {}).items() if not v['ok'])
            rel = r.get('rel') or r.get('file')
            d['signal-path-readback'].append(f"{r.get('verdict')}: {nm(rel)}: {bad or r.get('error') or ''}")
    return d


def step_report(a):
    out = os.path.abspath(a.out)
    e = os.path.join(out, EV)
    env = json.load(open(os.path.join(out, 'environment.json'))) if os.path.exists(os.path.join(out, 'environment.json')) else {}
    files = read_jsonl(os.path.join(e, 'files.jsonl'))
    chid = read_jsonl(os.path.join(e, 'chid-source.jsonl'))
    render = read_jsonl(os.path.join(e, 'render-check.jsonl'))
    signal = read_jsonl(os.path.join(e, 'signal-path-checked.jsonl'))
    # signal-path rows carry absolute paths; give them the pack-relative name for the report
    rel_of = {f['path']: f['rel'] for f in files}
    for r in signal:
        r['rel'] = rel_of.get(r.get('file'), r.get('file'))
    captures = read_jsonl(os.path.join(e, 'captures.jsonl'))
    config = read_jsonl(os.path.join(e, 'device-config-checked.jsonl'))
    for r in config:
        r['rel'] = rel_of.get(r.get('file'), r.get('file'))
    checks = read_checks(out)
    ev = build_evidence(env, files=files, chid=chid, checks=checks, signal=signal, render=render, captures=captures,
                        config=config, extra_unverified=env.get('unverified', []))
    stall = 'signal-path-stall-sample.txt'   # a `sample` of a blocked probe, when one was saved next to the report
    for c in ev['claims']:
        if c['id'] == 'signal-path-readback' and c['status'] == 'UNVERIFIED' and os.path.exists(os.path.join(out, stall)):
            c['reason'] += f', {stall}'
    with open(os.path.join(out, 'evidence.json'), 'w', encoding='utf-8') as f:
        json.dump(ev, f, indent=1, sort_keys=True)
    with open(os.path.join(out, 'REPORT.md'), 'w', encoding='utf-8') as f:
        f.write(render_markdown(ev, details_for(files, chid, render, signal, config)))
    # a hash of every file in the results folder, last, so the report can be checked later
    lines = []
    for root, dirs, names in os.walk(out):
        dirs.sort()
        for n in sorted(names):
            p = os.path.join(root, n)
            if n == 'results-sha256.txt' or os.path.islink(p):
                continue
            lines.append(f'{sha256(p)}  {os.path.relpath(p, out)}')
    with open(os.path.join(out, 'results-sha256.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    m = sum(1 for c in ev['claims'] if c['status'] == 'MEASURED')
    u = sum(1 for c in ev['claims'] if c['status'] == 'UNVERIFIED')
    failed = [c['id'] for c in ev['claims'] if c.get('result') == 'FAIL']
    print(f"report: {m} MEASURED ({len(failed)} FAIL{': ' + ', '.join(failed) if failed else ''}), {u} UNVERIFIED -> {out}/REPORT.md")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    for name in ('files', 'chid', 'render-list', 'render-check', 'signal-check', 'config-list', 'config-check', 'captures', 'report'):
        p = sub.add_parser(name)
        p.add_argument('--out', required=True)
        p.add_argument('--library')
        p.add_argument('--probe')
        p.add_argument('--python', default=sys.executable)
        p.add_argument('--jobs', type=int, default=4)
        p.add_argument('--runs', nargs='*', default=[])
    a = ap.parse_args(argv)
    return {'files': step_files, 'chid': step_chid, 'render-list': step_render_list, 'render-check': step_render_check,
            'signal-check': step_signal_check, 'config-list': step_config_list, 'config-check': step_config_check,
            'captures': step_captures, 'report': step_report}[a.cmd](a)


if __name__ == '__main__':
    sys.exit(main())
