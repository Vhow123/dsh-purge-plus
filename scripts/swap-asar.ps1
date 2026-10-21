param(
  [int]$Delay = 0,
  [string]$ExePath = ''
)
$ErrorActionPreference = 'Continue'
if ($Delay -gt 0) { Start-Sleep -Seconds $Delay }

$Log = Join-Path $env:TEMP 'purge-swap.log'
function Log($m) {
  Add-Content -LiteralPath $Log -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8
}
Set-Content -LiteralPath $Log -Value ("=== start " + (Get-Date -Format o) + " ===") -Encoding utf8

# Locate the desktop executable when not supplied.
if (-not $ExePath) {
  $candidates = @(
    'D:\deepseek\DeepSeek Harness.exe',
    (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe')
  )
  $keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  foreach ($k in $keys) {
    Get-ItemProperty $k -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.DisplayName -match 'DeepSeek Harness|DSH Desktop' -and $_.InstallLocation) {
        $candidates += (Join-Path $_.InstallLocation 'DeepSeek Harness.exe')
      }
    }
  }
  $ExePath = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) {
  Log "ERROR desktop executable not found"
  Write-Host "Could not locate DeepSeek Harness.exe. Pass -ExePath explicitly." -ForegroundColor Red
  exit 1
}
$ExePath = (Resolve-Path -LiteralPath $ExePath).Path
$AsarPath = Join-Path (Split-Path -Parent $ExePath) 'resources\app.asar'
$AppDir   = Join-Path (Split-Path -Parent $ExePath) 'resources\app'
Log ("exe=" + $ExePath)
Log ("asar=" + $AsarPath)

if (-not (Test-Path -LiteralPath (Split-Path -Parent $AsarPath))) {
  Log "ERROR resources directory missing"
  Write-Host "resources directory not found next to the executable." -ForegroundColor Red
  exit 1
}

$installRoot = (Split-Path -Parent $ExePath).TrimEnd('\')
$exeNorm = $ExePath.ToLower()

function Stop-HarnessInstall {
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $ep = $_.ExecutablePath
    if (-not $ep) { return $false }
    $low = $ep.ToLower()
    return ($low -eq $exeNorm) -or $low.StartsWith($installRoot.ToLower() + '\')
  } | ForEach-Object {
    try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; Log ("killed pid=" + $_.ProcessId) }
    catch { Log ("kill failed pid=" + $_.ProcessId) }
  }
}

Log "step1 stop harness"
Stop-HarnessInstall
Start-Sleep -Milliseconds 700
Stop-HarnessInstall
Start-Sleep -Milliseconds 500

$left = @()
$deadline = (Get-Date).AddSeconds(12)
while ((Get-Date) -lt $deadline) {
  $left = @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue | Where-Object {
    try {
      $_.Path -and ($_.Path.ToLower() -eq $exeNorm -or $_.Path.ToLower().StartsWith($installRoot.ToLower() + '\'))
    } catch { $false }
  })
  if ($left.Count -eq 0) { break }
  Stop-HarnessInstall
  Start-Sleep -Milliseconds 300
}
Log ("step1 done remaining=" + $left.Count)

# Copy native addons that live outside the asar payload.
$unpacked = $AsarPath + '.unpacked'
$marker = Join-Path $AppDir 'dsh\node_modules\node-addon-require-builtin-win32-x64-msvc\prebuilt\win32-x64-msvc-napi-v9.node'
if ((Test-Path -LiteralPath $unpacked) -and -not (Test-Path -LiteralPath $marker)) {
  Log "step2 robocopy unpacked -> app"
  & robocopy.exe $unpacked $AppDir /E /XC /XN /XO /NFL /NDL /NJH /NJS /nc /ns /np | Out-Null
  Log ("step2 robocopy exit=" + $LASTEXITCODE)
}

Log "step3 move app.asar aside"
$moved = -not (Test-Path -LiteralPath $AsarPath)
if (Test-Path -LiteralPath $AsarPath) {
  $bak = $AsarPath + '.bak'
  if (Test-Path -LiteralPath $bak) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
  for ($i = 0; $i -lt 80; $i++) {
    try {
      Move-Item -LiteralPath $AsarPath -Destination $bak -Force -ErrorAction Stop
      $moved = $true
      Log ("moved on attempt " + $i)
      break
    } catch {
      if ($i -eq 20 -or $i -eq 50) { Stop-HarnessInstall; Start-Sleep -Seconds 1 }
      Start-Sleep -Milliseconds 400
    }
  }
}

if ($moved) {
  Log "step4 relaunch"
  Remove-Item -LiteralPath ($AsarPath + '.rename-pending') -Force -ErrorAction SilentlyContinue
  Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue
  Start-Process -FilePath $ExePath
  Log "SUCCESS app.asar -> app.asar.bak, relaunched"
  Write-Host "app.asar moved aside. Desktop relaunched." -ForegroundColor Green
} else {
  Log "FAILED app.asar still locked"
  Set-Content -LiteralPath ($AsarPath + '.rename-pending') -Value ((Get-Date).ToString('o')) -Encoding ascii
  Start-Process -FilePath $ExePath
  Write-Host "app.asar is still locked. See $Log" -ForegroundColor Red
}
Write-Host "Log: $Log"
