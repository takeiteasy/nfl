# API Documentation

NFL's API reference is generated from source with [Nim's docgen](https://nim-lang.org/docs/docgen.html), driven by the `docs` nimble task.

## Generating

```sh
nimble docs
```

This runs `nim doc --project --index:on` over `src/nfl/cli.nim` (which imports every other module, directly or transitively) and writes one HTML page per module directly into `docs/`, plus docgen's search index (`theindex.html`, per-module `*.idx` files and `dochack.js`) and a thin `docs/index.html` landing page linking to the module pages. Every module page therefore has a full-text search box. Output lands in `docs/` (not `docs/api/`) for local preview convenience; the prose guides live in `/man` at the repo root instead so they don't collide with generated output. `docs/` itself is gitignored — the published copy comes from CI, not from a commit (see Publishing below).

Regenerate after adding or editing doc comments (`##`) on exported symbols, or after adding a new module under `src/nfl/`.

## `--index:on` and `dochack.js`

`nim doc --index:on` builds the search index by copying `tools/dochack/dochack.js` into the output, compiling it from source if missing. Some Nim distributions (notably Homebrew's) don't ship the `tools/` directory, which crashes docgen with an AssertionDefect. The `docs` task therefore calls the `dochack` task first (`nimble dochack`), which installs a compiled `dochack.js` into the Nim compiler prefix — fetched and built from the matching Nim version tag on GitHub if it isn't there already. Because docgen only compiles the file when it's missing, this sidesteps the crash entirely. Re-run `nimble dochack` after upgrading Nim if the docs task fails.

## Coverage

Doc comments cover every module: the public API surface (`cli`, `compiler`, `syntax`, `reader`, `macros`) as well as the internal implementation modules (`expand`, `lower`, `backend`, `runtime`, `stdlib`, `diagnostics`, `synforms`) — each has a module-level summary and a `##` comment on every exported symbol.

## Publishing

The canonical source lives on sourcehut; a GitHub mirror is used only to publish releases. Pushing a `v*` tag to GitHub triggers a workflow (`.github/workflows/release.yml`) that runs `nimble docs` and publishes the result to GitHub Pages, and builds release binaries attached to the corresponding GitHub release. Docs therefore track the latest tagged release, not the sourcehut trunk.
