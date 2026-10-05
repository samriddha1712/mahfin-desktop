# Captures what is actually on screen where a process's main window is (DWM output),
# after bringing it to the front. Unlike PrintWindow this shows real composition.
param([string]$Name = 'spike', [string]$Out = "$PSScriptRoot\shot.png", [double]$Scale = 0.5)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class ScreenShot {
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Ri, B; }
  [StructLayout(LayoutKind.Sequential)] public struct P { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref P p);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[ScreenShot]::SetProcessDPIAware() | Out-Null
$p = Get-Process -Name $Name -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
[ScreenShot]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
Start-Sleep -Milliseconds 600
$r = New-Object ScreenShot+R; [ScreenShot]::GetClientRect($p.MainWindowHandle, [ref]$r) | Out-Null
$o = New-Object ScreenShot+P; [ScreenShot]::ClientToScreen($p.MainWindowHandle, [ref]$o) | Out-Null
$w = $r.Ri - $r.L; $h = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($o.X, $o.Y, 0, 0, (New-Object System.Drawing.Size $w, $h))
$small = New-Object System.Drawing.Bitmap $bmp, ([int]($w * $Scale)), ([int]($h * $Scale))
$small.Save($Out)
Write-Output $Out
