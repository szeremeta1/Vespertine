// Makes the favicons, the web-app manifest icons and the Apple touch icon from the app icon
// (src/assets/brand/icon-512.png, the full-bleed square the brand scripts render). Deterministic: run it again after
// the icon changes, and commit what it writes to public/.
//   npm run icons
import sharp from 'sharp';
import { writeFileSync } from 'node:fs';

const src = new URL('../src/assets/brand/icon-512.png', import.meta.url).pathname;
const pub = (f) => new URL(`../public/${f}`, import.meta.url).pathname;
const png = (size) => sharp(src).resize(size, size, { kernel: 'lanczos3' }).png({ compressionLevel: 9, palette: size <= 48 }).toBuffer();

// favicon.ico: 16, 32 and 48 px PNGs in one ICO container.
const sizes = [16, 32, 48];
const images = await Promise.all(sizes.map(png));
const header = Buffer.alloc(6 + 16 * sizes.length);
header.writeUInt16LE(0, 0); header.writeUInt16LE(1, 2); header.writeUInt16LE(sizes.length, 4);
let offset = header.length;
sizes.forEach((s, i) => {
  const e = 6 + 16 * i;
  header.writeUInt8(s, e); header.writeUInt8(s, e + 1); header.writeUInt8(0, e + 2); header.writeUInt8(0, e + 3);
  header.writeUInt16LE(1, e + 4); header.writeUInt16LE(32, e + 6);
  header.writeUInt32LE(images[i].length, e + 8); header.writeUInt32LE(offset, e + 12);
  offset += images[i].length;
});
writeFileSync(pub('favicon.ico'), Buffer.concat([header, ...images]));

for (const [file, size] of [['icon-192.png', 192], ['icon-512.png', 512], ['apple-touch-icon.png', 180]]) writeFileSync(pub(file), await png(size));
console.log('wrote favicon.ico (16/32/48), icon-192.png, icon-512.png, apple-touch-icon.png');
