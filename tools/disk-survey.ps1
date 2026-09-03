<#
    disk-survey.ps1 - inventory every disk in a Windows machine before letting
    the Proxmox auto-installer loose on it.

        powershell -ExecutionPolicy Bypass -File disk-survey.ps1
        powershell -ExecutionPolicy Bypass -File disk-survey.ps1 -Json report.json

    Run it AS ADMINISTRATOR. Without elevation Windows hides the serial number
    of some controllers and refuses the BitLocker query, and the serial is the
    whole point: it is the one identifier the Proxmox installer can match that
    does not move when the machine reboots.

    Reads only. It opens nothing for write, mounts nothing and changes no boot
    setting.

    WHAT IT IS FOR
    --------------
    The Proxmox answer file names its victim in one of two ways: a kernel
    device name (sda, nvme0n1) or a udev property glob. Kernel names are handed
    out in probe order, so on a six-disk box the disk that is sdb while you are
    looking at it may be sde on the boot that actually installs. On a machine
    that still holds a Windows install, that is the difference between a spare
    disk and everything on it.

    So this prints, for every disk:

      - the serial, ready to paste into --disk-serial
      - the size, model and bus, to sanity-check the serial against
      - every volume on it with its LABEL and FREE SPACE, which is how a human
        actually recognises "that's the scratch disk" vs "that's my data"
      - unallocated space
      - whether Windows itself, its boot manager or a recovery partition lives
        there - each of which makes the disk a DO-NOT-TOUCH

    and finishes with the exact onboarding command for the disk you pick.
#>

[CmdletBinding()]
param(
    # Also write the raw inventory as JSON, for pasting somewhere it can be
    # read back exactly rather than retyped off a screen.
    [string]$Json
)

$ErrorActionPreference = 'Stop'

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0,7:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0,7:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0,7:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0,7:N0} B ' -f $Bytes)
}

$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ''
Write-Host '================================================================'
Write-Host " DISK SURVEY  -  $env:COMPUTERNAME  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
Write-Host '================================================================'
if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  !! NOT RUNNING AS ADMINISTRATOR.' -ForegroundColor Yellow
    Write-Host '     Serial numbers and BitLocker state may be missing or wrong.' -ForegroundColor Yellow
    Write-Host '     Re-run from an elevated PowerShell before trusting this.' -ForegroundColor Yellow
}

# The disk Windows itself boots from. Everything that follows is really about
# not touching this one.
$sysDrive   = $env:SystemDrive           # normally "C:"
$sysDiskNum = $null
try {
    $sysPart = Get-Partition -DriveLetter $sysDrive.TrimEnd(':') -ErrorAction Stop
    $sysDiskNum = $sysPart.DiskNumber
} catch {
    Write-Host "  (could not resolve which disk holds $sysDrive - be extra careful)" -ForegroundColor Yellow
}

