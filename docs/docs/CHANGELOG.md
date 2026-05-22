# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-05-22

Initial release.

### Added

- `Connect-PurviewDlpSession` — interactive auth wrapper around `Connect-IPPSSession`.
- `Get-DlpInventory` — reads policies, rules, and resolves referenced SIT/label names. Parses `AdvancedRule` JSON for the canonical condition representation.
- `ConvertTo-NormalisedBaseline` — pure normalisation: strips volatile fields, sorts keys deeply, backfills SIT/label names from `AdvancedRule`, annotates orphan references, flattens Purview enum-collision pairs to byte-stable JSON.
- `Export-DlpBaselineJson` — writes the JSON body plus a `.meta.json` audit sidecar (UTF-8, no BOM).
- `Export-DlpBaselineMarkdown` — writes a per-policy/per-rule narrative Markdown summary with LF line endings.
- Entrypoint script `scripts/Export-PurviewDlp.ps1` with PowerShell version + module pre-flight checks and fail-closed error handling.
- 47 Pester tests covering the pure pipeline against synthetic and realistic-shape fixtures.
- CI: Pester matrix across `ubuntu-latest`, `macos-latest`, `windows-latest`; super-linter via `LukeEvansTech/shared-workflows`.

[0.1.0]: https://github.com/LukeEvansTech/purview-dlp-export/releases/tag/v0.1.0
