#!/usr/bin/env python3
"""Compose review-only Store art from actual captures; missing iPad UI stays explicitly missing.
Requires Pillow. --reference optionally supplies old M1 phone captures for style review only.
"""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parent.parent
KIT = ROOT / 'docs/app-store/ios-m2'
FONTS = ROOT / 'docs/design/fonts'
BASE, IVORY, BRASS = '#09090A', '#ECE6DA', '#C8A66A'


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


def compose(size, item, source, status):
    w, h = size
    image = Image.new('RGB', size, BASE)
    draw = ImageDraw.Draw(image)
    scale = w / 1320
    margin = round(90 * scale)
    # Plan A's dark brass field, kept subtle and behind the real capture.
    for y in range(h):
        lift = max(0, 1 - abs(y / h - .44) * 2) * 8
        draw.line((0, y, w, y), fill=(9 + round(lift), 9 + round(lift * .75), 10 + round(lift * .4)))
    serif = font('Newsreader[opsz,wght].ttf', round(100 * scale))
    mono = font('JetBrainsMono[wght].ttf', round(25 * scale))
    sans = font('Inter[opsz,wght].ttf', round(25 * scale))
    wordmark = font('Newsreader[opsz,wght].ttf', round(44 * scale))
    draw.text((margin, round(65 * scale)), 'vespertine', font=wordmark, fill=IVORY)
    title = wrapped(draw, item['headline'], serif, w - 2 * margin)
    draw.multiline_text((margin, round(160 * scale)), title, font=serif, fill=IVORY, spacing=round(4 * scale))
    label_y = round(410 * scale)
    draw.text((margin, label_y), item['caption'], font=mono, fill=BRASS)
    top = round(535 * scale)
    bottom = h - round(145 * scale)
    box = (w - 2 * margin, bottom - top)
    if source:
        with Image.open(source) as shot:
            screen = ImageOps.contain(shot.convert('RGB'), box, Image.Resampling.LANCZOS)
        x = (w - screen.width) // 2
        y = top + (box[1] - screen.height) // 2
        image.paste(screen, (x, y))
        draw = ImageDraw.Draw(image)
        draw.rectangle((x - 1, y - 1, x + screen.width, y + screen.height), outline='#403A30', width=1)
    else:
        left, right = margin, w - margin
        draw.rectangle((left, top, right, bottom), outline='#403A30', width=2)
        missing = 'iPad capture required' if w > 1500 else 'iPhone capture required'
        draw.text((w / 2, (top + bottom) / 2), missing, font=sans, fill=IVORY, anchor='mm')
        draw.text((w / 2, (top + bottom) / 2 + 60 * scale), 'No simulator image available', font=mono, fill=BRASS, anchor='mm')
    draw.text((w / 2, h - round(70 * scale)), status, font=sans, fill=BRASS, anchor='mm')
    return image


def contact_sheet(files, output):
    cell_w, cell_h, columns = 330, 770, 4
    rows = (len(files) + columns - 1) // columns
    sheet = Image.new('RGB', (columns * cell_w, rows * cell_h + 70), '#16161A')
    draw = ImageDraw.Draw(sheet)
    label = font('Inter[opsz,wght].ttf', 17)
    draw.text((24, 20), 'DRAFT: reference phone images and missing iPad captures are labelled', font=label, fill=IVORY)
    for i, path in enumerate(files):
        x, y = i % columns * cell_w, 70 + i // columns * cell_h
        with Image.open(path) as shot:
            thumb = ImageOps.contain(shot.convert('RGB'), (cell_w - 20, cell_h - 55), Image.Resampling.LANCZOS)
        sheet.paste(thumb, (x + (cell_w - thumb.width) // 2, y))
        draw.text((x + 10, y + cell_h - 42), path.parent.name + '/' + path.stem, font=label, fill=IVORY)
    sheet.save(output)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--captures', type=Path)
    p.add_argument('--reference', type=Path)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    captions = json.loads((KIT / 'captions.json').read_text())
    files, manifest = [], []
    # Reference is always phone-only; never stretch it to stand in for an iPad.
    for device, size in [('iphone69', (1320, 2868)), ('ipad13', (2064, 2752))]:
        out = args.output / device
        out.mkdir(parents=True, exist_ok=True)
        for item in captions:
            source = args.captures / device / 'portrait/dark' / (item['screen'] + '.png') if args.captures else None
            status = 'Draft: Alex review required'
            kind = 'current capture'
            if source is None or not source.exists():
                source = args.reference / (item['screen'] + '.png') if device == 'iphone69' and args.reference else None
                if source and source.exists():
                    kind, status = 'M1 reference', 'M1 reference: recapture required'
                else:
                    source = None
                    kind, status = 'missing capture', 'Template only: capture required'
            path = out / (item['id'] + '.png')
            compose(size, item, source, status).save(path)
            files.append(path)
            manifest.append({'file': str(path.relative_to(args.output)), 'size': size, 'sourceKind': kind,
                             'source': str(source) if source else None, 'visualReview': 'pending', 'uploadReady': False})
    contact_sheet(files, args.output / 'contact-sheet.png')
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'{len(files)} draft images and contact sheet; no asset marked upload-ready.')


if __name__ == '__main__':
    main()
