---
name: dax-optimize
description: Lightweight Power BI DAX optimization workflow for Copilot. Use this when you need Microsoft Learn DAX evidence plus native PowerShell/.NET VertiPaq timing and model-structure analysis.
---

# DAX Optimize

This skill defines a lightweight optimization workflow for DAX authoring and review.

## Scope

- Runtime target: VS Code Copilot chat.
- No notebook dependencies.
- No third-party GUI tools required.
- Use only built-in/native components in this workflow:
    - `scripts/search_learn_dax_docs.py`
    - `scripts/capture_vertipaq_ai_timings.ps1` (PowerShell + .NET Analysis Services assemblies)

## Dependency Baseline

- Python 3.10+.
- Windows PowerShell 5.1 (the script auto-relaunches itself under `powershell.exe` for timing/apply operations; invoking via `pwsh` is supported but the actual work runs under 5.1).
- The timing and model-apply scripts are Windows-only. If the agent is running on macOS or Linux, stop and report `blocked: windows-only workflow` instead of attempting partial execution.
- Python package dependency from `requirements.txt`.
- Microsoft Analysis Services .NET assemblies required by `capture_vertipaq_ai_timings.ps1`.
- Full details in `DEPENDENCIES.md`.

## Required Workflow

1. Create or review the candidate DAX measure/query.
2. If the user gives a terse slash-style request such as `/dax-optimize connect to the open power bi file, and optimize the measure april sales`, expand it into the normal workflow instead of treating it as a literal command:
    - connect to the open model via auto-discovery,
    - if multiple PBIX/PBIT instances are open, use `-ListLocalInstances` and ask the user which one to target instead of guessing,
    - identify the target measure definition, using `-ListMeasures` when the measure name is known but the table or exact expression is not,
    - capture structure first if needed,
    - ask the output-mode question before writing DAX,
    - and only then run timing or rewrite steps.
3. If the request omits the exact measure table, DAX text, or output preference, do not guess; discover the measure first with `-ListMeasures` and ask only the missing question(s).

4. Ask the user which output mode they want before returning or applying DAX:
    - `file`: save as a `.dax` file in a workspace folder named `dax scripts` (create the folder if it does not exist).
    - `chat`: return DAX in chat as a code block.
    - `model`: apply directly to the open model using `scripts/capture_vertipaq_ai_timings.ps1 -ApplyMeasure -ConfirmApply -IAcknowledgeUserConsent -StructureOnly` (run timing in a separate follow-up command such as `-DaxQuery`).
    - In `model` mode, do not create a `.dax` artifact just because the DAX needs to be applied. Prefer `-MeasureExpression` for direct apply. If quoting is too complex and a file-backed expression source is needed, ask a separate explicit follow-up question before creating or using a `.dax` file. `model` output consent alone is not consent for a file-backed source.
    - **Hard rule**: `-ApplyMeasure`, `-ConfirmApply`, and `-StructureOnly` must never be passed unless the user explicitly answered `model` to this question. Skipping this question and proceeding with model apply is a critical workflow violation.
    - **Hard rule**: `-IAcknowledgeUserConsent` is an execution-consent token and must never be passed unless the user explicitly selected at least one eligible action: `model` output mode (for `-ApplyMeasure`) or `default file` / `custom file` findings mode (for `-WriteOutputFile` / `-OutputFile`).
5. File-backed expression source approval (model mode only):
    - Only applies when the user selected `model` in Step 4 and the candidate DAX has complex quoting that makes `-MeasureExpression` impractical.
    - Default: `no file-backed source` and re-craft the DAX to fit `-MeasureExpression`.
    - If the user explicitly answers `file-backed source`, then (and only then) call `scripts/write_dax_file.ps1` to materialize the `.dax` file under workspace `dax scripts/`, and use `-DaxFile <absolute path>` in the apply command.
    - **Hard rule**: Do not create a `.dax` file or pass `-DaxFile` to an apply command without this explicit user answer. `model` consent alone is not consent for a file-backed source.
