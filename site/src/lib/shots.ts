// The real screenshots each feature section shows, as optimized absolute URLs (for the JSON-LD and the sitemap).
import { getImage } from 'astro:assets';
import type { ImageMetadata } from 'astro';
import { SITE } from '../data/app';
import { scenes } from '../data/content';

const files = import.meta.glob<{ default: ImageMetadata }>('../assets/shots/*.jpg', { eager: true });
export const shot = (name: string) => {
  const f = files[`../assets/shots/${name}.jpg`];
  if (!f) throw new Error(`no src/assets/shots/${name}.jpg`);
  return f.default;
};

export const sceneShots = () =>
  Promise.all(scenes.map(async (s) => ({ url: SITE + (await getImage({ src: shot(s.shot), width: 1600, format: 'webp', quality: 78 })).src, caption: s.alt })));

export const trailerPoster = () => getImage({ src: shot('trailer-poster'), width: 1280, format: 'webp', quality: 70 });
export const TRAILER = '/assets/trailer/vespertine-trailer.mp4';
