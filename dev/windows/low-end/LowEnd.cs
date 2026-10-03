using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

// Runs a process tree inside a Job Object that limits it to N logical CPUs, a hard
// CPU-rate cap and (optionally) a commit limit, and samples it once a second.
public static class LowEnd
{
    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION Basic;
        public IO_COUNTERS Io;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_CPU_RATE_CONTROL_INFORMATION { public uint ControlFlags; public uint CpuRate; }
    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
    {
        public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb; public string lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

    [DllImport("kernel32", CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr a, string n);
    [DllImport("kernel32", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr j, int c, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION i, int l);
    [DllImport("kernel32", SetLastError = true)] static extern bool SetInformationJobObject(IntPtr j, int c, ref JOBOBJECT_CPU_RATE_CONTROL_INFORMATION i, int l);
    [DllImport("kernel32")] static extern bool QueryInformationJobObject(IntPtr j, int c, out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION i, int l, IntPtr r);
    [DllImport("kernel32")] static extern bool QueryInformationJobObject(IntPtr j, int c, out JOBOBJECT_EXTENDED_LIMIT_INFORMATION i, int l, IntPtr r);
    [DllImport("kernel32")] static extern bool QueryInformationJobObject(IntPtr j, int c, IntPtr buf, int l, IntPtr r);
    [DllImport("kernel32", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr j, IntPtr p);
    [DllImport("kernel32")] static extern uint ResumeThread(IntPtr t);
    [DllImport("kernel32")] static extern bool TerminateJobObject(IntPtr j, uint code);
    [DllImport("kernel32", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags,
                                     IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
    delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    [DllImport("user32")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    [DllImport("user32")] static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("kernel32")] static extern IntPtr GetCurrentThread();
    [DllImport("kernel32")] static extern UIntPtr SetThreadAffinityMask(IntPtr t, UIntPtr mask);
    static volatile bool s_hogStop;

    // Busy threads pinned to the same CPUs as the app. The scheduler then shares
    // each core between them in ordinary short slices, so the app sees a slower
    // core rather than a fast one that is frozen between quota periods.
    static void StartHogs(int[] cpus, int perCpu)
    {
        s_hogStop = false;
        foreach (var c in cpus)
            for (int i = 0; i < perCpu; i++)
            {
                ulong m = 1UL << c;
                var t = new Thread(() => { SetThreadAffinityMask(GetCurrentThread(), new UIntPtr(m)); double x = 0; while (!s_hogStop) x += Math.Sqrt(x + 1); });
                t.IsBackground = true; t.Start();
            }
    }

    [DllImport("user32")] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr res);

    static IntPtr FindMainWindow(int pid)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, l) =>
        {
            int p; GetWindowThreadProcessId(h, out p);
            if (p == pid && IsWindowVisible(h))
            {
                var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
                if (sb.ToString().Contains("Mahfin")) { found = h; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    static int[] JobPids(IntPtr job)
    {
        int size = 8 + 8 * 256;
        IntPtr buf = Marshal.AllocHGlobal(size);
        try
        {
            if (!QueryInformationJobObject(job, 3, buf, size, IntPtr.Zero)) return new int[0];
            int n = Marshal.ReadInt32(buf, 4);
            var r = new int[n];
            for (int i = 0; i < n; i++) r[i] = (int)Marshal.ReadInt64(buf, 8 + 8 * i);
            return r;
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    // cpus: list of logical CPU indices. ratePerCpu: percent of each allowed CPU (0 = no cap).
    public static int Run(string exe, string args, int[] cpus, double ratePerCpu, long jobMemMB,
                          int durationSec, string csvPath, string stopFile, int hogPerCpu)
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        var ext = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        uint flags = 0x2000; // KILL_ON_JOB_CLOSE
        if (cpus != null && cpus.Length > 0)
        {
            ulong mask = 0; foreach (var c in cpus) mask |= 1UL << c;
            ext.Basic.Affinity = new UIntPtr(mask); flags |= 0x10; // AFFINITY
        }
        if (jobMemMB > 0) { ext.JobMemoryLimit = new UIntPtr((ulong)jobMemMB * 1024 * 1024); flags |= 0x200; }
        ext.Basic.LimitFlags = flags;
        if (!SetInformationJobObject(job, 9, ref ext, Marshal.SizeOf(ext))) throw new Exception("limits " + Marshal.GetLastWin32Error());
        if (ratePerCpu > 0)
        {
            double total = ratePerCpu * cpus.Length / Environment.ProcessorCount; // percent of the whole machine
            var rate = new JOBOBJECT_CPU_RATE_CONTROL_INFORMATION { ControlFlags = 0x1 | 0x4, CpuRate = (uint)Math.Max(1, Math.Round(total * 100)) };
            if (!SetInformationJobObject(job, 15, ref rate, Marshal.SizeOf(rate))) throw new Exception("rate " + Marshal.GetLastWin32Error());
        }

        if (hogPerCpu > 0) StartHogs(cpus, hogPerCpu);
        var si = new STARTUPINFO(); si.cb = Marshal.SizeOf(si);
        PROCESS_INFORMATION pi;
        var cmd = new StringBuilder("\"" + exe + "\" " + args);
        if (!CreateProcess(null, cmd, IntPtr.Zero, IntPtr.Zero, false, 0x4 /*SUSPENDED*/, IntPtr.Zero, Path.GetDirectoryName(exe), ref si, out pi))
            throw new Exception("CreateProcess " + Marshal.GetLastWin32Error());
        if (!AssignProcessToJobObject(job, pi.hProcess)) throw new Exception("assign " + Marshal.GetLastWin32Error());
        var start = Stopwatch.StartNew();
        ResumeThread(pi.hThread);

        double budgetCores = (ratePerCpu > 0 ? ratePerCpu / 100.0 : (hogPerCpu > 0 ? 1.0 / (hogPerCpu + 1) : 1.0)) * (cpus != null && cpus.Length > 0 ? cpus.Length : Environment.ProcessorCount);
        using (var w = new StreamWriter(csvPath))
        {
            w.WriteLine("t,cpu_host_cores,cpu_pct_of_budget,procs,private_mb,workingset_mb,peak_job_mb,hung_ping_ms,window,page_faults_per_s");
            long lastCpu = 0; uint lastPf = 0; double lastT = 0;
            IntPtr win = IntPtr.Zero; double firstWindow = -1;
            while (start.Elapsed.TotalSeconds < durationSec && !File.Exists(stopFile))
            {
                Thread.Sleep(1000);
                double t = start.Elapsed.TotalSeconds;
                JOBOBJECT_BASIC_ACCOUNTING_INFORMATION acc;
                QueryInformationJobObject(job, 1, out acc, Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)), IntPtr.Zero);
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION e2;
                QueryInformationJobObject(job, 9, out e2, Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)), IntPtr.Zero);
                long cpu = acc.TotalUserTime + acc.TotalKernelTime;
                double cores = (cpu - lastCpu) / 1e7 / (t - lastT);
                double pf = (acc.TotalPageFaultCount - lastPf) / (t - lastT);
                lastCpu = cpu; lastPf = acc.TotalPageFaultCount; lastT = t;
                if (acc.ActiveProcesses == 0) { w.WriteLine("{0:F1},exited", t); break; }

                long priv = 0, ws = 0;
                foreach (var pid in JobPids(job))
                {
                    try { var p = Process.GetProcessById(pid); priv += p.PrivateMemorySize64; ws += p.WorkingSet64; } catch { }
                }
                if (win == IntPtr.Zero) { win = FindMainWindow(pi.dwProcessId); if (win != IntPtr.Zero) firstWindow = t; }
                long ping = -1;
                if (win != IntPtr.Zero)
                {
                    var sw = Stopwatch.StartNew(); IntPtr res;
                    // SMTO_ABORTIFHUNG | SMTO_BLOCK, 5 s
                    IntPtr ok = SendMessageTimeout(win, 0 /*WM_NULL*/, IntPtr.Zero, IntPtr.Zero, 0x2 | 0x1, 5000, out res);
                    ping = ok == IntPtr.Zero ? 5000 : sw.ElapsedMilliseconds;
                }
                w.WriteLine("{0:F1},{1:F3},{2:F1},{3},{4},{5},{6},{7},{8},{9:F0}", t, cores, 100 * cores / budgetCores, acc.ActiveProcesses,
                    priv >> 20, ws >> 20, (long)e2.PeakJobMemoryUsed.ToUInt64() >> 20, ping, firstWindow, pf);
                w.Flush();
            }
        }
        s_hogStop = true;
        TerminateJobObject(job, 0);
        return 0;
    }
}

