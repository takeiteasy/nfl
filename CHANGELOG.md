# Changelog

All notable changes to NFL are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## [1.0.2] — 2026-08-09

### Added

- `nfl run`/`compile`/`check` accept a trailing `-- <nim-args...>`, forwarding
  everything after `--` straight to the underlying `nim` invocation (e.g.
  `nfl compile file.nfl -- --mm:orc -d:release`). See
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
