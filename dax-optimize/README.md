# DAX Optimize Assets

This folder contains a lightweight DAX optimization skill workflow.

## Files

- `SKILL.md`: skill-level orchestration and guardrails.
- `DEPENDENCIES.md`: minimum Python/PowerShell/.NET dependency baseline.
- `requirements.txt`: Python package requirements.
- `scripts/search_learn_dax_docs.py`: Microsoft Learn DAX evidence search.
- `scripts/capture_vertipaq_ai_timings.ps1`: auto-discovery-by-default clear-cache FE/SE timing capture with Vertipaq snapshot export.
- `scripts/write_dax_file.ps1`: writes DAX into timestamped `.dax` files under workspace `dax scripts` with safe filename normalization.

This skill path intentionally avoids third-party optimization tools.

## Output Modes

When user asks for DAX output, ask which mode they want:

- `file`: write a `.dax` file under workspace folder `dax scripts` (create the folder if missing).
- `chat`: return DAX in chat as a code block.
- `model`: apply or update measure directly in the model using `capture_vertipaq_ai_timings.ps1 -ApplyMeasure -ConfirmApply -IAcknowledgeUserConsent -StructureOnly`.

In `model` mode, do not create a `.dax` artifact just because the DAX is being applied. Prefer `-MeasureExpression` for direct apply. If quoting is too complex and a file-backed expression source is needed, ask a separate explicit follow-up question before creating or using a `.dax` file. `model` output consent alone is not consent for a file-backed source.

Never use `-ApplyMeasure` or `-ConfirmApply` unless the user explicitly selected `model`, and pair them with `-IAcknowledgeUserConsent` and `-StructureOnly` whenever you do. `-StructureOnly` on its own (without `-ApplyMeasure`) is still allowed for read-only structure discovery. Never use `-WriteOutputFile` or `-OutputFile` unless the user explicitly selected a findings-file mode, and in those file-write cases also require `-IAcknowledgeUserConsent`.

When `-WriteOutputFile` is used without `-OutputFile`, the default findings path is `<workspace root>/dax_outputs/<database>_vertipaq_ai_snapshot.json`, where workspace root is derived from script location (`Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')`). It does not use the current shell working directory.

## File Output Helper

Write inline DAX to workspace `dax scripts`:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/write_dax_file.ps1 `
  -MeasureName "Net Sales" `
  -DaxText "Net Sales = SUM ( Sales[SalesAmount] )" `
  -OutputDir "<absolute workspace path>\dax scripts" `
  -Json
```

Write from an existing DAX file:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/write_dax_file.ps1 `
  -DaxFile ".\dax scripts\candidate.dax" `
  -FileName "net_sales_final" `
  -OutputDir "<absolute workspace path>\dax scripts" `
  -Json
```

Use `write_dax_file.ps1` only when the user selected `file` output mode or explicitly approved a file-backed expression source. Do not use it for internal scratch files, transient benchmarking files, or convenience-only quoting workarounds.

## Setup

```bash
python -m pip install -r .github/skills/dax-optimize/requirements.txt
```

For minimum versions and PowerShell/.NET prerequisites, see `DEPENDENCIES.md`.

## Install Guide

1. Install Python 3.10+ and ensure `python` is on PATH.
1. Install Python package requirements:

```bash
python -m pip install -r .github/skills/dax-optimize/requirements.txt
```

1. Ensure Windows PowerShell 5.1 is available. The script auto-relaunches under `powershell.exe` for timing/apply operations even when invoked via `pwsh`.

```powershell
pwsh -NoProfile -Command "$PSVersionTable.PSVersion"
```

1. Ensure Microsoft Analysis Services client libraries are installed (ADOMD.NET 160+).
1. Verify assemblies can be loaded from common locations:

```powershell
pwsh -NoProfile -Command "@(
  'C:\Program Files\Microsoft.NET\ADOMD.NET\160\Microsoft.AnalysisServices.AdomdClient.dll',
  'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Microsoft.AnalysisServices\v4.0_15.0.0.0__89845dcd8080cc91\Microsoft.AnalysisServices.dll',
  'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Microsoft.AnalysisServices.Core\v4.0_15.0.0.0__89845dcd8080cc91\Microsoft.AnalysisServices.Core.dll'
) | ForEach-Object { '{0} => {1}' -f $_, (Test-Path $_) }"
```

1. Run a lightweight smoke test:

```bash
python .github/skills/dax-optimize/scripts/search_learn_dax_docs.py "calculate filter context" --top 3
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -AutoDiscover -StructureOnly -Json
```

## Quick Commands

