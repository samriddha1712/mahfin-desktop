# Maximizes the Mahfin Desktop window (used by fullscreentest.sh).
Add-Type -Name W -Namespace U -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h,int n);'
$p = Get-Process -Name 'Mahfin Desktop' -ErrorAction Stop | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
[U.W]::ShowWindow($p.MainWindowHandle, 3) | Out-Null
