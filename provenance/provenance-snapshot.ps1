# provenance-snapshot.ps1
# Universal per-file provenance snapshot - usable anywhere.
#
# In the specified source folder, recursively creates a sidecar provenance file
# for every matching file:
#
#   <filename>.<ext>.provenance
#
# Each sidecar contains:
#   - SHA-256 hash at snapshot time
#   - Snapshot date and time
#   - File size and modification timestamp
#   - Host and user
#
# Sidecars are append-only by default: existing sidecars are NOT overwritten.
# Use -Force to refresh them.
#
# Usage:
#   powershell -File provenance-snapshot.ps1
#       -> interactively asks for source, target, and extensions
#
#   powershell -File provenance-snapshot.ps1 -Source "D:\docs\fontos.md"
#       -> snapshots ONLY this one file, sidecar next to the file
#
#   powershell -File provenance-snapshot.ps1 -Source "D:\docs"
#       -> snapshots every file in the folder, sidecars next to the files
#
#   powershell -File provenance-snapshot.ps1 -Source "D:\docs" -Target "E:\proofs" -Extensions .md,.pdf -Force
#
# Parameters:
#   -Source      : Source: ONE file or one folder. If omitted, prompts for it.
#                  For a file, snapshots only that one file.
#                  For a folder, scans recursively.
#   -Target      : Target folder for sidecars. If empty, writes them next to the files.
#                  If set, mirrors the source folder structure under the target.
#   -Extensions  : Extension list (for example .md,.sql,.py). If empty, all files.
#   -DryRun      : Computes hashes, but writes nothing.
#   -Force       : Refreshes existing sidecars too.
#   -NoPause     : Does not wait for Enter at the end, useful for scheduled runs.

[CmdletBinding()]
param(
    [string]$Source,
    [string]$Target,
    [string[]]$Extensions,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$NoPause
)

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------------
# Ask for / validate source
# ----------------------------------------------------------------------
if (-not $Source) {
    $Source = Read-Host "Source: file OR folder (file = only that file; folder = recursive)"
}
$Source = $Source.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $Source)) {
    Write-Host "ERROR: Source does not exist: $Source" -ForegroundColor Red
    if (-not $NoPause) { Read-Host "Press Enter to close" | Out-Null }
    exit 1
}
$Source = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
$SourceIsFile = Test-Path -LiteralPath $Source -PathType Leaf

# ----------------------------------------------------------------------
# Ask for target (Enter = sidecars next to files)
# ----------------------------------------------------------------------
if (-not $PSBoundParameters.ContainsKey('Target')) {
    $Target = Read-Host "Target folder for .provenance files (Enter = next to source files)"
}
$Target = if ($Target) { $Target.Trim().Trim('"') } else { "" }
if ($Target) {
    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }
    $Target = (Resolve-Path -LiteralPath $Target).Path.TrimEnd('\')
    if ($Target -eq $Source) { $Target = "" }  # same as "next to source files" mode
}