```bash
python .github/skills/dax-optimize/scripts/search_learn_dax_docs.py "calculate filter context" --top 8
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -AutoDiscover -StructureOnly -Json
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -Help
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -AutoDiscover -DaxQuery 'EVALUATE ROW("Net Sales", [Net Sales])' -Json
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -ListLocalInstances -Json
```

## CLI Help

Use `-Help` when the prompt is terse, ambiguous, or has quoting problems. The help output explains:

- how to discover the open model,
- how to pass DAX safely,
- how to disambiguate open Power BI Desktop instances,
- how to discover measures with `-ListMeasures`,
- how to apply a measure directly or from an approved file-backed source,
- and when to use `-StructureOnly` or `-WriteOutputFile`.

## Measure Discovery

When the model or prompt only gives a measure name, use `-ListMeasures` before inventing any lookup script or guessing the exact table:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -AutoDiscover `
  -ListMeasures `
  -Json
```

To narrow the list, add `-MeasureSearch`:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -AutoDiscover `
  -ListMeasures `
  -MeasureSearch "April" `
  -Json
```

## Hard-Prohibited Patterns

These patterns appeared in subagent probe runs and produced errors. They are banned:

| Prohibited | Why | Correct replacement |
| --- | --- | --- |
| `Import-Module SQLPS` | Wrong stack; Analysis Services tabular models do not use SQLPS | Use `capture_vertipaq_ai_timings.ps1 -AutoDiscover` |
| `New-Object Microsoft.AnalysisServices.Server` / `$server.Disconnect()` | Ad hoc AMO object model code outside the provided script bypasses the supported workflow and has caused runtime errors | Use `capture_vertipaq_ai_timings.ps1 -AutoDiscover` |
| Creating any `.ps1` file in the workspace root (e.g. `apply-april-sales.ps1`) | Invents tooling outside skill scope; breaks reproducibility | Use `capture_vertipaq_ai_timings.ps1 -ApplyMeasure -ConfirmApply -IAcknowledgeUserConsent -StructureOnly` with `-MeasureExpression` or, only after explicit file-backed-source approval, `-DaxFile` |

---

## Failure-Proof Examples

Use these patterns when you need to avoid quoting or runtime-compatibility issues.

### 1. Discover the open model without timing

Prefer structure-only discovery first:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -AutoDiscover `
  -StructureOnly `
  -Json
```

If the user gives a terse slash-style request like `/dax-optimize connect to the open power bi file, and optimize the measure april sales`, expand it into the normal workflow instead of treating it as a literal shell command. In practice that means: discover the open model, identify the `April Sales` measure, ask for output mode if you need to return or apply DAX, and then run timing capture.

If measure discovery is needed, use the canonical `-ListMeasures` path instead of writing direct ADOMD, AMO, SQLPS, or custom lookup code:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -AutoDiscover `
  -ListMeasures `
  -MeasureSearch "April" `
  -Json
```

### 2. Pass DAX safely on the command line

When sending a DAX query inline, wrap the whole DAX string in single quotes so inner DAX double quotes survive unchanged:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -AutoDiscover `
  -DaxQuery 'EVALUATE ROW("April Sales", [April Sales])' `
  -Json
```

If the query contains multiple quotes, line breaks, or nested string literals, prefer `-DaxQuery` inline when practical. Use `-DaxFile` only when the DAX already exists in an approved file source, or when the user selected `file` output / explicitly approved a file-backed source for complex quoting.

### 3. Apply a measure safely

Apply/update in one structure-only command, then benchmark in a separate timing command:

Only run this command after the user explicitly selects `model` as the DAX output mode.

Prefer `-MeasureExpression` for direct model apply:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -AutoDiscover `
  -ApplyMeasure `
  -ConfirmApply `
  -IAcknowledgeUserConsent `
  -MeasureTable "Sales" `
  -MeasureName "April Sales" `
  -MeasureExpression "SUM ( Sales[AprilAmount] )" `
  -StructureOnly `
  -Json
```

Use `-DaxFile` for model apply only after the user separately approves a file-backed expression source. Keep `-ConfirmApply -IAcknowledgeUserConsent -StructureOnly` on the apply command.

Then run timing separately:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -AutoDiscover `
  -DaxQuery 'EVALUATE ROW("April Sales", [April Sales])' `
  -Json
```

### 4. Complex quoting without scratch files

If a command is hard to quote correctly, do not create a scratch `.dax` file. Use inline `-DaxQuery` where practical. Use `write_dax_file.ps1` only when the user selected `file` output or explicitly approved a file-backed expression source, then reuse that approved file for timing or apply operations.

Use `-PowerBIFileName` to match the target open Power BI Desktop model by file name/window title (MCP-style instance matching):

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -AutoDiscover `
  -PowerBIFileName "Sales Model" `
  -StructureOnly `
  -Json
