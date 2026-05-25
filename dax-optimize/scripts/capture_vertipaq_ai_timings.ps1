[CmdletBinding()]
# Consent gate choice: use a switch (-IAcknowledgeUserConsent) so write/apply actions require explicit runtime acknowledgment after the user consents in SKILL.md step 4/6.
param(
    [string]$Server = "",
    [string]$Database = "",
    [switch]$AutoDiscover,
    [string]$PbixPath = "",
    [string]$PowerBIFileName = "",
    [switch]$ListLocalInstances,
    [switch]$ListMeasures,
    [string]$MeasureSearch = "",

    [string]$DaxQuery = "",
    [string]$DaxFile = "",
    [switch]$ApplyMeasure,
    [switch]$ConfirmApply,
    [switch]$IAcknowledgeUserConsent,
    [string]$MeasureTable = "",
    [string]$MeasureName = "",
    [string]$MeasureExpression = "",
    [string]$MeasureDescription = "",
    [string]$MeasureFormatString = "",
    [switch]$MeasureHidden,
    [string]$OutputFile = "",
    [switch]$WriteOutputFile,
    [int]$QueryTimeoutSeconds = 300,
    [switch]$StructureOnly,
    [switch]$NoClearCache,
    [Alias('h')]
    [switch]$Help,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-WorkspaceRoot {
    $workspaceRootComputation = "Resolve-Path (Join-Path `$PSScriptRoot '..\..\..\..')"

    try {
        $resolvedWorkspaceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') -ErrorAction Stop
    } catch {
        throw "Unable to derive the workspace root for default output files. This script computes workspace root as $workspaceRootComputation. Ensure the script remains at <workspace>/.github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1, or override with -OutputFile <absolute path>. Original error: $($_.Exception.Message)"
    }

    if (-not $resolvedWorkspaceRoot -or -not (Test-Path -LiteralPath $resolvedWorkspaceRoot.Path -PathType Container)) {
        throw "Derived workspace root path is invalid: '$($resolvedWorkspaceRoot.Path)'. This script computes workspace root as $workspaceRootComputation. Ensure the derived directory exists, or override with -OutputFile <absolute path>."
    }

    return $resolvedWorkspaceRoot.Path
}

trap {
    if ($Json.IsPresent) {
        [ordered]@{
            error = [string]$_.Exception.Message
            script_stacktrace = [string]$_.ScriptStackTrace
            category_info = [string]$_.CategoryInfo
            fully_qualified_error_id = [string]$_.FullyQualifiedErrorId
        } | ConvertTo-Json -Depth 4 | Write-Output
    } else {
        throw
    }
    exit 1
}

# PowerShell runtime compatibility block
if ($PSVersionTable.PSEdition -eq "Core" -and -not $ListLocalInstances.IsPresent) {
    $windowsPowerShell = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if (-not $windowsPowerShell) {
        throw "This script requires Windows PowerShell 5.1 for ADOMD.NET operations when running timing/model commands. Re-run with 'powershell -File ...'."
    }

    $relayArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) {
                $relayArgs += "-$key"
            }
        } else {
            $relayArgs += "-$key"
            $relayArgs += [string]$value
        }
    }

    $relayOutput = & $windowsPowerShell.Source @relayArgs 2>&1
    $relayExitCode = $LASTEXITCODE

    if ($relayOutput) {
        foreach ($line in @($relayOutput)) {
            Write-Output $line
        }
    }

    if ($relayExitCode -ne 0 -and (-not $relayOutput -or @($relayOutput).Count -eq 0)) {
        if ($Json.IsPresent) {
            [ordered]@{
                error = "Windows PowerShell relay exited with code $relayExitCode and returned no output."
                relay_shell = [string]$windowsPowerShell.Source
                relay_hint = "Rerun directly with powershell -File ... to capture child output before changing command shape."
            } | ConvertTo-Json -Depth 4 | Write-Output
        } else {
            [Console]::Error.WriteLine("Windows PowerShell relay exited with code $relayExitCode and returned no output. Rerun directly with powershell -File ...")
        }
    }

    [Environment]::Exit([int]$relayExitCode)
}

function Show-CaptureVertiPaqAiTimingsHelp {
    param(
        [switch]$AsJson
    )

    $helpText = [ordered]@{
        command = "capture_vertipaq_ai_timings.ps1"
        purpose = "Discover the open Power BI model, capture FE/SE timings, inspect structure, or apply/update a measure."
        modes = @(
            "-AutoDiscover: connect to the open model automatically.",
            "-StructureOnly: inspect model structure without timing capture.",
            "-ListMeasures: list measures in the open model, optionally filtered by -MeasureSearch.",
            "-DaxQuery or -DaxFile: run a DAX query for timing capture.",
            "-ApplyMeasure: create or update a measure in the open model only after the user explicitly selects model output mode; always pair it with -StructureOnly, -ConfirmApply, and -IAcknowledgeUserConsent, then run timing in a separate command.",
            "-WriteOutputFile: write the JSON artifact only when the user asks for it and pass -IAcknowledgeUserConsent.",
            "-ListLocalInstances: list visible Power BI Desktop instances."
        )
        examples = @(
            [ordered]@{
                title = "Discover the open model"
                command = "pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -AutoDiscover -StructureOnly -Json"
            },
            [ordered]@{
                title = "List measures in the open model (if multiple hits, choose exact measure-name match)"
                command = "pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -AutoDiscover -ListMeasures -Json"
            },
            [ordered]@{
                title = "Run a safe inline DAX query"
                command = "pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -AutoDiscover -DaxQuery 'EVALUATE ROW(""April Sales"", [April Sales])' -Json"
            },
            [ordered]@{
                title = "Apply a measure after explicit model-mode consent; replace table with the exact value returned by -ListMeasures"
                command = "pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -AutoDiscover -ApplyMeasure -ConfirmApply -IAcknowledgeUserConsent -MeasureTable ""<table from -ListMeasures>"" -MeasureName ""April Sales"" -MeasureExpression ""SUM ( Sales[AprilAmount] )"" -StructureOnly -Json"
            },
            [ordered]@{
                title = "Time the applied measure in a separate command"
                command = "pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -AutoDiscover -DaxQuery 'EVALUATE ROW(""April Sales"", [April Sales])' -Json"
            },
            [ordered]@{
                title = "Write the JSON artifact only when requested"
                command = "pwsh -File .github/skills/dax-optimize/scripts/capture_vertipaq_ai_timings.ps1 -AutoDiscover -DaxQuery 'EVALUATE ROW(""April Sales"", [April Sales])' -WriteOutputFile -IAcknowledgeUserConsent -Json"
            }
        )
        quoting = @(
            "Prefer -DaxQuery inline for benchmarking. Use -DaxFile only with an existing approved file source, explicit file output, or explicit file-backed-source approval.",
            "When using -DaxQuery, wrap the whole query in single quotes at the shell level.",
            "If a pwsh -Json command appears to return no output in VS Code terminal capture, retry with 2>&1. If output is still blank, rerun directly with powershell -File ... before changing command shape.",
            "When using -ApplyMeasure, prefer -MeasureExpression for direct model output. Use -DaxFile only after separate explicit file-backed-source approval. Always include -ConfirmApply and -IAcknowledgeUserConsent after the user selects model output mode.",
            "Do not mix -ApplyMeasure with timing capture in one invocation; use -StructureOnly for apply, then run a separate -DaxQuery timing command.",
            "When using -DaxFile, prefer an absolute path if the working directory may differ from the workspace root.",
            "Do not write direct ADOMD, AMO, SQLPS, or DMV lookup code outside this script; use -ListMeasures, -StructureOnly, -DaxQuery, or -DaxFile instead.",
            "Use -ListMeasures for measure discovery instead of inventing a custom lookup script.",
            "When -MeasureSearch returns multiple rows, use is_exact_name_match=true as the target unless the user asks for dependents."
        )
    }

    if ($AsJson) {
        return $helpText | ConvertTo-Json -Depth 6
    }

    Write-Output "DAX Optimize - capture_vertipaq_ai_timings.ps1"
    Write-Output ""
    Write-Output $helpText.purpose
    Write-Output ""
    Write-Output "Modes:"
    foreach ($mode in $helpText.modes) {
        Write-Output ("- {0}" -f $mode)
    }
    Write-Output ""
    Write-Output "Examples:"
    foreach ($example in $helpText.examples) {
        Write-Output ("- {0}" -f $example.title)
        Write-Output ("  {0}" -f $example.command)
    }
    Write-Output ""
    Write-Output "Quoting rules:"
    foreach ($rule in $helpText.quoting) {
        Write-Output ("- {0}" -f $rule)
    }
}

if ($Help.IsPresent) {
    Show-CaptureVertiPaqAiTimingsHelp -AsJson:$Json.IsPresent
    return
}

# Assembly load block
function Import-AnalysisServicesAssemblies {
    $assemblyCandidates = New-Object 'System.Collections.Generic.List[string]'
    $adomdRoots = @(
        "C:\Program Files\Microsoft.NET\ADOMD.NET",
        "C:\Program Files (x86)\Microsoft.NET\ADOMD.NET"
    )

    foreach ($root in $adomdRoots) {
        if (Test-Path $root) {
            Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object {
                    [void]$assemblyCandidates.Add((Join-Path $_.FullName "Microsoft.AnalysisServices.AdomdClient.dll"))
                }
        }
    }

    $gacRoot = "C:\Windows\Microsoft.NET\assembly\GAC_MSIL"
    if (Test-Path $gacRoot) {
        Get-ChildItem -Path $gacRoot -Directory -Filter "Microsoft.AnalysisServices*" -ErrorAction SilentlyContinue |
            ForEach-Object {
                Get-ChildItem -Path $_.FullName -Recurse -Filter "Microsoft.AnalysisServices*.dll" -ErrorAction SilentlyContinue |
                    Sort-Object FullName -Descending |
                    ForEach-Object { [void]$assemblyCandidates.Add($_.FullName) }
            }
    }

    foreach ($path in $assemblyCandidates) {
        if (Test-Path $path) {
            try {
                Add-Type -Path $path -ErrorAction SilentlyContinue
            } catch {
                # Ignore duplicate assembly load attempts.
            }
        }
    }

    if (-not ("Microsoft.AnalysisServices.AdomdClient.AdomdConnection" -as [type])) {
        throw "Unable to load Microsoft.AnalysisServices.AdomdClient. Install the Microsoft ADOMD.NET client library and ensure it is available under Program Files or the GAC."
    }

    if (-not ("Microsoft.AnalysisServices.Server" -as [type])) {
        throw "Unable to load Microsoft.AnalysisServices server assembly (Microsoft.AnalysisServices.dll). Install the Microsoft Analysis Services client libraries."
    }
}

