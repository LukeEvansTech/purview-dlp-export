# Contributing

PRs welcome. The codebase is small — a PowerShell module, a thin entrypoint script, and Pester tests — and the design rationale is in the Git log and the [design spec](https://github.com/LukeEvansTech/purview-dlp-export/blob/main/docs/docs/output-schema.md).

## Repository layout

```text
purview-dlp-export/
  src/
    PurviewDlpExport.psm1     # module — five exported functions
    PurviewDlpExport.psd1     # module manifest (sets ModuleVersion)
  scripts/
    Export-PurviewDlp.ps1     # entrypoint — pre-flight, connect, fetch, normalise, emit
  tests/
    Normalise.Tests.ps1       # tests for ConvertTo-NormalisedBaseline
    ExportJson.Tests.ps1      # tests for Export-DlpBaselineJson
    ExportMarkdown.Tests.ps1  # tests for Export-DlpBaselineMarkdown
    fixtures/
      raw-purview-sample.json # synthetic Purview inventory (all rule types)
      expected.md             # locked Markdown snapshot (LF line endings)
  examples/
    baseline-sample.md        # rendered sample for documentation
  docs/                       # this documentation site
```

## Running tests locally

```powershell
Invoke-Pester ./tests
# Expected: Tests Passed: 47
```

Tests are fixture-driven and require no live Purview connection — all 47 run against synthetic inputs in `tests/fixtures/`.

The test suite covers:

- `ConvertTo-NormalisedBaseline` — idempotency, byte-stability, volatile-field stripping, sort order, orphan annotation, semantics preservation.
- `Export-DlpBaselineJson` — file is written, meta sidecar fields are correct, UTF-8 no BOM.
- `Export-DlpBaselineMarkdown` — snapshot match against `tests/fixtures/expected.md` (byte-for-byte, LF).

## How the Markdown snapshot fixture works

`tests/fixtures/expected.md` is a locked snapshot. If you change `Export-DlpBaselineMarkdown` in a way that alters the rendered output, regenerate it:

```powershell
# From repo root:
pwsh -NoProfile -Command {
    Import-Module ./src/PurviewDlpExport.psd1 -Force
    $raw = Get-Content ./tests/fixtures/raw-purview-sample.json -Raw | ConvertFrom-Json
    $inventory = [PSCustomObject]@{
        Policies         = $raw.Policies
        Rules            = $raw.Rules
        ReferencedSits   = $raw.ReferencedSits
        ReferencedLabels = $raw.ReferencedLabels
    }
    $norm = ConvertTo-NormalisedBaseline -Inventory $inventory
    $null = Export-DlpBaselineMarkdown -Normalised $norm.Normalised -OutDir ./tests/fixtures -Tenant sample -DateStamp 20260521
    Move-Item ./tests/fixtures/baseline-20260521-sample.md ./tests/fixtures/expected.md -Force
}
```

After regenerating, review the diff carefully — any change to the snapshot is a change to the documented output contract.

## LF line-ending policy

`.gitattributes` locks `tests/fixtures/expected.md` to LF line endings. The `Export-DlpBaselineMarkdown` function normalises CRLF→LF at write time (`StringBuilder.AppendLine` emits `Environment.NewLine`, which is CRLF on Windows; the renderer explicitly replaces it). This means the snapshot is byte-identical across OS.

Do not change the `.gitattributes` entry for `expected.md` — doing so will cause snapshot tests to fail on Windows.

## CI

Three workflows (none require live-tenant access):

- **`test.yml`** — Pester matrix on `ubuntu-latest`, `macos-latest`, `windows-latest`. All 47 tests run on every push.
- **`lint.yml`** — Super-Linter (PSScriptAnalyzer, yamllint, markdownlint, gitleaks, actions-lint) via `LukeEvansTech/shared-workflows`.
- **`docs.yml`** — Builds this documentation site and deploys to GitHub Pages on pushes to `main` that touch `docs/**`.

## Local lint check

Before pushing, run PSScriptAnalyzer against the module with the same settings CI uses:

```powershell
Invoke-ScriptAnalyzer -Path ./src/PurviewDlpExport.psm1 -Settings ./.github/linters/.powershell-psscriptanalyzer.psd1
```

Expected: no output. Any output is a lint finding that will fail `lint.yml`.

## Adding new functions

Follow the existing conventions:

- **Singular noun** — `Export-DlpBaselineJson` not `Export-DlpBaselineJsons`.
- **Approved verb** — use `Get-Verb | Select-Object -ExpandProperty Group` to check. Unapproved verbs trigger a PSScriptAnalyzer warning.
- **`[OutputType(...)]`** attribute on every function — required by the linter settings.
- **`[CmdletBinding()]`** — all functions use it; keeps `Set-StrictMode -Version Latest` happy with advanced function binding.
- Add a `Describe` block in the appropriate `.Tests.ps1` file — at minimum test the happy path and an edge case.
- Export the new function in the `Export-ModuleMember` call at the bottom of `PurviewDlpExport.psm1`.

## Adding new volatile fields

If a new field is identified as volatile (changes between runs on an unchanged tenant), add it to `$script:VolatileFields` in `src/PurviewDlpExport.psm1` and add a test in `Normalise.Tests.ps1` under the "strips volatile fields" Describe block. The test should verify the field is absent from the normalised output, giving the next person a named regression guard.

## House rules

1. Keep `Set-StrictMode -Version Latest` and `$ErrorActionPreference = 'Stop'` in the entrypoint script.
2. No write cmdlets against Purview — ever. The grep recipe in [Troubleshooting](troubleshooting.md#read-only-verification) is the audit check.
3. PRs must be green on `test.yml` and `lint.yml` before review.
4. If you fix a footgun, add a note in [Troubleshooting](troubleshooting.md) so the next person doesn't hit it.