6. Ask a separate explicit question before writing timing/findings JSON to disk:
    - `no file` (default): do not write findings files; return findings in chat.
    - `default file`: write to `<workspace root>/dax_outputs/<database>_vertipaq_ai_snapshot.json` (derived from script path, not current shell cwd) by passing `-WriteOutputFile -IAcknowledgeUserConsent`.
    - `custom file`: write to a user path by passing `-OutputFile <path> -IAcknowledgeUserConsent`.
    - **Hard rule**: `-WriteOutputFile` and `-OutputFile` must never be passed unless the user explicitly answered `default file` or `custom file` to this question. Skipping this question and writing a findings file is a critical workflow violation.
    - **Hard rule**: `-IAcknowledgeUserConsent` is an execution-consent token and must never be passed unless the user explicitly selected at least one eligible action: `model` output mode (for `-ApplyMeasure`) or `default file` / `custom file` findings mode (for `-WriteOutputFile` / `-OutputFile`).
7. Spawn a reviewer subagent for critique-only feedback using this verification protocol:
    - **When to spawn**: always, before producing the final DAX recommendation, for every optimization request that proposes a rewrite or model change. Skip only when the response is pure structure/metadata reporting with no recommended changes (e.g. plain `-StructureOnly` or `-ListMeasures` answers).
    - Before invoking, attempt to select a reviewer model whose name string clearly differs from the core model's name string (for example, Claude-family vs GPT-family vs Gemini-family).
    - Record in chat output: `core_model=<name>, reviewer_model=<name>, provider_distinct=<true|false|unknown>`.
    - Set `provider_distinct=true` only when the name strings clearly indicate different model-provider families; if this cannot be verified from the model names, use `provider_distinct=unknown`.
    - If `provider_distinct` is not `true`, the agent must label the result as `single-provider critique` and must not describe it as a cross-provider, independent, or second-opinion review.
8. Tell the reviewer subagent to critique only. It must not invent new PowerShell scripts, helper files, or command wrappers. If discovery is needed, it must reference the existing `-Help`, `-StructureOnly`, `-ListMeasures`, `-DaxQuery`, `-DaxFile`, and `-ApplyMeasure` paths only.
9. If there is disagreement between the core model and the reviewer subagent, run `scripts/search_learn_dax_docs.py` and use Microsoft Learn evidence to resolve the disagreement.
10. Run `scripts/capture_vertipaq_ai_timings.ps1` to auto-discover the open PBIX/PBIT endpoint, clear cache, and capture FE/SE timings.
11. Use `-StructureOnly` mode first when you need model understanding before benchmarking.
12. Use non-`-StructureOnly` mode to collect timing data for optimization decisions.
13. Use `-ListMeasures` when the task is measure discovery, when a user names a measure without exact location, or when a subagent starts inventing lookup code.
14. Revise DAX based on subagent feedback, documentation evidence, and FE/SE signals, then repeat as needed.
15. Always provide user-facing FE/SE quality feedback in plain language, including:
    - a verdict (`good`, `mixed`, or `bad`),
    - why the verdict was reached from root-level `formula_engine_ms` and `storage_engine_ms`,
    - what to change next (query rewrite and/or model change),
    - and links to Microsoft Learn pages to study the exact issue.

## Subagent Execution Guardrails

Use these rules whenever a lightweight/low-context subagent is invoked for execution-oriented discovery, timing, or apply probes. Critique-only reviewer subagents are exempt from command execution and must remain read-only.

