Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

Import-Module WindowsDisplayManager

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class DisplayTopology {
  [DllImport("user32.dll")]
  public static extern int SetDisplayConfig(
    uint numPathArrayElements, IntPtr pathArray,
    uint numModeInfoArrayElements, IntPtr modeInfoArray,
    uint flags);

  public const uint SDC_APPLY            = 0x00000080;
  public const uint SDC_ALLOW_CHANGES    = 0x00000400;
  public const uint SDC_TOPOLOGY_EXTEND  = 0x00000004;
}
"@

function Set-ExtendTopology {
  $flags = [DisplayTopology]::SDC_APPLY -bor [DisplayTopology]::SDC_ALLOW_CHANGES -bor [DisplayTopology]::SDC_TOPOLOGY_EXTEND
  $rc = [DisplayTopology]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, $flags)
  if ($rc -ne 0) { throw "SetDisplayConfig(EXTEND) failed with code $rc" }
}


# ----------------------------
# helpers: env-first parsing
# ----------------------------
function Get-Int($envName, $argIndex) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) { return [int]$v }
    if ($args.Length -gt $argIndex) { return [int]$args[$argIndex] }
    Throw "missing $envName"
}

function Get-Bool($envName, $argIndex) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if ($v) { return $v -match '^(1|true|yes)$' }
    if ($args.Length -gt $argIndex) { return $args[$argIndex] -match '^(1|true|yes)$' }
    return $false
}

# ----------------------------
# sunshine parameters
# ----------------------------
$width        = Get-Int  "SUNSHINE_CLIENT_WIDTH"  0
$height       = Get-Int  "SUNSHINE_CLIENT_HEIGHT" 1
$refresh_rate = Get-Int  "SUNSHINE_CLIENT_FPS"    2
$hdr          = Get-Bool "SUNSHINE_CLIENT_HDR"    3
$hdr_string   = if ($hdr) { "on" } else { "off" }

Write-Host "sunshine params: ${width}x${height}@${refresh_rate} hdr=${hdr_string}"

# ----------------------------
# paths / tools
# ----------------------------
$filePath = Split-Path $MyInvocation.MyCommand.Source
$displayStateFile = Join-Path $filePath "display_state.json"
$stateFile        = Join-Path $filePath "state.json"
$vsynctool        = Join-Path $filePath "vsynctoggle-1.1.0-x86_64.exe"
$multitool        = Join-Path $filePath "multimonitortool-x64\MultiMonitorTool.exe"
$option_file_path = "C:\IddSampleDriver\option.txt"
# --- patch VDD driver XML with requested resolution if missing ---
$driverConfig = "C:\VirtualDisplayDriver\vdd_settings.xml"
# load XML
[xml]$xml = Get-Content $driverConfig

# ----------------------------
# snapshot current state
# ----------------------------
$state = @{ vsync = & $vsynctool status }
if ($state.vsync -like "*default*") { $state.vsync = "default" }
ConvertTo-Json $state | Out-File $stateFile

$initial_displays = WindowsDisplayManager\GetAllPotentialDisplays
if (!(WindowsDisplayManager\SaveDisplaysToFile -displays $initial_displays -filePath $displayStateFile)) {
    Throw "failed to save initial display state"
}

& $vsynctool off

# ----------------------------
# find virtual display device
# ----------------------------
$vdd_name = (
    Get-PnpDevice -Class Display |
    Where-Object {
        $_.FriendlyName -like "*idd*" -or
        $_.FriendlyName -like "*mtt*" -or
        $_.FriendlyName -like "Virtual Display*"
    }
)[0].FriendlyName

if (-not $vdd_name) {
    Throw "virtual display device not found"
}

# check if resolution exists
$resFound = $xml.vdd_settings.resolutions.resolution | Where-Object {
    $_.width -eq $width -and $_.height -eq $height -and $_.refresh -eq $refresh_rate
}

if (-not $resFound) {
    Write-Host "Resolution $width x $height @$refresh_rate not in driver XML. Adding it..."
    
    # create new <resolution> node
    $newRes = $xml.CreateElement("resolution")
    $wNode = $xml.CreateElement("width"); $wNode.InnerText = $width; $newRes.AppendChild($wNode) > $null
    $hNode = $xml.CreateElement("height"); $hNode.InnerText = $height; $newRes.AppendChild($hNode) > $null
    $rNode = $xml.CreateElement("refresh"); $rNode.InnerText = $refresh_rate; $newRes.AppendChild($rNode) > $null

    # append it
    $xml.vdd_settings.resolutions.AppendChild($newRes) > $null

    # save back
    $xml.Save($driverConfig)
    Write-Host "Driver XML patched, restarting Virtual Display Driver..."

    # restart driver service (change service name if yours differs)
    Get-PnpDevice -FriendlyName $vdd_name | Disable-PnpDevice -Confirm:$false

    Write-Host "Driver restarted, XML changes applied."
}

