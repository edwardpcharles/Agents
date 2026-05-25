# Dependencies

## Platform support

The DAX timing and model-apply workflow (`capture_vertipaq_ai_timings.ps1`, `write_dax_file.ps1`) is **Windows-only**. It requires: Windows PowerShell 5.1 or PowerShell 7+ on Windows; Power BI Desktop running locally for auto-discovery; ADOMD.NET 160+ and AMO assemblies (typically GAC-installed on Windows). macOS and Linux are NOT supported for the PowerShell scripts. The Microsoft Learn docs search helper (`search_learn_dax_docs.py`) is cross-platform.

## Python

- Minimum Python version: 3.10+
- Minimum pip package requirements:
  - requests>=2.31.0

Install Python dependency:

```bash
python -m pip install -r .github/skills/dax-optimize/requirements.txt
```

Verify Python runtime:

```bash
python --version
python -c "import requests; print(requests.__version__)"
```

## PowerShell and .NET

- Required runtime: Windows PowerShell 5.1 (the timing/apply path auto-relaunches under `powershell.exe`). PowerShell 7+ can be the launcher but is not the execution shell for ADOMD operations.
- Required built-in PowerShell modules:
  - CimCmdlets (for `Get-CimInstance`)
  - Microsoft.PowerShell.Management
  - Microsoft.PowerShell.Utility

Runtime note:

- The timing/model-connection path uses ADOMD.NET APIs that are most reliable on Windows PowerShell 5.1.
- The script auto-relaunches itself in `powershell.exe` when invoked from `pwsh` for any operation that connects to Analysis Services. Pure-metadata flags that do not connect (for example `-ListLocalInstances`) run in the original shell without relaunching.

The VertiPaq timing script requires Microsoft Analysis Services .NET client libraries on the machine:

- Microsoft.AnalysisServices.AdomdClient.dll (ADOMD.NET 160+)
- Microsoft.AnalysisServices.dll (Analysis Services server assembly)
- Microsoft.AnalysisServices.Core.dll when trace-reader support is provided by a split Core/server assembly layout

The script loads these from common install locations and the GAC, then compiles trace-reader support from the actual loaded Analysis Services assemblies instead of a fixed GAC version path. It errors clearly if required assemblies are missing.

Install notes:

- PowerShell: Windows PowerShell 5.1 is required for ADOMD operations. PowerShell 7+ is fine as a launcher only.
- ADOMD.NET: install Microsoft Analysis Services client libraries (ADOMD.NET 160+)

Verify PowerShell and assembly availability:

```powershell
pwsh -NoProfile -Command "$PSVersionTable.PSVersion"
pwsh -NoProfile -Command "@(
  'C:\Program Files\Microsoft.NET\ADOMD.NET\160\Microsoft.AnalysisServices.AdomdClient.dll',
  'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Microsoft.AnalysisServices\v4.0_15.0.0.0__89845dcd8080cc91\Microsoft.AnalysisServices.dll',
  'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Microsoft.AnalysisServices.Core\v4.0_15.0.0.0__89845dcd8080cc91\Microsoft.AnalysisServices.Core.dll'
) | ForEach-Object { '{0} => {1}' -f $_, (Test-Path $_) }"
```

> The GAC subfolder version token (e.g. `v4.0_15.0.0.0__89845dcd8080cc91`) may differ on your machine — Power BI Desktop ships newer AMO builds over time. If the literal paths above return `False`, enumerate the actual installed versions with:
>
> ```powershell
> Get-ChildItem 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Microsoft.AnalysisServices' -Recurse -Filter Microsoft.AnalysisServices.dll
> Get-ChildItem 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Microsoft.AnalysisServices.Core' -Recurse -Filter Microsoft.AnalysisServices.Core.dll
> ```
>
> The capture script does not depend on a fixed GAC version token — it loads whichever AMO build is registered and compiles the trace reader against the loaded assemblies.

## Runtime assumptions

- Windows environment with Power BI Desktop process visibility for auto-discovery.
- Network access to Microsoft Learn endpoints for DAX docs search.