1. The subagent must either execute the canonical command path or return `blocked` with a reason. It must not return a vague narrative.
2. Canonical command path for measure optimization requests:
    - Step 1: `capture_vertipaq_ai_timings.ps1 -AutoDiscover -ListMeasures [-MeasureSearch <name>] -Json`
    - Step 2: `capture_vertipaq_ai_timings.ps1 -AutoDiscover -DaxQuery '<query>' -Json` or `-DaxFile <path>`
    - If Step 1 returns multiple results, select the row where `is_exact_name_match` is `true`. Measures that only reference the target measure in their expression are dependents, not the optimization target, unless the user explicitly asks for them.
    - If Step 1 returns `count == 1` and that row has `is_exact_name_match = false`, stop and ask the user to disambiguate; the single hit is a dependent expression match, not the requested measure.
3. If any command fails, the subagent must return:
    - exact command string,
    - exact stderr/error text,
    - failing step name (`discover`, `measure_lookup`, `timing`, `apply_measure`),
    - and one safe retry using existing CLI options.
4. If no command was executed, the subagent must explicitly return `blocked: no command execution` and stop; do not claim optimization completed.
5. Never generate ad-hoc helper scripts (for example `apply-april-sales.ps1` or any custom `.ps1` file in the workspace root). Discovery must use `-ListMeasures` only.
6. **Never fabricate JSON output fields.** Every field reported (e.g. `measure_applied`, `timing_captured`, `formula_engine_ms`) must be quoted verbatim from actual script stdout. If the command was not run, those fields must not appear in the response. Reporting `measure_applied: true` without a successful `-ApplyMeasure` execution is a critical honesty violation.
7. **Never invent technical explanations for discrepancies.** If a claimed apply did not change the live model expression, report the actual stdout/stderr and stop. Do not construct rationalizations (e.g. "Power BI XMLA normalizes VAR expressions") to explain why a command that did not run produced no effect.
8. **Reviewer-provider claim integrity (critique-only reviewers).** Emit `core_model=<name>, reviewer_model=<name>, provider_distinct=<true|false|unknown>` in chat output. If `provider_distinct` is not `true`, label the review `single-provider critique` and do not call it cross-provider, independent, or second-opinion.

### Hard-Prohibited Patterns (observed failures)

These prohibitions apply to agents and ad-hoc scripts. They do NOT apply to the canonical scripts in `.github/skills/dax-optimize/scripts/`, which are the only sanctioned place for AMO / ADOMD / SQLPS / DMV calls.

These patterns have caused runaway behavior in prior probes. They are banned:

| Prohibited | Why | Correct alternative |
| --- | --- | --- |
| `Import-Module SQLPS` | Wrong stack for Analysis Services tabular models | Use `capture_vertipaq_ai_timings.ps1` only |
| `New-Object Microsoft.AnalysisServices.Server` / `$server.Disconnect()` | Direct AMO usage outside the canonical `capture_vertipaq_ai_timings.ps1` and `write_dax_file.ps1` scripts (the scripts themselves are allowed to use these APIs internally); produced errors | Use `capture_vertipaq_ai_timings.ps1 -AutoDiscover` |
| Creating any `.ps1` file (e.g. `apply-april-sales.ps1`) in the workspace root | Invents tooling outside the skill; breaks reproducibility | Use `capture_vertipaq_ai_timings.ps1 -ApplyMeasure -ConfirmApply -IAcknowledgeUserConsent -StructureOnly` with `-MeasureExpression` or, only after explicit file-backed-source approval, `-DaxFile` |
| Creating temporary `.dax` files anywhere in the workspace for benchmarking (e.g. `tmp_*.dax`, `candidate_v2.dax`) | Leaves file debris; user never approved these files | Use `-DaxQuery` inline. Use `write_dax_file.ps1` only when the user selected `file` output or explicitly approved a file-backed expression source; never create scratch files |
| Reporting `measure_applied: true` without an executed `-ApplyMeasure` command | Fabricated result; live model is not changed; user is misled | Only report fields that appear verbatim in captured script stdout |
| Passing `-WriteOutputFile` or `-OutputFile` without user consent (step 6) | Writes unrequested files to disk; violates `no file` default | Ask step-6 question; only pass these flags with `-IAcknowledgeUserConsent` when user selects `default file` or `custom file` |
| Passing `-ApplyMeasure` / `-ConfirmApply` without user consent (step 4) | Modifies the live Power BI model without authorization | Ask step-4 question; only pass these flags with `-IAcknowledgeUserConsent` when user selects `model` output mode |
| Passing `-ApplyMeasure` without `-ConfirmApply -IAcknowledgeUserConsent -StructureOnly` | Mixes live model apply with timing-mode execution and bypasses the script-level apply confirmation token | Always use `-ApplyMeasure -ConfirmApply -IAcknowledgeUserConsent -StructureOnly ...`, then run timing in a separate command |

