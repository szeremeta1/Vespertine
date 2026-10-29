/* The routed signal (from szeremeta.org): a brass line from the hero's origin node down a trunk at the left edge,
   drawn as you scroll, lighting each feature's node and branching into it, like the app's own signal path.
   On right-to-left pages the trunk runs down the right edge: positions are measured from the right and the SVG is
   mirrored in CSS, so the geometry below is the same either way. */
import { $, $$ } from './dom';

const NS = 'http://www.w3.org/2000/svg';
const DROP = 46;

type Node = { scene: HTMLElement; x: number; y: number; branch?: SVGPathElement[] };

export function initRoute(reduce: boolean) {
  const host = $('.route-host');
  const svg = $<SVGSVGElement>('.route');
  const origin = $('[data-route-origin]');
  const scenes = $$('[data-node]');
  if (!host || !svg || !origin || !scenes.length) return { schedule() {}, layout() {} };

  const bed = $<SVGPathElement>('.route__bed', svg)!;
  const live = $<SVGPathElement>('.route__live', svg)!;
  const halo = $<SVGPathElement>('.route__halo', svg)!;
  const head = $<SVGCircleElement>('.route__head', svg)!;
  const branchG = $<SVGGElement>('.route__branches', svg)!;

  // Resolve --trunk-x (a clamp()) to pixels.
  const probe = document.createElement('div');
  probe.style.cssText = 'position:absolute;visibility:hidden;width:var(--trunk-x);height:0';
  document.body.appendChild(probe);

  let nodes: Node[] = [];
  // Geometry of the path, so length-at-y is arithmetic instead of sampling the SVG.
  let g: null | { oy: number; y1: number; yh: number; r: number; curve: number; L1: number; L3: number; L4: number; total: number } = null;

  function layout() {
    const hr = host!.getBoundingClientRect();
    const rtl = document.documentElement.dir === 'rtl';
    const rel = (el: Element) => {
      const r = el.getBoundingClientRect();
      return { x: (rtl ? hr.right - r.right : r.left - hr.left) + r.width / 2, y: r.top - hr.top + r.height / 2 };
    };
    svg!.setAttribute('viewBox', `0 0 ${hr.width} ${hr.height}`);
    svg!.setAttribute('width', `${hr.width}`);
    svg!.setAttribute('height', `${hr.height}`);

    const tx = probe.offsetWidth;
    const o = rel(origin!);
    nodes = scenes.map((s) => ({ scene: s, ...rel($('.node', s)!) }));
    const lastY = nodes[nodes.length - 1].y;
    const r = Math.max(2, Math.min(28, (o.x - tx) / 2));
    const y1 = o.y + DROP;
    const yh = y1 + r;
    const d = [
      `M ${o.x} ${o.y}`,
      `V ${y1}`,
      `Q ${o.x} ${yh} ${o.x - r} ${yh}`,
      `H ${tx + r}`,
      `Q ${tx} ${yh} ${tx} ${yh + r}`,
      `V ${lastY}`,
    ].join(' ');
    bed.setAttribute('d', d);
    live.setAttribute('d', d);
    halo.setAttribute('d', d);
    const total = live.getTotalLength();
    live.style.strokeDasharray = halo.style.strokeDasharray = `${total}`;

    bed.setAttribute('d', `M ${o.x} ${y1} Q ${o.x} ${yh} ${o.x - r} ${yh}`);
    const curve = bed.getTotalLength();
    bed.setAttribute('d', d);
    const L1 = DROP;
    const L3 = L1 + curve + Math.max(0, o.x - r - (tx + r));
    g = { oy: o.y, y1, yh, r, curve, L1, L3, L4: L3 + curve, total };

    branchG.textContent = '';
    nodes.forEach((n) => {
      const len = n.x - 8 - tx;
      if (len > 12) {
        n.branch = ['halo', ''].map((cls) => {
          const p = document.createElementNS(NS, 'path');
          if (cls) p.setAttribute('class', cls);
          p.setAttribute('d', `M ${tx} ${n.y} H ${n.x - 8}`);
          p.style.strokeDasharray = `${len}`;
          p.style.strokeDashoffset = reduce ? '0' : `${len}`;
          branchG.appendChild(p);
          return p;
        });
      }
      const j = document.createElementNS(NS, 'circle');
      j.setAttribute('cx', `${tx}`);
      j.setAttribute('cy', `${n.y}`);
      j.setAttribute('r', '3');
      j.setAttribute('fill', '#E7CD98');
      branchG.appendChild(j);
    });
    svg!.classList.add('is-ready');
    update();
  }

  function lengthAtY(y: number) {
    const { oy, y1, yh, r, curve, L1, L3, L4, total } = g!;
    if (y <= oy) return 0;
    if (y <= y1) return y - oy;
    if (y < yh) return L1 + (1 - Math.sqrt(1 - (y - y1) / r)) * curve;
    if (y < yh + r) return L3 + Math.sqrt((y - yh) / r) * curve;
    return Math.min(total, L4 + (y - yh - r));
  }

  function update() {
    if (!g) return;
    const hr = host!.getBoundingClientRect();
    const headY = reduce ? Infinity : innerHeight * 0.62 - hr.top;
    const l = lengthAtY(headY);
    live.style.strokeDashoffset = halo.style.strokeDashoffset = `${g.total - l}`;
    const pt = live.getPointAtLength(Math.max(0, l));
    head.setAttribute('cx', `${pt.x}`);
    head.setAttribute('cy', `${pt.y}`);
    head.classList.toggle('is-idle', reduce || l <= 0 || l >= g.total - 1);
    nodes.forEach((n) => {
      const on = headY >= n.y - 1;
      n.scene.classList.toggle('is-live', on);
      if (n.branch) n.branch.forEach((p) => { p.style.strokeDashoffset = on ? '0' : p.style.strokeDasharray; });
    });
  }

  let raf = 0;
  const schedule = () => { if (!raf) raf = requestAnimationFrame(() => { raf = 0; update(); }); };
  let rt = 0;
  const relayout = () => { clearTimeout(rt); rt = window.setTimeout(layout, 120); };
  addEventListener('scroll', schedule, { passive: true });
  addEventListener('resize', relayout);
  document.fonts?.ready.then(layout);
  addEventListener('load', layout);
  new ResizeObserver(relayout).observe(host);
  layout();

  return { schedule, layout };
}
