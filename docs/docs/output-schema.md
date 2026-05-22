# Output schema

Every run produces three files. The JSON body is the machine-readable baseline; the meta sidecar is the audit trail; the Markdown summary is the human-readable narrative.

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

In the Markdown summary, orphan references render as `<orphan id=GUID>`. Surfacing orphans is deliberate — they are candidates for clean-up during realignment.

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

## Markdown summary — `baseline-YYYYMMDD-<tenant>.md`

Designed to be read by the DLP Team without opening the JSON. The document structure mirrors the JSON — same sort order, same data — but rendered as prose.

### Top-of-file counts

```markdown
# Purview DLP Baseline — acme

- Date: 20260522
- Policies: 12
- Rules: 47
```

### Per-policy section

One `## Policy: <Name>` heading per policy. Fields rendered: `Mode`, `Enabled`, `Workload`, `Priority`, and `Comment` (if present).

### Per-rule sub-section

One `### Rule: <Name>` heading per rule, nested under its parent policy. Fields rendered: `Mode`, `Priority`, `Disabled`, `Conditions`, `Actions`, exception clauses, and `Comment` (if present).

Conditions are rendered in plain English:

- SIT references: `SIT *AWS Access Key*`
- Label references: `label *Highly Confidential*`
- Keyword conditions: `keywords: card number, credit card, cvv`
- Multiple conditions joined with `OR`
- No conditions: `(no conditions)`

Actions are rendered as a semicolon-separated list: `block; notify: LastModifier, Owner; incident report: Owner`.

Orphan references render as `<orphan id=GUID>` — the angle-bracket form makes them visually distinctive.

### Sample

See [`examples/baseline-sample.md`](https://github.com/LukeEvansTech/purview-dlp-export/blob/main/examples/baseline-sample.md) for a complete rendered example covering all rule types (label-conditioned, SIT-conditioned, keyword-based, orphan reference, disabled rule, rule with exception clauses).
