/* Page behaviour. Everything here is enhancement: every page reads and works without it.
   This is the only script on the critical path; GSAP + Lenis load later from ./motion, and only on the home page. */
import { $, $$, state } from './dom';
import { initRoute } from './route';
import { STORAGE_KEY } from '../i18n/locales.mjs';

const reduceMQ = matchMedia('(prefers-reduced-motion: reduce)');
const reduce = reduceMQ.matches;
const finePointer = matchMedia('(hover: hover) and (pointer: fine)').matches;

const rtl = document.documentElement.dir === 'rtl';

/* ---------- Copy the Homebrew command (labels in the page's language) ---------- */
$$<HTMLButtonElement>('[data-copy]').forEach((b) => {
  const label = b.textContent;
  b.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(b.dataset.copy ?? '');
      b.textContent = b.dataset.copied ?? 'Copied';
      b.classList.add('is-done');
    } catch {
      b.textContent = b.dataset.failed ?? 'Select it';
    }
    setTimeout(() => { b.textContent = label; b.classList.remove('is-done'); }, 2200);
  });
});

/* ---------- Language menu: remember the choice, keep the section, close on Esc or a click outside ---------- */
$$<HTMLDetailsElement>('[data-lang-menu]').forEach((menu) => {
  const summary = $('summary', menu)!;
  $$<HTMLAnchorElement>('[data-lang-choice]', menu).forEach((a) => {
    a.addEventListener('click', () => {
      try { localStorage.setItem(STORAGE_KEY, a.dataset.langChoice!); } catch { /* private mode: the link still works */ }
      if (location.hash.length > 1) a.href = a.href.split('#')[0] + location.hash;
    });
  });
  menu.addEventListener('toggle', () => {
    if (menu.open) ($('a[aria-current]', menu) ?? $('a', menu))?.scrollIntoView({ block: 'nearest' });
  });
  menu.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && menu.open) { menu.open = false; summary.focus(); }
    if (!menu.open || (e.key !== 'ArrowDown' && e.key !== 'ArrowUp')) return;
    // Arrow keys move through the list, like a menu; Tab still works as usual.
    const items = $$<HTMLAnchorElement>('a', menu);
    const i = items.indexOf(document.activeElement as HTMLAnchorElement);
    const next = e.key === 'ArrowDown' ? (i + 1) % items.length : (i <= 0 ? items.length - 1 : i - 1);
    items[next].focus();
    e.preventDefault();
  });
  document.addEventListener('click', (e) => { if (menu.open && !menu.contains(e.target as Node)) menu.open = false; });
  menu.addEventListener('focusout', (e) => { if (menu.open && e.relatedTarget && !menu.contains(e.relatedTarget as Node)) menu.open = false; });
});

/* ---------- Nav: links that don't fit on one line (long words in some languages) hide, rather than overflow ---------- */
$$('.nav__links').forEach((list) => {
  const items = $$('li', list);
  // Hiding a link narrows the nav (its flex basis shrinks), which can push the next one out, so re-measure until
  // nothing more needs hiding. A link is out when it wrapped onto the clipped second row or is cut off at the edge.
  const fit = () => {
    items.forEach((li) => li.classList.remove('is-squeezed'));
    for (let pass = 0; pass < items.length; pass++) {
      const box = list.getBoundingClientRect();
      const shown = items.filter((li) => li.offsetParent && !li.classList.contains('is-squeezed'));
      const top = shown[0]?.offsetTop ?? 0;
      const out = shown.filter((li) => { const r = li.getBoundingClientRect(); return li.offsetTop > top + 4 || r.right > box.right - 5 || r.left < box.left + 5; });
      if (!out.length) break;
      out.forEach((li) => li.classList.add('is-squeezed'));
    }
  };
  new ResizeObserver(fit).observe(list.closest('.nav') ?? list);
  document.fonts?.ready.then(fit);
  fit();
});

/* ---------- Comparison table: mark which edges have more columns (fade, shadow, hint) ---------- */
$$('.compare-wrap').forEach((wrap) => {
  const table = $('.compare', wrap)!;
  const update = () => {
    const max = table.scrollWidth - table.clientWidth;
    // Distance scrolled from the start edge (right-to-left pages scroll to negative scrollLeft).
    const pos = rtl ? -table.scrollLeft : table.scrollLeft;
    wrap.classList.toggle('more-left', max > 1 && pos > 1);
    wrap.classList.toggle('more-right', max > 1 && pos < max - 1);
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
