/* Page behaviour. Everything here is enhancement: every page reads and works without it.
   This is the only script on the critical path; GSAP + Lenis load later from ./motion, and only on the home page. */
import { $, $$, state } from './dom';
import { initRoute } from './route';

const reduceMQ = matchMedia('(prefers-reduced-motion: reduce)');
const reduce = reduceMQ.matches;
const finePointer = matchMedia('(hover: hover) and (pointer: fine)').matches;

/* ---------- Copy the Homebrew command ---------- */
$$<HTMLButtonElement>('[data-copy]').forEach((b) => {
  b.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(b.dataset.copy ?? '');
      b.textContent = 'Copied';
      b.classList.add('is-done');
    } catch {
      b.textContent = 'Select it';
    }
    setTimeout(() => { b.textContent = 'Copy'; b.classList.remove('is-done'); }, 2200);
  });
});

/* ---------- Comparison table: mark which edges have more columns (fade, shadow, hint) ---------- */
$$('.compare-wrap').forEach((wrap) => {
  const table = $('.compare', wrap)!;
  const update = () => {
    const max = table.scrollWidth - table.clientWidth;
    wrap.classList.toggle('more-left', max > 1 && table.scrollLeft > 1);
    wrap.classList.toggle('more-right', max > 1 && table.scrollLeft < max - 1);
  };
  table.addEventListener('scroll', update, { passive: true });
  new ResizeObserver(update).observe(table);
});

/* ---------- Pointer spotlight + magnetic buttons ---------- */
if (finePointer) {
  $$('.spot').forEach((el) => {
    el.addEventListener('pointermove', (e) => {
      const r = el.getBoundingClientRect();
      el.style.setProperty('--mx', `${e.clientX - r.left}px`);
      el.style.setProperty('--my', `${e.clientY - r.top}px`);
    });
  });
  if (!reduce) {
    $$('.magnetic').forEach((el) => {
      const inner = el.firstElementChild as HTMLElement | null;
      if (!inner) return;
      el.addEventListener('pointermove', (e) => {
        const r = el.getBoundingClientRect();
        const dx = ((e.clientX - r.left) / r.width - 0.5) * 8;
        const dy = ((e.clientY - r.top) / r.height - 0.5) * 6;
        inner.style.transform = `translate(${dx}px, ${dy}px)`;
      });
      el.addEventListener('pointerleave', () => { inner.style.transform = ''; });
    });
  }
}

/* ---------- Active nav link (home page sections) ---------- */
const navLinks = $$<HTMLAnchorElement>('.nav__links a[href^="#"]');
if (navLinks.length) {
  const navIO = new IntersectionObserver((entries) => {
    entries.forEach((e) => {
      if (!e.isIntersecting) return;
      navLinks.forEach((a) => {
        if (a.getAttribute('href') === `#${e.target.id}`) a.setAttribute('aria-current', 'true');
        else a.removeAttribute('aria-current');
      });
    });
  }, { rootMargin: '-45% 0px -50% 0px' });
  navLinks.map((a) => $(a.getAttribute('href') ?? '')).filter((s): s is HTMLElement => !!s).forEach((s) => navIO.observe(s));
}

/* ---------- The routed signal (home page) ---------- */
const route = initRoute(reduce);

/* ---------- In-page links: offset for the fixed nav, light the jack, move focus ---------- */
const scrollToY = (y: number, duration = 1.6) => {
  if (state.lenis) state.lenis.scrollTo(y, { duration });
  else scrollTo({ top: y, behavior: reduce ? 'auto' : 'smooth' });
};
$$<HTMLAnchorElement>('a[href^="#"]').forEach((a) => {
  a.addEventListener('click', (e) => {
    const id = a.getAttribute('href')!;
    const target = id.length > 1 ? $(id) : null;
    if (!target) return;
    e.preventDefault();
    if (a.dataset.routeTo) {
      $$('.jack').forEach((j) => j.classList.toggle('is-routed', j === a));
      target.classList.remove('is-arrived');
      void target.offsetWidth;
      target.classList.add('is-arrived');
    }
    if (id === '#top') scrollToY(0, 1.4);
    else scrollToY(target.getBoundingClientRect().top + scrollY - (id === '#main' ? 0 : 84));
    history.replaceState(null, '', id);
    if (target.tabIndex < 0 && !target.hasAttribute('tabindex')) target.setAttribute('tabindex', '-1');
    target.focus({ preventScroll: true });
  });
});

/* ---------- Scroll choreography, once the first screen has loaded and painted (home page only) ---------- */
if (!reduce && $('[data-motion]')) {
  const go = () => import('./motion')
    .then(({ startMotion }) => { state.lenis = startMotion({ onScroll: route.schedule, onRefresh: route.layout }); })
    .catch(() => { /* the page is complete without it */ });
  const idle = (cb: () => void) => ('requestIdleCallback' in window ? requestIdleCallback(cb, { timeout: 2000 }) : setTimeout(cb, 0));
  const settle = () => requestAnimationFrame(() => setTimeout(() => idle(go), 300));
  if (document.readyState === 'complete') settle();
  else addEventListener('load', settle, { once: true });
}

reduceMQ.addEventListener('change', () => location.reload());
