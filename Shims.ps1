# Shims.ps1 — diskpart-backed replacements for the Hyper-V VHD cmdlets (plus AD/BitLocker stubs)
#
# Lets the FSLogixMigration module run on servers that do NOT have the Hyper-V platform installed
# (e.g. SQL/file servers where enabling Hyper-V is not an option), and from non-interactive
# logon contexts (SSH/network logons) where the ActiveDirectory module cannot reach ADWS.
#
# Dot-source this BEFORE importing FSLogixMigration:
#   . "$PSScriptRoot\Shims.ps1"
#   Import-Module <path>\FSLogixMigration.psd1
#
# Requires: elevated session (diskpart), the storage cmdlets (built-in).
# Optional:   $ShimDomain — defaults to $env:USERDOMAIN; used by the Get-ADUser shim.

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning 'Shims.ps1: session is NOT elevated - diskpart calls will fail. Run from an elevated PowerShell.'
}

$global:ShimMounts = @{}   # vhd path (lowercase) -> disk number

function Invoke-Diskpart {
    param([string]$ScriptText, [string]$Tag)
    $tmp = Join-Path $env:TEMP ("dp-" + [guid]::NewGuid().ToString('N') + '.txt')
    Set-Content -Path $tmp -Value $ScriptText -Encoding ASCII
    $out = diskpart /s $tmp
    Remove-Item $tmp -ErrorAction SilentlyContinue
    $bad = $out | Where-Object { $_ -match 'error|fail|denied|not recognized' }
    if ($bad) {
        Write-Host "  [shim][diskpart:$Tag] output:" -ForegroundColor Yellow
        $out | Where-Object { $_.Trim() } | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    }
    return ($null -eq $bad)
}

function New-VHD {
    # Replaces: Hyper-V New-VHD. Creates a dynamic (expandable) VHDX via diskpart.
    # NOTE: diskpart has no logical-sector-size switch; VHDX defaults apply (512 logical).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)][string]$Path,
        [uint64]$SizeBytes,
        [switch]$Dynamic,
        [uint32]$LogicalSectorSizeBytes
    )
    $dir = Split-Path $Path
    if (-not (Test-Path $dir)) { New-Item $dir -ItemType Directory -Force | Out-Null }
    $mb = [uint32]($SizeBytes / 1MB)
    $ok = Invoke-Diskpart -ScriptText ("create vdisk file=`"$Path`" maximum=$mb type=expandable") -Tag 'create'
    if (-not $ok) { Write-Error "[shim] create vdisk FAILED: $Path"; return }
    Write-Host "  [shim] created vdisk: $Path ($mb MB dynamic)"
    [pscustomobject]@{ Path = $Path }
}

function Mount-VHD {
    # Replaces: Hyper-V Mount-VHD. Attaches via diskpart and emits an object with
    # Number/DiskNumber/Path so the module's pipelines (`| Get-Disk`, `Get-Disk -number {$_.DiskNumber}`)
    # both bind correctly.
    # IMPORTANT: ValueFromPipelineByPropertyName is REQUIRED on $Path — with Position=0 alone,
    # pipeline objects bind ByValue (string) only and the module fails with
    # "missing mandatory parameters: Path". That was the one-line difference between failure and success.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)][string]$Path,
        [switch]$Passthru,
        [switch]$ReadOnly
    )
    $before = @(Get-Disk).Number
    $mode = if ($ReadOnly) { 'attach vdisk readonly' } else { 'attach vdisk' }
    $ok = Invoke-Diskpart -ScriptText ("select vdisk file=`"$Path`"`r`n$mode") -Tag 'attach'
    if (-not $ok) { Write-Error "[shim] attach FAILED (diskpart error): $Path"; return }
    $num = $null
    foreach ($i in 1..20) {
        Start-Sleep -Milliseconds 500
        $new = @(Get-Disk | Where-Object { $_.Number -notin $before })
        if ($new.Count -ge 1) { $num = ($new | Select-Object -First 1).Number; break }
    }
    if ($null -eq $num) { Write-Error "[shim] attach FAILED (no new disk appeared within 10s): $Path"; return }
    $global:ShimMounts[$Path.ToLower()] = $num
    Write-Host "  [shim] attached $Path -> disk $num"
    if ($Passthru) { [pscustomobject]@{ Number = $num; DiskNumber = $num; Path = $Path } }
}

function Dismount-VHD {
    # Replaces: Hyper-V Dismount-VHD.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)][string]$Path)
    $null = Invoke-Diskpart -ScriptText ("select vdisk file=`"$Path`"`r`ndetach vdisk") -Tag 'detach'
    $global:ShimMounts.Remove($Path.ToLower())
    Write-Host "  [shim] detached $Path"
}

function Get-DiskImage {
    # Replaces: Hyper-V Get-DiskImage. Returns the real Get-Disk object for a mounted vhd,
    # resolved from the shim's path->disk map (falling back to the sole file-backed disk).
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ImagePath)
    $p = if ($ImagePath) { $ImagePath.ToLower() } else { $null }
    $num = if ($p -and $global:ShimMounts.ContainsKey($p)) { $global:ShimMounts[$p] } else { $null }
    if ($null -eq $num) {
        $fb = @(Get-Disk | Where-Object BusType -match 'File')
        if ($fb.Count -eq 1) { $num = $fb[0].Number }
    }
    if ($null -eq $num) { Write-Error "[shim] Get-DiskImage: no mapping for '$ImagePath'"; return }
    Get-Disk -Number $num
}

function Get-ADUser {
    # Replaces: the ActiveDirectory module's Get-ADUser, but ONLY for what FSLogixMigration's
    # active code paths need: SID <-> SamAccountName translation. Done locally via the LSA
    # (SecurityIdentifier.Translate) so it works from network-logon/SSH sessions where ADWS
    # discovery fails. ObjectGUID is a dummy — the module's GUID-consuming templates are
    # commented out upstream. NOT a general-purpose Get-ADUser.
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $true)][string]$Identity,
        [string[]]$Properties
    )
    $dom = if ($global:ShimDomain) { $global:ShimDomain } else { $env:USERDOMAIN }
    if ($Identity -match '^S-1-') {
        $sid = $Identity
        $sam = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value.Split('\')[-1]
    }
    else {
        $sam = $Identity
        $sid = (New-Object System.Security.Principal.NTAccount($dom, $sam)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    }
    [pscustomobject]@{ SamAccountName = $sam; SID = $sid; ObjectGUID = [guid]::NewGuid() }
}

if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
    # The module calls Get-BitLockerVolume unguarded; stub it on servers without the BitLocker module.
    function Get-BitLockerVolume { param($MountPoint) [pscustomobject]@{ VolumeStatus = 'FullyDecrypted'; MountPoint = $MountPoint } }
    Write-Host '[shim] Get-BitLockerVolume stubbed (module not installed)'
}
