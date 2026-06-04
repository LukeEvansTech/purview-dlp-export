# Running the export

A practical, start-to-finish guide to running the Purview DLP export — including on a locked-down **Windows PowerShell 5.1** box, which is the supported runtime target.

## 1. Prerequisites

- **PowerShell 5.1 or later.** Windows PowerShell 5.1 (built into Windows) is supported; PowerShell 7 also works. Check your version:

  ```powershell
  $PSVersionTable.PSVersion
  ```

  The script runs a pre-flight check and stops with a clear message if it's older than 5.1.

- **`ExchangeOnlineManagement` module ≥ 3.0** — provides `Connect-IPPSSession`, `Get-DlpCompliancePolicy`, `Get-DlpComplianceRule`, and the SIT/label resolvers:

  ```powershell
  Install-Module ExchangeOnlineManagement -MinimumVersion 3.0 -Scope CurrentUser
  ```

  Check what you have: `Get-Module ExchangeOnlineManagement -ListAvailable | Select-Object Version`

- **Compliance Administrator or DLP Reader role** on the target tenant. Without one, `Get-DlpCompliancePolicy` returns 0 results and the tool stops with an explanatory error (see [Troubleshooting](troubleshooting.md#empty-inventory-error-0-policies-returned)).

!!! note "On a locked-down box"
`Install-Module ... -Scope CurrentUser` installs into your profile and does **not** need admin rights. If the box blocks the PowerShell Gallery, ask whoever manages it to pre-install `ExchangeOnlineManagement` ≥ 3.0, or copy the module folder into one of your `$env:PSModulePath` directories. Nothing else needs installing — the tool is plain script files, no build step.

## 2. Get the tool onto the box

The scripts run in place — there is no build or install step:

```powershell
git clone https://github.com/LukeEvansTech/purview-dlp-export.git
cd purview-dlp-export
```

If `git` isn't available on the box, copy the repository folder across however you normally move files (the only directories the run needs are `scripts/` and `src/`).

## 3. Run it

Only `-UserPrincipalName` is required:

```powershell
./scripts/Export-PurviewDlp.ps1 -UserPrincipalName admin@yourtenant.onmicrosoft.com
```

| Parameter            | Required | What it is                                                                                                                               |
| -------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `-UserPrincipalName` | yes      | The admin account you authenticate as (MFA is prompted)                                                                                  |
| `-Tenant`            | no       | Short label used in the output filenames. Inferred from the UPN domain if omitted (e.g. `admin@codelooks.onmicrosoft.com` → `codelooks`) |
| `-OutDir`            | no       | Where the files are written. Created if it doesn't exist; defaults to the current directory                                              |

The script runs pre-flight checks (PowerShell version, module version), creates the output directory if needed, and infers the tenant label from the UPN when `-Tenant` is not given. It then opens the interactive sign-in — the same MFA flow as signing into the Microsoft Purview compliance portal. Complete the prompt and it fetches and writes.

Sample output after a successful run:

```text
Connecting to Purview as admin@yourtenant.onmicrosoft.com...
Fetching DLP inventory...
  policies: 12, rules: 47, referenced SITs: 18, referenced labels: 6
Wrote:
  ./out/baseline-20260602-yourtenant.json
  ./out/baseline-20260602-yourtenant.meta.json
  ./out/baseline-20260602-yourtenant-overview.md
  ./out/baseline-20260602-yourtenant-detail.md
  ./out/baseline-20260602-yourtenant-matrix.csv
```

## 4. What you get — and how to read it

Five files land in `OutDir`. The three new human-readable ones are designed to be read **top-down**:

| File                     | Read it for…                                                                                                                                                                                         |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `…-overview.md`          | **Start here.** One table — every policy with its workloads, mode, rule count, and what it detects. Scan the whole estate on one screen.                                                             |
| `…-detail.md`            | **Then drill in.** Per policy and per rule in plain English: scope, conditions (with confidence and instance counts), actions, exceptions. This is where you understand what a rule actually _does_. |
| `…-matrix.csv`           | **For analysis.** One row per rule — open in Excel to sort/filter across all policies (e.g. "show every rule that blocks", "every rule touching credit-card SITs").                                  |
| `…-baseline-….json`      | The byte-stable machine baseline (everything captured, nothing summarised). Used for diffing tenants over time.                                                                                      |
| `…-baseline-….meta.json` | Audit sidecar — extract timestamp, who ran it, tool version, stripped-fields manifest.                                                                                                               |

Orphaned references (a rule pointing at a SIT or label that no longer exists) are shown as `<orphan id=…>` rather than hidden — those are clean-up candidates. See [Output schema](output-schema.md) for the full structure of each file.

## 5. Re-run / idempotency

Running the same command again on an **unchanged** tenant produces a **byte-identical** JSON body — that's the point of the baseline. The `.meta.json` sidecar gets a fresh timestamp (expected). Verify it yourself:

```powershell
# After the first run, copy the JSON aside:
Copy-Item ./out/baseline-20260602-yourtenant.json ./out/first.json

# Run again, then compare:
./scripts/Export-PurviewDlp.ps1 -UserPrincipalName admin@yourtenant.onmicrosoft.com -Tenant yourtenant -OutDir ./out
Compare-Object (Get-Content ./out/first.json) (Get-Content ./out/baseline-20260602-yourtenant.json)
# Expected: no output (identical)
```

!!! note "Byte-stability is per-box"
Re-runs are byte-identical on the **same** machine. A baseline produced on Windows PowerShell 5.1 will differ slightly from one produced on PowerShell 7 (different JSON formatting) — that's expected and doesn't affect same-box diffing.

!!! note "Same-day re-runs overwrite silently"
Filenames carry a `YYYYMMDD` datestamp, not a time. Same-day re-runs overwrite the previous files; because the JSON body is byte-identical on unchanged tenants this is safe. Copy files aside first if you need multiple within-day captures.

## 6. A note on safety

The tool is **read-only** — it calls only `Get-*` cmdlets against Purview and never creates, changes, or deletes anything. The output files contain real tenant configuration; keep them with the engagement workspace and don't commit them to this repository (`.gitignore` already excludes `baseline-*` outputs).

## Optional: run the unit tests

Only needed if you're changing the code; no live tenant required. Requires `Pester` 5+ (`Install-Module Pester -Scope CurrentUser -SkipPublisherCheck`):

```powershell
Invoke-Pester ./tests
# Expected: Tests Passed: 101
```
