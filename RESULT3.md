# RESULT3

Changed only `verification/CLAIMS.md`: 9 `Text:` anchors moved from `site/src/data/content.ts:N` to `site/src/i18n/en.json:N` (the exact English sentence now lives there).

| CLAIMS.md line | old | new |
|---|---|---|
| 41 | content.ts:284 | en.json:510 |
| 97 | content.ts:170 | en.json:237 |
| 142 | content.ts:190 | en.json:254 |
| 194 | content.ts:66 | en.json:133 |
| 411 | content.ts:62 | en.json:129 |
| 427 | content.ts:71 | en.json:138 |
| 447 | content.ts:68 | en.json:135 |
| 473 | content.ts:232 | en.json:303 |
| 485 | content.ts:149 | en.json:216 |

No other errors. check_registry.py already anchors into JSON (substring-on-line), so no tool change or test needed. No site text changed.

## Output
- check_registry.py: `65 records: 9 blocked, 3 oracle, 14 spec, 39 vespertine-rule` / `registry OK`
- check:i18n: `45 languages × 540 strings OK`
- build: `225 page(s) built`; check-dist: `225 pages OK`
