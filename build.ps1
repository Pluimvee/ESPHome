# ESPHome build script
# Updates version.yaml with today's date and compiles/uploads specified device(s)
#
# Usage:
#   .\build.ps1                         # update version only
#   .\build.ps1 temp-floor              # compile + upload one device
#   .\build.ps1 temp-floor,water-meter  # compile + upload multiple
#   .\build.ps1 all                     # compile + upload all devices

param(
    [string]$devices = ""
)

# Update version.yaml with today's date
$date = Get-Date -Format "MMM d yyyy"
Set-Content -Path "$PSScriptRoot\version.yaml" -Value "substitutions:`n  version: `"$date`""
Write-Host "Version set to: $date"

if ($devices -eq "") { exit 0 }

# Build device list
if ($devices -eq "all") {
    $deviceList = Get-ChildItem "$PSScriptRoot\*.yaml" |
        Where-Object { $_.Name -notin @("version.yaml", "template.yaml", "resideo-base.yaml") } |
        Select-Object -ExpandProperty BaseName
} else {
    $deviceList = $devices -split ","
}

# Compile and upload each device
foreach ($device in $deviceList) {
    $yaml = "$PSScriptRoot\$device.yaml"
    if (-not (Test-Path $yaml)) {
        Write-Host "WARNING: $yaml not found, skipping"
        continue
    }
    Write-Host "`n=== $device ==="
    esphome compile $yaml
    if ($LASTEXITCODE -eq 0) {
        esphome upload --device "$device.local" $yaml
    }
}