# BitLocker matters here for two reasons: an encrypted Windows volume cannot be
# inspected from Linux at all, and changing the boot path on a BitLockered
# machine can demand the 48-digit recovery key on next boot.
$blByLetter = @{}
try {
    foreach ($v in (Get-BitLockerVolume -ErrorAction Stop)) {
        if ($v.MountPoint) { $blByLetter[$v.MountPoint.TrimEnd('\')] = $v.ProtectionStatus }
    }
} catch { }

$report = @()

foreach ($disk in (Get-Disk | Sort-Object Number)) {

    # Some controllers pad these with spaces; an untrimmed serial pasted into
    # --disk-serial matches nothing and the install aborts having done nothing,
    # which is a confusing way to spend a reboot.
    $serial = ([string]$disk.SerialNumber).Trim()
    $model  = ([string]$disk.FriendlyName).Trim()

    $isSystem = ($null -ne $sysDiskNum -and $disk.Number -eq $sysDiskNum)
    $flags    = @()
    if ($isSystem)      { $flags += "HOLDS WINDOWS ($sysDrive)" }
    if ($disk.IsBoot)   { $flags += 'IsBoot' }
    if ($disk.IsSystem) { $flags += 'IsSystem (holds the EFI boot partition)' }
    if ($disk.IsOffline){ $flags += 'Offline' }

    $parts = @()
    try { $parts = @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop) } catch { }

    foreach ($p in $parts) {
        if ($p.Type -match 'Recovery|System|Reserved') {
            $flags += "has a $($p.Type) partition"
        }
    }
    $flags = $flags | Select-Object -Unique

    Write-Host ''
    Write-Host '----------------------------------------------------------------'
    $hdr = "  DISK $($disk.Number)   $model"
    if ($flags -contains "HOLDS WINDOWS ($sysDrive)") {
        Write-Host $hdr -ForegroundColor Red
    } else {
        Write-Host $hdr -ForegroundColor Green
    }
    Write-Host ('    size        : {0}' -f (Format-Size $disk.Size))
    Write-Host ('    serial      : {0}' -f $(if ($serial) { $serial } else { '(not reported - run elevated)' }))
    Write-Host ('    bus / type  : {0} / {1}' -f $disk.BusType, $disk.PartitionStyle)
    if ($disk.UniqueId) { Write-Host ('    unique id   : {0}' -f $disk.UniqueId) }

    if ($flags.Count) {
        Write-Host ('    flags       : {0}' -f ($flags -join '; ')) -ForegroundColor Yellow
    }

    # ---- volumes: the human-readable half. Label and free space are what
    # ---- actually lets someone say "yes, that is the disk I meant".
    if ($parts.Count) {
        Write-Host '    volumes:'
        Write-Host '      part  letter  label                 fs        size       free      used'
        foreach ($p in ($parts | Sort-Object PartitionNumber)) {
            $letter = if ($p.DriveLetter) { "$($p.DriveLetter):" } else { '--' }
            $label = ''; $fs = ''; $sizeTxt = (Format-Size $p.Size); $freeTxt = '       -'; $usedTxt = '       -'
            if ($p.DriveLetter) {
                try {
                    $vol = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction Stop
                    $label   = $vol.FileSystemLabel
                    $fs      = $vol.FileSystem
                    $freeTxt = Format-Size $vol.SizeRemaining
                    $usedTxt = Format-Size ($vol.Size - $vol.SizeRemaining)
                } catch { }
            } elseif ($p.Type) {
                $label = "<$($p.Type)>"
            }
            $bl = ''
            if ($p.DriveLetter -and $blByLetter.ContainsKey("$($p.DriveLetter):")) {
                if ($blByLetter["$($p.DriveLetter):"] -ne 'Off') { $bl = '  [BitLocker ON]' }
            }
            Write-Host ('      {0,-4}  {1,-6}  {2,-20}  {3,-8}  {4}  {5}  {6}{7}' -f `
                $p.PartitionNumber, $letter, $label, $fs, $sizeTxt, $freeTxt, $usedTxt, $bl)
        }
    } else {
        Write-Host '    volumes: (none - raw/uninitialised disk)'
    }

    $allocated   = ($parts | Measure-Object -Property Size -Sum).Sum
    if (-not $allocated) { $allocated = 0 }
    $unallocated = $disk.Size - $allocated
    if ($unallocated -gt 100MB) {
        Write-Host ('    unallocated : {0}' -f (Format-Size $unallocated))
    }

    # ---- the verdict line, which is the reason anyone runs this.
    Write-Host ''
    if ($isSystem -or $disk.IsBoot -or $disk.IsSystem) {
        Write-Host '    >>> DO NOT INSTALL HERE - this is the Windows 11 disk. <<<' -ForegroundColor Red
    } elseif (-not $parts.Count) {
        Write-Host '    >>> EMPTY / uninitialised - safe to wipe.' -ForegroundColor Green
        if ($serial) { Write-Host ("        --disk-serial $serial") -ForegroundColor Green }
    } else {
        $used = ($parts | Where-Object { $_.DriveLetter } | ForEach-Object {
                    try { (Get-Volume -DriveLetter $_.DriveLetter).FileSystemLabel } catch { }
                 }) -join ', '
        Write-Host ("    Has data ($used) - wiping it destroys that. If that is fine:") -ForegroundColor Yellow
        if ($serial) { Write-Host ("        --disk-serial $serial") -ForegroundColor Green }
    }

    $report += [pscustomobject]@{
        Number       = $disk.Number
        Model        = $model
        Serial       = $serial
        SizeBytes    = $disk.Size
        Size         = (Format-Size $disk.Size).Trim()
        BusType      = "$($disk.BusType)"
        PartitionStyle = "$($disk.PartitionStyle)"
        HoldsWindows = [bool]$isSystem
        IsBoot       = [bool]$disk.IsBoot
        IsSystem     = [bool]$disk.IsSystem
        UnallocatedBytes = $unallocated
        Volumes      = @($parts | ForEach-Object {
            $v = $null
            if ($_.DriveLetter) { try { $v = Get-Volume -DriveLetter $_.DriveLetter -ErrorAction Stop } catch { } }
            [pscustomobject]@{
                Partition   = $_.PartitionNumber
                DriveLetter = "$($_.DriveLetter)"
                Type        = "$($_.Type)"
                Label       = if ($v) { $v.FileSystemLabel } else { '' }
                FileSystem  = if ($v) { $v.FileSystem } else { '' }
                SizeBytes   = $_.Size
                FreeBytes   = if ($v) { $v.SizeRemaining } else { $null }
            }
        })
    }
}

Write-Host ''
Write-Host '================================================================'
Write-Host ' SUMMARY'
Write-Host '================================================================'
Write-Host ''
Write-Host '  disk  size        serial                     model                     verdict'
foreach ($d in $report) {
    $verdict = if ($d.HoldsWindows -or $d.IsBoot -or $d.IsSystem) { 'WINDOWS - DO NOT TOUCH' }
               elseif ($d.Volumes.Count -eq 0) { 'empty - safe' }
               else { 'has data' }
    $colour  = if ($verdict -like 'WINDOWS*') { 'Red' } elseif ($verdict -eq 'empty - safe') { 'Green' } else { 'Yellow' }
    Write-Host ('  {0,-4}  {1,-10}  {2,-25}  {3,-24}  {4}' -f `
        $d.Number, $d.Size, $(if ($d.Serial) { $d.Serial } else { '?' }),
        $(if ($d.Model) { $d.Model.Substring(0, [Math]::Min(24, $d.Model.Length)) } else { '?' }),
        $verdict) -ForegroundColor $colour
}

Write-Host ''
Write-Host '  Then, on the PXE server (arduino):'
Write-Host ''
Write-Host '      ~/scripts/onboard-node.sh <name> --disk-serial <SERIAL FROM ABOVE>'
Write-Host ''
Write-Host '  The serial - not the disk number, not sda - is what goes in the answer'
Write-Host '  file, because it is the same on every boot. Cross-check it against the'
Write-Host '  size and model before you commit: this erases that disk with no prompt.'
Write-Host ''
Write-Host '  Windows reports serials with the bytes in a different order than Linux on'
Write-Host '  some SATA controllers. If the install aborts with "filter did not match'
Write-Host '  any device", boot SystemRescue from the PXE server and run disk-survey.sh'
Write-Host '  there instead - that reads the exact string the installer will compare.'
Write-Host ''

if ($Json) {
    $report | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -Path $Json
    Write-Host "  raw inventory written to $Json"
    Write-Host ''
}
