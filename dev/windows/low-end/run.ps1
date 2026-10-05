param(
  # host     : no limits (this Ryzen 9 / RTX laptop)
  # budget   : ~Core i3 7th gen, 2C/4T, 8 GB, working iGPU driver
  # lowend   : ~Celeron N4020, 2C/2T, 4 GB, working iGPU driver
  # nodriver : lowend, but no vendor GPU driver (Qt falls back to llvmpipe)
  # tieronly : lowend's settings at full speed - separates what the tier does from the slowness
  # hardcap  : lowend's cores under a Job Object hard CPU-rate cap. Kept for comparison only:
  #            a hard cap freezes the whole process between quota periods, which no real CPU
  #            does, and under it video frames reach the screen late and out of order (stale
  #            window contents over the film, audio fine). Not a Mahfin bug; do not judge
  #            playback by it.
  # probook  : ~HP ProBook x360 435 G8 (Ryzen 5 5600U at 15 W, 6C/12T, 8 GB, Radeon Vega iGPU).
  #            12 CPUs each shared with 1 busy thread, and drawn on this machine's AMD 610M.
  [ValidateSet('host','budget','lowend','nodriver','tieronly','hardcap','probook')] [string]$Machine = 'lowend',
  # Which GPU Windows hands the app and its Chromium processes. 'default' leaves it to the
  # driver, which on this laptop means the RTX: every profile above except probook ran there.
  # 'igpu' (the AMD 610M) and 'dgpu' set the per-app preference for the run and restore it after.
  [ValidateSet('default','igpu','dgpu')] [string]$Gpu = '',
  [int]$Duration = 120,
  [string]$Tag = '',
  [string]$ExtraArgs = '',
  [long]$MemLimitMB = 0,
  # Another build to run instead, e.g. a baseline copied next to the real one.
  [string]$Exe = ''
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$repo = (Resolve-Path "$here\..\..\..").Path
$exe  = if ($Exe) { $Exe } else { "$repo\build\src\Mahfin.exe" }
if (-not $env:QT_DIR) { $env:QT_DIR = 'C:\Qt\6.9.3\msvc2022_64' }
$env:PATH = "$env:QT_DIR\bin;$repo\build\mpv;$env:PATH"
$env:QT_OPENGL = $null
$env:MAHFIN_SIMULATE_MACHINE = $null

# Slowness comes from sharing the app's cores with busy threads ($hog per core):
# with two of them the app gets about a third of each core, in ordinary scheduler
# slices - a slower core, rather than a fast one frozen between quota periods.
# CPU indices: even numbers are separate physical cores on this SMT part.
$hog = 0; $rate = 0
switch ($Machine) {
  'host'     { $cpus = @() }
  'budget'   { $cpus = @(0,1,2,3); $hog = 1; $env:MAHFIN_SIMULATE_MACHINE = 'ram=8192;cores=4' }
  'lowend'   { $cpus = @(0,2);     $hog = 2; $env:MAHFIN_SIMULATE_MACHINE = 'ram=4096;cores=2' }
  'nodriver' { $cpus = @(0,2);     $hog = 2; $env:MAHFIN_SIMULATE_MACHINE = 'ram=4096;cores=2;adapter=Microsoft Basic Display Adapter'
               $env:QT_OPENGL = 'software' }
  'tieronly' { $cpus = @();                  $env:MAHFIN_SIMULATE_MACHINE = 'ram=4096;cores=2' }
  'hardcap'  { $cpus = @(0,2);  $rate = 25;  $env:MAHFIN_SIMULATE_MACHINE = 'ram=4096;cores=2' }
  'probook'  { $cpus = 0..11; $hog = 1; $env:MAHFIN_SIMULATE_MACHINE = 'ram=7680;cores=6;adapter=AMD Radeon(TM) Graphics'
               if (-not $Gpu) { $Gpu = 'igpu' } }
}
if (-not $Gpu) { $Gpu = 'default' }

# A second instance just raises the first and exits, so never start on top of one.
$deadline = (Get-Date).AddSeconds(120)
while ((Get-Process -Name 'Mahfin' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
if (Get-Process -Name 'Mahfin' -ErrorAction SilentlyContinue) { throw 'an earlier Mahfin is still running' }
if (-not ('LowEnd' -as [type])) { Add-Type -Path "$here\LowEnd.cs" }
$name = if ($Tag) { "$Machine-$Tag" } else { $Machine }
$csv  = "$here\out\$name.csv"
New-Item -ItemType Directory -Force "$here\out" | Out-Null
if (Test-Path "$here\stop") { [IO.File]::Delete("$here\stop") }
$args2 = "--log-level debug --remote-debugging-port=9222 $ExtraArgs"

# Windows' per-app GPU preference (Settings > Display > Graphics), which the AMD and NVIDIA
# OpenGL drivers both honour. Set for the run only; the previous value is put back after.
$prefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$prefExes = @((Resolve-Path $exe).Path, "$env:QT_DIR\bin\QtWebEngineProcess.exe")
$prefOld = @{}
if ($Gpu -ne 'default') {
  $value = if ($Gpu -eq 'igpu') { 'GpuPreference=1;' } else { 'GpuPreference=2;' }
  if (-not (Test-Path $prefKey)) { New-Item -Path $prefKey -Force | Out-Null }
  foreach ($p in $prefExes) {
    $prefOld[$p] = (Get-ItemProperty -Path $prefKey -Name $p -ErrorAction SilentlyContinue).$p
    Set-ItemProperty -Path $prefKey -Name $p -Value $value
  }
}
try {
  [LowEnd]::Run($exe, $args2, [int[]]$cpus, $rate, $MemLimitMB, $Duration, $csv, "$here\stop", [int]$hog) | Out-Null
} finally {
  foreach ($p in $prefOld.Keys) {
    if ($null -eq $prefOld[$p]) { Remove-ItemProperty -Path $prefKey -Name $p -ErrorAction SilentlyContinue }
    else { Set-ItemProperty -Path $prefKey -Name $p -Value $prefOld[$p] }
  }
}
Write-Output "wrote $csv"
