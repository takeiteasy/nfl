# API Documentation

NFL's API reference is generated from source with [Nim's docgen](https://nim-lang.org/docs/docgen.html), driven by the `docs` nimble task.

## Generating

```sh
nimble docs
```

This runs `nim doc --project` over `src/nfl/cli.nim` (which imports every other module, directly or transitively) and writes one HTML page per module directly into `docs/`, plus a hand-written `docs/index.html` linking to all of them. Output lands in `docs/` (not `docs/api/`) because GitHub Pages serves a repo's `/docs` directory as-is; the prose guides live in `/man` at the repo root instead so they don't collide with generated output.

Regenerate after adding or editing doc comments (`##`) on exported symbols, or after adding a new module under `src/nfl/`.

## Why `--index:off`

`nim doc --project` can also build a full-text search index, but that requires compiling `tools/dochack.nim` to JavaScript — a file some Nim distributions (notably Homebrew's) don't ship, which crashes docgen. The `docs` task passes `--index:off` to skip it; the plain module-list `index.html` it writes instead is enough to navigate the per-module pages.

## Coverage

Doc comments currently cover the modules that make up NFL's public API surface: `cli`, `compiler`, `syntax`, `reader`, and `macros`. Other modules (`expand`, `lower`, `backend`, `runtime`, `stdlib`, `diagnostics`, `synforms`) are internal implementation details and mostly undocumented — their generated pages show bare signatures only. Extending doc-comment coverage to those modules is tracked as a follow-up.

## Publishing

Generated docs are currently local-only (`docs/` is committed but not automatically rebuilt or deployed). CI-driven regeneration and publishing (e.g. GitHub Pages) is planned once v1 lands.
