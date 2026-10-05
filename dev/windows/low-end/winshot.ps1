# Captures the Mahfin window's own contents — including the native
# video under the page — even when other windows cover it. Nothing else on the
# screen is captured.
param([string]$Out = "$PSScriptRoot\out\window.png", [double]$Scale = 0.5)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class MahfinShot {
  [StructLayout(LayoutKind.Sequential)] public struct R { public int L, T, Ri, B; }
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[MahfinShot]::SetProcessDPIAware() | Out-Null
$p = Get-Process -Name 'Mahfin' -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
$r = New-Object MahfinShot+R
[MahfinShot]::GetClientRect($p.MainWindowHandle, [ref]$r) | Out-Null
$bmp = New-Object System.Drawing.Bitmap ($r.Ri - $r.L), ($r.B - $r.T)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
# PW_CLIENTONLY | PW_RENDERFULLCONTENT: the latter is what makes GL/DirectComposition content come through.
[MahfinShot]::PrintWindow($p.MainWindowHandle, $hdc, 0x1 -bor 0x2) | Out-Null
$g.ReleaseHdc($hdc)
$small = New-Object System.Drawing.Bitmap $bmp, ([int]($bmp.Width * $Scale)), ([int]($bmp.Height * $Scale))
$small.Save($Out)
Write-Output $Out
