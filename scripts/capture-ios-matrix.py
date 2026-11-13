#!/usr/bin/env python3
"""Serial tests and real captures. Uses UDIDs, owns only simulators it boots, never shuts down all.

Usage: python3 scripts/capture-ios-matrix.py devices.json --output build/ios-m2
Config is an array of {name, udid}. Choose one 6.9-inch iPhone, iPad Pro 13-inch,
iPad 11-inch and iPad mini. Every command is bounded. Requires an unrestricted local
CoreSimulator session; this script does not change accounts or install runtimes.
"""
import argparse
import json
from pathlib import Path
import subprocess
import struct
import time

ROOT = Path(__file__).resolve().parent.parent
BUNDLE = 'org.szeremeta.VespertineRemote'
SCREENS = [
    ('01-macs', ['-VTSamplePairing', 'YES']),
    ('02-connection', ['-VTSamplePairing', 'YES', '-VTScreen', 'connection']),
    ('03-now-playing', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTVinyl', 'NO']),
    ('04-now-playing-vinyl', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTVinyl', 'YES']),
    ('05-cover-flow', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTScreen', 'coverFlow', '-VTTilt', '0,0']),
    ('07-library', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTScreen', 'library']),
    ('08-albums', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTScreen', 'albums']),
    ('09-album', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTScreen', 'album']),
    ('10-queue', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTScreen', 'queue']),
    ('11-output', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTScreen', 'output']),
    ('12-settings', ['-VTSamplePairing', 'YES', '-VTScreen', 'settings']),
    ('13-artists', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTScreen', 'artists']),
    ('14-playlists', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTScreen', 'playlists']),
    ('15-favorites', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTScreen', 'favorites']),
    ('16-search', ['-VTDemo', 'YES', '-VTPlay', 'YES', '-VTScreen', 'search']),
]


def run(args, timeout=60, check=True, capture=False, env=None):
    return subprocess.run([str(a) for a in args], cwd=ROOT, timeout=timeout, check=check,
                          text=True, capture_output=capture, env=env)


def sim(*args, **kwargs):
    return run(['xcrun', 'simctl', *args], **kwargs)


def capture_device(device, output, tests=True):
    udid = device['udid']
    listing = json.loads(sim('list', 'devices', '--json', capture=True).stdout)
    all_devices = [d for group in listing['devices'].values() for d in group]
    target = next((d for d in all_devices if d['udid'] == udid and d.get('isAvailable')), None)
    if target is None:
        raise RuntimeError(f'Unavailable simulator: {udid}')
    booted = [d['udid'] for d in all_devices if d['state'] == 'Booted']
    if booted:
        raise RuntimeError(f'Refusing to add load or touch existing booted devices: {booted}')
    owned = False
    device_out = output / device['name']
    device_out.mkdir(parents=True, exist_ok=True)
    derived = output / 'derived'
    try:
        # Set ownership as soon as boot succeeds, even if bootstatus later times out.
        sim('boot', udid)
        owned = True
        sim('bootstatus', udid, '-b', timeout=180)
        build = ['xcodebuild', '-project', 'RemoteApp/VespertineRemote.xcodeproj', '-scheme', 'VespertineRemote',
                 '-configuration', 'Debug', '-destination', f'platform=iOS Simulator,id={udid}',
                 '-derivedDataPath', derived, '-parallel-testing-enabled', 'NO',
                 '-maximum-concurrent-test-simulator-destinations', '1', 'CODE_SIGNING_ALLOWED=NO']
        # Avoid XCTest's extra cloned simulators. Run on the one explicit booted UDID.
        if tests:
            run([*build, '-resultBundlePath', device_out / 'tests.xcresult', 'test'], timeout=900)
        else:
            run([*build, 'build'], timeout=900)
        app = derived / 'Build/Products/Debug-iphonesimulator/VespertineRemote.app'
        sim('install', udid, app)
        sim('status_bar', udid, 'override', '--time', '9:41', '--batteryState', 'charged',
            '--batteryLevel', '100', '--cellularBars', '4', '--wifiBars', '3')
        sim('ui', udid, 'content_size', 'large')
        # Orient through XCTest on this same simulator, then capture every main screen.
        # The orientation-only test accepts an explicit portrait/landscape launch environment.
        for orientation in ['portrait', 'landscape']:
            run([*build, '-only-testing:VespertineRemoteUITests/AdaptiveNavigationTests/testSetCaptureOrientation', f'VT_CAPTURE_ORIENTATION={orientation}', 'test'],
                timeout=300)
            for appearance in ['light', 'dark']:
                folder = device_out / orientation / appearance
                folder.mkdir(parents=True, exist_ok=True)
                sim('ui', udid, 'appearance', appearance)
                for name, args in SCREENS:
                    sim('terminate', udid, BUNDLE, check=False, capture=True)
                    sim('launch', udid, BUNDLE, *args)
                    time.sleep(3)
                    capture = folder / (name + '.png')
                    sim('io', udid, 'screenshot', capture)
                    with capture.open('rb') as png:
                        header = png.read(24)
                    if header[:8] != b'\x89PNG\r\n\x1a\n':
                        raise RuntimeError(f'Invalid screenshot: {capture}')
                    width, height = struct.unpack('>II', header[16:24])
                    if (width > height) != (orientation == 'landscape'):
                        raise RuntimeError(f'Orientation did not take effect: {capture}, {width}x{height}')
                    accepted = {'iphone69': {(1320, 2868), (1290, 2796), (1260, 2736)},
                                'ipad13': {(2064, 2752), (2048, 2732)}}
                    portrait_size = (min(width, height), max(width, height))
                    if device['name'] in accepted and portrait_size not in accepted[device['name']]:
                        raise RuntimeError(f'Wrong Store device dimensions for {device["name"]}: {portrait_size}')
        (device_out / 'capture.json').write_text(json.dumps({
            'device': device, 'screensPerAppearance': len(SCREENS), 'orientations': ['portrait', 'landscape'],
            'appearances': ['light', 'dark'], 'visualReview': 'pending'
        }, indent=2) + '\n')
    finally:
        if owned:
            try:
                sim('terminate', udid, BUNDLE, check=False, capture=True)
                sim('status_bar', udid, 'clear', check=False)
            finally:
                sim('shutdown', udid)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/ios-m2')
    parser.add_argument('--skip-tests', action='store_true', help='Capture only; does not establish test success')
    args = parser.parse_args()
    devices = json.loads(args.config.read_text())
    if len({d['udid'] for d in devices}) != len(devices):
        parser.error('Duplicate UDIDs')
    run(['xcodegen', 'generate', '--spec', 'RemoteApp/project.yml'])
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for device in devices:
        capture_device(device, output, tests=not args.skip_tests)


if __name__ == '__main__':
    main()
