[CmdletBinding()]
param(
    [string]$DaxText = "",
    [string]$DaxFile = "",
    [string]$OutputDir = "",
    [string]$FileName = "",
    [string]$MeasureName = "",
    [switch]$Force,
    [switch]$Json
)

# Guard: surface a clear list of valid parameters if the caller passes an unknown one.
# PowerShell stops binding at an unrecognised parameter, so this block runs only when
# all params above were accepted. Unknown params cause PowerShell's own binding error
# before reaching here; the message below is shown in the catch inside any wrapper.
# Valid parameters: -DaxText, -DaxFile, -OutputDir, -FileName, -MeasureName, -Force, -Json
# Invalid (never use): -MeasureTable, -Table, -Expression, -Database, -Server

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-DaxContent {
    param(
        [string]$InlineText,
        [string]$InputFile
    )

    if (($InlineText -and $InlineText.Trim().Length -gt 0) -and ($InputFile -and $InputFile.Trim().Length -gt 0)) {
        throw "Conflicting parameters: -DaxText and -DaxFile cannot be used together. Pass only one."
    }

    if ($InlineText -and $InlineText.Trim().Length -gt 0) {
        return $InlineText
    }

    if ($InputFile -and -not (Test-Path $InputFile)) {
        throw "DAX file not found: '$InputFile'"
    }

    if ($InputFile -and (Test-Path $InputFile)) {
        return [System.IO.File]::ReadAllText((Resolve-Path $InputFile), [System.Text.Encoding]::UTF8)
    }

    throw "No DAX content provided. Use -DaxText or -DaxFile."
}

function Get-SafeBaseName {
    param(
        [string]$PreferredName,
        [string]$FallbackName
    )

    $candidate = ""
    if ($PreferredName -and $PreferredName.Trim().Length -gt 0) {
        $candidate = $PreferredName.Trim()
    } elseif ($FallbackName -and $FallbackName.Trim().Length -gt 0) {
        $candidate = $FallbackName.Trim()
    } else {
        $candidate = "dax_script"
    }

    $candidate = [System.IO.Path]::GetFileNameWithoutExtension($candidate)
    $safe = $candidate -replace '[\\/:*?"<>|]', '_'
    $safe = $safe -replace '\s+', '_'
    $safe = $safe -replace '_+', '_'
    $safe = $safe.Trim('_')

    if (-not $safe -or $safe.Length -eq 0) {
        return "dax_script"
    }

    return $safe
}

function Get-WorkspaceRootFromScriptPath {
    $workspaceRootComputation = "Resolve-Path (Join-Path `$PSScriptRoot '..\..\..\..')"
    $actionableMessage = "Unable to derive the workspace root for default output files. This script computes workspace root as $workspaceRootComputation. Ensure the script remains at <workspace>/.github/skills/dax-optimize/scripts/write_dax_file.ps1, or pass -OutputDir <absolute path>."

    try {
        $resolvedWorkspaceRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..') -ErrorAction Stop
    } catch {
        throw "$actionableMessage Original error: $($_.Exception.Message)"
    }

    if (-not $resolvedWorkspaceRoot -or -not (Test-Path -LiteralPath $resolvedWorkspaceRoot.Path -PathType Container)) {
        throw $actionableMessage
    }

    return $resolvedWorkspaceRoot.Path
}

$daxContent = Get-DaxContent -InlineText $DaxText -InputFile $DaxFile

if (-not $OutputDir -or $OutputDir.Trim().Length -eq 0) {
    $OutputDir = Join-Path (Get-WorkspaceRootFromScriptPath) "dax scripts"
} elseif (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
    throw "-OutputDir must be an absolute path. Use the workspace 'dax scripts' folder."
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
if ($FileName -and $FileName.Trim().Length -gt 0) {
    $requestedName = [System.IO.Path]::GetFileName($FileName.Trim())
    $requestedStem = [System.IO.Path]::GetFileNameWithoutExtension($requestedName)
    $safeStem = Get-SafeBaseName -PreferredName $requestedStem -FallbackName "dax_script"
    $finalName = "{0}_{1}.dax" -f $safeStem, $timestamp
    if (-not $finalName) {
        throw "Invalid -FileName value: '$FileName'."
    }
} else {
    $baseName = Get-SafeBaseName -PreferredName $FileName -FallbackName $MeasureName
    $finalName = "{0}_{1}.dax" -f $baseName, $timestamp
}
$outputPath = Join-Path $OutputDir $finalName

if ((Test-Path $outputPath) -and -not $Force.IsPresent) {
    throw "Output file already exists: '$outputPath'. Use -Force to overwrite."
}

[System.IO.File]::WriteAllText($outputPath, $daxContent, [System.Text.Encoding]::UTF8)
$resolvedPath = (Resolve-Path $outputPath).Path

$result = [ordered]@{
    output_file = $resolvedPath
    output_dir = (Resolve-Path $OutputDir).Path
    file_name = [System.IO.Path]::GetFileName($resolvedPath)
    content_length = $daxContent.Length
}

if ($Json.IsPresent) {
    $result | ConvertTo-Json -Depth 4
} else {
    Write-Output ("Output file: {0}" -f $result.output_file)
    Write-Output ("Content length: {0}" -f $result.content_length)
}
