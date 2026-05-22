# Troubleshooting

Real issues encountered during development and bring-up, with resolution notes. If you hit something not on this list, please [open an issue](https://github.com/LukeEvansTech/purview-dlp-export/issues).

---

## Empty inventory error: "0 policies returned"

**Symptom:** The script throws immediately after connecting with:

```text
0 policies returned — check your account has Compliance Administrator or DLP Reader role on this tenant.
```

**Cause:** `Get-DlpCompliancePolicy` returns an empty result when the authenticated account doesn't have the right Purview role. It does not throw an "access denied" error — it silently returns zero records. The tool treats an empty policy list as a permissions signal rather than a genuinely empty tenant (a real-world tenant with no DLP policies is not a normal operating state).

**Resolution:** Verify the account holds **Compliance Administrator** or **DLP Reader** in the Microsoft Purview compliance portal:

1. Go to [compliance.microsoft.com](https://compliance.microsoft.com) → **Settings** → **Roles & scopes** → **Role groups**.
2. Search for "Compliance Administrator" or "DLP Reader".
3. Confirm the authenticating account is a member.

If you've just been added to the role, wait a few minutes for replication and re-authenticate (close and re-open the PowerShell session before running `Connect-IPPSSession` again — token caching can serve a stale session).

!!! note
    The same role check applies if you see "0 rules returned" — policies exist but the account can't enumerate rules. Same resolution.

---

## Property-presence drift between runs

**Symptom:** A `git diff` between two baselines of an unchanged tenant shows fields appearing or disappearing — properties like `ContextPropertiesContainWords`, `GroupSet`, or `appgroup` present in one run but absent in another.

**Cause:** Purview's compliance cmdlets occasionally include optional rule fields only when they are populated or only under certain tenant rollout states. The set of serialised properties is not guaranteed to be identical between PowerShell module versions or between API gateway nodes in a multi-region tenant. This is outside the tool's control.

**What to do:** Treat absent-vs-null changes in these optional properties as noise when reviewing diffs. The fields that matter for realignment analysis (`Mode`, `Enabled`, `Priority`, `Conditions`, `Actions`, `Disabled`, `Comment`, `ParentPolicyName`) are always present.

If a genuinely volatile field keeps appearing in body diffs, open an issue — we can evaluate adding it to `$script:VolatileFields` in `src/PurviewDlpExport.psm1`.

---

## `AllowEmptyCollection` error (pre-v0.1.0)

**Fixed in v0.1.0.** Earlier development builds threw on tenants that had no sensitivity labels referenced by any DLP rule — `Add-OrphanAnnotation` passed an empty array to a parameter that didn't carry `[AllowEmptyCollection()]`. If you see this error, update to v0.1.0 or later.

---

## Read-only verification

To independently confirm the tool only calls read cmdlets against Purview:

```bash
grep -E "(New|Set|Remove|Enable|Disable|Reset)-(Dlp|Compliance|Label|Sensitive|IPP)" src/PurviewDlpExport.psm1
```

Expected: no output. Any match is a bug — surface it immediately as an issue.

!!! note "Avoid over-broad grep patterns"
    A naive grep for `Set-` will produce false positives: `Set-StrictMode` (PowerShell standard) and `Remove-VolatileFields` (internal helper, not a Purview cmdlet). The pattern above is scoped to Purview-domain noun prefixes only, which avoids these false positives.

---

## Manual smoke procedure

Use this procedure after any meaningful change to `Connect-PurviewDlpSession` or `Get-DlpInventory`, and during initial week-1 bring-up against a new tenant.

1. Open PowerShell 7. Verify `ExchangeOnlineManagement` ≥ 3.0 is installed:

   ```powershell
   Get-Module ExchangeOnlineManagement -ListAvailable | Select-Object Name, Version
   ```

2. Create a clean output directory:

   ```powershell
   mkdir ./out-smoke
   ```

3. Run the export:

   ```powershell
   ./scripts/Export-PurviewDlp.ps1 `
       -UserPrincipalName admin@<tenant>.onmicrosoft.com `
       -Tenant <tenant-short-name> `
       -OutDir ./out-smoke
   ```

4. Authenticate when prompted (interactive MFA flow).

5. Verify three files were written: `baseline-YYYYMMDD-<tenant>.json`, `.meta.json`, and `.md`.

6. Verify the meta sidecar records the correct tool version:

   ```bash
   cat out-smoke/baseline-*.meta.json | grep -i ToolVersion
   ```

   Expected: `"ToolVersion": "0.1.0"`. If it shows `"0.0"`, the entrypoint loaded the module via the `.psm1` directly instead of the manifest — flag as a bug, do not commit the baseline.

7. Re-run the same command immediately. Copy the first JSON aside first:

   ```bash
   cp out-smoke/baseline-YYYYMMDD-<tenant>.json out-smoke/baseline-YYYYMMDD-<tenant>.json.first
   ```

   After the second run:

   ```bash
   diff out-smoke/baseline-YYYYMMDD-<tenant>.json.first out-smoke/baseline-YYYYMMDD-<tenant>.json
   ```

   Expected: empty diff. If there is a diff, a field that should be stripped isn't — capture it and add it to `$script:VolatileFields` in `src/PurviewDlpExport.psm1`, with a corresponding test.

8. Open the `.md` and skim for readability. The DLP Team should be able to read it without referring to the JSON.
