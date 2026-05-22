# purview-dlp-export

Read-only export of a Microsoft Purview DLP ruleset to a re-runnable, idempotent baseline. Captures policies, rules, and the names of any sensitivity labels and Sensitive Information Types referenced by those rules, then emits a byte-stable JSON body, a human-readable Markdown summary, and a `.meta.json` audit sidecar.

!!! note "Not affiliated with Microsoft"
"Microsoft Purview" and "Microsoft 365" are Microsoft trademarks. This tool calls public PowerShell cmdlets from the `ExchangeOnlineManagement` module and does not have any affiliation with Microsoft.

## What you get out

For every run against a connected Purview tenant, the tool writes three files to the output directory:

| File                                   | What it is                                                                                                                                                            |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `baseline-YYYYMMDD-<tenant>.json`      | Normalised, byte-stable ruleset body. Volatile fields stripped. Re-running on an unchanged tenant produces a byte-identical file — diffs over time are the changelog. |
| `baseline-YYYYMMDD-<tenant>.meta.json` | Audit sidecar. Varies per run: extract timestamp, runner UPN, tool version, list of stripped fields.                                                                  |
| `baseline-YYYYMMDD-<tenant>.md`        | Human-readable per-policy/per-rule narrative. Conditions and actions in plain English. Designed to be readable by the DLP Team without opening the JSON.              |

Full schema documented at [Output schema](output-schema.md). A rendered sample lives in [`examples/baseline-sample.md`](https://github.com/LukeEvansTech/purview-dlp-export/blob/main/examples/baseline-sample.md) in the repository.

## Where to next

- **First time?** → [Quick start](quickstart.md)
- **Understanding the output files?** → [Output schema](output-schema.md)
- **Hit an error?** → [Troubleshooting](troubleshooting.md)
- **Contributing or running tests?** → [Contributing](contributing.md)

## Why this exists

Before realigning a DLP ruleset against a benchmark, you need a stable record of what the ruleset currently looks like. Microsoft Purview's compliance portal gives you a live view, but no structured snapshot. This tool produces that snapshot.

The byte-stability guarantee matters: because an unchanged ruleset produces an identical JSON body on every run, `git diff` of successive baselines gives you a clean, noise-free view of what actually changed. Volatile metadata (timestamps, ETags, object versions) is in the sidecar — not in the body — so it doesn't pollute the diff.

The Markdown summary exists because "the DLP Team needs to read it". A JSON file is fine as a changelog, but the human sign-off step requires a format people can actually parse without tooling.

## License

[MIT](https://github.com/LukeEvansTech/purview-dlp-export/blob/main/LICENSE)