## Output Interpretation

- `output_file` is populated only when the user opts in to writing findings JSON (`-WriteOutputFile` or `-OutputFile`).
- In default chat-first mode (no file write), use CLI JSON/stdout fields directly without relying on artifact files.
- `measure_applied: false` is the expected value for timing/query runs that did not pass `-ApplyMeasure`. It is not an error and must not trigger a remediation loop.
- DAX visual queries are resolved by both the Formula Engine (FE) and Storage Engine (SE).
- Engine roles:
    - FE generates query plans and can execute all DAX functions, including complex logic, but is single-threaded and has no cache.
    - SE serves as VertiPaq for Import models and as the relational source for DirectQuery models.
    - SE executes simple joins, grouping, filtering, aggregations, and distinct count.
    - SE can process data in parallel by segment (approximately 1M rows per segment).
- FE sends requests to SE; if SE has no matching cache, SE scans/computes data and returns caches to FE.
- Core optimization principle: maximize work pushed to SE and minimize the size of FE-operated caches.
- Use the root-level JSON fields `formula_engine_ms`, `storage_engine_ms`, and `total_elapsed_ms` to decide optimization direction:
    - `formula_engine_ms`: Total time spent in the Formula Engine (FE). This is the single-threaded part of DAX execution that handles complex logic and calculations.
    - `storage_engine_ms`: Total time spent in the Storage Engine (SE). This is the multi-threaded VertiPaq engine that scans, filters, and aggregates data.
    - `total_elapsed_ms`: The total wall-clock time for the query. In the default trace path, `formula_engine_ms = total_elapsed_ms - storage_engine_ms` by construction (so `formula_engine_ms + storage_engine_ms ≈ total_elapsed_ms`). In the counter-fallback path, FE/SE values are inferred and the relationship is approximate.
    - FE-heavy (`formula_engine_ms > storage_engine_ms`): prioritize iterator simplification, variable reuse, and reduced row-context transitions.
    - SE-heavy (`storage_engine_ms > formula_engine_ms`): prioritize model-level reductions (high-cardinality columns, filter path simplification, pre-aggregation).
- In default `-Json` stdout mode, use the flattened root-level model counts (`model_tables`, `model_columns`, `model_measures`, `model_relationships`) for model complexity context. Full `model_structure.counts` and `model_structure.relationships` are available only in the full findings artifact after the user explicitly opts into `-WriteOutputFile` or `-OutputFile`.
- If timing fields are null (structure-only mode), collect a non-structure-only run before making timing-based optimization claims.
- Every optimization response must include an explicit FE/SE assessment section with:
    - `Verdict`: `good`, `mixed`, or `bad`.
    - `Reason`: short explanation tied directly to FE vs SE timing balance.
    - `Next action`: one concrete DAX or model step.
    - `Learn more`: at least 2 Microsoft Learn links relevant to the issue.

### FE/SE Verdict Guidance

- `good`:
    - FE and SE are both low in absolute terms for the workload, or
    - one engine dominates but total elapsed time is still low and stable across reruns.
- `mixed`:
    - total time is acceptable but one engine is clearly the bottleneck and likely to regress with scale.
- `bad`:
    - total time is high, or FE/SE split indicates expensive patterns (heavy FE iterators/context transitions or large SE scans/high-cardinality pressure).

