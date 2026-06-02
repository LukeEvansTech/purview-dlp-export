# Design: PowerShell 5.1 support + human-readable layered output

- Date: 2026-06-02
- Status: Approved (pending written-spec review)
- Branch: `feat/ps51-and-readable-output`

## Problem

Two requirements:

1. **Run on PowerShell 5.1.** The target box is locked down and has only Windows
   PowerShell 5.1 — no PowerShell 7. The tool currently hard-requires PS 7 and uses one
   PS 6+ only construct, so it will not run there.
2. **Make the output genuinely human-readable.** The owner needs to understand an
   inherited DLP ruleset — what rules exist and what they actually mean — by reading,
   starting from a high-level overview and drilling down into detail.

## Constraints & decisions

- **Environment:** the tool must *run* on PS 5.1; development and CI continue on PS 7.
  Code must be 5.1-safe, but the Pester suite runs on PS 7 only.
- **Byte-stability scope:** idempotency means byte-stable **re-run to re-run on the same
  box**. A baseline produced on PS 5.1 will *not* be byte-identical to one from PS 7
  (different `ConvertTo-Json` escaping/indentation); that is accepted.
- **Impure boundary untouched:** all new behaviour is rendering. `Get-DlpInventory`
  (the only tenant-touching function) does not change — the raw inventory already
  contains scope, the full `AdvancedRule` condition tree, and all action flags.
- **Rendering architecture:** compute a presentation **view model once**, then render
  thin (Approach C). Guarantees overview, detail, and CSV agree on what each rule means
  and keeps the interpretation logic unit-tested in one place.

## Architecture

```
Connect-PurviewDlpSession                       (impure: auth)
Get-DlpInventory                                (impure: tenant — UNCHANGED)
ConvertTo-NormalisedBaseline  → byte-stable JSON model   (UNCHANGED)
ConvertTo-DlpView             → presentation view model  (NEW, pure)
  ├─ Export-DlpOverviewMarkdown → ...-overview.md  (NEW, thin)
  ├─ Export-DlpDetailMarkdown   → ...-detail.md    (NEW, thin)
  └─ Export-DlpMatrixCsv        → ...-matrix.csv   (NEW, thin)
Export-DlpBaselineJson + .meta.json sidecar     (UNCHANGED)
```

- New file `src/PurviewDlpRender.psm1` holds `ConvertTo-DlpView`, the three emitters,
  and the interpretation helpers. `src/PurviewDlpExport.psm1` keeps connect/fetch/
  normalise/JSON. The entrypoint imports both manifests/modules.
- The existing combined `Export-DlpBaselineMarkdown` is **replaced** by the
  overview + detail pair.

## PowerShell 5.1 port (4 changes)

1. **Rewrite `Format-NormalisedKey`** to drop `ConvertFrom-Json -AsHashtable` (PS 6+ only).
   Parse JSON to `PSCustomObject`, then rebuild deep-sorted `[ordered]` hashtables using
   the existing explicit-stack iterative walk (no recursion — deep Purview structures
   overflow the call stack). `ConvertTo-Json` on an ordered hashtable preserves key order
   on both 5.1 and 7. This is the only hard incompatibility.
2. **`scripts/Export-PurviewDlp.ps1`:** invert the version gate — require **≥ 5.1**
   instead of throwing on `< 7`; drop the `#!/usr/bin/env pwsh` assumption.
3. **`src/PurviewDlpExport.psd1`:** `PowerShellVersion = '5.1'` (and add the new module if
   packaged with a manifest).
4. **Static safety net:** enable PSScriptAnalyzer `PSUseCompatibleSyntax` /
   `PSUseCompatibleCmdlets` (target 5.1) in `.github/linters/` so a 5.1-only regression is
   caught in CI even though tests run on PS 7.

## View model (`ConvertTo-DlpView`)

```
View
└─ Policies[]   (sorted by Priority, then Name)
   ├─ Name, Mode (Enforce / Test / Test+Notify), Enabled, Priority, Comment
   ├─ Workloads   → plain list: Exchange, SharePoint, OneDrive, Teams, Endpoint
   ├─ Scope       → per workload: Included[] / Excluded[] (users, groups, sites; "All" when unset)
   └─ Rules[]     (sorted by Priority, then Name)
      ├─ Name, Mode, Enabled, Priority, Comment
      ├─ DetectionSummary → short phrase, e.g. "Credit Card Number (high confidence, 10+ instances)"
      ├─ Conditions  → plain-English lines from the AdvancedRule tree: SIT/label names,
      │                confidence (low/med/high), instance counts (min–max), AND/OR/NOT grouping,
      │                plus sender/recipient/domain/file-type/doc-property conditions
      ├─ Actions     → block (everyone vs external-only), encrypt/RMS, restrict access,
      │                notify users + policy-tip text, user overrides, incident-report recipients
      └─ Exceptions  → except-if conditions, same plain-English style
```

Orphan SIT/label references (already flagged `Orphan = true` by the normaliser) render as
`<orphan id=…>` rather than being dropped, so dangling references in an inherited ruleset
stay visible.

## Outputs

All three are UTF-8 **no-BOM**, **LF** endings, deterministically ordered — same
byte-stability discipline as the JSON body.

### `...-overview.md` — scan tier
Header counts: total policies, total rules, enforce vs test counts, disabled count.
Then one table:

| Policy | Mode | Workloads | Rules | Detects (top SITs/labels) | Acts | Priority |

### `...-detail.md` — deep-dive tier
Per policy: mode / enabled / priority / comment + the **Scope** block in plain terms.
Per rule: DetectionSummary, full **Conditions** tree, full **Actions**, **Exceptions**, comment.

### `...-matrix.csv` — analysis tier
One row per rule. Columns:
`Policy, Rule, Workloads, Enabled, Mode, Priority, Detects, Conditions, Actions, Exceptions`.
Multi-value cells joined with `; ` so each rule is a single row.

## Testing

PS 7 Pester suite (existing cross-OS matrix), plus:

- **View-model tests** (`tests/View.Tests.ps1`): drive `ConvertTo-DlpView` from the
  existing `tests/fixtures/raw-purview-sample.json` and assert plain-English
  interpretation of conditions (confidence, instance counts, AND/OR), scope, actions,
  detection summary, and orphan rendering.
- **Renderer snapshot tests:** byte-for-byte snapshots for each output —
  `fixtures/expected-overview.md`, `fixtures/expected-detail.md`, `fixtures/expected-matrix.csv`.
  Replaces the single `expected.md` snapshot. Each asserts no-BOM + LF.
- **Determinism test:** overview/detail/CSV are byte-identical across two runs on the
  same input (mirrors the existing JSON two-run test).
- The fixture may need enriching to exercise the new condition/scope/action types; if so,
  enrich `raw-purview-sample.json` and regenerate all snapshots together.

## Out of scope

- Service-principal / certificate auth (still interactive only).
- Changing the JSON body or `.meta.json` schema.
- Cross-version (5.1 vs 7) byte-identical output.

## Manual verification

After implementation, run the README "Manual smoke test" on the **PS 5.1 target box**:
confirm the export runs to completion, the five files are written
(`json`, `meta.json`, `overview.md`, `detail.md`, `matrix.csv`), `ToolVersion` in the meta
sidecar matches the manifest, and a second run diffs empty against the first.