# ----------------------------------------------------------------------
# Extensions (Enter = all files)
# ----------------------------------------------------------------------
if (-not $SourceIsFile -and (-not $Extensions -or $Extensions.Count -eq 0)) {
    $extInput = Read-Host "Extensions separated by commas (for example .md,.sql,.py - Enter = all files)"
    if ($extInput) {
        $Extensions = $extInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
}
if ($Extensions) {
    $Extensions = $Extensions | ForEach-Object {
        $e = $_.ToLower()
        if ($e.StartsWith('.')) { $e } else { ".$e" }
    }
}

# Never snapshot sidecar / timestamp files themselves.
$ExcludePatterns = @('\.provenance$', '\.ots$')

# ----------------------------------------------------------------------
# Log - under provenance_logs next to the target or source
# ----------------------------------------------------------------------
# For a single file, do not create a log/transcript - fast, no side effects.
$LogFile = $null
$LogDir  = $null
if (-not $SourceIsFile) {
    $LogRoot = if ($Target) { $Target } else { $Source }
    $LogDir  = Join-Path $LogRoot "provenance_logs"
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    $RunTimestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $LogFile = Join-Path $LogDir ("snapshot_{0}.log" -f $RunTimestamp)
    Start-Transcript -Path $LogFile -Append | Out-Null
}

Write-Host ""
Write-Host "===================================================================="
Write-Host "  PROVENANCE SNAPSHOT"
Write-Host "  Started:  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
Write-Host "  Source:   $Source"
Write-Host "  Target:   $(if ($Target) { $Target } else { '(next to files)' })"
Write-Host "  Types:    $(if ($Extensions) { $Extensions -join ', ' } else { 'all files' })"
if ($DryRun) { Write-Host "  Mode:     DRY RUN (nothing will be written)" }
if ($Force)  { Write-Host "  Mode:     FORCE (existing sidecars will be refreshed)" }
Write-Host "===================================================================="
Write-Host ""

# ----------------------------------------------------------------------
# File list - recursive scan and filtering
# ----------------------------------------------------------------------
if ($SourceIsFile) {
    $found = @(Get-Item -LiteralPath $Source)
} else {
    $found = Get-ChildItem -LiteralPath $Source -File -Recurse -ErrorAction SilentlyContinue
    if ($Extensions) {
        $found = $found | Where-Object { $Extensions -contains $_.Extension.ToLower() }
    }
}

$collected = New-Object System.Collections.Generic.List[string]
foreach ($f in $found) {
    $excluded = $false
    foreach ($pat in $ExcludePatterns) {
        if ($f.Name -match $pat) { $excluded = $true; break }
    }
    # Skip the log folder too.
    if ($LogDir -and $f.FullName.StartsWith($LogDir)) { $excluded = $true }
    if (-not $excluded) { [void]$collected.Add($f.FullName) }
}
$files = $collected | Sort-Object -Unique

Write-Host "  Files found: $($files.Count)"
Write-Host ""

if ($files.Count -eq 0) {
    Write-Warning "No matching files found in the source."
    if ($LogFile) { Stop-Transcript | Out-Null }
    if (-not $NoPause) { Read-Host "Press Enter to close" | Out-Null }
    exit 0
}

# ----------------------------------------------------------------------
# Compute sidecar path
#   - No Target: <file>.provenance next to the file
#   - With Target: mirror the source relative structure under the target
# ----------------------------------------------------------------------
function Get-SidecarPath([string]$filePath) {
    if (-not $Target) { return "$filePath.provenance" }
    $rel = if ($SourceIsFile) {
        Split-Path $filePath -Leaf
    } else {
        $filePath.Substring($Source.Length).TrimStart('\')
    }
    $dest = Join-Path $Target "$rel.provenance"
    $destDir = Split-Path $dest -Parent
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    return $dest
}

# ----------------------------------------------------------------------
# Snapshot every file
# ----------------------------------------------------------------------
$snapshotTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'
$snapshotIso  = Get-Date -Format 'yyyy-MM-ddTHH:mm:sszzz'
$host_        = $env:COMPUTERNAME
$user_        = $env:USERNAME

$written = 0
$skipped = 0
$failed  = 0

foreach ($file in $files) {
    $sidecar = Get-SidecarPath $file
    $exists  = Test-Path -LiteralPath $sidecar

    if ($exists -and -not $Force) {
        Write-Host "  [skip]   sidecar exists: $(Split-Path $sidecar -Leaf)"
        $skipped++
        continue
    }

    try {
        $h        = (Get-FileHash -Algorithm SHA256 -LiteralPath $file).Hash.ToLower()
        $item     = Get-Item -LiteralPath $file
        $size     = $item.Length
        $mtime    = $item.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
        $mtimeIso = $item.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss')
        $leaf     = Split-Path $file -Leaf

        $sidecarContent = @"
# Provenance - $leaf

- **File:**             ``$leaf``
- **Full path:**        ``$file``
- **SHA-256:**          ``$h``
- **Size:**             $size bytes
- **Modified (file):**  $mtime
- **Snapshotted at:**   $snapshotTime
- **Host:**             $host_
- **User:**             $user_
- **Script:**           ``provenance-snapshot.ps1``

## ISO-8601 timestamps

- File modified:    ``$mtimeIso``
- Snapshot taken:   ``$snapshotIso``

## Verification

To verify this file has not been altered since this snapshot was taken:

``````powershell
Get-FileHash -Algorithm SHA256 -LiteralPath '$file'
``````

The output ``Hash`` field must match ``$h``. If it differs, the file has been modified since this snapshot.

## Notes

- This sidecar is append-only by default. Re-running the snapshot script does not overwrite it.
- To refresh this sidecar against the file's current content, re-run with ``-Force``.
- For blockchain-anchored timestamping, drag this sidecar (or the file itself) into https://opentimestamps.org and save the resulting .ots file next to it.
"@

        $verb = if ($exists) { "refresh" } else { "create " }
        if ($DryRun) {
            Write-Host "  [$verb] (dry) $(Split-Path $sidecar -Leaf)  (sha=$($h.Substring(0,12))...)"
        } else {
            Set-Content -LiteralPath $sidecar -Value $sidecarContent -Encoding utf8 -NoNewline
            Write-Host "  [$verb] $(Split-Path $sidecar -Leaf)  (sha=$($h.Substring(0,12))...)"
        }
        $written++

    } catch {
        Write-Warning "  [fail] $file - $_"
        $failed++
    }
}

# ----------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------
Write-Host ""
Write-Host "===================================================================="
Write-Host "  DONE"
Write-Host "  Total files:       $($files.Count)"
Write-Host "  Sidecars written:  $written"
Write-Host "  Skipped existing:  $skipped"
if ($failed -gt 0) {
    Write-Host "  Failed:            $failed (see warnings above)"
}
if ($LogFile) { Write-Host "  Log:               $LogFile" }
Write-Host "===================================================================="
Write-Host ""

if (-not $DryRun -and $written -gt 0) {
    Write-Host "To refresh, for example after editing files:"
    Write-Host "  .\provenance-snapshot.ps1 -Source '$Source'$(if ($Target) { " -Target '$Target'" }) -Force"
    Write-Host ""
    Write-Host "For blockchain-anchored evidence, drag any sidecar or source file here:"
    Write-Host "  https://opentimestamps.org"
    Write-Host ""
}

if ($LogFile) { Stop-Transcript | Out-Null }

if (-not $NoPause) { Read-Host "Press Enter to close" | Out-Null }
