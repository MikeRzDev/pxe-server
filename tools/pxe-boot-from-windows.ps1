<#
.SYNOPSIS
    Arm a ONE-SHOT network boot into the Manhattan PXE server, from Windows,
    without anyone standing at the machine.

.DESCRIPTION
    Run this in an ELEVATED PowerShell on the machine you want to enrol, while
    it is still running Windows. It:

        1. downloads ipxe-chain.efi from the PXE server
        2. installs it onto this machine's EFI System Partition
        3. creates a UEFI firmware boot entry pointing at it
        4. sets that entry as BootNext - ONE SHOT ONLY

    Then reboot. The machine boots iPXE once, iPXE fetches whatever payload is
    armed on the server, and the next boot after that is Windows again as
    normal. The permanent boot order is not changed.

    NOTHING IS ERASED BY THIS SCRIPT. It writes one ~1 MB file to the EFI
    partition and one boot entry. What happens after the reboot depends
    entirely on which payload is armed on the server - the read-only `survey`
    payload only looks, while an installer payload wipes the disk named in the
    answer file.

.WHY THIS EXISTS
    The PXE server normally finds clients by proxy-DHCP: it overhears a DHCP
    broadcast and injects "netboot from me" alongside the LAN's real DHCP
    reply. That is passive, and it only works if the server HEARS the
    broadcast. A client sitting behind a router that answers DHCP itself and
    does not flood the request onward is invisible to it - so the firmware
    waits for boot information that nobody sends, and eventually gives up.

    Everything AFTER discovery is ordinary unicast and crosses that router
    perfectly well. So this removes the need for discovery: the server's
    address is baked into ipxe-chain.efi, and this puts that file on the
    machine's own disk where the firmware can always find it.

.EXAMPLE
    .\pxe-boot-from-windows.ps1 -DryRun
    .\pxe-boot-from-windows.ps1
    .\pxe-boot-from-windows.ps1 -Reboot
    .\pxe-boot-from-windows.ps1 -Remove       # undo: entry and file both go
