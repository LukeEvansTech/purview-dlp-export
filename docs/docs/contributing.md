# Contributing

PRs welcome. The codebase is small — a PowerShell module, a thin entrypoint script, and Pester tests — and the design rationale is in the Git log and the [design spec](https://github.com/LukeEvansTech/purview-dlp-export/blob/main/docs/docs/output-schema.md).

## Repository layout

```text
purview-dlp-export/
  src/
    PurviewDlpExport.psm1     # module — four exported functions (fetch/normalise/emit JSON)
    PurviewDlpExport.psd1     # module manifest (sets ModuleVersion)
    PurviewDlpRender.psm1     # render module — view model + three human-readable emitters
  scripts/
    Export-PurviewDlp.ps1     # entrypoint — pre-flight, connect, fetch, normalise, emit
  tests/
    Normalise.Tests.ps1       # tests for ConvertTo-NormalisedBaseline
    ExportJson.Tests.ps1      # tests for Export-DlpBaselineJson
    View.Tests.ps1            # tests for ConvertTo-DlpView
    Overview.Tests.ps1        # tests for Export-DlpOverviewMarkdown
    Detail.Tests.ps1          # tests for Export-DlpDetailMarkdown
    Matrix.Tests.ps1          # tests for Export-DlpMatrixCsv
    Entrypoint.Tests.ps1      # tests for entrypoint wiring
    Ps51Compat.Tests.ps1      # guard: no PS 6+ -AsHashtable in .psm1 files
    fixtures/
      raw-purview-sample.json    # synthetic Purview inventory (all rule types)
      expected-overview.md       # locked overview Markdown snapshot (LF)
      expected-detail.md         # locked detail Markdown snapshot (LF)
      expected-matrix.csv        # locked CSV matrix snapshot (LF)
  examples/
    baseline-sample.md        # rendered sample for documentation
  docs/                       # this documentation site
```

## Running tests locally

```powershell
Invoke-Pester ./tests
# Expected: Tests Passed: 87
```

Tests are fixture-driven and require no live Purview connection — all tests run against synthetic inputs in `tests/fixtures/`.

The test suite covers:

- `ConvertTo-NormalisedBaseline` — idempotency, byte-stability, volatile-field stripping, sort order, orphan annotation, semantics preservation.
- `Export-DlpBaselineJson` — file is written, meta sidecar fields are correct, UTF-8 no BOM.
- `ConvertTo-DlpView` — shape, policy sort order, workload/mode mapping, condition/action rendering.
- `Export-DlpOverviewMarkdown` — file written, table contents, UTF-8 no BOM, byte-stability, snapshot match.
- `Export-DlpDetailMarkdown` — file written, confidence/instance-count rendering, orphan reference, byte-stability, snapshot match.
- `Export-DlpMatrixCsv` — file written, header columns, row count, byte-stability, snapshot match.
- Entrypoint wiring — references all three new emitters, does not call retired `Export-DlpBaselineMarkdown`.
- PS 5.1 compat guard — no `.psm1` file uses `ConvertFrom-Json -AsHashtable`.

## How the snapshot fixtures work

`tests/fixtures/expected-overview.md`, `expected-detail.md`, and `expected-matrix.csv` are locked snapshots. If you change an emitter in a way that alters its output, regenerate the relevant snapshot:

```powershell
# From repo root:
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

After regenerating, review the diff carefully — any change to a snapshot is a change to the documented output contract.

## LF line-ending policy

`.gitattributes` locks `tests/fixtures/expected-overview.md`, `expected-detail.md`, and `expected-matrix.csv` to LF line endings. All emitters normalise CRLF→LF at write time (`StringBuilder.AppendLine` emits `Environment.NewLine`, which is CRLF on Windows; the shared `Write-NoBomLf` helper in `PurviewDlpRender.psm1` replaces it). This means snapshots are byte-identical across OS.

Do not remove the `.gitattributes` entries for these fixtures — doing so will cause snapshot tests to fail on Windows.

## CI

Three workflows (none require live-tenant access):

- **`test.yml`** — Pester matrix on `ubuntu-latest`, `macos-latest`, `windows-latest`. All 87 tests run on every push.
- **`lint.yml`** — Super-Linter (PSScriptAnalyzer, yamllint, markdownlint, gitleaks, actions-lint) via `LukeEvansTech/shared-workflows`.
- **`docs.yml`** — Builds this documentation site and deploys to GitHub Pages on pushes to `main` that touch `docs/**`.

## Local lint check

Before pushing, run PSScriptAnalyzer against the module with the same settings CI uses:

```powershell
Invoke-ScriptAnalyzer -Path ./src/PurviewDlpExport.psm1 -Settings ./.github/linters/.powershell-psscriptanalyzer.psd1
Invoke-ScriptAnalyzer -Path ./src/PurviewDlpRender.psm1 -Settings ./.github/linters/.powershell-psscriptanalyzer.psd1
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