Use relative balance and absolute runtime together; do not classify solely by FE>SE or SE>FE.

### Required Learn Links (Microsoft Learn)

Choose links whose **title and topic directly match the diagnosed problem**. Do not include generic catch-all pages (`dax-overview`, `dax-function-reference`) unless no specific link applies to the issue.

| Diagnosed problem | Preferred link |
|---|---|
| VAR / variable caching, repeated measure references | https://learn.microsoft.com/dax/var-dax |
| General DAX best practices (use only when no specific link applies) | https://learn.microsoft.com/dax/best-practices/dax-best-practices |
| Row context / filter context / context transition | https://learn.microsoft.com/dax/dax-overview#row-context |
| CALCULATE / filter modification | https://learn.microsoft.com/dax/calculate-function-dax |
| Iterator overhead (SUMX, AVERAGEX, etc.) | https://learn.microsoft.com/dax/sumx-function-dax |
| Star schema / model structure | https://learn.microsoft.com/power-bi/guidance/star-schema |
| Relationship pressure / ambiguous paths | https://learn.microsoft.com/power-bi/transform-model/desktop-relationships-understand |
| DirectQuery SE overhead | https://learn.microsoft.com/power-bi/guidance/directquery-model-guidance |
| DAX overview (last resort only) | https://learn.microsoft.com/dax/dax-overview |

### Failure-Proof Invocation Rules

- Prefer `-DaxQuery` inline for benchmarking. Use `-DaxFile` only when the DAX already exists in an approved file source, or when the user selected `file` output / explicitly approved a file-backed source for complex quoting.
- When using `-DaxQuery`, wrap the entire query in single quotes at the shell level and keep DAX string literals in double quotes.
- If `pwsh ... -Json` appears to return no output in VS Code terminal capture, rerun the exact same command with `2>&1` first. If output is still blank, rerun directly with `powershell -File ...` before changing command shape or inventing a fallback.
- When using `-ApplyMeasure`, always pair it with `-ConfirmApply -StructureOnly`. Apply/update the measure first, then run a separate non-`-StructureOnly` timing command such as `-DaxQuery 'EVALUATE ROW("Measure", [Measure])'`.
- In `model` mode, prefer `-MeasureExpression` over `-DaxFile` so the selected output mode stays `model` rather than implicitly drifting into file-artifact behavior.
- When using `-DaxFile`, prefer an absolute path if the working directory may differ from the workspace root.
- Do not write direct ADOMD, AMO, SQLPS, or DMV lookup code outside the provided scripts; the canonical script handles Windows PowerShell compatibility for model operations.
- If a direct model query fails because of shell quoting, re-run with a file-based DAX source before changing the model or the measure. Do not create a new DAX file for retry unless the user selected `file` output or explicitly approved a file-backed source.
- Use `-StructureOnly` first for discovery, then a non-structure-only run for timing, rather than trying to infer FE/SE from structure alone.
- Use `-ListMeasures` for discovery when the user knows the measure name but you do not yet know the table or exact expression.
- If auto-discovery reports multiple open Power BI Desktop instances, stop and disambiguate with `-ListLocalInstances`, then rerun with `-PowerBIFileName`, `-PbixPath`, or explicit `-Server` / `-Database` before timing or applying changes (see README 'Multi-instance recovery example' for the exact recovery sequence).
- Never ask a subagent to create custom lookup scripts, custom PowerShell wrappers, or new CLI shims. Measure discovery must flow through `-ListMeasures` and existing helper commands only.
- When calling `write_dax_file.ps1`, pass `-OutputDir` as an **absolute path** to the workspace `dax scripts` folder. If omitted, the helper derives the workspace root from its script path and writes to that workspace folder. Relative `-OutputDir` values are rejected.
- Use `write_dax_file.ps1` only after the user explicitly selected `file` output mode or explicitly approved a file-backed expression source. Do not call it for internal scratch files, transient benchmarking files, or convenience-only quoting workarounds.
- Never pass parameters to `write_dax_file.ps1` that are not in its documented list (`-DaxText`, `-DaxFile`, `-OutputDir`, `-FileName`, `-MeasureName`, `-Force`, `-Json`). PowerShell will hard-fail with a binding error on any unrecognised parameter name.

