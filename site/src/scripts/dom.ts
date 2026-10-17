export const $ = <T extends Element = HTMLElement>(s: string, c: ParentNode = document) => c.querySelector<T>(s);
export const $$ = <T extends Element = HTMLElement>(s: string, c: ParentNode = document) => [...c.querySelectorAll<T>(s)];

/** Shared between the critical script and the lazily loaded motion module. */
export const state: { lenis: null | { scrollTo(target: number, opts?: { duration?: number }): void } } = { lenis: null };
