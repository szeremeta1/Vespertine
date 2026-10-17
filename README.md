# Review images for the vespertineapp.com rebuild (PR from `vesper/site-rebuild`)

Screenshots, social cards and Lighthouse reports for reviewing the pull request. This branch holds no code and is not
meant to be merged; delete it once the PR is settled.

- `shots/`: full pages at 390 px (1x) and 1440 px, JS on (`after-*`), JS off (`nojs-*`), reduced motion
  (`reduced-*`), the old site (`before-*`), and viewport frames while scrolling with motion on (`motion-*`).
- `og/`: the social card for each page, exactly as served.
- `lighthouse/`: `summary.json`, the HTML reports, and the axe-core results (`axe.json` with JS and reduced motion,
  `axe-nojs.json` without JS).
