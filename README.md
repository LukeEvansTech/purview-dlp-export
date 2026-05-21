# purview-dlp-export

Read-only export of a Microsoft Purview DLP ruleset to a re-runnable, idempotent baseline.

Captures policies, rules, and the names of any sensitivity labels and Sensitive Information Types referenced by those rules. Emits a JSON body (byte-stable on unchanged tenants) plus a human-readable Markdown summary and a `.meta.json` sidecar containing audit metadata.

## Requirements

- PowerShell 7.x
- `ExchangeOnlineManagement` ≥ 3.x: `Install-Module ExchangeOnlineManagement -MinimumVersion 3.0`
- An account with Compliance Administrator or DLP Reader role on the tenant

## Usage

```powershell
Import-Module ./src/PurviewDlpExport.psm1
./scripts/Export-PurviewDlp.ps1 -UserPrincipalName admin@tenant.onmicrosoft.com -Tenant acme -OutDir ./out
```

Produces in `./out/`:

- `baseline-YYYYMMDD-<tenant>.json` — normalised body, byte-stable
- `baseline-YYYYMMDD-<tenant>.meta.json` — extract timestamp, runner, stripped-fields manifest
- `baseline-YYYYMMDD-<tenant>.md` — readable per-policy/per-rule narrative

## Development

```powershell
Invoke-Pester ./tests
```

No live tenant required for unit tests — they run entirely against fixtures.

## Read-only guarantee

This tool calls only `Get-*` cmdlets. It never invokes `New-`, `Set-`, `Remove-`, or `Enable-` against Purview. Inspect `src/PurviewDlpExport.psm1` to verify.
