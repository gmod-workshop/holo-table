# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Split the client map subsystem into ordered `map/cl_map_*.lua`
  fragments with shared internals on `ENT._Map`.
- Added clientside LVS tracer projection on the holo display.

### Documented

- Current map subsystem layout, spawn-time split fixes, and steady-state
  Lua allocation estimates.

## [0.1.0]

### Added

- Initial release

[Unreleased]: https://github.com/gmod-workshop/holo-table/compare/0.1.0...HEAD
[0.1.0]: https://github.com/gmod-workshop/holo-table/releases/tag/0.1.0