### Reviewer Subagent Prompt Guardrail

When spawning a reviewer subagent, include a short instruction like this:

> Review the DAX only. Do not write any PowerShell, Python, or helper scripts. Do not create `.ps1` files. Do not use `Import-Module SQLPS`, `New-Object Microsoft.AnalysisServices.Server`, or any AMO/SQLPS patterns. Do not invent new commands. If you need measure discovery context, use `-ListMeasures` / `-Help` only.

For execution-oriented subagent probes, use this variant:

> Execute only the canonical dax-optimize CLI path in this exact order:
> 1. `pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -AutoDiscover -ListMeasures -MeasureSearch <name> -Json`
> 2. `pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -AutoDiscover -DaxQuery '<query>' -Json`
>
> If a step fails, return: exact command + exact error text + step name. If you execute no command, return `blocked: no command execution`. Never create helper `.ps1` files. Never use SQLPS or AMO Server objects directly.

### Interaction Examples

Use these examples as the default command shapes when the skill is invoked. Treat them as prompt-to-command templates, not just documentation.

#### Example 1: Connect to the open model and inspect structure

User request:

```text
/dax-optimize connect to the open power bi file and inspect the model
```

Execute:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
    -AutoDiscover `
    -StructureOnly `
    -Json
```

#### Example 2: User names a measure but not the table or expression

User request:

```text
/dax-optimize optimize the measure april sales
```

Execute discovery first:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
    -AutoDiscover `
    -ListMeasures `
    -MeasureSearch "April Sales" `
    -Json
```

Then ask only the missing questions:
- output mode: `chat`, `file`, or `model`
- findings file mode: `no file`, `default file`, or `custom file`

If discovery returns `count > 1`, select only the row where `is_exact_name_match` is `true`. If discovery returns `count == 1` and `is_exact_name_match = false`, stop and ask the user to disambiguate because the single hit is a dependent expression match. Results that only reference the measure in their expression are dependents and are not the optimization target unless the user explicitly asks for them.

#### Example 3: Benchmark a measure after discovery

User request:

```text
/dax-optimize optimize BW PM and return findings in chat
```

Execute timing capture with a query wrapper around the existing measure:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
    -AutoDiscover `
    -DaxQuery 'EVALUATE ROW("BW PM", [BW PM])' `
    -Json
```

#### Example 4: Apply optimized DAX directly to the open model

User request:

```text
/dax-optimize optimize BW PM and apply it to the model
```

After the user explicitly selects `model`, apply with a structure-only command:

```powershell
# Step 4 consent required: the user must have explicitly answered "model" before this command.
# Replace -MeasureTable with the exact table value returned by -ListMeasures.
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
    -AutoDiscover `
    -ApplyMeasure `
    -ConfirmApply `
    -IAcknowledgeUserConsent `
    -StructureOnly `
    -MeasureTable "Dim Date" `
    -MeasureName "BW PM" `
    -MeasureExpression "VAR AprilSales = [April Sales]`nVAR MaySales = [May Sales]`nRETURN`n    DIVIDE ( AprilSales - MaySales, AprilSales )" `
    -Json
```

Then benchmark the applied measure in a second command:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
    -AutoDiscover `
    -DaxQuery 'EVALUATE ROW("BW PM", [BW PM])' `
    -Json
```

#### Example 5: Output to file instead of model

User request:

```text
/dax-optimize optimize april sales and save the dax
```

After the user explicitly selects `file`, write the DAX artifact with the helper script:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/write_dax_file.ps1 `
    -MeasureName "April Sales" `
    -DaxText "CALCULATE ( SUM ( 'Fact Table'[order_val] ), 'Dim Date'[month] = 4 )" `
    -OutputDir "<absolute workspace path>\dax scripts" `
    -Json
```

