# Changelog

All notable changes to LFN are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## [1.0.3] — 2026-08-29

### Changed

- Renamed the project from **NFL** (Nim Flavoured Lisp) to **LFN** (Lisp
  Flavoured Nim). The `.nfl` source extension is now `.lfn`, the `nfl`
  binary/package is now `lfn`, and the source directory moved from `src/nfl/`
  to `src/lfn/`.

## [1.0.2] — 2026-08-09

### Added

- `lfn run`/`compile`/`check` accept a trailing `-- <nim-args...>`, forwarding
  everything after `--` straight to the underlying `nim` invocation (e.g.
  `lfn compile file.lfn -- --mm:orc -d:release`). See
  [man/cli.md](man/cli.md#passing-arguments-straight-to-nim).
- Release builds now include a Windows binary alongside Linux and macOS.
- Full `##` doc-comment coverage across `expand`, `lower`, `backend`,
  `runtime`, `stdlib`, `diagnostics`, and `synforms` (previously only
  `cli`/`compiler`/`syntax`/`reader`/`macros` were fully documented).

### Fixed

- Release workflow no longer bundles the GitHub Pages artifact into release
  assets.

## [1.0.0] — 2026-08-02

Initial release.
