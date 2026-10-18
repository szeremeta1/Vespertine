/* Scroll choreography from szeremeta.org: Lenis smooth scrolling plus GSAP ScrollTrigger reveals, parallax and the
   marquee drift. Loaded after the page has finished loading, and never with prefers-reduced-motion. The hero intro
   is CSS, so it does not wait for this file. */
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import Lenis from 'lenis';
import { $, $$ } from './dom';

export function startMotion(hooks: { onScroll(): void; onRefresh(): void }) {
  gsap.registerPlugin(ScrollTrigger);

  const lenis = new Lenis({ lerp: 0.09, wheelMultiplier: 1 });
  lenis.on('scroll', () => { ScrollTrigger.update(); hooks.onScroll(); });
  gsap.ticker.add((t) => lenis.raf(t * 1000));
  gsap.ticker.lagSmoothing(0);

  // This file can arrive after someone has started reading. Only hide-and-reveal things that are still below the
  // fold, so nothing on screen blinks out.
  const unseen = <T extends Element>(els: T[]) => els.filter((el) => el.getBoundingClientRect().top > innerHeight * 0.95);

  // Hero drift on scroll
  gsap.to('.hero__panel', { yPercent: 8, ease: 'none', scrollTrigger: { trigger: '.hero', start: 'top top', end: 'bottom top', scrub: true } });
  gsap.to('.hero__title', { yPercent: -14, opacity: 0.35, ease: 'none', scrollTrigger: { trigger: '.hero', start: 'top top', end: 'bottom top', scrub: true } });

  // Section titles, word by word
  $$('[data-words]').forEach((el) => {
    const words = unseen($$('.rw > span', el));
    if (words.length) gsap.from(words, { yPercent: 110, duration: 1.1, ease: 'expo.out', stagger: 0.05, scrollTrigger: { trigger: el, start: 'top 85%' } });
  });

  // Feature scenes: copy, then the screenshot
  $$('.scene').forEach((scene) => {
    const copy = unseen($$('.scene__copy > :not(.node)', scene));
    if (copy.length) gsap.from(copy, { y: 34, opacity: 0, duration: 1.1, ease: 'expo.out', stagger: 0.06, scrollTrigger: { trigger: scene, start: 'top 72%' } });
    const media = unseen($$('.scene__media', scene));
    if (media.length) gsap.from(media, { y: 80, opacity: 0, scale: 0.96, duration: 1.4, ease: 'expo.out', scrollTrigger: { trigger: scene, start: 'top 70%' } });
    const num = $('.scene__num', scene);
    if (num) gsap.fromTo(num, { yPercent: 30 }, { yPercent: -30, ease: 'none', scrollTrigger: { trigger: scene, scrub: true } });
  });
  $$('[data-parallax]').forEach((el) => {
    const amt = Number(el.dataset.parallax);
    gsap.fromTo(el, { y: -amt * 6 }, { y: amt * 6, ease: 'none', scrollTrigger: { trigger: el.closest('.scene'), scrub: true } });
  });

  // Marquee drifts with scroll
  if ($('.marquee')) gsap.fromTo('.marquee__track', { xPercent: 0 }, { xPercent: -30, ease: 'none', scrollTrigger: { trigger: '.marquee', start: 'top bottom', end: 'bottom top', scrub: 0.6 } });

  // Cards and rows
  $$('[data-reveal]').forEach((group) => {
    const items = unseen($$(':scope > *', group));
    if (items.length) gsap.from(items, { y: 30, opacity: 0, duration: 1, ease: 'expo.out', stagger: 0.07, scrollTrigger: { trigger: group, start: 'top 82%' } });
  });

  ScrollTrigger.addEventListener('refresh', hooks.onRefresh);
  ScrollTrigger.refresh();
  return lenis;
}
