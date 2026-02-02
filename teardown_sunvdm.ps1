Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
Import-Module WindowsDisplayManager

# ----------------------------
# Force EXTEND topology helper
# ----------------------------
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
  # Don't hard-fail teardown if Windows refuses briefly; just log it.
  if ($rc -ne 0) { Write-Host "WARN: SetDisplayConfig(EXTEND) returned $rc" }
}

# ----------------------------
# paths / tools
# ----------------------------
$filePath         = Split-Path $MyInvocation.MyCommand.Source
$displayStateFile = Join-Path $filePath "display_state.json"
$stateFile        = Join-Path $filePath "state.json"
$vsynctool        = Join-Path $filePath "vsynctoggle-1.1.0-x86_64.exe"

# ----------------------------
# find virtual display device (safe)
# ----------------------------
$vdd_device = Get-PnpDevice -Class Display |
  Where-Object {
      $_.FriendlyName -like "*idd*" -or
      $_.FriendlyName -like "*mtt*" -or
      $_.FriendlyName -like "Virtual Display*"
  } | Select-Object -First 1

if (-not $vdd_device) {
  Write-Host "WARN: Virtual display device not found; continuing teardown restore."
} else {
  $vdd_name = $vdd_device.FriendlyName
  Write-Host "Disabling virtual display device: $vdd_name"

  # Disable the VDD (ignore failures if already disabled)
  try {
    Get-PnpDevice -FriendlyName $vdd_name | Disable-PnpDevice -Confirm:$false | Out-Null
  } catch {
    Write-Host "WARN: Disable-PnpDevice failed: $($_.Exception.Message)"
  }

  # Give Windows time to re-enumerate displays after disabling
  Start-Sleep -Milliseconds 800
}

# ----------------------------
# restore vsync state (safe)
# ----------------------------
try {
  if (Test-Path $stateFile) {
    $prev = (Get-Content -Raw $stateFile | ConvertFrom-Json)
    if ($prev.vsync) {
      & $vsynctool $prev.vsync | Out-Null
    }
  } else {
    Write-Host "WARN: state.json not found; skipping vsync restore."
  }
} catch {
  Write-Host "WARN: vsync restore failed: $($_.Exception.Message)"
}

# ----------------------------
# restore display layout
# ----------------------------
if (!(Test-Path $displayStateFile)) {
  throw "display_state.json not found; cannot restore display state."
}

# Try multiple times; Windows display stack can be slow after VDD disable
$counter = 0
while ($true) {
  $ok = $false
  try {
    $ok = WindowsDisplayManager\UpdateDisplaysFromFile `
      -filePath $displayStateFile `
      -disableNotSpecifiedDisplays `
      -validate
  } catch {
    $ok = $false
    Write-Host "WARN: UpdateDisplaysFromFile error: $($_.Exception.Message)"
  }

  if ($ok) { break }

  if (++$counter -gt 6) {
    throw "Failure restoring display state from file after $counter attempts."
  }

  Start-Sleep -Seconds 2
}

# Nudge Windows back into EXTEND (prevents rare “stuck duplicate” after restore)
Set-ExtendTopology
Start-Sleep -Milliseconds 300

Write-Host "Teardown complete: virtual display removed and display state restored."
