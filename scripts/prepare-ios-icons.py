#!/usr/bin/env python3
"""Install Alex's approved A2 masters. Requires Pillow; never redraws the approved artwork."""
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / 'docs/design/ios-icon-proposals'
DEST = ROOT / 'RemoteApp/Resources/Assets.xcassets/AppIcon.appiconset'
EXPORT = ROOT / 'docs/design/ios-icon-a2/sizes'

def main():
    DEST.mkdir(parents=True, exist_ok=True)
    EXPORT.mkdir(parents=True, exist_ok=True)
    images = []
    sizes = {20, 29, 40, 48, 58, 60, 64, 76, 80, 87, 96, 120, 128, 152, 167, 180, 192, 256, 512, 1024}
    for appearance, source in [('light', 'A2-horizon.png'), ('dark', 'A2-horizon.png'), ('tinted', 'A2-horizon-tinted.png')]:
        with Image.open(SOURCE / source) as original:
            assert original.size == (1024, 1024)
            rgb = original.convert('RGB')
            filename = f'AppIcon-{appearance}-1024.png'
            rgb.save(DEST / filename)
            entry = {'filename': filename, 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}
            if appearance != 'light':
                entry['appearances'] = [{'appearance': 'luminosity', 'value': appearance}]
            images.append(entry)
            # Xcode derives device slots from the universal masters. These explicit opaque exports
            # also allow review at every shipping and Spotlight/Settings pixel size.
            for px in sorted(sizes):
                rgb.resize((px, px), Image.Resampling.LANCZOS).save(EXPORT / f'{appearance}-{px}.png')
    (DEST / 'Contents.json').write_text(json.dumps({'images': images, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
    # Remove the superseded M1 catalog image only, not either proposal master.
    (DEST / 'AppIcon-1024.png').unlink(missing_ok=True)
    print(f'Installed 3 opaque universal masters; exported {len(sizes) * 3} device-size previews.')

if __name__ == '__main__':
    main()
