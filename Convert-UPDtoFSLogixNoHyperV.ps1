# Convert-UPDtoFSLogixNoHyperV.ps1 — migrate RDS User Profile Disks (UPD) to FSLogix Profile
# Containers on servers WITHOUT the Hyper-V platform, using the FSLogixMigration module over
# diskpart-backed shims.
#
# .SYNOPSIS
#   Single user:  .\Convert-UPDtoFSLogixNoHyperV.ps1 -SourcePath D:\Staging\UVHD-S-1-5-21-...-1234.vhdx -Target D:\FSLogix -ModulePath C:\FSLogixMigration\FSLogixMigration.psd1
#   Whole folder: .\Convert-UPDtoFSLogixNoHyperV.ps1 -SourcePath D:\Staging -Target D:\FSLogix -ModulePath C:\FSLogixMigration\FSLogixMigration.psd1
#   Space-safe:   add -DeleteSource to remove each UPD after its container is verified (keeps peak
#                 disk usage at roughly one profile instead of double).
#
# .PARAMETER SourcePath
#   A single UVHD-*.vhdx file, or a folder containing them.
#
# .PARAMETER Target
#   The FSLogix container root (local path or UNC). Containers are created as
#   <Target>\<SID>_<SAM>\Profile_<SAM>.vhdx by the module.
#
# .PARAMETER ModulePath
#   Full path to the FSLogixMigration module's .psd1 (see README for obtaining the module).
#
# .PARAMETER VHDMaxSizeGB   Max dynamic VHDX size per container (default 25).
# .PARAMETER SectorSize     Logical sector size: 512 or 4K (default 512 — matches typical UPDs).
# .PARAMETER DeleteSource   Switch: delete each UPD only after its container verifies (>=25% of
#                           source size). Without it, sources are left untouched.
# .PARAMETER LogPath        Progress log (default: <SourcePath>\convert-batch.log).
#
# .NOTES
#   - Run elevated, on the server holding the UPDs (all disk operations are local — no SMB needed).
#   - Resumable: already-converted users (container exists) are skipped; with -DeleteSource their
#     leftover UPDs are simply removed.
#   - KEEP YOUR ORIGINALS elsewhere until you have validated real logons. This script does not
#     touch the original RDS profile share — copy your UPDs to a staging folder first.

param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$Target,
    [Parameter(Mandatory = $true)][string]$ModulePath,
    [int]$VHDMaxSizeGB = 25,
    [ValidateSet('512', '4K')][string]$SectorSize = '512',
    [switch]$DeleteSource,
    [string]$LogPath
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'NOT ELEVATED - diskpart requires an elevated session. Aborting.' -ForegroundColor Red
    return
}

. (Join-Path $PSScriptRoot 'Shims.ps1')

if (-not $LogPath) {
    $lp = if (Test-Path $SourcePath -PathType Container) { $SourcePath } else { Split-Path $SourcePath }
    $LogPath = Join-Path $lp 'convert-batch.log'
}
function Log([string]$m) { $m | Tee-Object -FilePath $LogPath -Append }

Import-Module $ModulePath -Force

# Build the work list
if (Test-Path $SourcePath -PathType Container) {
    $files = @(Get-ChildItem $SourcePath -Filter 'UVHD-S-*.vhdx' | Sort-Object Length -Descending)
}
else {
    $files = @(Get-Item $SourcePath)
}
if (-not $files) { Log 'No UVHD files found at SourcePath.'; return }

Log ('=== convert start {0} — {1} profile(s), DeleteSource={2} ===' -f (Get-Date -Format 'HH:mm:ss'), $files.Count, $DeleteSource.IsPresent)
$done = 0; $failed = 0; $skipped = 0

foreach ($f in $files) {
    # SID is embedded in the UPD filename: UVHD-<SID>.vhdx — resolve the SAM locally (no ADWS needed)
    $sid = $f.BaseName -replace '^UVHD-', ''
    $sam = $null
    try { $sam = (Get-ADUser -Identity $sid).SamAccountName } catch { }
    if (-not $sam) { Log ("{0}: cannot resolve SID to a user - SKIPPED" -f $f.Name); $skipped++; continue }

    $cont = Join-Path (Join-Path $Target ($sid + '_' + $sam)) ("Profile_$sam.vhdx")

    if (Test-Path $cont) {
        if ($DeleteSource) {
            Remove-Item $f.FullName -Force
            Log ("{0}: container already exists - source deleted" -f $sam)
        }
        else { Log ("{0}: container already exists - skipped (source kept)" -f $sam) }
        $skipped++
        continue
    }

    Log ('{0}: converting ({1:N0} MB)...' -f $sam, ($f.Length / 1MB))
    Convert-UPDProfile -ProfilePath $f.FullName -Target $Target -VHDMaxSizeGB $VHDMaxSizeGB -VHDLogicalSectorSize $SectorSize -LogPath (Join-Path (Split-Path $LogPath) 'module.log')

    if ((Test-Path $cont) -and ((Get-Item $cont).Length -ge ($f.Length * 0.25))) {
        if ($DeleteSource) {
            Remove-Item $f.FullName -Force
            Log ('{0}: OK - container {1:N0} MB, source deleted' -f $sam, ((Get-Item $cont).Length / 1MB))
        }
        else {
            Log ('{0}: OK - container {1:N0} MB (source kept)' -f $sam, ((Get-Item $cont).Length / 1MB))
        }
        $done++
    }
    else {
        Log ('{0}: FAILED verification (container missing or <25% of source size) - source kept' -f $sam)
        $failed++
    }

    # detach anything the module left behind so the next iteration starts clean
    foreach ($stray in @($f.FullName, $cont)) {
        if ($stray -and (Test-Path $stray)) {
            $null = Invoke-Diskpart -ScriptText ("select vdisk file=`"$stray`"`r`ndetach vdisk") -Tag 'cleanup'
        }
    }
}

Log ('=== convert end {0}: converted {1}, skipped {2}, failed {3} ===' -f (Get-Date -Format 'HH:mm:ss'), $done, $skipped, $failed)
