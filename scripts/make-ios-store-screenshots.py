#!/usr/bin/env python3
"""Compose the Store screenshots from raw Simulator captures (no draft labels inside the images).

Usage: python3 scripts/make-ios-store-screenshots.py --raw <dir with iphone69/ and ipad13/ per appearance> --output docs/app-store/ios-m2/screenshots
Raw layout: <raw>/<device>/<appearance>/<file>.png. Headlines and captions come from captions.json; the screen each uses is
SCREENS below. Output: <output>/<device>/<NN-name>.png (RGB, no alpha) and <output>/contact-sheet.png. Requires Pillow.
Text is left-aligned to the screenshot's own left edge; the screenshot is rounded and fitted whole, never cropped.
"""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parent.parent
KIT = ROOT / 'docs/app-store/ios-m2'
FONTS = ROOT / 'docs/design/fonts'
BASE, IVORY, BRASS, HAIR = '#09090A', '#ECE6DA', '#C8A66A', '#403A30'
SIZES = {'iphone69': (1320, 2868), 'ipad13': (2752, 2064)}  # iPad 13-inch is landscape (2752 x 2064 is an accepted size)
RAW_DIR = {'iphone69': 'iphone69', 'ipad13': 'ipad13l'}
# caption id -> raw file stem
SCREENS = {'01-now-playing': '01-now-playing', '02-library': '02-library', '03-queue': '03-queue',
           '04-output': '04-output', '05-connection': '07-macs', '06-cover-flow': '06-cover-flow'}

# On the phone the albums grid scrolls under the mini player and tab bar, so the album page is the cleaner library shot.
PHONE_OVERRIDE = {'02-library': '09-album'}


def font(name, size):
    return ImageFont.truetype(str(FONTS / name), size)


def wrapped(draw, text, face, width):
    lines, line = [], ''
    for word in text.split():
        candidate = f'{line} {word}'.strip()
        if line and draw.textlength(candidate, font=face) > width:
            lines.append(line)
            line = word
        else:
            line = candidate
    return '\n'.join([*lines, line])


def compose(device, item, source, appearance_bg=BASE):
    w, h = SIZES[device]
    scale = min(w / 1320, 1.1)
    image = Image.new('RGB', (w, h), BASE)
    draw = ImageDraw.Draw(image)
    for y in range(h):
        lift = max(0, 1 - abs(y / h - .44) * 2) * 8
        draw.line((0, y, w, y), fill=(9 + round(lift), 9 + round(lift * .75), 10 + round(lift * .4)))
    landscape = w > h
    top = round((365 if landscape else 520) * scale)
    bottom = h - round(90 * scale)
    with Image.open(source) as shot:
        screen = ImageOps.contain(shot.convert('RGB'), (w - 2 * round(90 * scale), bottom - top), Image.Resampling.LANCZOS)
    x, y = (w - screen.width) // 2, top
    radius = round(min(screen.size) * (0.035 if w > h else 0.05))
    mask = Image.new('L', screen.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, screen.width - 1, screen.height - 1), radius, fill=255)
    image.paste(screen, (x, y), mask)
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((x - 1, y - 1, x + screen.width, y + screen.height), radius + 1, outline=HAIR, width=2)
    serif = font('Newsreader[opsz,wght].ttf', round(100 * scale))
    mono = font('JetBrainsMono[wght].ttf', round(25 * scale))
    wordmark = font('Newsreader[opsz,wght].ttf', round(44 * scale))
    draw.text((x, round((55 if landscape else 70) * scale)), 'vespertine', font=wordmark, fill=IVORY)
    draw.multiline_text((x, round((120 if landscape else 165) * scale)), wrapped(draw, item['headline'], serif, screen.width), font=serif,
                        fill=IVORY, spacing=round(4 * scale))
    draw.text((x, round((265 if landscape else 400) * scale)), item['caption'], font=mono, fill=BRASS)
    return image


def contact_sheet(groups, output):
    """One PNG with every screenshot: each device on its own row, thumbnails 520 px tall (portrait) or 330 px (landscape)."""
    pad, label = 16, font('Inter[opsz,wght].ttf', 16)
    rows = []
    for name, files in groups:
        thumbs = []
        for path in files:
            with Image.open(path) as shot:
                portrait = shot.height > shot.width
                thumbs.append(ImageOps.contain(shot.convert('RGB'), (520, 520) if portrait else (440, 330), Image.Resampling.LANCZOS))
        rows.append((name, thumbs))
    width = max(sum(t.width + pad for t in thumbs) for _, thumbs in rows) + pad
    height = sum(max(t.height for t in thumbs) + 38 + pad for _, thumbs in rows) + pad
    sheet = Image.new('RGB', (width, height), '#16161A')
    draw = ImageDraw.Draw(sheet)
    y = pad
    for name, thumbs in rows:
        draw.text((pad, y + 6), name, font=label, fill=IVORY)
        y += 38
        x = pad
        for thumb in thumbs:
            sheet.paste(thumb, (x, y))
            x += thumb.width + pad
        y += max(t.height for t in thumbs) + pad
    sheet.save(output)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--raw', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--appearance', default='dark')
    args = p.parse_args()
    captions = {c['id']: c for c in json.loads((KIT / 'captions.json').read_text())}
    groups, manifest = [], []
    for device, size in SIZES.items():
        out = args.output / device
        out.mkdir(parents=True, exist_ok=True)
        files = []
        for cid, stem in SCREENS.items():
            stem = PHONE_OVERRIDE.get(cid, stem) if device == 'iphone69' else stem
            source = args.raw / RAW_DIR[device] / args.appearance / (stem + '.png')
            path = out / (cid + '.png')
            image = compose(device, captions[cid], source)
            assert image.size == size and image.mode == 'RGB'
            image.save(path)
            files.append(path)
            manifest.append({'file': str(path.relative_to(args.output)), 'size': size, 'source': source.name,
                             'appearance': args.appearance, 'headline': captions[cid]['headline']})
        groups.append((device, files))
    contact_sheet(groups, args.output / 'contact-sheet.png')
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'{len(manifest)} screenshots + contact sheet')


if __name__ == '__main__':
    main()
