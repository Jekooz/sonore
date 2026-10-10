using System;
using System.Runtime.InteropServices;

namespace YtMusicClient.Services
{
    /// <summary>
    /// A Windows Job Object configured with JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE.
    ///
    /// The sidecar is python.exe, a console-subsystem process. Without a job it
    /// only dies if this app runs its own cleanup code, which never happens when
    /// the app is force-killed or crashes — that is how orphaned python.exe
    /// processes kept holding port 8000 (observed live: a stray backend sitting
    /// on 8001 while the app's own sidecar sat on 8000).
    ///
    /// Assigning the child to this job makes the OS responsible: when the last
    /// handle to the job closes — whether we dispose it on a clean exit or the
    /// whole process is torn down — Windows terminates every process in the job.
    ///
    /// Assignment can legitimately fail (a host that already placed us in a job
    /// without breakaway rights, or a process that exited in the meantime), so
    /// every failure path degrades to "no protection" rather than throwing.
    /// </summary>
    internal sealed class JobObjectHandle : IDisposable
    {
        // The three structs below mirror the Win32 layout exactly; the OS reads
        // the whole extended-limit block, so the size and field order matter.
        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        private const uint JobObjectExtendedLimitInformation = 9;
        private const uint JobObjectLimitKillOnJobClose = 0x2000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr hJob, uint jobObjectInformationClass, IntPtr lpJobObjectInformation, uint cbJobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr hObject);

        private IntPtr _handle;

        private JobObjectHandle(IntPtr handle)
        {
            _handle = handle;
        }

        /// <summary>
        /// Create the job with kill-on-close set, or return null when Windows
        /// refuses. Callers treat null as "no job protection" and carry on.
        /// </summary>
        public static JobObjectHandle Create()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero)
                return null;

            var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;

            int size = Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>();
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, buffer, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, buffer, (uint)size))
                {
                    CloseHandle(job);
                    return null;
                }
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }

            return new JobObjectHandle(job);
        }

        /// <summary>
        /// Attach a running process to the job. False (never an exception) means
        /// the process will not be managed — e.g. it already exited.
        /// </summary>
        public bool Assign(IntPtr processHandle)
        {
            if (_handle == IntPtr.Zero || processHandle == IntPtr.Zero)
                return false;

            try
            {
                return AssignProcessToJobObject(_handle, processHandle);
            }
            catch (Exception)
            {
                return false;
            }
        }

        /// <summary>
        /// Closing the handle terminates everything still in the job. Safe to
        /// call more than once.
        /// </summary>
        public void Dispose()
        {
            if (_handle != IntPtr.Zero)
            {
                CloseHandle(_handle);
                _handle = IntPtr.Zero;
            }
        }
    }
}