# ----------------------------
# ensure option.txt contains mode
# ----------------------------
if (!(Test-Path $option_file_path)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $option_file_path) | Out-Null
    Set-Content -Path $option_file_path -Value "1"
}

$option_to_check = "$width, $height, $refresh_rate"
if ((Get-Content $option_file_path) -notcontains $option_to_check) {
    Add-Content -Path $option_file_path -Value $option_to_check
}

Write-Host "setting up virtual display ${width}x${height}@${refresh_rate} hdr ${hdr_string}"

# ----------------------------
# enable virtual display
# ----------------------------
Get-PnpDevice -FriendlyName $vdd_name | Enable-PnpDevice -Confirm:$false

# ---------------------------
# display convergence loop (2 displays + EXTEND)
# ---------------------------

function To-MMTDisplayName([string]$name) {
    if (-not $name) { return $null }
    if ($name -match '^\\\\\.\\DISPLAY\d+$') { return $name }
    if ($name -match '^DISPLAY\d+$') { return "\\.\$name" }
    return $name
}

Start-Sleep -Milliseconds 800

$retries = 0
while ($true) {
    $displays = WindowsDisplayManager\GetAllPotentialDisplays

    $virtual = $displays | Where-Object { $_.source.description -eq $vdd_name } | Select-Object -First 1
    if (-not $virtual) { throw "virtual display vanished" }

    # choose ONE physical display to keep (first active non-virtual; fallback to first non-virtual)
    $physical = ($displays | Where-Object { $_.source.description -ne $vdd_name -and $_.active } | Select-Object -First 1)
    if (-not $physical) {
        $physical = ($displays | Where-Object { $_.source.description -ne $vdd_name } | Select-Object -First 1)
    }
    if (-not $physical) { throw "no physical display found to extend with" }

    $vName = To-MMTDisplayName $virtual.source.name
    $pName = To-MMTDisplayName $physical.source.name

    # Ensure both are enabled
    & $multitool /enable $vName
    & $multitool /enable $pName

    # If you have MORE than these 2 active, disable the extras
    $active = $displays | Where-Object { $_.active }
    $allowed = @($virtual.source.name, $physical.source.name)
    $extras = $active | Where-Object { $allowed -notcontains $_.source.name }

    foreach ($d in $extras) {
        $dName = To-MMTDisplayName $d.source.name
        Write-Host "disabling extra active display: $($d.source.name) -> $dName"
        & $multitool /disable $dName
    }

    # Force EXTEND topology (this is the key part that prevents mirroring)
    Force-ExtendTopology
    Start-Sleep -Milliseconds 350

    # Optional but recommended for Sunshine: make virtual primary (so it captures that one consistently)
    & $multitool /setprimary $vName

    # refresh and check success: exactly 2 active, and virtual is active
    $displays2 = WindowsDisplayManager\GetAllPotentialDisplays
    $active2 = $displays2 | Where-Object { $_.active }
    $virtual2 = $displays2 | Where-Object { $_.source.description -eq $vdd_name } | Select-Object -First 1

    if ($virtual2 -and $virtual2.active -and $active2.Count -eq 2) { break }

    if ($retries++ -ge 60) { throw "failed to converge to 2 displays in EXTEND mode" }
}

Write-Host "sunshine display extend setup complete"


# ----------------------------
# set virtual resolution LAST
# ----------------------------
$virtual.SetResolution($width, $height, $refresh_rate)

# ----------------------------
# hdr toggle (windowsdisplaymanager hack)
# ----------------------------
$displays = WindowsDisplayManager\GetAllPotentialDisplays
$hdr_host = WindowsDisplayManager\GetRefreshedDisplay($displays[0])

if ($hdr_host.hdrInfo.hdrSupported) {
    if ($hdr) {
        $i = 0
        while (-not $hdr_host.hdrInfo.hdrEnabled) {
            $hdr_host.EnableHdr() | Out-Null
            if ($i++ -ge 50) { Throw "failed to enable hdr" }
            Start-Sleep -Milliseconds 200
            $hdr_host = WindowsDisplayManager\GetRefreshedDisplay($displays[0])
        }
    } else {
        $i = 0
        while ($hdr_host.hdrInfo.hdrEnabled) {
            $hdr_host.DisableHdr() | Out-Null
            if ($i++ -ge 50) { Throw "failed to disable hdr" }
            Start-Sleep -Milliseconds 200
            $hdr_host = WindowsDisplayManager\GetRefreshedDisplay($displays[0])
        }
    }
}

Write-Host "sunshine display setup complete (rdp intact)"
