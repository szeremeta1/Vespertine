#!/usr/bin/env python3
"""Stream production-decoded DSD; reject missing, extra or concealed audio.
No audio is saved. Reports contain private paths and must be sanitized for sharing.
"""
# SPDX-License-Identifier: GPL-3.0-or-later
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import subprocess


def audit_one(core, name):
    result = {'image': name, 'areas': []}
    process = None
    try:
        path = Path(name)
        before = path.stat()
        result.update(size=before.st_size, mtime_ns=before.st_mtime_ns)
        prefix = 'dff-' if path.suffix.lower() in ['.dff', '.dsdiff'] else ''
        areas = json.loads(subprocess.check_output([core, prefix + 'toc', str(path)]))
        if not areas:
            raise RuntimeError('no audio areas')
        for area in areas:
            process = subprocess.Popen([core, prefix + 'decode', str(path), area['area']], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            whole = hashlib.sha256()
            try:
                for track in area['tracks']:
                    remaining = track['frameCount'] * area.get('frameBytes', 4704) * area['channels']
                    track['dsdBytes'] = remaining
                    digest = hashlib.sha256()
                    while remaining:
                        data = process.stdout.read(min(1 << 20, remaining))
                        if not data:
                            raise RuntimeError('unexpected end of DSD stream: ' + process.stderr.read().decode())
                        whole.update(data)
                        digest.update(data)
                        remaining -= len(data)
                    track['sha256'] = digest.hexdigest()
                if process.stdout.read(1):
                    raise RuntimeError('DSD after final track')
                detail = process.stderr.read().decode()
                code = process.wait()
                area['sha256'] = whole.hexdigest()
                area['concealedFrames'] = int(detail.strip().split('=')[-1]) if detail.strip().startswith('concealed=') else None
                result['areas'].append(area)
                if code != 0 or detail.strip() != 'concealed=0':
                    raise RuntimeError(detail)
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()
                process.stdout.close()
                process.stderr.close()
        after = path.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            raise RuntimeError('source changed during audit')
        result['status'] = 'passed'
    except Exception as error:
        result['status'] = 'failed'
        result['error'] = str(error)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('core')
    parser.add_argument('manifest')
    parser.add_argument('report')
    parser.add_argument('--jobs', type=int, choices=range(1, 9), default=1)
    args = parser.parse_args()
    previous = {}
    if Path(args.report).exists():
        for line in Path(args.report).read_text().splitlines():
            record = json.loads(line)
            previous[record['image']] = record
    names = [n for n in dict.fromkeys(json.load(open(args.manifest))) if previous.get(n, {}).get('status') != 'passed']
    with open(args.report, 'a', buffering=1) as out, ThreadPoolExecutor(max_workers=args.jobs) as pool:
        jobs = [pool.submit(audit_one, args.core, n) for n in names]
        for job in as_completed(jobs):
            result = job.result()
            out.write(json.dumps(result) + '\n')
            print(Path(result['image']).name, result['status'], flush=True)


if __name__ == '__main__':
    main()
