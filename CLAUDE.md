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

# Run the export against a real tenant (interactive MFA).
# -Tenant is optional: when omitted it's inferred from the UPN via Get-TenantNameFromUpn
# (onmicrosoft.com label, else first domain label). -OutDir defaults to cwd and is created if absent.
./scripts/Export-PurviewDlp.ps1 -UserPrincipalName admin@<tenant>.onmicrosoft.com [-Tenant <short>] [-OutDir ./out]
```

Linting runs in CI via the shared super-linter (`.github/workflows/lint.yml`). Super-linter reads its per-linter configs from `.github/linters/` — note its `.markdown-lint.yml` there enforces a 400-char line limit even though the root `.markdownlint.yml` disables MD013. To pre-flight locally before pushing:

```bash
npx prettier --check "docs/docs/**/*.md" README.md   # respects .prettierignore
uvx codespell src/ tests/ docs/ scripts/
pwsh -c "Invoke-ScriptAnalyzer -Path ./src -Settings ./.github/linters/.powershell-psscriptanalyzer.psd1 -Recurse"  # one -Path per call; the parameter rejects arrays
```

Super-linter also runs textlint terminology ("id" → "ID", "bash" → "Bash" in prose; code spans are exempt). For codespell false positives (e.g. Pester's `AfterAll`), use a bare `# codespell:ignore` line comment — the `# codespell:ignore <word>` form does not suppress.

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

**The view-model split (`ConvertTo-DlpView`) is the second design line.** The three rendered outputs all derive from one view model computed once, so they can never disagree about what a rule "means". The interpretation of Purview's `AdvancedRule` condition tree, `*Location` scope, and action flags into plain English lives only there. Note it **re-parses each rule's `AdvancedRule` JSON** to recover confidence levels and instance counts, because the normaliser deliberately keeps only `{Id, Name}` for detectors (it is byte-stability-focused, not render-focused). Rules whose `ParentPolicyName` matches no exported policy land in the view's `UnattachedRules` collection and are rendered explicitly (overview warning line, detail section, `<unattached: name>` matrix rows) — never silently dropped, so the human outputs cannot disagree with the JSON.

`Get-DlpInventory` resolves referenced SIT/label names by **bulk-fetching each catalogue once** and indexing locally; a fetch failure aborts the run. (Per-id lookups with a silent catch previously made a transient failure indistinguishable from a true orphan, silently changing baseline bytes.) An id absent from the catalogue is a genuine orphan and keeps `Name = $null`.

**PowerShell 5.1 runtime.** The tool must run on Windows PowerShell 5.1 (locked-down target boxes); dev/CI run on PS 7. Keep all code 5.1-safe — no PS 6+ constructs (e.g. `ConvertFrom-Json -AsHashtable`, ternary, `??`). When reading view-model array properties for `.Count` or iteration, wrap in `@(...)`: PS 5.1 unwraps single-element array properties to scalars. PSScriptAnalyzer's `PSUseCompatibleSyntax`/`PSUseCompatibleCmdlets` (in `.github/linters/`) guard this statically. Byte-stability is only required re-run-to-re-run *on the same box* — output is not byte-identical across PS 5.1 vs 7 (different `ConvertTo-Json` escaping).