#### Example 6: Complex quoting, use a file-backed expression source in model mode

User request:

```text
/dax-optimize apply this multiline dax to the model
```

If quoting is too complex for `-MeasureExpression`, a file-backed expression source is acceptable only after two separate approvals: the user must choose `model` output mode and must explicitly approve creating or using a file-backed expression source. `model` output consent alone is not enough.

```powershell
# Step 4 consent required: the user must have explicitly answered "model" before this command.
# Separate file-backed-source approval required before creating or using the .dax file below.
# Replace -MeasureTable with the exact table value returned by -ListMeasures.
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
    -AutoDiscover `
    -ApplyMeasure `
    -ConfirmApply `
    -IAcknowledgeUserConsent `
    -StructureOnly `
    -MeasureTable "Sales" `
    -MeasureName "Net Sales" `
    -DaxFile "<absolute workspace path>\dax scripts\Net Sales.dax" `
    -Json
```

#### Example 7: Findings file explicitly enabled

User request:

```text
/dax-optimize benchmark april sales and save the findings json
```

Only after the user explicitly selects `default file` or `custom file`, run one of these forms:

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
    -AutoDiscover `
    -DaxQuery 'EVALUATE ROW("April Sales", [April Sales])' `
    -WriteOutputFile `
    -IAcknowledgeUserConsent `
    -Json
```

```powershell
pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 `
    -AutoDiscover `
    -DaxQuery 'EVALUATE ROW("April Sales", [April Sales])' `
    -OutputFile "C:\path\to\april_sales_snapshot.json" `
    -IAcknowledgeUserConsent `
    -Json
```

#### Example 8: Slash-style terse prompt expansion checklist

For a terse request like:

```text
/dax-optimize connect to the open power bi file, and optimize the measure april sales
```

Always expand it into this sequence:
1. `-AutoDiscover -ListMeasures -MeasureSearch "April Sales" -Json`
2. If `count > 1`, select the exact `name` match and treat expression-only matches as dependents. If `count == 1` but `is_exact_name_match = false`, stop and ask the user to disambiguate.
3. Ask for output mode.
4. If output mode is `model` and quoting makes `-MeasureExpression` impractical, ask whether to use a file-backed expression source (default: no file-backed source).
5. Ask for findings-file mode.
6. If needed, run `-StructureOnly -Json` for model context.
7. If output mode is `model`, run `-ApplyMeasure -ConfirmApply -IAcknowledgeUserConsent -StructureOnly ...` first, then benchmark in a separate command with `-DaxQuery`.
8. If output mode is `chat` or `file`, run non-structure-only timing with `-DaxQuery` before returning or saving the rewrite.

### Response Template (Use In Every Timing-Based Reply)

Use this exact structure for non-`-StructureOnly` results. Render each section as shown — the DAX rewrite **must** be a fenced ` ```dax ` code block in the actual chat response, never indented prose or plain text.

**FE/SE Assessment**
Verdict: `<good|mixed|bad>`
Reason:
- FE ms: `<value>`
- SE ms: `<value>`
- Total elapsed ms: `<value>`
- Why this is good/mixed/bad for this query and model shape.

**Next Action**
- `<one concrete next DAX or model change>`
- If no change is needed, write: "No immediate action needed" and a one-line reason.

**Suggested Rewrite** (if needed)

```dax
<revised DAX — full expression ready to copy/paste — or "No rewrite needed" with one-line reason>
```

**Learn More (Microsoft Learn)**
1. `<link 1 — must directly match the diagnosed issue>`
2. `<link 2 — must directly match the diagnosed issue>`

Template rules:

- Always include all sections above when timing is captured.
- If values are null (structure-only), replace verdict with `insufficient timing data` and instruct to run non-structure-only capture.
- Keep reasons evidence-based and tied to measured FE/SE values.
- The `Suggested Rewrite` block must always be a fenced ` ```dax ` code block — never indented text or plain prose.
- `Next Action` may explicitly be `No immediate action needed` when performance is already good and stable.

