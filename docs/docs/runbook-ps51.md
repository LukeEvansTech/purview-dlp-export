# End-to-end smoke test (Windows PowerShell 5.1)

A start-to-finish runbook for verifying a build against a **live tenant** on a locked-down **Windows PowerShell 5.1** box - the supported runtime target, and the box where byte-stability and parser-compatibility regressions actually surface.

Run this after any meaningful change to the impure boundary (`Connect-PurviewDlpSession`, `Get-DlpInventory`, or the entrypoint wiring), and during week-1 bring-up against a new tenant. The unit tests (`Invoke-Pester ./tests`) cover normalisation and rendering against fixtures, but cannot exercise the live Purview cmdlets - this procedure is how that boundary gets tested.

!!! note "Why the PS 5.1 variant"
    Byte-stability is only guaranteed **re-run-to-re-run on the same box**. Output is _not_ byte-identical across PowerShell 5.1 and 7 (different `ConvertTo-Json` escaping).
    The determinism check in step 6 must therefore run on the 5.1 machine. The verification commands below are PS-native (`Compare-Object`, `Select-String`) rather than
    the Bash `diff`/`grep` used elsewhere in the docs, because a hardened Windows box usually has no git-bash.

## 0. Confirm you are on 5.1

```powershell
$PSVersionTable.PSVersion      # Major 5, Minor 1
$PSVersionTable.PSEdition      # "Desktop" (PowerShell 7 reports "Core")
```

If this reports 7.x, launch **Windows PowerShell** (`powershell.exe`), not **PowerShell** (`pwsh.exe`).

## 1. One-time environment setup

PowerShell 5.1 needs three things PowerShell 7 provides for free: TLS 1.2 (PSGallery rejects the 5.1 default of SSL3/TLS 1.0), an execution policy that lets an unsigned local module load, and the `ExchangeOnlineManagement` module.

```powershell
# TLS 1.2 — required for Install-Module against PSGallery on 5.1 (this session only)
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Allow the local module + entrypoint to run this session (no admin, not persisted)
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

# Install the Exchange/IPPS module if absent (>= 3.0)
Get-Module ExchangeOnlineManagement -ListAvailable | Select-Object Name, Version
# If nothing >= 3.0 is present:
Install-Module ExchangeOnlineManagement -MinimumVersion 3.0 -Scope CurrentUser -Force
```

The authenticating account needs **Compliance Administrator** or **DLP Reader** on the tenant. Without it, `Get-DlpCompliancePolicy` returns _zero_ records (not an access-denied error), and the tool treats "0 policies" as a permissions signal and stops. See [Troubleshooting](troubleshooting.md#empty-inventory-error-0-policies-returned).

## 2. Read-only pre-flight

Prove the build cannot write to Purview _before_ pointing it at a live tenant:

```powershell
Select-String -Path .\src\PurviewDlpExport.psm1 `
    -Pattern '(New|Set|Remove|Enable|Disable|Reset)-(Dlp|Compliance|Label|Sensitive|IPP)'
```

Expected: **no output.** Any match is a bug - stop and surface it. The pattern is scoped to Purview-domain nouns, so it won't false-positive on `Set-StrictMode` or the internal `Remove-VolatileFields` helper.

## 3. Clean output directory + first run

```powershell
mkdir .\out-smoke -Force | Out-Null

.\scripts\Export-PurviewDlp.ps1 `
    -UserPrincipalName admin@<tenant>.onmicrosoft.com `
    -OutDir .\out-smoke
```

`-Tenant` is optional - it is inferred from the UPN (`admin@acme.onmicrosoft.com` → `acme`). Pass `-Tenant <short>` explicitly only for a vanity domain. Authenticate at the interactive MFA prompt when it appears.

## 4. Verify all five outputs were written

```powershell
Get-ChildItem .\out-smoke\baseline-*.* | Select-Object Name, Length
```

Expected: one date-stamped set of five files.

| File                                     | What it is                   |
| ---------------------------------------- | ---------------------------- |
| `baseline-YYYYMMDD-<tenant>.json`        | normalised, byte-stable body |
| `baseline-YYYYMMDD-<tenant>.meta.json`   | audit sidecar                |
| `baseline-YYYYMMDD-<tenant>-overview.md` | estate scan table            |
| `baseline-YYYYMMDD-<tenant>-detail.md`   | per-rule narrative           |
| `baseline-YYYYMMDD-<tenant>-matrix.csv`  | one row per rule, for Excel  |

If you get only `.json` + `.meta.json` + a single `.md`, the entrypoint is wired to the retired single-Markdown emitter - that is a bug.

## 5. Verify the tool version flowed through the manifest

```powershell
(Get-Content .\out-smoke\baseline-*.meta.json -Raw | ConvertFrom-Json).ToolVersion
```

Expected: the `ModuleVersion` in `src\PurviewDlpExport.psd1`. A `0.0` means the entrypoint loaded the `.psm1` directly instead of the `.psd1` manifest - flag it, do not commit the baseline.

## 6. Verify determinism (the core guarantee)

Re-run immediately and compare byte-for-byte. This is the property the whole normalisation pipeline exists to defend, and it can only be checked on this 5.1 box.

```powershell
# Snapshot the first body
$first = Get-ChildItem .\out-smoke\baseline-*-<tenant>.json |
    Where-Object { $_.Name -notlike '*.first*' } | Select-Object -First 1
Copy-Item $first.FullName "$($first.FullName).first"

# Re-run, same args
.\scripts\Export-PurviewDlp.ps1 `
    -UserPrincipalName admin@<tenant>.onmicrosoft.com `
    -OutDir .\out-smoke

# Compare (PS-native; no bash 'diff' needed)
$a = [IO.File]::ReadAllBytes("$($first.FullName).first")
$b = [IO.File]::ReadAllBytes($first.FullName)
if ($a.Length -eq $b.Length -and -not (Compare-Object $a $b)) {
    "IDENTICAL — determinism holds"
} else {
    "DRIFT — bodies differ"
    Compare-Object (Get-Content "$($first.FullName).first") (Get-Content $first.FullName)
}
```

Expected: **`IDENTICAL`.** If it drifts, a per-run field is leaking through. Capture the differing key, add it to `$script:VolatileFields` in `src\PurviewDlpExport.psm1`, and lock it in with a strip test in `tests\Normalise.Tests.ps1`.

!!! note "Absent-vs-null is not drift"
    Optional Purview properties that flip between _absent_ and _null_ across runs - `ContextPropertiesContainWords`, `GroupSet`, `appgroup` - are tenant-side noise,
    not a tool bug. See [Property-presence drift between runs](troubleshooting.md#property-presence-drift-between-runs).

## 7. Verify human readability

Open all three rendered outputs - the DLP team should understand each **without** reading the JSON:

```powershell
Invoke-Item .\out-smoke\baseline-*-overview.md   # estate scan
Invoke-Item .\out-smoke\baseline-*-detail.md     # per-rule conditions/actions in English
Invoke-Item .\out-smoke\baseline-*-matrix.csv    # opens in Excel
```

## 8. Cleanup

```powershell
Remove-Item .\out-smoke -Recurse -Force
```

Output files are **never committed** - `.gitignore` excludes `out*/`, and they belong with the engagement workspace. If any step above failed, do not commit a stale baseline.

## Pass criteria at a glance

- Step 2 grep returns nothing (read-only holds)
- Five files written (step 4)
- `ToolVersion` matches `ModuleVersion` in the `.psd1` (step 5)
- Re-run body is byte-identical (step 6)
- All three rendered outputs are readable standalone (step 7)
