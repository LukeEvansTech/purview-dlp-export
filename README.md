# purview-dlp-export

Read-only export of a Microsoft Purview DLP ruleset to a re-runnable, idempotent baseline.

Captures policies, rules, and the names of any sensitivity labels and Sensitive Information Types referenced by those rules. Emits a JSON body (byte-stable on unchanged tenants) plus a human-readable Markdown summary and a `.meta.json` sidecar containing audit metadata.

## Requirements

- PowerShell 7.x
- `ExchangeOnlineManagement` ≥ 3.x: `Install-Module ExchangeOnlineManagement -MinimumVersion 3.0 -Scope CurrentUser`
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

## Manual smoke test (week-1 bring-up)

The unit tests cover the normalisation and rendering logic but cannot exercise the live Purview cmdlets. After every meaningful change to `Connect-PurviewDlpSession` or `Get-DlpInventory`, run the smoke procedure below:

1. Open PowerShell 7. Confirm `ExchangeOnlineManagement` ≥ 3.0 is installed.
2. Create a clean output directory: `mkdir ./out-smoke`.
3. Run the export against the target tenant:

   ```powershell
   ./scripts/Export-PurviewDlp.ps1 `
       -UserPrincipalName admin@<tenant>.onmicrosoft.com `
       -Tenant <tenant-short-name> `
       -OutDir ./out-smoke
   ```

4. Authenticate when prompted (interactive MFA flow).
5. Verify three files were written: `baseline-YYYYMMDD-<tenant>.json`, `.meta.json`, and `.md`.
6. Re-run the same command immediately. Before the second run, copy the first JSON aside (e.g. `cp out-smoke/baseline-YYYYMMDD-<tenant>.json out-smoke/baseline-YYYYMMDD-<tenant>.json.first`). After the second run, compare:

   ```bash
   diff out-smoke/baseline-YYYYMMDD-<tenant>.json.first out-smoke/baseline-YYYYMMDD-<tenant>.json
   ```

   Expected: empty diff. If there's a diff, a field that should be stripped isn't — capture the diff and add the field to `$script:VolatileFields` in `src/PurviewDlpExport.psm1`, with a corresponding test in the strip-volatile-fields Describe block to lock it in.

7. Open the `.md` and skim for readability. The DLP Team should be able to read it without referring to the JSON.

If any step fails, do not commit a stale baseline. The output files should never be committed to this repo (see `.gitignore`); they belong with the engagement workspace.

## Read-only verification

To independently verify the tool only invokes write cmdlets against Purview, grep for any Purview-domain write verbs:

```bash
grep -E "(New|Set|Remove|Enable|Disable|Reset)-(Dlp|Compliance|Label|Sensitive|IPP)" src/PurviewDlpExport.psm1
```

Expected: no output. Any match is a bug — surface immediately.

Note: a naive grep for `Set-` or `Remove-` will surface false positives (`Set-StrictMode`, internal helpers like `Remove-VolatileFields`). The pattern above is scoped to Purview-domain noun prefixes only.
