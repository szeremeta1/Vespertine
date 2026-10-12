# Requirement records

One record per testable requirement, grouped by file. `../tools/check_registry.py` enforces the rules below in CI.

```yaml
- id: DOP-002                       # unique; tests tag every assertion with it (// REQ: DOP-002)
  claim: CLAIMS.md#dop-marker       # the public claim this supports
  source:
    doc: "DoP Open Standard"
    version: "1.1 (2012-03-30)"
    section: "§2 Solutions, page 2"
    url: "https://…"                # opened on 2026-10-09; see SOURCES.md
    availability: public            # public | paywalled | not-public | repository
    cache: { doc: dop-1.1, pages: 2, from: "…", to: "…" }   # where the clause is, for the hash
  requirement: "Paraphrase, at most 40 words."
  quote: "Verbatim, at most 25 words, public sources only (optional)."
  quote_sha256: "…"                 # see below; BLOCKED when the source isn't in hand
  kind: spec                        # spec | oracle | vespertine-rule
  testable: true
  gap: "What the source doesn't say. Empty if nothing."
  interface: "contracts/dop-pack.md"
```

## Kinds

- **spec**: a published standard says so. The source is the standard, never an implementation.
- **vespertine-rule**: Vespertine's own definition, from its public docs (the BIT-PERFECT conditions, for example). The source is the doc line, at the commit this harness was written against.
- **oracle**: no public standard can be cited; the requirement is agreement with an independent implementation, named in the record. It is a second opinion, not proof.

## The hash

`quote_sha256` is the SHA-256 of the clause in canonical form: the text from the `from` phrase through the `to` phrase, normalised to Unicode NFKC, case-folded, keeping only `a`–`z` and `0`–`9`. Different PDF text extractors break lines and space differently; this form doesn't change between them (checked with poppler's `pdftotext` and Apple's PDFKit on every public clause cited here).

- **repository** sources (Vespertine's docs): `cache: { repo: <path>, lines: <n> or [first, last], from, to }`. CI recomputes these hashes, so a doc edit that changes a cited rule fails CI until the record is reviewed.
- **public** standards and Apple headers: the text lives in `verification/spec-cache/` (git-ignored). Run `tools/spec_cache.py fetch`, then `tools/spec_cache.py verify` to recompute every hash. CI checks only that the hash is present and well formed.
- **paywalled** and **not-public** sources that aren't in the cache: `quote_sha256: BLOCKED`, `testable: false`, `status: blocked-on-source`. When the document is bought, `spec_cache.py add` puts it in the cache and the record gets its hash; its text never enters the repository.
- **oracle** records: `cache: { oracle: <dir>, files: [...] }`, and the hash is a digest of the oracle's pinned source: SHA-256 over each listed file's path (relative to `<dir>`), a zero byte, its contents and a zero byte, in sorted path order. Third-party oracles aren't vendored: `tools/fetch_oracles.py` downloads them at the pinned version into `verification/oracles/fetched/` (git-ignored) and refuses a download whose digest differs. Wherever the files are present, `check_registry.py` recomputes the digest.

## Rules

- No record without a source.
- When the source can be read two ways, the record says so in `gap`, or there are two records. A test may not pick a reading the record leaves open.
- A `spec` record never cites FFmpeg, sacd_extract, Apple sample code or any other implementation.