Two 5.1 pitfalls that only surfaced on real target boxes (PS 7 tests can't catch them):

- **All parsed PowerShell must be pure ASCII** (`src/`, `scripts/`, and `tests/*.ps1` — fixtures are data and exempt). PS 5.1 reads BOM-less files as the system ANSI codepage, so an em-dash or ellipsis in any string or comment breaks the parser at import. Use `-`/`...` instead. `Ps51Compat.Tests.ps1` enforces this byte-level.
- **Resolve paths to absolute before any .NET IO call.** `[System.IO.File]::WriteAllText` resolves relative paths against the .NET process directory, not PowerShell's current location, so a relative `-OutDir` writes to the wrong place. Every emitter does `(Resolve-Path -LiteralPath $OutDir).Path` after the existence check — follow that pattern for any new file-writing code.

### Byte-stability machinery (inside `ConvertTo-NormalisedBaseline`)

Re-runs drift unless four things are neutralised, in this order:

1. **`Skip-VolatileField`** strips per-run noise (`$script:VolatileFields`: RunspaceId, ETag, WhenCreated/ChangedUTC, ObjectVersion, ImmutableId). If a diff appears between two runs, a field that should be here isn't — add it to `$script:VolatileFields` AND add a strip test in `Normalise.Tests.ps1`.
2. **`Resolve-AdvancedRuleReference`** / **`Expand-AdvancedRuleReference`** backfill SIT/label *names* from the `AdvancedRule` JSON. Purview stores even simple-UI rules as `AdvancedRule` JSON, so **do not gate on `IsAdvancedRule`** — parse the JSON regardless.
3. **`Compress-EnumCollision`** flattens Purview's `{value:N, Value:"X"}` enum-collision pairs to just `"X"`. Done via regex on serialised JSON, not object walk — real Purview objects are deep enough to blow the call stack.
4. **`Format-NormalisedKey`** deep-sorts all keys alphabetically using an **iterative DFS with an explicit stack** (recursion overflows on deep structures). Sorting is mandatory because cmdlet key order is non-deterministic across calls.

`Add-OrphanAnnotation` tags SIT/label references whose IDs aren't in the resolved set (`Orphan = true`) so the rendered outputs can flag dangling references (they show as `<orphan id=…>` rather than being dropped).

### Output stability details

- All five outputs (JSON, meta sidecar, two Markdown files, CSV) are written UTF-8 **without BOM** and with **LF line endings** via `Write-NoBomLf` (each module carries its own copy so both stay standalone). The LF normalisation (`-replace "`r`n", "`n"`) matters because `StringBuilder.AppendLine` and `ConvertTo-Json` use CRLF on Windows, which would break the cross-OS snapshot tests. `.gitattributes` locks every `tests/fixtures/expected-*.{md,csv}` snapshot to LF.
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
- **`Overview.Tests.ps1` / `Detail.Tests.ps1` / `Matrix.Tests.ps1`** — each asserts no-BOM, two-run determinism, and a **byte-for-byte** snapshot (`tests/fixtures/expected-overview.md`, `expected-detail.md`, `expected-matrix.csv`). If you intentionally change a rendering, regenerate the affected snapshot(s):

```powershell
# From repo root — use a fixed DateStamp so filenames are predictable
pwsh -NoProfile -Command {
    Import-Module ./src/PurviewDlpExport.psd1 -Force
    Import-Module ./src/PurviewDlpRender.psm1 -Force
    $raw  = Get-Content ./tests/fixtures/raw-purview-sample.json -Raw | ConvertFrom-Json
    $view = ConvertTo-DlpView -Normalised (ConvertTo-NormalisedBaseline -Inventory $raw).Normalised
    Export-DlpOverviewMarkdown -View $view -OutDir ./tests/fixtures -Tenant acme -DateStamp 20260601
    Export-DlpDetailMarkdown   -View $view -OutDir ./tests/fixtures -Tenant acme -DateStamp 20260601
    Export-DlpMatrixCsv        -View $view -OutDir ./tests/fixtures -Tenant acme -DateStamp 20260601
    Move-Item -Force ./tests/fixtures/baseline-20260601-acme-overview.md ./tests/fixtures/expected-overview.md
    Move-Item -Force ./tests/fixtures/baseline-20260601-acme-detail.md   ./tests/fixtures/expected-detail.md
    Move-Item -Force ./tests/fixtures/baseline-20260601-acme-matrix.csv  ./tests/fixtures/expected-matrix.csv
}
```

Review the diff carefully after regenerating — any snapshot change is a change to the documented output contract.
- **`Inventory.Tests.ps1`** — covers `Get-DlpInventory` against globally-stubbed, module-scope-mocked Purview cmdlets: bulk single-call catalogue fetch, name resolution, true-orphan handling, and fetch-failure propagation.
- **`Tenant.Tests.ps1`** — covers `Get-TenantNameFromUpn`: the onmicrosoft.com label is preferred (case-insensitive suffix match, label case preserved), with a fallback to the first domain label for vanity domains.
- **`Ps51Compat.Tests.ps1`** — guards 5.1 parseability: no `.psm1` uses a PS 6+ construct (greps for `-AsHashtable`), and every parsed PowerShell file (`src/`, `scripts/`, `tests/*.ps1`) contains only ASCII bytes.
- **`Entrypoint.Tests.ps1`** — source-grep that the entrypoint wires the three emitters and not the retired single-Markdown export (the entrypoint itself needs a live tenant, so it can't be run in tests).

CI runs Pester on ubuntu/macos/windows (`test.yml`) plus a parse-check of the `.psm1` and entrypoint script. Cross-OS matrix exists specifically to catch line-ending and encoding regressions. A fourth workflow, `docs-standard-check.yml`, runs a Zensical drift check on PRs touching `docs/**`, `.github/workflows/**`, `renovate.json`, or `.markdownlint.yml`.

## Adding new functions

- **Singular noun** — `Export-DlpBaselineJson` not `Export-DlpBaselineJsons`.
- **Approved verb** — check with `Get-Verb | Select-Object -ExpandProperty Group`; unapproved verbs trigger PSScriptAnalyzer.
- Every function requires `[OutputType(...)]` and `[CmdletBinding()]` — the linter settings enforce both.
- Export new functions in the `Export-ModuleMember` call at the bottom of the relevant `.psm1`.
- Entrypoint conventions: `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` must stay in place.
- Add a `Describe` block in the appropriate `.Tests.ps1`; cover at minimum the happy path and one edge case.

## After changing the impure boundary

Unit tests cannot exercise live Purview cmdlets, and the entrypoint itself is untested (it needs a tenant). After any meaningful change to `Connect-PurviewDlpSession`, `Get-DlpInventory`, or the entrypoint wiring, run the manual smoke procedure against a real tenant **on a PowerShell 5.1 box** (the runtime target) — the 5.1-tailored step-by-step lives in `docs/docs/runbook-ps51.md` (summary in `README.md` "Manual smoke test"): confirm five files are written (`.json`, `.meta.json`, `-overview.md`, `-detail.md`, `-matrix.csv`), the meta sidecar's `ToolVersion` matches `ModuleVersion` in `src/PurviewDlpExport.psd1` (a `"0.0"` means the entrypoint loaded the `.psm1` directly instead of the `.psd1` manifest), and a re-run diffs empty.

## Conventions

- **Output files are never committed** — they belong with the engagement workspace, and `.gitignore` excludes `out*/`.
- The version of record is `ModuleVersion` in `src/PurviewDlpExport.psd1`; the entrypoint loads via the `.psd1` manifest, not the `.psm1`, so the version flows into the meta sidecar.
- **Releases**: when bumping `ModuleVersion`, also cut the matching section in `docs/docs/CHANGELOG.md` (Keep a Changelog format, with compare links), update the `ToolVersion` literals in `README.md` and `docs/docs/output-schema.md`, and after merge tag `vX.Y.Z` + create a GitHub release (current: v0.2.0).
- Docs live in `docs/` and build with [Zensical](https://zensical.org/) (`npm --prefix docs run build`); they publish to GitHub Pages via `docs.yml` on push to main.
- The site's display name is `site_name = "Purview DLP Export"` in `docs/zensical.toml`; the repo slug appears only in code blocks, URLs, and the header's repo widget. `index.md`'s H1 is deliberately **"Overview"**, not the site name — Material composes the tab title as `<H1> - <site_name>`, so matching them doubles the name.
- **Zensical admonitions (`!!! note`) vs Prettier**: admonition bodies must be 4-space-indented to render, but Prettier de-indents them into plain paragraphs. Any doc page using admonitions must be listed in `.prettierignore` (currently `docs/docs/runbook-ps51.md` and `docs/docs/index.md`).
- Field-delivery of the tool to a locked-down box is a zip of `scripts/` + `src/` (layout preserved — the entrypoint resolves `../src` relative to itself) plus a run guide; remind the operator to `Unblock-File` after extracting (Mark-of-the-Web blocks the scripts).
