# Quick start

## Prerequisites

- **PowerShell 7+.** The entrypoint script declares `#Requires`-equivalent checks at startup. macOS, Windows, and Linux all work.
- **`ExchangeOnlineManagement` module** (provides `Connect-IPPSSession`, `Get-DlpCompliancePolicy`, `Get-DlpComplianceRule`, and the SIT/label resolvers):

  ```powershell
  Install-Module ExchangeOnlineManagement -MinimumVersion 3.0 -Scope CurrentUser
  ```

- **Compliance Administrator or DLP Reader role** on the target tenant. Without one of these, `Get-DlpCompliancePolicy` returns 0 results and the tool throws with a clear message. See [Troubleshooting](troubleshooting.md#empty-inventory-error-0-policies-returned) if this happens.
- **`Pester` 5+** — only needed if you want to run the unit tests locally:

  ```powershell
  Install-Module Pester -Scope CurrentUser -SkipPublisherCheck
  ```

## Install

Clone the repo — the scripts run in place:

```bash
git clone https://github.com/LukeEvansTech/purview-dlp-export.git
cd purview-dlp-export
```

Verify the unit tests pass (no live tenant required):

```powershell
Invoke-Pester ./tests
# Expected: Tests Passed: 47
```

## Run

```powershell
./scripts/Export-PurviewDlp.ps1 `
    -UserPrincipalName admin@yourtenant.onmicrosoft.com `
    -Tenant yourtenant `
    -OutDir ./out
```

The script runs pre-flight checks (PowerShell version, module version, output directory), then connects interactively. You'll be prompted to authenticate — the same MFA flow as signing into the Microsoft Purview compliance portal.

Sample output after a successful run:

```text
Connecting to Purview as admin@yourtenant.onmicrosoft.com...
Fetching DLP inventory...
  policies: 12, rules: 47, referenced SITs: 18, referenced labels: 6
Wrote:
  ./out/baseline-20260522-yourtenant.json
  ./out/baseline-20260522-yourtenant.meta.json
  ./out/baseline-20260522-yourtenant.md
```

## What gets produced

Three files in `OutDir`:

| File | Description |
|---|---|
| `baseline-YYYYMMDD-<tenant>.json` | Byte-stable normalised ruleset body |
| `baseline-YYYYMMDD-<tenant>.meta.json` | Audit sidecar (timestamp, runner, tool version) |
| `baseline-YYYYMMDD-<tenant>.md` | Human-readable per-policy/per-rule narrative |

See [Output schema](output-schema.md) for the full structure of each file.

## Re-run / idempotency

Running the same command a second time on an unchanged tenant produces a byte-identical JSON body. The `.meta.json` sidecar gets a fresh timestamp — that's expected and intentional.

To verify this yourself:

```bash
# After first run:
cp out/baseline-YYYYMMDD-<tenant>.json out/baseline-YYYYMMDD-<tenant>.json.first

# Run again:
./scripts/Export-PurviewDlp.ps1 -UserPrincipalName admin@yourtenant.onmicrosoft.com -Tenant yourtenant -OutDir ./out

# Compare:
diff out/baseline-YYYYMMDD-<tenant>.json.first out/baseline-YYYYMMDD-<tenant>.json
# Expected: empty diff
```

!!! note "Same-day re-runs overwrite silently"
    The file name includes a `YYYYMMDD` datestamp, not a timestamp, so same-day re-runs overwrite the previous file. Because the JSON body is byte-identical on unchanged tenants this is safe. If you need to preserve multiple within-day captures, copy the file aside before re-running.
