# purview-dlp-export

Read-only export of a Microsoft Purview DLP ruleset to a re-runnable, idempotent baseline.

Captures policies, rules, and the names of any sensitivity labels and Sensitive Information Types referenced by those rules. Emits a JSON body (byte-stable on unchanged tenants), a `.meta.json` audit sidecar, and three layered human-readable outputs: an overview Markdown table, a detail Markdown narrative, and a CSV matrix for Excel analysis.

## Requirements

- PowerShell 5.1 or later (Windows PowerShell 5.1 supported)
- `ExchangeOnlineManagement` ≥ 3.x: `Install-Module ExchangeOnlineManagement -MinimumVersion 3.0 -Scope CurrentUser`
- An account with Compliance Administrator or DLP Reader role on the tenant

## Usage

```powershell
./scripts/Export-PurviewDlp.ps1 -UserPrincipalName admin@tenant.onmicrosoft.com -OutDir ./out
```

Only `-UserPrincipalName` is required. `-Tenant` is inferred from the UPN domain when omitted (e.g. `admin@acme.onmicrosoft.com` → `acme`), and `-OutDir` is created if it doesn't exist (defaults to the current directory).

Produces in `./out/`:

- `baseline-YYYYMMDD-<tenant>.json` — normalised body, byte-stable
- `baseline-YYYYMMDD-<tenant>.meta.json` — extract timestamp, runner, stripped-fields manifest
- `baseline-YYYYMMDD-<tenant>-overview.md` — one-table scan of all policies (workloads, mode, rule counts, detects)
- `baseline-YYYYMMDD-<tenant>-detail.md` — per-policy/per-rule narrative with conditions, actions, exceptions
- `baseline-YYYYMMDD-<tenant>-matrix.csv` — one row per rule for sorting and filtering in Excel

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
5. Verify five files were written: `baseline-YYYYMMDD-<tenant>.json`, `.meta.json`, `-overview.md`, `-detail.md`, and `-matrix.csv`.

6. Verify the meta sidecar records the correct tool version:

   ```bash
   cat out-smoke/baseline-*.meta.json | grep -i ToolVersion
   ```

   Expected: `"ToolVersion": "0.1.0"` (matching `ModuleVersion` in `src/PurviewDlpExport.psd1`). If it shows `"0.0"`, the entrypoint loaded the module via the `.psm1` directly instead of the manifest — flag as a bug, do not commit the baseline.

7. Re-run the same command immediately. Before the second run, copy the first JSON aside (e.g. `cp out-smoke/baseline-YYYYMMDD-<tenant>.json out-smoke/baseline-YYYYMMDD-<tenant>.json.first`). After the second run, compare:

   ```bash
   diff out-smoke/baseline-YYYYMMDD-<tenant>.json.first out-smoke/baseline-YYYYMMDD-<tenant>.json
   ```

   Expected: empty diff. If there's a diff, a field that should be stripped isn't — capture the diff and add the field to `$script:VolatileFields` in `src/PurviewDlpExport.psm1`, with a corresponding test in the strip-volatile-fields Describe block to lock it in.

8. Open the `-overview.md` for a quick scan of the estate. Open `-detail.md` to read any rule's conditions and actions in plain English. Open `-matrix.csv` in Excel to sort and filter rules across policies. The DLP Team should be able to read all three without referring to the JSON.

If any step fails, do not commit a stale baseline. The output files should never be committed to this repository (see `.gitignore`); they belong with the engagement workspace.

## Read-only verification

To independently verify the tool only invokes write cmdlets against Purview, grep for any Purview-domain write verbs:

```bash
grep -E "(New|Set|Remove|Enable|Disable|Reset)-(Dlp|Compliance|Label|Sensitive|IPP)" src/PurviewDlpExport.psm1
```

Expected: no output. Any match is a bug — surface immediately.

Note: a naive grep for `Set-` or `Remove-` will surface false positives (`Set-StrictMode`, internal helpers like `Remove-VolatileFields`). The pattern above is scoped to Purview-domain noun prefixes only.