#>
[CmdletBinding()]
param(
    [string]$Server  = '192.168.1.229',
    [string]$Url,
    [string]$EfiFile,
    [string]$Label   = 'iPXE (Manhattan PXE)',
    [switch]$Reboot,
    [switch]$DryRun,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
if (-not $Url) { $Url = "http://$Server/ipxe-chain.efi" }

$EspPath  = '\EFI\ipxe\ipxe-chain.efi'
$script:MountedLetter = $null

function Say  { param($m) Write-Host $m }
function Head { param($m) Write-Host ''; Write-Host "== $m" -ForegroundColor Cyan }
function Warn { param($m) Write-Host "!! $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host ''; Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# --------------------------------------------------------------- checks ----
function Assert-Ready {
    $me = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Die "must run as Administrator (right-click PowerShell -> Run as administrator)."
    }

    $fw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType `
              -ErrorAction SilentlyContinue).PEFirmwareType
    if ($fw -ne 2) {
        Die "this machine booted Windows in legacy BIOS mode, not UEFI. There is no firmware boot entry to set. Use a USB stick instead."
    }

    # Secure Boot is the one that actually stops this. iPXE is not signed by
    # anyone Microsoft's UEFI CA trusts, so with Secure Boot on the firmware
    # refuses to execute it and the boot silently falls through to Windows.
    # Worth saying up front rather than after a confusing reboot - and it is
    # not just this file: SystemRescue's kernel and the Proxmox installer are
    # netbooted unsigned too, so Secure Boot has to be off for ANY of this.
    $sb = $null
    try { $sb = Confirm-SecureBootUEFI } catch { $sb = $null }
    if ($sb -eq $true) {
        Write-Host ''
        Write-Host 'SECURE BOOT IS ENABLED.' -ForegroundColor Red
        Write-Host ''
        Write-Host '  iPXE, the SystemRescue kernel and the Proxmox installer are all'
        Write-Host '  unsigned, so the firmware will refuse to run them and the machine'
        Write-Host '  will just boot Windows again. Nothing here can work around that.'
        Write-Host ''
        Write-Host '  Turn it off once, in the BIOS:'
        Write-Host '     Settings -> Advanced -> Windows OS Configuration -> Secure Boot'
        Write-Host '     (MSI Click BIOS: press Del at POST, F7 for Advanced)'
        Write-Host ''
        Write-Host '  Windows 11 keeps running with Secure Boot off. If BitLocker is on'
        Write-Host '  it will ask for its recovery key on the next boot, so have that'
        Write-Host '  key to hand first - check with:  manage-bde -status'
        Write-Host ''
        Die "Secure Boot must be disabled before netbooting this machine."
    }
    if ($null -eq $sb) { Warn "could not read the Secure Boot state - if the netboot silently falls back to Windows, that is why." }
}

# ------------------------------------------------------------------ ESP ----
# mountvol /S mounts the ESP this machine actually boots from - which is the
# same one {bootmgr} lives on. That matters on a multi-disk box like this,
# where several disks may each carry an ESP.
function Mount-Esp {
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    $free = 90..83 | ForEach-Object { [char]$_ } | Where-Object { $used -notcontains "$_" }
    if (-not $free) { Die "no free drive letter to mount the EFI partition on." }
    $letter = $free[0]
    & mountvol "${letter}:" /S 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "${letter}:\EFI")) {
        Die "could not mount the EFI System Partition (mountvol ${letter}: /S)."
    }
    $script:MountedLetter = $letter
    Say "   EFI System Partition mounted at ${letter}:"
    return "${letter}:"
}

function Dismount-Esp {
    if ($script:MountedLetter) {
        & mountvol "$($script:MountedLetter):" /D 2>&1 | Out-Null
        $script:MountedLetter = $null
    }
}

# -------------------------------------------------------------- bcdedit ----
# Copying {bootmgr} is the standard way to make a firmware boot entry for an
# arbitrary .efi: the copy already has the ESP as its device, so only `path`
# has to change. Nothing about the real {bootmgr} entry is touched.
function Get-ExistingEntry {
    $out = & bcdedit /enum firmware 2>&1 | Out-String
    $guid = $null
    foreach ($block in ($out -split "(?m)^(?=Firmware Application|Windows Boot Manager)")) {
        if ($block -match [regex]::Escape($Label)) {
            if ($block -match '\{[0-9a-fA-F-]{36}\}') { $guid = $Matches[0]; break }
        }
    }
    return $guid
}

function New-Entry {
    $out = & bcdedit /copy "{bootmgr}" /d "$Label" 2>&1 | Out-String
    if ($out -notmatch '\{[0-9a-fA-F-]{36}\}') { Die "bcdedit /copy failed: $out" }
    return $Matches[0]
}

# Not param($Args): $args is an automatic variable and declaring it as a
# parameter is an error in PowerShell, which would only surface at run time on
# the target machine.
function Invoke-Bcd {
    param([string[]]$BcdArgs)
    $out = & bcdedit @BcdArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Die "bcdedit $($BcdArgs -join ' ') failed: $out" }
}

# ------------------------------------------------------------------ run ----
Head "checks"
Assert-Ready
Say "   Administrator, UEFI, Secure Boot not blocking - good."

if ($Remove) {
    Head "removing"
    $guid = Get-ExistingEntry
    if ($guid) {
        if ($DryRun) { Say "   would run: bcdedit /delete $guid /f" }
        else { Invoke-Bcd @('/delete', $guid, '/f'); Say "   deleted boot entry $guid" }
    } else { Say "   no boot entry named '$Label' - nothing to delete" }

    $esp = Mount-Esp
    try {
        $target = Join-Path $esp $EspPath.TrimStart('\')
        if (Test-Path $target) {
            if ($DryRun) { Say "   would delete $target" }
            else { Remove-Item $target -Force; Say "   deleted $target" }
        } else { Say "   no file at $target" }
    } finally { Dismount-Esp }
    Write-Host ''
    Say "Done. This machine boots exactly as it did before."
    exit 0
}

Head "fetching the chainloader"
$tmp = Join-Path $env:TEMP 'ipxe-chain.efi'
if ($EfiFile) {
    if (-not (Test-Path $EfiFile)) { Die "no such file: $EfiFile" }
    Copy-Item $EfiFile $tmp -Force
    Say "   from $EfiFile"
} else {
    Say "   $Url"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 60
    } catch {
        Die "could not download $Url - $($_.Exception.Message)`n`n  Is the PXE server armed? On the Pi:  sudo pxectl status"
    }
}

# A 404 page saved as ipxe-chain.efi would produce a boot entry that silently
# does nothing, so check this is really an EFI executable before trusting it.
$bytes = [IO.File]::ReadAllBytes($tmp)
if ($bytes.Length -lt 100000 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
    Die "what came back is not an EFI binary ($($bytes.Length) bytes, no MZ header). The server is probably serving an error page."
}
$sha = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLower()
Say "   $($bytes.Length) bytes, sha256 $($sha.Substring(0,16))..."

Head "installing onto the EFI System Partition"
$esp = Mount-Esp
try {
    $target = Join-Path $esp $EspPath.TrimStart('\')
    if ($DryRun) {
        Say "   would copy to ${esp}${EspPath}"
    } else {
        New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
        Copy-Item $tmp $target -Force
        Say "   wrote ${esp}${EspPath}"
    }
} finally { Dismount-Esp }

Head "boot entry"
$guid = Get-ExistingEntry
if ($guid) {
    Say "   reusing existing entry $guid"
} elseif ($DryRun) {
    Say "   would run: bcdedit /copy {bootmgr} /d `"$Label`""
    $guid = '{DRYRUN-GUID}'
} else {
    $guid = New-Entry
    Say "   created $guid"
}

$steps = @(
    @('/set', $guid, 'path', $EspPath),
    @('/set', "{fwbootmgr}", 'displayorder', $guid, '/addlast'),
    @('/set', "{fwbootmgr}", 'bootsequence', $guid)
)
foreach ($s in $steps) {
    if ($DryRun) { Say "   would run: bcdedit $($s -join ' ')" }
    else { Invoke-Bcd $s; Say "   bcdedit $($s -join ' ')" }
}

Write-Host ''
Write-Host '======================================================================'
if ($DryRun) {
    Write-Host ' DRY RUN - nothing was changed. Re-run without -DryRun to apply.'
    Write-Host '======================================================================'
    exit 0
}
Write-Host ' ARMED - the NEXT boot only.' -ForegroundColor Green
Write-Host '======================================================================'
Write-Host ''
Write-Host "  Entry : $Label  $guid"
Write-Host "  File  : <ESP>$EspPath"
Write-Host "  Server: $Server"
Write-Host ''
Write-Host '  BootNext is one-shot: the firmware consumes it and the boot after'
Write-Host '  this one is Windows again. Windows is still the default entry.'
Write-Host ''
Write-Host '  Make sure the payload you want is armed on the PXE server BEFORE'
Write-Host '  rebooting - the read-only survey is the safe one to start with:'
Write-Host ''
Write-Host '      ssh arduino'
Write-Host '      ~/scripts/onboard-node.sh <name>'
Write-Host ''
Write-Host '  Undo without rebooting:  .\pxe-boot-from-windows.ps1 -Remove'
Write-Host ''

if ($Reboot) {
    Write-Host 'Rebooting in 15 seconds. Ctrl-C to stop.' -ForegroundColor Yellow
    Start-Sleep -Seconds 15
    & shutdown /r /t 0
} else {
    Write-Host 'Reboot when ready:  shutdown /r /t 0'
}