# Power BI process discovery block
function Get-PowerBICommandLineProcesses {
    $cimRows = @(Get-CimInstance Win32_Process -Filter "Name='PBIDesktop.exe'")
    $processById = @{}
    foreach ($proc in @(Get-Process -Name "PBIDesktop" -ErrorAction SilentlyContinue)) {
        $processById[[int]$proc.Id] = $proc
    }

    $rows = @()
    foreach ($row in $cimRows) {
        $mainWindowTitle = $null
        if ($processById.ContainsKey([int]$row.ProcessId)) {
            $mainWindowTitle = $processById[[int]$row.ProcessId].MainWindowTitle
        }

        $rows += [pscustomobject]@{
            ProcessId = [int]$row.ProcessId
            ParentProcessId = [int]$row.ParentProcessId
            CommandLine = [string]$row.CommandLine
            MainWindowTitle = [string]$mainWindowTitle
        }
    }

    return @($rows)
}

# PBIX parsing block
function Get-PbixPathFromCommandLine {
    param([string]$CommandLine)

    if (-not $CommandLine) {
        return $null
    }

    $quotedMatches = [regex]::Matches($CommandLine, '"([^"]+\.pbi[tx])"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($quotedMatches.Count -gt 0) {
        return $quotedMatches[0].Groups[1].Value
    }

    $unquotedMatches = [regex]::Matches($CommandLine, '(?<path>[A-Za-z]:\\[^\s]+\.pbi[tx])', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($unquotedMatches.Count -gt 0) {
        return $unquotedMatches[0].Groups['path'].Value
    }

    return $null
}

# Analysis Services process discovery block
function Get-MsmdsrvCandidates {
    $rows = Get-CimInstance Win32_Process -Filter "Name='msmdsrv.exe'"
    $candidates = @()
    foreach ($row in $rows) {
        $workspace = $null
        if ($row.CommandLine) {
            $workspaceMatch = [regex]::Match($row.CommandLine, '-s\s+"([^"]+)"')
            if ($workspaceMatch.Success) {
                $workspace = $workspaceMatch.Groups[1].Value
            }
        }

        $portFile = $null
        $port = $null
        if ($workspace) {
            $candidatePortFiles = @(
                (Join-Path $workspace "msmdsrv.port.txt"),
                (Join-Path $workspace "Data\msmdsrv.port.txt")
            )
            foreach ($pf in $candidatePortFiles) {
                if (Test-Path $pf) {
                    $portFile = $pf
                    $rawPort = [System.IO.File]::ReadAllText($pf)
                    $numericPort = ($rawPort -replace '[^\d]', '')
                    if ($numericPort -match '^\d+$') {
                        $port = [int]$numericPort
                    }
                    break
                }
            }
        }

        $candidates += [pscustomobject]@{
            process_id = [int]$row.ProcessId
            parent_process_id = [int]$row.ParentProcessId
            command_line = [string]$row.CommandLine
            workspace_path = $workspace
            port_file = $portFile
            port = $port
        }
    }

    return $candidates
}

# Local instance list block
function Get-LocalSemanticModelInstances {
    $pbidProcesses = @(Get-PowerBICommandLineProcesses)
    $msmdCandidates = @(Get-MsmdsrvCandidates)

    $pbidById = @{}
    foreach ($pbid in $pbidProcesses) {
        $pbidById[[int]$pbid.ProcessId] = $pbid
    }

    $instances = New-Object 'System.Collections.Generic.List[psobject]'
    foreach ($msmd in $msmdCandidates) {
        if (-not $msmd.port) {
            continue
        }

        $parent = $null
        if ($pbidById.ContainsKey([int]$msmd.parent_process_id)) {
            $parent = $pbidById[[int]$msmd.parent_process_id]
        }

        $pbixPath = $null
        $parentTitle = $null
        if ($parent) {
            $pbixPath = Get-PbixPathFromCommandLine -CommandLine $parent.CommandLine
            $parentTitle = $parent.MainWindowTitle
        }

        [void]$instances.Add([pscustomobject]@{
            process_id = [int]$msmd.process_id
            parent_process_id = [int]$msmd.parent_process_id
            port = [int]$msmd.port
            server = "localhost:{0}" -f $msmd.port
            server_connection_string = "Data Source=localhost:{0};Application Name=MCP-PBIModeling" -f $msmd.port
            workspace_path = $msmd.workspace_path
            port_file = $msmd.port_file
            pbix_path = $pbixPath
            parent_window_title = [string]$parentTitle
        })
    }

    return @($instances)
}

# Name normalization block
function Get-FileNameStem {
    param([string]$PathOrName)

    if (-not $PathOrName -or $PathOrName.Trim().Length -eq 0) {
        return $null
    }

    try {
        return [System.IO.Path]::GetFileNameWithoutExtension($PathOrName.Trim())
    } catch {
        return $PathOrName.Trim()
    }
}

function Get-NormalizedFullPath {
    param([string]$Path)

    if (-not $Path -or $Path.Trim().Length -eq 0) {
        return $null
    }

    try {
        return [System.IO.Path]::GetFullPath($Path.Trim()).TrimEnd('\')
    } catch {
        return $Path.Trim().TrimEnd('\')
    }
}

function Format-LocalInstanceChoices {
    param([object[]]$Instances)

    $choices = @($Instances | ForEach-Object {
        "server={0}; window='{1}'; pbix='{2}'" -f $_.server, $_.parent_window_title, $_.pbix_path
    })

    return ($choices -join " | ")
}

# Instance matching block
function Select-PreferredLocalInstance {
    param(
        [object[]]$Instances,
        [string]$RequestedPbixPath,
        [string]$RequestedPowerBIFileName
    )

    if (-not $Instances -or $Instances.Count -eq 0) {
        return $null
    }

    if ($RequestedPbixPath -and $RequestedPbixPath.Trim().Length -gt 0) {
        $requestedFullPath = Get-NormalizedFullPath -Path $RequestedPbixPath
        $pathMatches = @($Instances | Where-Object {
            $instancePath = Get-NormalizedFullPath -Path ([string]$_.pbix_path)
            $instancePath -and $instancePath.Equals($requestedFullPath, [System.StringComparison]::OrdinalIgnoreCase)
        })

        if ($pathMatches.Count -eq 1) {
            return $pathMatches[0]
        }

        if ($pathMatches.Count -gt 1) {
            $choices = Format-LocalInstanceChoices -Instances $pathMatches
            throw "Requested PBIX path '$RequestedPbixPath' matched multiple open local Power BI Desktop instances. Re-run with explicit -Server/-Database. Matches: $choices"
        }

        throw "Requested PBIX path '$RequestedPbixPath' does not match any open local Power BI Desktop instance. Use -ListLocalInstances -Json to inspect open models."
    }

    $requestedStem = $null
    if ($RequestedPowerBIFileName -and $RequestedPowerBIFileName.Trim().Length -gt 0) {
        $requestedStem = Get-FileNameStem -PathOrName $RequestedPowerBIFileName
    }

    if ($requestedStem -and $requestedStem.Trim().Length -gt 0) {
        $needle = $requestedStem.ToLowerInvariant()
        $instanceMatches = @($Instances | Where-Object {
            $title = ([string]$_.parent_window_title).ToLowerInvariant()
            $pathStem = (Get-FileNameStem -PathOrName ([string]$_.pbix_path))
            $pathStemNorm = if ($pathStem) { $pathStem.ToLowerInvariant() } else { "" }
            $title -like "*$needle*" -or $pathStemNorm -eq $needle
        })

        if ($instanceMatches.Count -eq 1) {
            return $instanceMatches[0]
        }

        if ($instanceMatches.Count -gt 1) {
            $choices = Format-LocalInstanceChoices -Instances $instanceMatches
            throw "Requested Power BI file '$requestedStem' matched multiple open local Power BI Desktop instances. Re-run with a more specific -PowerBIFileName, -PbixPath, or explicit -Server/-Database. Matches: $choices"
        }

        throw "Could not match requested Power BI file '$requestedStem' to any open local Power BI Desktop instance."
    }

    if ($Instances.Count -gt 1) {
        $choices = Format-LocalInstanceChoices -Instances $Instances
        throw "Multiple open local Power BI Desktop instances detected. Re-run with -PowerBIFileName, -PbixPath, or explicit -Server/-Database before timing or applying changes. Matches: $choices"
    }

    return $Instances | Sort-Object parent_process_id -Descending | Select-Object -First 1
}

# Input selection block
function Get-DaxText {
    param(
        [string]$InlineDax,
        [string]$FilePath
    )

    if (($InlineDax -and $InlineDax.Trim().Length -gt 0) -and ($FilePath -and $FilePath.Trim().Length -gt 0)) {
        throw "Conflicting parameters: -DaxQuery and -DaxFile cannot be used together. Pass only one."
    }

    if ($InlineDax -and $InlineDax.Trim().Length -gt 0) {
        return $InlineDax
    }

    if ($FilePath -and -not (Test-Path $FilePath)) {
        throw "DAX file not found: '$FilePath'"
    }

    if ($FilePath -and (Test-Path $FilePath)) {
        return [System.IO.File]::ReadAllText((Resolve-Path $FilePath), [System.Text.Encoding]::UTF8)
    }

    throw "No DAX query provided. Use -DaxQuery or -DaxFile."
}

# Measure expression selection block
function Get-MeasureExpressionText {
    param(
        [string]$InlineExpression,
        [string]$FilePath
    )

    if (($InlineExpression -and $InlineExpression.Trim().Length -gt 0) -and ($FilePath -and $FilePath.Trim().Length -gt 0)) {
        throw "Conflicting parameters: -MeasureExpression and -DaxFile cannot be used together. Pass only one."
    }

    if ($InlineExpression -and $InlineExpression.Trim().Length -gt 0) {
        return $InlineExpression
    }

    if ($FilePath -and -not (Test-Path $FilePath)) {
        throw "DAX file not found: '$FilePath'"
    }

    if ($FilePath -and (Test-Path $FilePath)) {
        $fileText = [System.IO.File]::ReadAllText((Resolve-Path $FilePath), [System.Text.Encoding]::UTF8)
        $queryKeywordPattern = '^\s*(EVALUATE|DEFINE|ORDER\s+BY|START\s+AT|SELECT)\b'
        $queryKeywordMatch = [regex]::Match($fileText, $queryKeywordPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($queryKeywordMatch.Success) {
            $detectedKeyword = $queryKeywordMatch.Groups[1].Value.ToUpperInvariant()
            throw "-DaxFile content used with -ApplyMeasure must be a measure expression, not a query. Detected leading keyword '$detectedKeyword'. Provide a pure expression file or pass -MeasureExpression directly."
        }

        return $fileText
    }

    throw "No measure expression provided. Use -MeasureExpression or -DaxFile with -ApplyMeasure. -DaxQuery is for timing/benchmark queries, not model apply."
}

# Endpoint auto-discovery block
function Get-AutoDiscoveredEndpoint {
    param(
        [string]$RequestedPbixPath,
        [string]$RequestedPowerBIFileName
    )

    $instances = @(Get-LocalSemanticModelInstances)
    if ($instances.Count -eq 0) {
        throw "No open local Power BI Desktop Analysis Services instance detected. Open a PBIX/PBIT in Power BI Desktop or pass -Server and -Database explicitly."
    }

    $selected = Select-PreferredLocalInstance -Instances $instances -RequestedPbixPath $RequestedPbixPath -RequestedPowerBIFileName $RequestedPowerBIFileName
    if (-not $selected) {
        throw "Could not resolve a local Power BI Desktop Analysis Services instance."
    }

    return [pscustomobject]@{
        server = $selected.server
        server_connection_string = $selected.server_connection_string
        powerbi_process_id = [int]$selected.parent_process_id
        powerbi_window_title = $selected.parent_window_title
        pbix_path = $selected.pbix_path
        msmdsrv_process_id = [int]$selected.process_id
        workspace_path = $selected.workspace_path
        port_file = $selected.port_file
    }
}

# XMLA cache clear block
function Clear-DatabaseCache {
    param(
        [string]$DataSource,
        [string]$InitialCatalog
    )

        $escapedCatalog = [System.Security.SecurityElement]::Escape($InitialCatalog)

        $xmla = @"
<ClearCache xmlns="http://schemas.microsoft.com/analysisservices/2003/engine">
  <Object>
        <DatabaseID>$escapedCatalog</DatabaseID>
  </Object>
</ClearCache>
"@

    $server = New-Object Microsoft.AnalysisServices.Server
    try {
        $server.Connect("Data Source=$DataSource")
        [void]$server.Execute($xmla)
    } finally {
        if ($server.Connected) {
            $server.Disconnect()
        }
    }
}

# Generic DMV query block
function Invoke-DmvRows {
    param(
        [Microsoft.AnalysisServices.AdomdClient.AdomdConnection]$Connection,
        [string]$Query
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = $Query
    $rows = New-Object 'System.Collections.Generic.List[psobject]'

    $reader = $command.ExecuteReader()
    try {
        while ($reader.Read()) {
            $row = [ordered]@{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $name = $reader.GetName($i)
                $value = $null
                if (-not $reader.IsDBNull($i)) {
                    $value = $reader.GetValue($i)
                }
                $row[$name] = $value
            }
            [void]$rows.Add([pscustomobject]$row)
        }
    } finally {
        $reader.Dispose()
        $command.Dispose()
    }

    return @($rows)
}

# DMV field access block
function Get-DmvFieldValue {
    param(
        [object]$Row,
        [string]$Name
    )

    if ($null -eq $Row) {
        return $null
    }

    $prop = $Row.PSObject.Properties[$Name]
    if ($null -ne $prop) {
        return $prop.Value
    }

    return $null
}

# Catalog discovery block
function Get-ServerCatalogNames {
    param([string]$DataSource)

    $connection = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection("Data Source=$DataSource")
    $connection.Open()
    try {
        $rows = @(Invoke-DmvRows -Connection $connection -Query "SELECT [CATALOG_NAME] FROM `$SYSTEM.DBSCHEMA_CATALOGS")
        return @($rows | ForEach-Object { [string]$_.CATALOG_NAME } | Where-Object { $_ -and $_.Trim().Length -gt 0 })
    } finally {
        if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
            $connection.Close()
        }
        $connection.Dispose()
    }
}

# Database selection block
function Resolve-DatabaseName {
    param(
        [string]$DataSource,
        [string]$RequestedDatabase
    )

    if ($RequestedDatabase -and $RequestedDatabase.Trim().Length -gt 0) {
        return $RequestedDatabase
    }

    $catalogs = @(Get-ServerCatalogNames -DataSource $DataSource)
    if ($catalogs.Count -eq 0) {
        throw "No databases discovered on server '$DataSource'."
    }

    if ($catalogs.Count -eq 1) {
        return $catalogs[0]
    }

    $modelCatalog = $catalogs | Where-Object { $_.Equals("Model", [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
    if ($modelCatalog) {
        return $modelCatalog
    }

    $catalogList = $catalogs -join ", "
    throw "Multiple databases were discovered on server '$DataSource' and none is named 'Model'. Candidate databases: $catalogList. Pass -Database explicitly."
}

# Table existence validation block
function Test-ModelTableExists {
    param(
        [Microsoft.AnalysisServices.AdomdClient.AdomdConnection]$Connection,
        [string]$TableName
    )

    $safeName = $TableName.Replace("'", "''")
    $query = "SELECT [Name] FROM `$SYSTEM.TMSCHEMA_TABLES WHERE [Name] = '$safeName'"
    $rows = @(Invoke-DmvRows -Connection $Connection -Query $query)
    return ($rows.Count -gt 0)
}

# Measure create/update block
function Set-ModelMeasure {
    param(
        [string]$DataSource,
        [string]$InitialCatalog,
        [string]$TableName,
        [string]$Name,
        [string]$Expression,
        [string]$Description,
        [string]$FormatString,
        [bool]$IsHidden
    )

    $server = New-Object Microsoft.AnalysisServices.Server
    try {
        $server.Connect("Data Source=$DataSource")
        $database = $server.Databases.FindByName($InitialCatalog)
        if (-not $database) {
            $database = $server.Databases.Find($InitialCatalog)
        }
        if (-not $database) {
            throw "Database '$InitialCatalog' was not found on '$DataSource'."
        }
        if (-not $database.Model) {
            throw "Database '$InitialCatalog' does not expose a tabular model."
        }

        $table = $database.Model.Tables.Find($TableName)
        if (-not $table) {
            throw "Table '$TableName' was not found in model '$InitialCatalog'."
        }

        $measure = $table.Measures.Find($Name)
        $created = $false
        if (-not $measure) {
            $measure = New-Object Microsoft.AnalysisServices.Tabular.Measure
            $measure.Name = $Name
            [void]$table.Measures.Add($measure)
            $created = $true
        }

        $measure.Expression = $Expression
        if ($Description -and $Description.Trim().Length -gt 0) {
            $measure.Description = $Description
        }
        if ($FormatString -and $FormatString.Trim().Length -gt 0) {
            $measure.FormatString = $FormatString
        }
        if ($IsHidden) {
            $measure.IsHidden = $true
        }

        [void]$database.Model.SaveChanges()
        return [pscustomobject]@{
            created = $created
            metadata_preserved = (-not $created)
        }
    } finally {
        if ($server.Connected) {
            $server.Disconnect()
        }
    }
}

# Query execution timing block
function Invoke-DaxAndMeasureTotal {
    param(
        [Microsoft.AnalysisServices.AdomdClient.AdomdConnection]$Connection,
        [string]$Query,
        [int]$TimeoutSeconds
    )

    $command = $Connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = $TimeoutSeconds

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $reader = $null
    try {
        $reader = $command.ExecuteReader()
        while ($reader.Read()) {
            # Consume resultset to force full execution.
        }
        $stopwatch.Stop()
        return [double]$stopwatch.Elapsed.TotalMilliseconds
    } finally {
        $stopwatch.Stop()
        if ($reader) {
            $reader.Dispose()
        }
        $command.Dispose()
    }
}

# Interval union block
function Get-IntervalUnionDurationMs {
    param(
        [object[]]$Intervals
    )

    if (-not $Intervals -or $Intervals.Count -eq 0) {
        return 0.0
    }

    $ordered = $Intervals | Sort-Object start_time, end_time
    $totalMs = 0.0
    $currentStart = $null
    $currentEnd = $null

    foreach ($interval in $ordered) {
        $start = [datetime]$interval.start_time
        $end = [datetime]$interval.end_time
        if ($end -lt $start) {
            continue
        }

        if (-not $currentStart) {
            $currentStart = $start
            $currentEnd = $end
            continue
        }

        if ($start -le $currentEnd) {
            if ($end -gt $currentEnd) {
                $currentEnd = $end
            }
            continue
        }

        $totalMs += ($currentEnd - $currentStart).TotalMilliseconds
        $currentStart = $start
        $currentEnd = $end
    }

    if ($currentStart) {
        $totalMs += ($currentEnd - $currentStart).TotalMilliseconds
    }

    return [double][math]::Round($totalMs, 3)
}

# Trace event setup block
function Add-TraceEventWithColumns {
    param(
        [Microsoft.AnalysisServices.Trace]$Trace,
        [Microsoft.AnalysisServices.TraceEventClass]$EventClass
    )

    if ($Trace.Events.Find($EventClass)) {
        return
    }

    $traceEvent = New-Object Microsoft.AnalysisServices.TraceEvent($EventClass)

    $columns = @()
    if ($EventClass -eq [Microsoft.AnalysisServices.TraceEventClass]::DiscoverBegin -or
        $EventClass -eq [Microsoft.AnalysisServices.TraceEventClass]::CommandBegin) {
        $columns = @(
            [Microsoft.AnalysisServices.TraceColumn]::CurrentTime,
            [Microsoft.AnalysisServices.TraceColumn]::SessionID,
            [Microsoft.AnalysisServices.TraceColumn]::ActivityID,
            [Microsoft.AnalysisServices.TraceColumn]::RequestID,
            [Microsoft.AnalysisServices.TraceColumn]::TextData
        )
    } else {
        $columns = @(
            [Microsoft.AnalysisServices.TraceColumn]::CurrentTime,
            [Microsoft.AnalysisServices.TraceColumn]::Duration,
            [Microsoft.AnalysisServices.TraceColumn]::CpuTime,
            [Microsoft.AnalysisServices.TraceColumn]::SessionID,
            [Microsoft.AnalysisServices.TraceColumn]::ActivityID,
            [Microsoft.AnalysisServices.TraceColumn]::RequestID,
            [Microsoft.AnalysisServices.TraceColumn]::TextData
        )
    }

    foreach ($column in $columns) {
        if (-not $traceEvent.Columns.Contains($column)) {
            [void]$traceEvent.Columns.Add($column)
        }
    }

    [void]$Trace.Events.Add($traceEvent)
}

# Adaptive trace update block
function Update-TraceWithAdaptiveColumnPruning {
    param(
        [Microsoft.AnalysisServices.Trace]$Trace,
        [int]$MaxAttempts = 20
    )

    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        try {
            $Trace.Update([Microsoft.AnalysisServices.UpdateOptions]::Default, [Microsoft.AnalysisServices.UpdateMode]::CreateOrReplace)
            return
        } catch {
            $message = $_.Exception.ToString()
            $match = [regex]::Match($message, 'event\s+Id=(\d+)\s+does\s+not\s+contain\s+the\s+column\s+Id=(\d+)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if (-not $match.Success) {
                throw
            }

            $eventId = [int]$match.Groups[1].Value
            $columnId = [int]$match.Groups[2].Value

            $eventClass = [Microsoft.AnalysisServices.TraceEventClass]$eventId
            $traceEvent = $Trace.Events.Find($eventClass)
            if (-not $traceEvent) {
                throw "Trace update failed for event id $eventId / column id $columnId, but event was not found in trace definition."
            }

            $column = [Microsoft.AnalysisServices.TraceColumn]$columnId
            if (-not $traceEvent.Columns.Contains($column)) {
                throw "Trace update failed for event id $eventId / column id $columnId, but column is not present to remove."
            }

            [void]$traceEvent.Columns.Remove($column)
        }
    }

    throw "Trace update failed after $MaxAttempts adaptive pruning attempts."
}

# Trace reader initialization block
function Initialize-TraceReaderSupport {
    if ("CopilotTraceCollector" -as [type]) {
        return
    }

    $traceEventArgsType = "Microsoft.AnalysisServices.TraceEventArgs" -as [type]
    $serverType = "Microsoft.AnalysisServices.Server" -as [type]
    if (-not $traceEventArgsType -or -not $serverType) {
        throw "Unable to resolve Microsoft Analysis Services trace types from loaded assemblies."
    }

    $referencedAssemblies = @(
        $traceEventArgsType.Assembly.Location,
        ([Microsoft.AnalysisServices.TraceEventClass]).Assembly.Location,
        ([Microsoft.AnalysisServices.TraceColumn]).Assembly.Location,
        $serverType.Assembly.Location
    ) | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Select-Object -Unique

    $collectorSource = @"
using System;
using System.Collections.Concurrent;
using Microsoft.AnalysisServices;

public class CopilotTraceCollector
{
    public class TraceItem
    {
        public string EventClass;
        public string EventSubclass;
        public DateTime CurrentTime;
        public DateTime StartTime;
        public DateTime EndTime;
        public long Duration;
        public long CpuTime;
        public string SessionId;
        public string ActivityId;
        public string RequestId;
        public string TextData;
    }

    private readonly ConcurrentQueue<TraceItem> _queue = new ConcurrentQueue<TraceItem>();

    public void OnEvent(object sender, TraceEventArgs e)
    {
        var item = new TraceItem();
        try { item.EventClass = e.EventClass.ToString(); } catch { item.EventClass = string.Empty; }
        try { item.EventSubclass = e.EventSubclass.ToString(); } catch { item.EventSubclass = string.Empty; }
        try { item.CurrentTime = e.CurrentTime; } catch { item.CurrentTime = DateTime.UtcNow; }
        try { item.StartTime = e.StartTime; } catch { item.StartTime = item.CurrentTime; }
        try { item.EndTime = e.EndTime; } catch { item.EndTime = item.CurrentTime; }
        try { item.Duration = e.Duration; } catch { item.Duration = 0; }
        try { item.CpuTime = e.CpuTime; } catch { item.CpuTime = 0; }
        try { item.SessionId = e.SessionID; } catch { item.SessionId = string.Empty; }
        try { item.ActivityId = Convert.ToString(e[TraceColumn.ActivityID]); } catch { item.ActivityId = string.Empty; }
        try { item.RequestId = Convert.ToString(e[TraceColumn.RequestID]); } catch { item.RequestId = string.Empty; }
        try { item.TextData = e.TextData; } catch { item.TextData = string.Empty; }
        _queue.Enqueue(item);
    }

    public void OnStopped(object sender, TraceStoppedEventArgs e)
    {
    }

    public int Count()
    {
        return _queue.Count;
    }

    public TraceItem[] Snapshot()
    {
        return _queue.ToArray();
    }
}
"@

    Add-Type -TypeDefinition $collectorSource -ReferencedAssemblies $referencedAssemblies
}

# Trace filter block
function New-TraceSessionFilterNode {
    param([string]$SessionId)

    $xml = @"
<Equal xmlns="http://schemas.microsoft.com/analysisservices/2003/engine">
  <ColumnID>$([int][Microsoft.AnalysisServices.TraceColumn]::SessionID)</ColumnID>
  <Value>$SessionId</Value>
</Equal>
"@

    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($xml)
    return $doc.DocumentElement
}

# Trace timing capture block
function Invoke-DaxWithTraceTimings {
    param(
        [Microsoft.AnalysisServices.AdomdClient.AdomdConnection]$Connection,
        [string]$DataSource,
        [string]$Query,
        [int]$TimeoutSeconds
    )

    $sessionId = [string]$Connection.SessionID
    if (-not $sessionId -or $sessionId.Trim().Length -eq 0) {
        throw "Cannot capture trace timings because Adomd session ID is unavailable."
    }

    $amoServer = New-Object Microsoft.AnalysisServices.Server
    $trace = $null
    $traceName = "Copilot_ServerTimings_{0}" -f ([guid]::NewGuid().ToString("N"))
    $capturedEvents = New-Object 'System.Collections.Generic.List[psobject]'
    $syncRoot = New-Object object
    $queryEndSignal = New-Object System.Threading.ManualResetEventSlim($false)
    $traceStartedSignal = New-Object System.Threading.ManualResetEventSlim($false)
    $traceReader = $null
    $traceReaderType = $null
    $traceReaderStartMethod = $null
    $traceReaderStopMethod = $null
    $traceReaderDisposeMethod = $null
    $traceCollector = $null
    $traceStep = "initialization"

    $handler = [Microsoft.AnalysisServices.TraceEventHandler]{
        param($traceEventSender, $e)

        try {
            $eventClass = [string]$e.EventClass
        } catch {
            $eventClass = "Unknown"
        }

        try {
            $currentTime = [datetime]$e.CurrentTime
        } catch {
            $currentTime = [datetime]::UtcNow
        }

        try {
            $durationMs = [double]$e.Duration
        } catch {
            $durationMs = 0.0
        }

        try {
            $cpuMs = [double]$e.CpuTime
        } catch {
            $cpuMs = 0.0
        }

        $endTime = $currentTime
        if ($durationMs -gt 0) {
            $startTime = $endTime.AddMilliseconds(-1.0 * $durationMs)
        } else {
            $startTime = $endTime
        }

        try {
            $eventSubclass = [string]$e.EventSubclass
        } catch {
            $eventSubclass = ""
        }

        try {
            $sessionIdValue = [string]$e.SessionID
        } catch {
            $sessionIdValue = ""
        }

        try {
            $activityIdValue = [string]$e[[Microsoft.AnalysisServices.TraceColumn]::ActivityID]
        } catch {
            $activityIdValue = ""
        }

        try {
            $requestIdValue = [string]$e[[Microsoft.AnalysisServices.TraceColumn]::RequestID]
        } catch {
            $requestIdValue = ""
        }

        try {
            $textDataValue = [string]$e.TextData
        } catch {
            $textDataValue = ""
        }

        $record = [pscustomobject]@{
            event_class = $eventClass
            event_subclass = $eventSubclass
            current_time = $currentTime
            start_time = $startTime
            end_time = $endTime
            duration_ms = $durationMs
            cpu_ms = $cpuMs
            session_id = $sessionIdValue
            activity_id = $activityIdValue
            request_id = $requestIdValue
            text_data = $textDataValue
        }

        [System.Threading.Monitor]::Enter($syncRoot)
        try {
            [void]$capturedEvents.Add($record)
            if (-not $traceStartedSignal.IsSet) {
                $traceStartedSignal.Set()
            }
        } finally {
            [System.Threading.Monitor]::Exit($syncRoot)
        }

        if ($eventClass -eq "QueryEnd") {
            $queryEndSignal.Set()
        }
    }

    try {
        $traceStep = "connect_server"
        $amoServer.Connect("Data Source=$DataSource")
        $traceStep = "create_trace"
        $trace = $amoServer.Traces.Add($traceName)
        $traceStep = "add_events"
        # DAX Studio pattern: include heartbeat events so we can detect when the trace is active.
        Add-TraceEventWithColumns -Trace $trace -EventClass ([Microsoft.AnalysisServices.TraceEventClass]::DiscoverBegin)
        Add-TraceEventWithColumns -Trace $trace -EventClass ([Microsoft.AnalysisServices.TraceEventClass]::CommandBegin)
        Add-TraceEventWithColumns -Trace $trace -EventClass ([Microsoft.AnalysisServices.TraceEventClass]::QueryBegin)
        Add-TraceEventWithColumns -Trace $trace -EventClass ([Microsoft.AnalysisServices.TraceEventClass]::QueryEnd)
        Add-TraceEventWithColumns -Trace $trace -EventClass ([Microsoft.AnalysisServices.TraceEventClass]::VertiPaqSEQueryBegin)
        Add-TraceEventWithColumns -Trace $trace -EventClass ([Microsoft.AnalysisServices.TraceEventClass]::VertiPaqSEQueryEnd)
        try {
            $cacheMatchEventClass = [System.Enum]::Parse([Microsoft.AnalysisServices.TraceEventClass], "VertiPaqSEQueryCacheMatch")
            Add-TraceEventWithColumns -Trace $trace -EventClass $cacheMatchEventClass
        } catch {
            # Older client libraries may not expose this event class.
        }
        Add-TraceEventWithColumns -Trace $trace -EventClass ([Microsoft.AnalysisServices.TraceEventClass]::DirectQueryBegin)
        Add-TraceEventWithColumns -Trace $trace -EventClass ([Microsoft.AnalysisServices.TraceEventClass]::DirectQueryEnd)

        $traceStep = "register_event_handler"
        $trace.add_OnEvent($handler)
        $trace.StopTime = [datetime]::UtcNow.AddHours(1)
        $traceStep = "trace_update"
        Update-TraceWithAdaptiveColumnPruning -Trace $trace
        $traceStep = "trace_start"
        $trace.Start()

        $traceStep = "trace_reader_start"
        Initialize-TraceReaderSupport
        $traceCollector = New-Object CopilotTraceCollector
        $collectorType = $traceCollector.GetType()
        $collectorOnEventMethod = $collectorType.GetMethod("OnEvent")
        $collectorOnStoppedMethod = $collectorType.GetMethod("OnStopped")
        $eventDelegate = [System.Delegate]::CreateDelegate([Microsoft.AnalysisServices.TraceEventHandler], $traceCollector, $collectorOnEventMethod)
        $stopDelegate = [System.Delegate]::CreateDelegate([Microsoft.AnalysisServices.TraceStoppedEventHandler], $traceCollector, $collectorOnStoppedMethod)
        $traceReaderType = [Microsoft.AnalysisServices.Server].Assembly.GetType("Microsoft.AnalysisServices.TraceEventsReader", $true)
        $traceReader = [System.Activator]::CreateInstance($traceReaderType, $true)
        $traceReaderStartMethod = $traceReaderType.GetMethods() | Where-Object { $_.Name -eq "Start" -and $_.GetParameters().Count -eq 3 } | Select-Object -First 1
        $traceReaderStopMethod = $traceReaderType.GetMethod("Stop")
        $traceReaderDisposeMethod = $traceReaderType.GetMethod("Dispose")
        [void]$traceReaderStartMethod.Invoke($traceReader, [object[]]@($trace, $eventDelegate, $stopDelegate))

        $traceStep = "trace_heartbeat"
        if (-not $traceStartedSignal.Wait(300)) {
            $pingAttempts = 0
            while (-not $traceStartedSignal.IsSet -and $pingAttempts -lt 12) {
                $pingAttempts++
                try {
                    $pingCmd = $Connection.CreateCommand()
                    $pingCmd.CommandText = "SELECT * FROM `$SYSTEM.DISCOVER_SESSIONS"
                    $pingCmd.CommandTimeout = 5
                    $pingReader = $pingCmd.ExecuteReader()
                    if ($pingReader.Read()) {
                        # Heartbeat read.
                    }
                    $pingReader.Close()
                } catch {
                    # Ignore heartbeat failures while trace is warming up.
                }
                [void]$traceStartedSignal.Wait(250)
            }
        }

        $runId = [guid]::NewGuid().ToString("N")
        $runMarker = "-- RUNID:$runId"
        $taggedQuery = "$runMarker`r`n$Query"

        $queryStartMarker = [datetime]::UtcNow
        $traceStep = "execute_dax"
        $totalElapsedMs = Invoke-DaxAndMeasureTotal -Connection $Connection -Query $taggedQuery -TimeoutSeconds $TimeoutSeconds
        $queryFinishMarker = [datetime]::UtcNow
        $traceStep = "wait_query_end"
        [void]$queryEndSignal.Wait(2000)
        [System.Threading.Thread]::Sleep(1200)

        $events = @()
        [System.Threading.Monitor]::Enter($syncRoot)
        try {
            $events = @($capturedEvents)
        } finally {
            [System.Threading.Monitor]::Exit($syncRoot)
        }

        if ($traceCollector) {
            $readerEvents = @($traceCollector.Snapshot())
            if ($readerEvents.Count -gt 0) {
                $events = @($readerEvents | ForEach-Object {
                    $effectiveEnd = if ($_.EndTime -eq [datetime]::MinValue) { $_.CurrentTime } else { $_.EndTime }
                    $effectiveStart = if ($_.StartTime -eq [datetime]::MinValue) { $effectiveEnd } else { $_.StartTime }
                    if ($effectiveEnd -lt $effectiveStart -and $_.Duration -gt 0) {
                        $effectiveStart = $effectiveEnd.AddMilliseconds(-1.0 * $_.Duration)
                    }
                    [pscustomobject]@{
                        event_class = [string]$_.EventClass
                        event_subclass = [string]$_.EventSubclass
                        current_time = [datetime]$_.CurrentTime
                        start_time = [datetime]$effectiveStart
                        end_time = [datetime]$effectiveEnd
                        duration_ms = [double]$_.Duration
                        cpu_ms = [double]$_.CpuTime
                        session_id = [string]$_.SessionId
                        activity_id = [string]$_.ActivityId
                        request_id = [string]$_.RequestId
                        text_data = [string]$_.TextData
                    }
                })
            }
        }

        $traceCorrelationWarnings = New-Object 'System.Collections.Generic.List[string]'
        $windowStart = $queryStartMarker.AddSeconds(-2)
        $windowEnd = $queryFinishMarker.AddSeconds(2)
        $eventsBeforeWindowFilter = $events.Count
        $windowedEvents = @($events | Where-Object { $_.current_time -ge $windowStart -and $_.current_time -le $windowEnd })
        $timeWindowFilterApplied = $false
        if ($windowedEvents.Count -gt 0) {
            $timeWindowFilterApplied = ($windowedEvents.Count -lt $eventsBeforeWindowFilter)
            $events = $windowedEvents
        } else {
            [void]$traceCorrelationWarnings.Add("time_window_filter_skipped: zero matching events")
        }

        $noisePattern = '(?is)(\bDISCOVER_|^\s*<Discover\b|SELECT\s+\*\s+FROM\s+\$SYSTEM\.)'
        $eventsBeforeNoiseFilter = $events.Count
        $filteredEvents = @($events | Where-Object {
            $txt = [string]$_.text_data
            -not ($txt -and ($txt -match $noisePattern))
        })
        $noiseFilterApplied = $false
        if ($filteredEvents.Count -gt 0) {
            $noiseFilterApplied = ($filteredEvents.Count -lt $eventsBeforeNoiseFilter)
            $events = $filteredEvents
        } else {
            [void]$traceCorrelationWarnings.Add("noise_filter_skipped: zero matching events")
        }

        $normalizeText = {
            param([string]$Text)
            if (-not $Text) {
                return ""
            }
            return (($Text -replace "\s+", " ").Trim())
        }

        $targetSessionId = $null
        $targetRequestId = $null
        $targetActivityId = $null
        $runIdMarkerMatched = $false
        $normalizedTextFallbackUsed = $false
        $eventsBeforeCorrelation = $events.Count
        $queryNorm = & $normalizeText $Query
        $queryEndCandidates = @($events | Where-Object { $_.event_class -eq "QueryEnd" })
        if ($queryEndCandidates.Count -gt 0) {
            $exactMarkerMatch = $queryEndCandidates | Where-Object { $_.text_data -and ($_.text_data -match [regex]::Escape($runMarker)) } | Select-Object -First 1
            $runIdMarkerMatched = ($null -ne $exactMarkerMatch)
            $exactMatch = if ($exactMarkerMatch) {
                $exactMarkerMatch
            } else {
                $normalizedTextFallbackUsed = $true
                $queryEndCandidates | Where-Object { (& $normalizeText $_.text_data) -eq $queryNorm } | Select-Object -First 1
            }

            if ($exactMatch) {
                $targetSessionId = $exactMatch.session_id
                $targetRequestId = $exactMatch.request_id
                $targetActivityId = $exactMatch.activity_id
            } else {
                throw "Could not uniquely resolve target QueryEnd event for the DAX query in the captured trace window."
            }
        }

        if ($targetRequestId) {
            # RequestId is the strongest correlation key for the target DAX query.
            $events = @($events | Where-Object {
                ((-not $targetSessionId) -or ($_.session_id -eq $targetSessionId)) -and
                (
                    ($_.request_id -eq $targetRequestId) -or
                    ((-not $_.request_id) -and $targetActivityId -and $_.activity_id -eq $targetActivityId)
                )
            })
        } elseif ($targetActivityId) {
            $events = @($events | Where-Object {
                ((-not $targetSessionId) -or ($_.session_id -eq $targetSessionId)) -and
                ($_.activity_id -eq $targetActivityId)
            })
        } elseif ($targetSessionId) {
            $events = @($events | Where-Object { $_.session_id -eq $targetSessionId })
        }

        $eventsAfterCorrelation = $events.Count
        $traceCorrelationConfidence = if ($runIdMarkerMatched) {
            "high"
        } elseif ($normalizedTextFallbackUsed) {
            "medium"
        } else {
            "low"
        }

        $traceCorrelation = [pscustomobject]@{
            runid_marker_matched = $runIdMarkerMatched
            normalized_text_fallback_used = $normalizedTextFallbackUsed
            time_window_filter_applied = $timeWindowFilterApplied
            noise_filter_applied = $noiseFilterApplied
            target_session_id = $targetSessionId
            target_request_id = $targetRequestId
            target_activity_id = $targetActivityId
            events_before_correlation = $eventsBeforeCorrelation
            events_after_correlation = $eventsAfterCorrelation
            confidence = $traceCorrelationConfidence
            warnings = @($traceCorrelationWarnings)
        }

        $queryEndEvent = $events |
            Where-Object { $_.event_class -eq "QueryEnd" } |
            Sort-Object end_time -Descending |
            Select-Object -First 1

        $seEndEvents = @($events | Where-Object { $_.event_class -eq "VertiPaqSEQueryEnd" -or $_.event_class -eq "DirectQueryEnd" })
        $sortedEvents = @($events | Sort-Object current_time)
        $vertiPaqBeginStack = New-Object 'System.Collections.Generic.Stack[datetime]'
        $directQueryBeginStack = New-Object 'System.Collections.Generic.Stack[datetime]'
        $seIntervals = New-Object 'System.Collections.Generic.List[psobject]'

        foreach ($traceEvent in $sortedEvents) {
            switch ($traceEvent.event_class) {
                "VertiPaqSEQueryBegin" {
                    $vertiPaqBeginStack.Push([datetime]$traceEvent.current_time)
                }
                "DirectQueryBegin" {
                    $directQueryBeginStack.Push([datetime]$traceEvent.current_time)
                }
                "VertiPaqSEQueryEnd" {
                    $endTs = [datetime]$traceEvent.current_time
                    $startTs = $null
                    if ($traceEvent.duration_ms -gt 0) {
                        $startTs = $endTs.AddMilliseconds(-1.0 * [double]$traceEvent.duration_ms)
                    } elseif ($vertiPaqBeginStack.Count -gt 0) {
                        $startTs = $vertiPaqBeginStack.Pop()
                    } else {
                        $startTs = $endTs
                    }

                    if ($endTs -ge $startTs) {
                        [void]$seIntervals.Add([pscustomobject]@{ start_time = $startTs; end_time = $endTs })
                    }
                }
                "DirectQueryEnd" {
                    $endTs = [datetime]$traceEvent.current_time
                    $startTs = $null
                    if ($traceEvent.duration_ms -gt 0) {
                        $startTs = $endTs.AddMilliseconds(-1.0 * [double]$traceEvent.duration_ms)
                    } elseif ($directQueryBeginStack.Count -gt 0) {
                        $startTs = $directQueryBeginStack.Pop()
                    } else {
                        $startTs = $endTs
                    }

                    if ($endTs -ge $startTs) {
                        [void]$seIntervals.Add([pscustomobject]@{ start_time = $startTs; end_time = $endTs })
                    }
                }
            }
        }

        $seIntervals = @($seIntervals)
        $seSumMs = if ($seEndEvents.Count -gt 0) {
            [double][math]::Round(($seEndEvents | Measure-Object duration_ms -Sum).Sum, 3)
        } else {
            0.0
        }
        $seDerivedMs = if ($seIntervals.Count -gt 0) {
            [double][math]::Round(($seIntervals | ForEach-Object { ([datetime]$_.end_time - [datetime]$_.start_time).TotalMilliseconds } | Measure-Object -Sum).Sum, 3)
        } else {
            0.0
        }
        $seNetMs = Get-IntervalUnionDurationMs -Intervals $seIntervals

        $totalMs = if ($queryEndEvent -and $queryEndEvent.duration_ms -gt 0) {
            [double][math]::Round($queryEndEvent.duration_ms, 3)
        } else {
            [double][math]::Round($totalElapsedMs, 3)
        }

        $feMs = [double][math]::Round([math]::Max(0.0, $totalMs - $seNetMs), 3)
        $cacheHits = @($events | Where-Object { $_.event_class -eq "VertiPaqSEQueryCacheMatch" }).Count

        return [pscustomobject]@{
            total_elapsed_ms = $totalMs
            storage_engine_ms = $seNetMs
            formula_engine_ms = $feMs
            storage_engine_source = [pscustomobject]@{
                source = "trace"
                event_classes = @("VertiPaqSEQueryEnd", "DirectQueryEnd")
                raw_sum_ms = $seSumMs
                derived_sum_ms = $seDerivedMs
                net_parallel_ms = $seNetMs
                query_count = $seEndEvents.Count
                cache_matches = $cacheHits
            }
            formula_engine_source = [pscustomobject]@{
                source = "trace"
                calculation = "max(0, total - storage_engine_net_parallel)"
            }
            inference_note = "FE/SE values are derived from server trace events (QueryEnd, VertiPaqSEQueryEnd, DirectQueryEnd), matching DAX Studio timing semantics."
            trace_correlation = $traceCorrelation
            trace_event_count = $events.Count
            trace_events = $events
        }
    } catch {
        throw "Trace timing failed at step '$traceStep'. $($_.Exception.ToString())"
    } finally {
        if ($trace) {
            try {
                $trace.remove_OnEvent($handler)
            } catch {
                # Ignore handler detach failures during cleanup.
            }

            try {
                if ($trace.IsStarted) {
                    $trace.Stop()
                }
            } catch {
                # Ignore trace stop failures during cleanup.
            }

            try {
                $trace.Drop()
            } catch {
                # Ignore trace drop failures during cleanup.
            }
        }

        if ($traceReader) {
            try {
                if ($traceReaderStopMethod) {
                    [void]$traceReaderStopMethod.Invoke($traceReader, @())
                }
            } catch {
                # Ignore trace reader stop failures during cleanup.
            }

            try {
                if ($traceReaderDisposeMethod) {
                    [void]$traceReaderDisposeMethod.Invoke($traceReader, @())
                }
            } catch {
                # Ignore trace reader dispose failures during cleanup.
            }
        }

        if ($amoServer.Connected) {
            $amoServer.Disconnect()
        }
        $amoServer.Dispose()
        $queryEndSignal.Dispose()
        $traceStartedSignal.Dispose()
    }
}

# Performance counter snapshot block
function Get-PerformanceCounters {
    param(
        [Microsoft.AnalysisServices.AdomdClient.AdomdConnection]$Connection
    )

    # Try explicit projection first, then fallback to wildcard for engines that expose different schemas.
    $candidateQueries = @(
@"
SELECT
  [OBJECT_NAME],
  [COUNTER_NAME],
  [INSTANCE_NAME],
  [CNTR_VALUE]
FROM `$SYSTEM.DISCOVER_PERFORMANCE_COUNTERS
"@,
@"
SELECT *
FROM `$SYSTEM.DISCOVER_PERFORMANCE_COUNTERS
"@
    )

    $errors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($query in $candidateQueries) {
        try {
            return @(Invoke-DmvRows -Connection $Connection -Query $query)
        } catch {
            [void]$errors.Add($_.Exception.Message)
        }
    }

    throw ("Unable to read DISCOVER_PERFORMANCE_COUNTERS. Attempts failed: {0}" -f ($errors -join " | "))
}

# Counter delta block
function Get-CounterDelta {
    param(
        [object[]]$Before,
        [object[]]$After
    )

    $beforeMap = @{}
    foreach ($row in $Before) {
        $key = "{0}|{1}|{2}" -f $row.OBJECT_NAME, $row.COUNTER_NAME, $row.INSTANCE_NAME
        $beforeMap[$key] = [double]($row.CNTR_VALUE)
    }

    $deltaRows = New-Object 'System.Collections.Generic.List[psobject]'
    foreach ($row in $After) {
        $key = "{0}|{1}|{2}" -f $row.OBJECT_NAME, $row.COUNTER_NAME, $row.INSTANCE_NAME
        $afterValue = [double]($row.CNTR_VALUE)
        $beforeValue = 0.0
        if ($beforeMap.ContainsKey($key)) {
            $beforeValue = $beforeMap[$key]
        }

        $delta = $afterValue - $beforeValue
        if ($delta -ne 0) {
            [void]$deltaRows.Add([pscustomobject]@{
                object_name = [string]$row.OBJECT_NAME
                counter_name = [string]$row.COUNTER_NAME
                instance_name = [string]$row.INSTANCE_NAME
                delta_value = [double]$delta
            })
        }
    }

    return @($deltaRows)
}

# FE/SE inference block
function Get-EngineTimeInference {
    param(
        [object[]]$CounterDeltas,
        [double]$TotalElapsedMs
    )

    $seCandidates = $CounterDeltas | Where-Object {
        $name = (([string]$_.object_name) + " " + ([string]$_.counter_name) + " " + ([string]$_.instance_name)).ToLowerInvariant()
        ($name -match "storage\s*engine|vertipaq|\bse\b") -and ($name -match "time|duration|ms|msec|cpu")
    } | Sort-Object delta_value -Descending

    $feCandidates = $CounterDeltas | Where-Object {
        $name = (([string]$_.object_name) + " " + ([string]$_.counter_name) + " " + ([string]$_.instance_name)).ToLowerInvariant()
        ($name -match "formula\s*engine|\bfe\b") -and ($name -match "time|duration|ms|msec|cpu")
    } | Sort-Object delta_value -Descending

    $seMs = $null
    $feMs = $null

    if ($seCandidates -and $seCandidates.Count -gt 0) {
        $seMs = [double]$seCandidates[0].delta_value
    }
    if ($feCandidates -and $feCandidates.Count -gt 0) {
        $feMs = [double]$feCandidates[0].delta_value
    }

    return [pscustomobject]@{
        total_elapsed_ms = [math]::Round($TotalElapsedMs, 3)
        storage_engine_ms = $seMs
        formula_engine_ms = $feMs
        storage_engine_source = if ($seCandidates -and $seCandidates.Count -gt 0) { $seCandidates[0] } else { $null }
        formula_engine_source = if ($feCandidates -and $feCandidates.Count -gt 0) { $feCandidates[0] } else { $null }
        inference_note = "FE/SE values are inferred from DISCOVER_PERFORMANCE_COUNTERS deltas and depend on engine-exposed counters."
    }
}

# VertiPaq snapshot extraction block
function Get-VertiPaqSnapshot {
    param(
        [Microsoft.AnalysisServices.AdomdClient.AdomdConnection]$Connection
    )

    $dmvQueries = [ordered]@{
        storage_table_columns = "SELECT * FROM `$SYSTEM.DISCOVER_STORAGE_TABLE_COLUMNS"
        object_memory_usage = "SELECT * FROM `$SYSTEM.DISCOVER_OBJECT_MEMORY_USAGE"
        tm_tables = "SELECT * FROM `$SYSTEM.TMSCHEMA_TABLES"
        tm_columns = "SELECT * FROM `$SYSTEM.TMSCHEMA_COLUMNS"
        tm_measures = "SELECT * FROM `$SYSTEM.TMSCHEMA_MEASURES"
        tm_relationships = "SELECT * FROM `$SYSTEM.TMSCHEMA_RELATIONSHIPS"
        tm_hierarchies = "SELECT * FROM `$SYSTEM.TMSCHEMA_HIERARCHIES"
    }

    $snapshot = [ordered]@{}
    foreach ($key in $dmvQueries.Keys) {
        try {
            $snapshot[$key] = @(Invoke-DmvRows -Connection $Connection -Query $dmvQueries[$key])
        } catch {
            $snapshot[$key] = [ordered]@{ error = $_.Exception.Message }
        }
    }

    return $snapshot
}

# Model structure extraction block
function Get-ModelStructure {
    param(
        [Microsoft.AnalysisServices.AdomdClient.AdomdConnection]$Connection
    )

    $tables = @(Invoke-DmvRows -Connection $Connection -Query "SELECT * FROM `$SYSTEM.TMSCHEMA_TABLES")
    $columns = @(Invoke-DmvRows -Connection $Connection -Query "SELECT * FROM `$SYSTEM.TMSCHEMA_COLUMNS")
    $measures = @(Invoke-DmvRows -Connection $Connection -Query "SELECT * FROM `$SYSTEM.TMSCHEMA_MEASURES")
    $relationships = @(Invoke-DmvRows -Connection $Connection -Query "SELECT * FROM `$SYSTEM.TMSCHEMA_RELATIONSHIPS")

    $tableById = @{}
    foreach ($table in $tables) {
        $tableId = [string](Get-DmvFieldValue -Row $table -Name "ID")
        $tableName = [string](Get-DmvFieldValue -Row $table -Name "Name")
        if ($tableId -and $tableId.Trim().Length -gt 0) {
            $tableById[$tableId] = $tableName
        }
    }

    $columnById = @{}
    foreach ($column in $columns) {
        $columnId = [string](Get-DmvFieldValue -Row $column -Name "ID")
        $tableId = [string](Get-DmvFieldValue -Row $column -Name "TableID")
        $columnName = [string](Get-DmvFieldValue -Row $column -Name "Name")
        if ($columnId -and $columnId.Trim().Length -gt 0) {
            $columnById[$columnId] = [pscustomobject]@{
                table_id = $tableId
                table_name = $tableById[$tableId]
                column_name = $columnName
            }
        }
    }

    $relationshipView = New-Object 'System.Collections.Generic.List[psobject]'
    foreach ($rel in $relationships) {
        $relId = [string](Get-DmvFieldValue -Row $rel -Name "ID")
        $fromColumnId = [string](Get-DmvFieldValue -Row $rel -Name "FromColumnID")
        $toColumnId = [string](Get-DmvFieldValue -Row $rel -Name "ToColumnID")
        $isActive = Get-DmvFieldValue -Row $rel -Name "IsActive"
        $crossFilteringBehavior = Get-DmvFieldValue -Row $rel -Name "CrossFilteringBehavior"

        $fromCol = $columnById[$fromColumnId]
        $toCol = $columnById[$toColumnId]
        [void]$relationshipView.Add([pscustomobject]@{
            id = $relId
            from = if ($fromCol) { "{0}[{1}]" -f @($fromCol.table_name, $fromCol.column_name) } else { $fromColumnId }
            to = if ($toCol) { "{0}[{1}]" -f @($toCol.table_name, $toCol.column_name) } else { $toColumnId }
            is_active = if ($null -ne $isActive) { [bool]$isActive } else { $null }
            cross_filtering_behavior = $crossFilteringBehavior
        })
    }

    return [ordered]@{
        counts = [ordered]@{
            tables = $tables.Count
            columns = $columns.Count
            measures = $measures.Count
            relationships = $relationships.Count
        }
        tables = $tables
        columns = $columns
        measures = $measures
        relationships = @($relationshipView)
    }
}

if ($ListMeasures.IsPresent) {
    Import-AnalysisServicesAssemblies
    $discovery = $null
    if ($AutoDiscover.IsPresent -or -not $Server -or $Server.Trim().Length -eq 0) {
        $discovery = Get-AutoDiscoveredEndpoint -RequestedPbixPath $PbixPath -RequestedPowerBIFileName $PowerBIFileName
        $Server = $discovery.server
    }

    if (-not $Server -or $Server.Trim().Length -eq 0) {
        throw "Server is required. Auto-discovery failed, so pass -Server and optionally -Database explicitly."
    }

    $Database = Resolve-DatabaseName -DataSource $Server -RequestedDatabase $Database
    $connection = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection("Data Source=$Server;Initial Catalog=$Database")
    $connection.Open()

    try {
        $modelStructure = Get-ModelStructure -Connection $connection
        $tableById = @{}
        foreach ($table in $modelStructure.tables) {
            $tableId = [string](Get-DmvFieldValue -Row $table -Name "ID")
            if ($tableId -and $tableId.Trim().Length -gt 0) {
                $tableById[$tableId] = [string](Get-DmvFieldValue -Row $table -Name "Name")
            }
        }

        $searchText = if ($MeasureSearch) { $MeasureSearch.Trim() } else { "" }
        $allMeasures = @($modelStructure.measures | ForEach-Object {
            $measureName = [string](Get-DmvFieldValue -Row $_ -Name "Name")
            $tableId = [string](Get-DmvFieldValue -Row $_ -Name "TableID")
            $expression = [string](Get-DmvFieldValue -Row $_ -Name "Expression")
            $isHidden = Get-DmvFieldValue -Row $_ -Name "IsHidden"

            [pscustomobject]@{
                table = $tableById[$tableId]
                name = $measureName
                expression = $expression
                is_exact_name_match = if ($searchText.Length -gt 0) { $measureName.ToLowerInvariant() -eq $searchText.ToLowerInvariant() } else { $null }
                is_hidden = if ($null -ne $isHidden) { [bool]$isHidden } else { $null }
            }
        })
        $totalMeasureCount = $allMeasures.Count
        $measures = $allMeasures

        if ($searchText.Length -gt 0) {
            $searchLower = $searchText.ToLowerInvariant()
            $measures = @($measures | Where-Object {
                ($_.name -and $_.name.ToLowerInvariant().Contains($searchLower)) -or
                ($_.table -and $_.table.ToLowerInvariant().Contains($searchLower)) -or
                ($_.expression -and $_.expression.ToLowerInvariant().Contains($searchLower))
            })
        }

        $noMatchesForSearch = $null
        if ($searchText.Length -gt 0 -and $measures.Count -eq 0) {
            $tokens = @($searchText -split '\s+' | Where-Object { $_ -and $_.Trim().Length -gt 0 } | ForEach-Object { $_.ToLowerInvariant() })
            $suggestions = @()

            if ($tokens.Count -gt 0) {
                $suggestions = @(
                    $allMeasures |
                        Where-Object {
                            $nameLower = if ($_.name) { $_.name.ToLowerInvariant() } else { "" }
                            ($tokens | Where-Object { $nameLower.Contains($_) } | Select-Object -First 1).Count -gt 0
                        } |
                        Select-Object -ExpandProperty name |
                        Sort-Object -Unique |
                        Select-Object -First 10
                )
            }

            if ($suggestions.Count -eq 0) {
                $suggestions = @(
                    $allMeasures |
                        Select-Object -ExpandProperty name |
                        Sort-Object -Unique |
                        Select-Object -First 10
                )
            }

            $noMatchesForSearch = [ordered]@{
                search = $searchText
                total_measures_in_model = $totalMeasureCount
                suggestions = $suggestions
                guidance = "No measures matched -MeasureSearch. Retry with a different fragment, or omit -MeasureSearch to list all measures. Do NOT write custom lookup code."
            }
        }

        $payload = [ordered]@{
            discovered_server = $Server
            discovered_database = $Database
            discovered_pbix_path = if ($discovery) { $discovery.pbix_path } else { $null }
            count = $measures.Count
            search = if ($searchText.Length -gt 0) { $searchText } else { $null }
            measures = $measures
        }
        if ($noMatchesForSearch) {
            $payload.no_matches_for_search = $noMatchesForSearch
        }

        if ($Json.IsPresent) {
            $payload | ConvertTo-Json -Depth 6
        } else {
            Write-Output ("Measures found: {0}" -f $payload.count)
            if ($payload.search) {
                Write-Output ("Search: {0}" -f $payload.search)
            }
            foreach ($measure in $measures) {
                Write-Output ("- {0}[{1}]" -f @($measure.table, $measure.name))
                if ($null -ne $measure.is_hidden) {
                    Write-Output ("  Hidden: {0}" -f $measure.is_hidden)
                }
            }
        }
    } finally {
        if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
            $connection.Close()
        }
        $connection.Dispose()
    }

    return
}

# Main orchestration block
if ($ListLocalInstances.IsPresent) {
    $instances = @(Get-LocalSemanticModelInstances)
    if ($Json.IsPresent) {
        [ordered]@{
            count = $instances.Count
            instances = $instances
        } | ConvertTo-Json -Depth 6
    } else {
        Write-Output ("Local instances found: {0}" -f $instances.Count)
        foreach ($instance in $instances) {
            Write-Output ("- {0} ({1})" -f $instance.server, $instance.parent_window_title)
        }
    }
    return
}

Import-AnalysisServicesAssemblies
$discovery = $null
if ($AutoDiscover.IsPresent -or -not $Server -or $Server.Trim().Length -eq 0) {
    $discovery = Get-AutoDiscoveredEndpoint -RequestedPbixPath $PbixPath -RequestedPowerBIFileName $PowerBIFileName
    $Server = $discovery.server
}

if (-not $Server -or $Server.Trim().Length -eq 0) {
    throw "Server is required. Auto-discovery failed, so pass -Server and optionally -Database explicitly."
}

$Database = Resolve-DatabaseName -DataSource $Server -RequestedDatabase $Database

if ($ApplyMeasure.IsPresent -and -not $StructureOnly.IsPresent) {
    throw "-ApplyMeasure must be combined with -StructureOnly. Apply or update the measure first, then run a separate timing command with -DaxQuery or -DaxFile."
}

if ($ApplyMeasure.IsPresent -and -not $ConfirmApply.IsPresent) {
    throw "-ApplyMeasure requires -ConfirmApply after the user explicitly selects model output mode."
}

if ($ApplyMeasure.IsPresent -and -not $IAcknowledgeUserConsent.IsPresent) {
    throw "ERROR: -ApplyMeasure requires explicit user consent. The orchestrating agent must pass -IAcknowledgeUserConsent only after the user selected 'model' output mode (see SKILL.md step 4)."
}

if (($DaxQuery -and $DaxQuery.Trim().Length -gt 0) -and ($DaxFile -and $DaxFile.Trim().Length -gt 0)) {
    throw "Conflicting parameters: -DaxQuery and -DaxFile cannot be used together. Pass only one."
}

$daxText = ""
$timingCaptured = -not $StructureOnly.IsPresent
if ($timingCaptured) {
    if (($DaxQuery -and $DaxQuery.Trim().Length -gt 0) -or ($DaxFile -and $DaxFile.Trim().Length -gt 0)) {
        $daxText = Get-DaxText -InlineDax $DaxQuery -FilePath $DaxFile
    } elseif (-not $ApplyMeasure.IsPresent) {
        $daxText = Get-DaxText -InlineDax $DaxQuery -FilePath $DaxFile
    } else {
        $timingCaptured = $false
    }
}

$measureApplyResult = $null
$measureExpressionText = ""
if ($ApplyMeasure.IsPresent) {
    if (-not $MeasureTable -or $MeasureTable.Trim().Length -eq 0) {
        throw "-MeasureTable is required when using -ApplyMeasure."
    }
    if (-not $MeasureName -or $MeasureName.Trim().Length -eq 0) {
        throw "-MeasureName is required when using -ApplyMeasure."
    }
    if ($DaxQuery -and $DaxQuery.Trim().Length -gt 0) {
        throw "-DaxQuery cannot be used with -ApplyMeasure. Use -MeasureExpression for direct model apply, or -DaxFile only after explicit file-backed-source approval. Use -DaxQuery only in the separate timing command."
    }
    $measureExpressionText = Get-MeasureExpressionText -InlineExpression $MeasureExpression -FilePath $DaxFile
}

if (-not $timingCaptured -and -not $ApplyMeasure.IsPresent -and -not $StructureOnly.IsPresent) {
    $daxText = Get-DaxText -InlineDax $DaxQuery -FilePath $DaxFile
}

$connection = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection("Data Source=$Server;Initial Catalog=$Database")
$connection.Open()

try {
    $cacheCleared = $false
    if ($timingCaptured -and -not $NoClearCache.IsPresent) {
        Clear-DatabaseCache -DataSource $Server -InitialCatalog $Database
        $cacheCleared = $true
    }

    if ($ApplyMeasure.IsPresent) {
        if (-not (Test-ModelTableExists -Connection $connection -TableName $MeasureTable)) {
            throw "Table '$MeasureTable' was not found in model '$Database'."
        }

        $setMeasureResult = Set-ModelMeasure -DataSource $Server -InitialCatalog $Database -TableName $MeasureTable -Name $MeasureName -Expression $measureExpressionText -Description $MeasureDescription -FormatString $MeasureFormatString -IsHidden $MeasureHidden.IsPresent
        $measureApplyResult = [ordered]@{
            applied = $true
            table = $MeasureTable
            measure = $MeasureName
            expression_source = if ($MeasureExpression -and $MeasureExpression.Trim().Length -gt 0) { "MeasureExpression" } else { "DaxFile" }
            created = $setMeasureResult.created
            metadata_preserved = $setMeasureResult.metadata_preserved
        }
    }

    $counterDeltas = @()
    $traceEvents = @()
    $engineTimes = [pscustomobject]@{
        total_elapsed_ms = $null
        storage_engine_ms = $null
        formula_engine_ms = $null
        storage_engine_source = $null
        formula_engine_source = $null
        inference_note = "No timing captured in structure-only mode."
    }

    if ($timingCaptured) {
        try {
            $traceTiming = Invoke-DaxWithTraceTimings -Connection $connection -DataSource $Server -Query $daxText -TimeoutSeconds $QueryTimeoutSeconds
            $engineTimes = $traceTiming
            $traceEvents = @($traceTiming.trace_events)
        } catch {
            $counterCaptureError = "Trace timing capture failed and counter fallback was used. Trace error: $($_.Exception.ToString())"
            try {
                $fallbackCacheCleared = $false
                if (-not $NoClearCache.IsPresent) {
                    try {
                        Clear-DatabaseCache -DataSource $Server -InitialCatalog $Database
                        $fallbackCacheCleared = $true
                    } catch {
                        $counterCaptureError = "$counterCaptureError Fallback cache re-clear failed: $($_.Exception.ToString())"
                    }
                }
                if ($NoClearCache.IsPresent) {
                    $cacheCleared = $false
                } else {
                    $cacheCleared = $fallbackCacheCleared
                }

                $beforeCounters = @(Get-PerformanceCounters -Connection $connection)
                $totalElapsedMs = Invoke-DaxAndMeasureTotal -Connection $connection -Query $daxText -TimeoutSeconds $QueryTimeoutSeconds
                $afterCounters = @(Get-PerformanceCounters -Connection $connection)
                $counterDeltas = @(Get-CounterDelta -Before $beforeCounters -After $afterCounters)
                $engineTimes = Get-EngineTimeInference -CounterDeltas $counterDeltas -TotalElapsedMs $totalElapsedMs
                $engineTimes.inference_note = "Counter-based fallback was used because trace timing capture failed. $counterCaptureError"
            } catch {
                throw "Trace timing capture failed and counter fallback also failed. $counterCaptureError Counter fallback error: $($_.Exception.ToString())"
            }
        }
    }

    try {
        $modelStructure = Get-ModelStructure -Connection $connection
        $vertipaqSnapshot = Get-VertiPaqSnapshot -Connection $connection
    } catch {
        if ($measureApplyResult) {
            $partialCli = [ordered]@{
                error = "Measure apply succeeded, but post-apply model inspection failed: $($_.Exception.Message)"
                partial_success = $true
                inspection_failed = $true
                output_file = $null
                discovered_server = $Server
                discovered_database = $Database
                discovered_pbix_path = if ($discovery) { $discovery.pbix_path } else { $null }
                cache_cleared_before_measurement = $cacheCleared
                timing_captured = $timingCaptured
                measure_applied = $true
                measure_target = "{0}[{1}]" -f @($measureApplyResult.table, $measureApplyResult.measure)
                measure_apply = $measureApplyResult
            }
            if ($Json.IsPresent) {
                $partialCli | ConvertTo-Json -Depth 6
            } else {
                Write-Output $partialCli.error
                Write-Output ("Measure applied: {0}" -f $partialCli.measure_target)
            }
            exit 0
        }

        throw
    }

    $result = [ordered]@{
        generated_at_utc = [DateTime]::UtcNow.ToString("o")
        server = $Server
        database = $Database
        discovery = $discovery
        cache_cleared_before_measurement = $cacheCleared
        structure_only = (-not $timingCaptured)
        timing_captured = $timingCaptured
        measure_apply = $measureApplyResult
        query = $daxText
        model_structure = $modelStructure
        timings = $engineTimes
        trace_events = $traceEvents
        counter_deltas = $counterDeltas
        vertipaq_snapshot = $vertipaqSnapshot
    }

    $resolvedOutputFile = $null
    $shouldWriteOutputFile = $WriteOutputFile.IsPresent -or ($OutputFile -and $OutputFile.Trim().Length -gt 0)
    if ($shouldWriteOutputFile -and -not $IAcknowledgeUserConsent.IsPresent) {
        throw "ERROR: -WriteOutputFile and -OutputFile require explicit user consent. The orchestrating agent must pass -IAcknowledgeUserConsent only after the user selected 'default file' or 'custom file' output mode (see SKILL.md step 6)."
    }
    if ($shouldWriteOutputFile) {
        if (-not $OutputFile -or $OutputFile.Trim().Length -eq 0) {
            $safeDb = ($Database -replace "[^A-Za-z0-9_-]", "_")
            $workspaceRoot = Get-WorkspaceRoot
            $OutputFile = Join-Path $workspaceRoot ("dax_outputs/{0}_vertipaq_ai_snapshot.json" -f $safeDb)
        }

        $outputDir = Split-Path -Parent $OutputFile
        if ($outputDir -and -not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }

        $jsonText = $result | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($OutputFile, $jsonText, [System.Text.Encoding]::UTF8)
        $resolvedOutputFile = (Resolve-Path $OutputFile).Path
    }

    $cli = [ordered]@{
        output_file = $resolvedOutputFile
        discovered_server = $Server
        discovered_database = $Database
        discovered_pbix_path = if ($discovery) { $discovery.pbix_path } else { $null }
        cache_cleared_before_measurement = $cacheCleared
        timing_captured = $timingCaptured
        measure_applied = if ($measureApplyResult) { $measureApplyResult.applied } else { $false }
        measure_target = if ($measureApplyResult) { "{0}[{1}]" -f @($measureApplyResult.table, $measureApplyResult.measure) } else { $null }
        model_tables = $modelStructure.counts.tables
        model_columns = $modelStructure.counts.columns
        model_measures = $modelStructure.counts.measures
        model_relationships = $modelStructure.counts.relationships
        total_elapsed_ms = $engineTimes.total_elapsed_ms
        storage_engine_ms = $engineTimes.storage_engine_ms
        formula_engine_ms = $engineTimes.formula_engine_ms
    }

    if ($Json.IsPresent) {
        $cli | ConvertTo-Json -Depth 6
    } else {
        if ($cli.output_file) {
            Write-Output ("Output file: {0}" -f $cli.output_file)
        } else {
            Write-Output "Output file: not written (use -WriteOutputFile or -OutputFile with -IAcknowledgeUserConsent to save JSON artifact)"
        }
        Write-Output ("Cache cleared before run: {0}" -f $cli.cache_cleared_before_measurement)
        Write-Output ("Total elapsed ms: {0}" -f $cli.total_elapsed_ms)
        Write-Output ("Storage engine ms: {0}" -f $cli.storage_engine_ms)
        Write-Output ("Formula engine ms: {0}" -f $cli.formula_engine_ms)
    }
} finally {
    if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
        $connection.Close()
    }
    $connection.Dispose()
}
