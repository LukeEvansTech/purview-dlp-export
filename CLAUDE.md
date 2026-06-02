# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A read-only PowerShell tool that exports a Microsoft Purview DLP ruleset to a re-runnable, **idempotent baseline**. The defining property: re-running against an unchanged tenant must produce a **byte-identical** JSON body. Everything in the normalisation pipeline exists to defend that guarantee.

## Commands

```powershell
# Run all unit tests (no live tenant needed — runs against fixtures)
Invoke-Pester ./tests

# Run a single test file
Invoke-Pester ./tests/Normalise.Tests.ps1

# CI-mode run (emits testResults.xml)
Invoke-Pester ./tests -CI

# Run the export against a real tenant (interactive MFA)
./scripts/Export-PurviewDlp.ps1 -UserPrincipalName admin@<tenant>.onmicrosoft.com -Tenant <short> -OutDir ./out
```

Linting runs in CI via the shared super-linter (`.github/workflows/lint.yml`); there is no local lint command. PSScriptAnalyzer config lives in `.github/linters/`.

## Architecture

The flow is a strict pipeline. The connect/fetch/normalise/JSON stages live in `src/PurviewDlpExport.psm1`; all human-readable rendering lives in `src/PurviewDlpRender.psm1`. The entrypoint `scripts/Export-PurviewDlp.ps1` imports both and orchestrates:

```
Connect-PurviewDlpSession    → Connect-IPPSSession (interactive only)
Get-DlpInventory             → raw {Policies, Rules, ReferencedSits, ReferencedLabels}  (IMPURE — hits tenant)
ConvertTo-NormalisedBaseline → byte-stable {Normalised, StrippedFields}                 (PURE)
Export-DlpBaselineJson       → baseline-<date>-<tenant>.json + .meta.json
ConvertTo-DlpView            → presentation view model (PURE; in PurviewDlpRender.psm1)
  ├─ Export-DlpOverviewMarkdown → baseline-<date>-<tenant>-overview.md  (estate scan table)
  ├─ Export-DlpDetailMarkdown   → baseline-<date>-<tenant>-detail.md    (per-rule narrative)
  └─ Export-DlpMatrixCsv        → baseline-<date>-<tenant>-matrix.csv   (one row per rule, for Excel)
```

**The purity split is the key design line.** `Get-DlpInventory` is the only function that touches the tenant; everything downstream is a pure transform of its output. This is why every test runs against `tests/fixtures/raw-purview-sample.json` with no live connection — fixtures stand in for the impure boundary.

**The view-model split (`ConvertTo-DlpView`) is the second design line.** The three rendered outputs all derive from one view model computed once, so they can never disagree about what a rule "means". The interpretation of Purview's `AdvancedRule` condition tree, `*Location` scope, and action flags into plain English lives only there. Note it **re-parses each rule's `AdvancedRule` JSON** to recover confidence levels and instance counts, because the normaliser deliberately keeps only `{Id, Name}` for detectors (it is byte-stability-focused, not render-focused).

**PowerShell 5.1 runtime.** The tool must run on Windows PowerShell 5.1 (locked-down target boxes); dev/CI run on PS 7. Keep all code 5.1-safe — no PS 6+ constructs (e.g. `ConvertFrom-Json -AsHashtable`, ternary, `??`). When reading view-model array properties for `.Count` or iteration, wrap in `@(...)`: PS 5.1 unwraps single-element array properties to scalars. PSScriptAnalyzer's `PSUseCompatibleSyntax`/`PSUseCompatibleCmdlets` (in `.github/linters/`) guard this statically. Byte-stability is only required re-run-to-re-run *on the same box* — output is not byte-identical across PS 5.1 vs 7 (different `ConvertTo-Json` escaping).

### Byte-stability machinery (inside `ConvertTo-NormalisedBaseline`)

Re-runs drift unless four things are neutralised, in this order:

1. **`Skip-VolatileField`** strips per-run noise (`$script:VolatileFields`: RunspaceId, ETag, WhenCreated/ChangedUTC, ObjectVersion, ImmutableId). If a diff appears between two runs, a field that should be here isn't — add it to `$script:VolatileFields` AND add a strip test in `Normalise.Tests.ps1`.
2. **`Resolve-AdvancedRuleReference`** / **`Expand-AdvancedRuleReference`** backfill SIT/label *names* from the `AdvancedRule` JSON. Purview stores even simple-UI rules as `AdvancedRule` JSON, so **do not gate on `IsAdvancedRule`** — parse the JSON regardless.
3. **`Compress-EnumCollision`** flattens Purview's `{value:N, Value:"X"}` enum-collision pairs to just `"X"`. Done via regex on serialised JSON, not object walk — real Purview objects are deep enough to blow the call stack.
4. **`Format-NormalisedKey`** deep-sorts all keys alphabetically using an **iterative DFS with an explicit stack** (recursion overflows on deep structures). Sorting is mandatory because cmdlet key order is non-deterministic across calls.

