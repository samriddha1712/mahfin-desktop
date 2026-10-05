# Turns a crash offset (from the Application event log's "Fault offset") into a
# function and source line, using the PDB next to the executable. No debugger needed.
#   .\symbolize.ps1 -Exe "build-native\src\Mahfin.exe" -Offset 0x77794
param([Parameter(Mandatory)] [string]$Exe, [Parameter(Mandatory)] [string]$Offset)
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class Sym {
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SymInitializeW(IntPtr h, string path, bool invade);
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern ulong SymLoadModuleExW(IntPtr h, IntPtr f, string image, string module, ulong baseAddr, uint size, IntPtr data, uint flags);
  [DllImport("dbghelp.dll", SetLastError=true)] public static extern uint SymSetOptions(uint o);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct SYMBOL_INFOW {
    public uint SizeOfStruct, TypeIndex; public ulong Reserved0, Reserved1; public uint Index, Size; public ulong ModBase; public uint Flags; public ulong Value, Address; public uint Register, Scope, Tag, NameLen, MaxNameLen;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=1024)] public string Name; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct LINEW64 { public uint SizeOfStruct; public IntPtr Key; public uint LineNumber; public IntPtr FileName; public ulong Address; }
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SymFromAddrW(IntPtr h, ulong addr, out ulong disp, ref SYMBOL_INFOW s);
  [DllImport("dbghelp.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool SymGetLineFromAddrW64(IntPtr h, ulong addr, out uint disp, ref LINEW64 l);
}
'@
$h = [IntPtr]42
[Sym]::SymSetOptions(0x2 -bor 0x10) | Out-Null   # UNDNAME | LOAD_LINES
$exePath = (Resolve-Path $Exe).Path
[Sym]::SymInitializeW($h, (Split-Path $exePath), $false) | Out-Null
$base = [uint64]0x140000000
[Sym]::SymLoadModuleExW($h, [IntPtr]::Zero, $exePath, $null, $base, 0, [IntPtr]::Zero, 0) | Out-Null
$addr = $base + [Convert]::ToUInt64($Offset.Replace('0x',''), 16)
$si = New-Object Sym+SYMBOL_INFOW; $si.SizeOfStruct = 88; $si.MaxNameLen = 1024
$disp = [uint64]0
if ([Sym]::SymFromAddrW($h, $addr, [ref]$disp, [ref]$si)) { "function: $($si.Name) +0x{0:x}" -f $disp } else { "no symbol" }
$ln = New-Object Sym+LINEW64; $ln.SizeOfStruct = [Runtime.InteropServices.Marshal]::SizeOf($ln)
$d2 = [uint32]0
if ([Sym]::SymGetLineFromAddrW64($h, $addr, [ref]$d2, [ref]$ln)) { "line: $([Runtime.InteropServices.Marshal]::PtrToStringUni($ln.FileName)):$($ln.LineNumber)" }