## Implementation Standards

- Add short purpose comments above each major code block.
- Avoid noisy line-by-line comments.
- Keep scripts CLI-friendly and deterministic.
- Avoid notebook-only modules or APIs.
- Do not require third-party optimization tools in this skill path.

## Helper Scripts

- `scripts/search_learn_dax_docs.py`: Microsoft Learn DAX documentation search.
- `scripts/capture_vertipaq_ai_timings.ps1`: auto-discovery of open Power BI model endpoint, cache-clear-first FE/SE timing capture, Vertipaq/model-structure export for AI optimization, and metadata-preserving direct model measure create/update with `-ApplyMeasure -ConfirmApply -IAcknowledgeUserConsent -StructureOnly`.
- `scripts/write_dax_file.ps1`: writes DAX to timestamped `.dax` files in workspace folder `dax scripts` with safe filename normalization.
    - Use this helper only for explicit `file` output mode or a user-approved file-backed expression source. It is not a scratch-file helper for benchmarking or private agent retries.
  - Valid parameters (do **not** invent others — the script will hard-fail on unknown parameter names):
    - `-DaxText <string>` — inline DAX expression string
    - `-DaxFile <string>` — path to a `.dax` source file
    - `-OutputDir <string>` — absolute output folder (optional; omitted value defaults to workspace `dax scripts`; relative values are rejected)
    - `-FileName <string>` — override the base filename stem (optional; extension is forced to `.dax` and a timestamp is appended)
    - `-MeasureName <string>` — used to derive the output filename
    - `-Force` — overwrite an existing file. Filenames are always suffixed with a `yyyyMMdd_HHmmss` timestamp, so same-second collisions in a single folder are the only realistic scenario; `-Force` is rarely needed in normal use.
    - `-Json` — emit JSON result to stdout
  - **Never pass** `-MeasureTable`, `-Table`, `-Expression`, or any other invented parameter; they do not exist and will cause a hard failure.

## Measure Apply Mode

- Use direct model output mode with:
    - `-ApplyMeasure -ConfirmApply -IAcknowledgeUserConsent -StructureOnly -MeasureTable <table> -MeasureName <name>`
    - One expression source: `-MeasureExpression`, or `-DaxFile` only after explicit file-backed-source approval
- Optional measure metadata:
    - `-MeasureDescription`
    - `-MeasureFormatString`
    - `-MeasureHidden`

After a successful apply, run timing in a separate command using `-DaxQuery` or `-DaxFile` against the resulting measure/query. Do not try to apply and benchmark in the same invocation.

## Validation Checklist

1. Reviewer subagent is spawned and uses a different model provider than the core model when provider selection is available; otherwise the limitation is stated explicitly and the reviewer is still constrained to critique-only feedback.
2. Documentation evidence is fetched when core and subagent DAX recommendations disagree.
3. Endpoint discovery works without manually passing `-Server` in typical open-PBIX sessions.
4. Cache clear is performed before FE/SE timing capture unless user explicitly opts out. The opt-out flag is `-NoClearCache`; use it only when the user has explicitly asked for a warm-cache measurement (e.g. to characterize repeat-query behavior). Cold-cache (default) is the correct mode for diagnosing optimization opportunities. The JSON output's `cache_cleared_before_measurement` field reports the actual cold-cache state of the measured run.
5. Structure-only model extraction works when timing execution is not requested.
6. Every non-structure-only result includes FE/SE `good`/`mixed`/`bad` feedback with reasons and Microsoft Learn links.
7. If apply output includes `partial_success: true`, report that the measure was applied and post-apply inspection failed; treat `inspection_failed: true` as the machine-readable indicator for that state.
