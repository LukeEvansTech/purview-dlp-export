# Output schema

Every run produces five files. The JSON body is the machine-readable baseline; the meta sidecar is the audit trail; the three human-readable outputs (overview Markdown, detail Markdown, and CSV matrix) serve different reading audiences.

---

## JSON body — `baseline-YYYYMMDD-<tenant>.json`

The byte-stable normalised ruleset. Re-running on an unchanged tenant produces an identical file — this is the property that makes `git diff` of successive baselines a clean changelog.

### Top-level keys

| Key                | Type  | What it contains                                                                          |
| ------------------ | ----- | ----------------------------------------------------------------------------------------- |
| `Policies`         | Array | All DLP compliance policies in the tenant, sorted by `Name` ascending                     |
| `Rules`            | Array | All DLP compliance rules, sorted by `ParentPolicyName` then `Name` ascending              |
| `ReferencedSits`   | Array | `{ Id, Name }` pairs for every SIT referenced by any rule, sorted by `Name`               |
| `ReferencedLabels` | Array | `{ Id, Name }` pairs for every sensitivity label referenced by any rule, sorted by `Name` |

### Stripped (volatile) fields

The following fields are removed from every policy and rule record before writing. They change between runs on unchanged tenants and would produce false-positive diffs:

- `RunspaceId`
- `ETag`
- `WhenCreatedUTC`
- `WhenChangedUTC`
- `ObjectVersion`
- `ImmutableId`

The complete list is also recorded in the `.meta.json` sidecar (`StrippedFields` key) so you can audit exactly what was omitted.

### Byte-stability guarantee

The normaliser does four things to guarantee a stable body:

1. Strips the volatile fields listed above.
2. Backfills SIT and label names from the `AdvancedRule` JSON embedded in each rule (Purview stores the canonical condition representation there, even for rules created through the simple UI).
3. Deep-sorts all object keys alphabetically. Without this, Purview occasionally emits the same object with keys in a different order between calls.
4. Flattens Purview "enum-collision" pairs — objects of the form `{ "value": 3, "Value": "Enforce" }` — to just the string label (`"Enforce"`). These pairs are a Purview serialisation artefact; flattening them makes the output semantically stable.

### Sample rule shape

A representative rule object after normalisation:

```json
{
  "BlockAccess": true,
  "Comment": "Tier-1 credential SITs, enforced.",
  "ContentContainsSensitiveInformation": [
    {
      "Id": "50842eb5-1a3c-44a2-8aa4-1ae3a5e92c10",
      "Name": "AWS Access Key",
      "Orphan": false
    }
  ],
  "Disabled": false,
  "Mode": "Enable",
  "Name": "Block AWS Access Keys",
  "NotifyUser": ["LastModifier", "Owner"],
  "ParentPolicyName": "Block Credential Leakage",
  "Priority": 0
}
```

### Orphan references

If a rule references a SIT or label ID that no longer exists in the tenant (i.e. the SIT/label was deleted after the rule was created), the reference is annotated rather than dropped:

```json
{
  "Id": "sit-deleted-orphan-99999",
  "Name": null,
  "Orphan": true
}
```

In the detail Markdown and the CSV matrix, orphan references render as `<orphan id=GUID>`. Surfacing orphans is deliberate — they are candidates for clean-up during realignment.

---

## Meta sidecar — `baseline-YYYYMMDD-<tenant>.meta.json`

Written alongside the JSON body. Contains fields that vary per run and therefore cannot be in the stable body without breaking diff stability.

| Field                 | What it is                                                                        |
| --------------------- | --------------------------------------------------------------------------------- |
| `Tenant`              | The `-Tenant` argument passed to the entrypoint                                   |
| `RunnerUpn`           | The `-UserPrincipalName` argument (the account that authenticated)                |
| `ExtractTimestampUtc` | ISO 8601 UTC timestamp of when the extract ran                                    |
| `StrippedFields`      | Array of field names removed from the body — the complete volatile-field manifest |
| `ToolVersion`         | `ModuleVersion` from `src/PurviewDlpExport.psd1` at the time of the run           |

Example:

```json
{
  "Tenant": "acme",
  "RunnerUpn": "admin@acme.onmicrosoft.com",
  "ExtractTimestampUtc": "2026-05-22T12:02:44.3065740Z",
  "StrippedFields": [
    "RunspaceId",
    "ETag",
    "WhenCreatedUTC",
    "WhenChangedUTC",
    "ObjectVersion",
    "ImmutableId"
  ],
  "ToolVersion": "0.1.0"
}
```

---

## Overview Markdown — `baseline-YYYYMMDD-<tenant>-overview.md`

Designed for a quick scan of the full DLP estate. One header block with policy/rule counts, followed by one Markdown table row per policy.

### Header block

```markdown
# Purview DLP Overview - acme

- Date: 20260522
- Policies: 3 (2 enforce, 1 test)
- Rules: 12 (1 disabled)
```

### Policy table

Columns: `Policy`, `Mode`, `Workloads`, `Rules`, `Detects`, `Acts`, `Priority`.

- **Workloads** — raw Purview workload tokens mapped to friendly names (e.g. `OneDriveForBusiness` → `OneDrive`).
- **Detects** — unique detection summaries (SIT/label names) across all rules in the policy, semicolon-separated.
- **Acts** — unique action verbs across all rules, semicolon-separated.

---

## Detail Markdown — `baseline-YYYYMMDD-<tenant>-detail.md`

A full per-policy/per-rule narrative for deep reading. One `## Policy` section per policy and one `### Rule` sub-section per rule.

### Per-policy block

Fields: `Mode`, `Enabled`, `Priority`, `Applies to` (friendly workloads), included/excluded locations (if present), `Comment` (if present).

### Per-rule block

Fields: `Mode`, `Enabled`, `Priority`, `Detects` (one-line summary), then bulleted lists for `Conditions`, `Actions`, `Exceptions` (if any), and `Comment` (if present).

Conditions are rendered in plain English:

- SIT references: `SIT: AWS Access Key (high confidence, 1+ instances)`
- Label references: `Label: Highly Confidential`
- Keyword conditions: `Keywords: card number, credit card, cvv`
- File-extension conditions: `File extensions: doc, docx, pdf`
- No conditions: `(no conditions)`

Advanced-rule confidence and instance-count thresholds are rendered inline (e.g. `medium confidence, 10+ instances`). Orphan references render as `<orphan id=GUID>` — the angle-bracket form makes them visually distinctive.

---

## CSV matrix — `baseline-YYYYMMDD-<tenant>-matrix.csv`

One row per rule, suitable for sorting and filtering in Excel or any CSV viewer.

### Columns

| Column       | What it contains                                                                   |
| ------------ | ---------------------------------------------------------------------------------- |
| `Policy`     | Parent policy name                                                                 |
| `Rule`       | Rule name                                                                          |
| `Workloads`  | Friendly workload string from the parent policy                                    |
| `Enabled`    | `True` or `False`                                                                  |
| `Mode`       | Friendly mode string (`Enforce`, `Test (notify)`, `Test (silent)`, `Disabled`)     |
| `Priority`   | Rule priority integer                                                              |
| `Detects`    | One-line detection summary (SIT/label names, comma-separated)                      |
| `Conditions` | Full condition list (semicolon-separated, matches the detail Markdown bullet list) |
| `Actions`    | Full action list (semicolon-separated)                                             |
| `Exceptions` | Exception clauses (semicolon-separated), empty string if none                      |

All data fields are RFC-4180 quoted so commas and semicolons inside values never split a row. The header row is unquoted. Line endings are LF throughout.