```

If more than one PBIX/PBIT is open, `-AutoDiscover` fails rather than guessing. Run `-ListLocalInstances -Json`, then rerun with `-PowerBIFileName`, `-PbixPath`, or explicit `-Server` / `-Database`.

### Multi-instance recovery example

```powershell
# 1) List open local instances
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -ListLocalInstances -Json

# Example JSON response (script returns this shape; keys are snake_case)
{
  "count": 2,
  "instances": [
    {
      "process_id": 12345,
      "port": 51234,
      "server": "localhost:51234",
      "pbix_path": "C:\\Reports\\Sales.pbix",
      "parent_window_title": "Sales - Power BI Desktop"
    },
    {
      "process_id": 67890,
      "port": 59876,
      "server": "localhost:59876",
      "pbix_path": "C:\\Reports\\Finance.pbix",
      "parent_window_title": "Finance - Power BI Desktop"
    }
  ]
}

# 2a) Follow-up choice: disambiguate by file name (matches the pbix_path stem)
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -AutoDiscover `
  -PowerBIFileName Sales `
  -StructureOnly `
  -Json

# 2b) Follow-up choice: target explicit server from the listed instance
#     (database is resolved automatically from the server; pass -Database only if multiple databases live on the same instance)
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -Server localhost:51234 `
  -StructureOnly `
  -Json
```

If the user does not specify which instance, ASK before proceeding.

## JSON Output Schema (top-level fields)

When `-Json` is passed, the script writes a single JSON object to stdout. The agent consumes these fields verbatim — do not paraphrase, infer missing fields, or fabricate values.

Key top-level fields (always present, may be `null` when not applicable):

- `output_file` — absolute path of the snapshot file written (or `null` when `-OutputFile` was suppressed).
- `discovered_server` / `discovered_database` / `discovered_pbix_path` — endpoint actually used.
- `cache_cleared_before_measurement` — boolean; true only when the timed run was preceded by a successful cache clear. Mirrors the `-NoClearCache` opt-out and any fallback re-clear.
- `timing_captured` — boolean; true only when FE/SE timings were measured (false for `-StructureOnly` or pure metadata flags).
- `measure_applied` — boolean; true only when `-ApplyMeasure -ConfirmApply -IAcknowledgeUserConsent` actually wrote a measure. Never report `true` without a successful apply.
- `measure_target` — `Table[Measure]` string of the applied measure, or `null`.
- `model_tables` / `model_columns` / `model_measures` / `model_relationships` — counts from the structure snapshot.
- `total_elapsed_ms` / `storage_engine_ms` / `formula_engine_ms` — root-level timing numbers used for the FE/SE verdict.

Nested objects the agent commonly consumes:

- `timings.trace_correlation` — correlation diagnostics object with fields: `runid_marker_matched`, `normalized_text_fallback_used`, `time_window_filter_applied`, `noise_filter_applied`, `target_session_id`, `target_request_id`, `target_activity_id`, `events_before_correlation`, `events_after_correlation`, `confidence` (`high` / `medium` / `low`), and `warnings[]`.
- `vertipaq_snapshot` — column- and table-level cardinality, size, and encoding details from the model structure capture.
- `no_matches_for_search` — only present when `-ListMeasures -MeasureSearch` returns zero hits; contains `search`, `total_measures_in_model`, `suggestions[]` (up to 10), and `guidance`.

The `-ListLocalInstances` flag emits a different top-level shape: `{ "count": <int>, "instances": [ { ...snake_case instance fields... } ] }` — see the "Multi-instance recovery example" block above.

## Direct Model Measure Apply

Apply or update a measure directly in the open model:

Only run these commands after the user explicitly selects `model` as the DAX output mode.

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -ApplyMeasure `
  -ConfirmApply `
  -IAcknowledgeUserConsent `
  -StructureOnly `
  -MeasureTable "Sales" `
  -MeasureName "Net Sales" `
  -MeasureExpression "SUM ( Sales[SalesAmount] )" `
  -Json
```

Use a `.dax` file as expression source:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
  -ApplyMeasure `
  -ConfirmApply `
  -IAcknowledgeUserConsent `
  -StructureOnly `
  -MeasureTable "Sales" `
  -MeasureName "Net Sales" `
  -DaxFile "<absolute workspace path>\dax scripts\Net Sales.dax" `
  -Json
```
