# Changelog

All notable changes to NFL are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## [1.0.1] — 2026-08-09

### Added

- `nfl run`/`compile`/`check` accept a trailing `-- <nim-args...>`, forwarding
  everything after `--` straight to the underlying `nim` invocation (e.g.
  `nfl compile file.nfl -- --mm:orc -d:release`). See
  [man/cli.md](man/cli.md#passing-arguments-straight-to-nim).

## [1.0.0] — 2026-08-02

Initial release.