`Add-OrphanAnnotation` tags SIT/label references whose IDs aren't in the resolved set (`Orphan = true`) so the rendered outputs can flag dangling references (they show as `<orphan id=…>` rather than being dropped).

### Output stability details

- All five outputs (JSON, meta sidecar, two Markdown files, CSV) are written UTF-8 **without BOM** and with **LF line endings** via the shared `Write-NoBomLf` helper (the JSON/meta path in `PurviewDlpExport.psm1` does the same inline). The LF normalisation (`-replace "`r`n", "`n"`) matters because `StringBuilder.AppendLine` uses CRLF on Windows, which would break the cross-OS snapshot tests. `.gitattributes` locks every `tests/fixtures/expected-*.{md,csv}` snapshot to LF.
- Free-text Purview fields (policy-tip custom text, comments) are collapsed to a single line (`Format-SingleLine`) so an embedded newline can't split a CSV row or break a Markdown bullet.

## Read-only invariant (non-negotiable)

This tool calls **only `Get-*` cmdlets** against Purview. It must never invoke `New-`, `Set-`, `Remove-`, `Enable-`, `Disable-`, or `Reset-` against any Purview-domain noun (`Dlp*`, `Compliance*`, `Label*`, `Sensitive*`, `IPP*`). Verify with:

```bash
grep -E "(New|Set|Remove|Enable|Disable|Reset)-(Dlp|Compliance|Label|Sensitive|IPP)" src/PurviewDlpExport.psm1
```

Any match is a bug. (A naive `Set-`/`Remove-` grep gives false positives like `Set-StrictMode` and the internal `Remove-VolatileFields`/`Skip-VolatileField` helpers — scope to Purview nouns.)

## Testing model

- **`Normalise.Tests.ps1`** — the bulk; verifies field stripping, name backfill, orphan annotation, key sorting.
- **`ExportJson.Tests.ps1`** — asserts no-BOM and **byte-identical output across two runs** with the same input.
- **`View.Tests.ps1`** — drives `ConvertTo-DlpView` from the fixture and asserts the plain-English interpretation (confidence, instance counts, scope, actions, orphan rendering).
- **`Overview.Tests.ps1` / `Detail.Tests.ps1` / `Matrix.Tests.ps1`** — each asserts no-BOM, two-run determinism, and a **byte-for-byte** snapshot (`tests/fixtures/expected-overview.md`, `expected-detail.md`, `expected-matrix.csv`). If you intentionally change a rendering, regenerate that snapshot (the recipe is in `docs/docs/contributing.md`).
- **`Ps51Compat.Tests.ps1`** — guards that no `.psm1` uses a PS 6+ construct (greps for `-AsHashtable`).
- **`Entrypoint.Tests.ps1`** — source-grep that the entrypoint wires the three emitters and not the retired single-Markdown export (the entrypoint itself needs a live tenant, so it can't be run in tests).

CI runs Pester on ubuntu/macos/windows (`test.yml`) plus a parse-check of the `.psm1` and entrypoint script. Cross-OS matrix exists specifically to catch line-ending and encoding regressions.

## After changing the impure boundary

Unit tests cannot exercise live Purview cmdlets, and the entrypoint itself is untested (it needs a tenant). After any meaningful change to `Connect-PurviewDlpSession`, `Get-DlpInventory`, or the entrypoint wiring, run the manual smoke procedure in `README.md` ("Manual smoke test") against a real tenant **on a PowerShell 5.1 box** (the runtime target): confirm five files are written (`.json`, `.meta.json`, `-overview.md`, `-detail.md`, `-matrix.csv`), the meta sidecar's `ToolVersion` matches `ModuleVersion` in `src/PurviewDlpExport.psd1` (a `"0.0"` means the entrypoint loaded the `.psm1` directly instead of the `.psd1` manifest), and a re-run diffs empty.

## Conventions

- **Output files are never committed** — they belong with the engagement workspace, and `.gitignore` excludes `out*/`.
- The version of record is `ModuleVersion` in `src/PurviewDlpExport.psd1`; the entrypoint loads via the `.psd1` manifest, not the `.psm1`, so the version flows into the meta sidecar.
- Docs live in `docs/` and build with [Zensical](https://zensical.org/) (`npm --prefix docs run build`); they publish to GitHub Pages via `docs.yml`.
