# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Windows PowerShell 5.1 support: replaced `ConvertFrom-Json -AsHashtable` (PS 6+ only) with a 5.1-safe ordered-tree deep-sort helper. Version gate and manifest floor lowered to 5.1. PSScriptAnalyzer compatibility rules added as a static safety net.
- `ConvertTo-DlpView` in `src/PurviewDlpRender.psm1` — pure view-model builder that resolves workload tokens, mode strings, and advanced-rule confidence/instance-counts into a single presentation model shared by all three emitters.
- `Export-DlpOverviewMarkdown` — writes `baseline-YYYYMMDD-<tenant>-overview.md`: a header with policy/rule counts and one Markdown table row per policy.
- `Export-DlpDetailMarkdown` — writes `baseline-YYYYMMDD-<tenant>-detail.md`: a full per-policy/per-rule narrative with conditions, actions, and exceptions in plain English.
- `Export-DlpMatrixCsv` — writes `baseline-YYYYMMDD-<tenant>-matrix.csv`: one row per rule, RFC-4180 quoted, for sorting and filtering in Excel.
- Entrypoint now imports `PurviewDlpRender.psm1`, builds the view model once, and writes all five output files (`.json`, `.meta.json`, `-overview.md`, `-detail.md`, `-matrix.csv`).

### Removed

- `Export-DlpBaselineMarkdown` and its private helpers `Format-RuleCondition` / `Format-RuleAction` — superseded by the three layered emitters above.

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

[Unreleased]: https://github.com/LukeEvansTech/purview-dlp-export/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/LukeEvansTech/purview-dlp-export/releases/tag/v0.1.0
