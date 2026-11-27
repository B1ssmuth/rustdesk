using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Security.Principal;

static class Wts
{
    internal sealed record Session(int SessionId, string Sid, string Username,
        DateTimeOffset LogonAt, string Transport, string State);

    [StructLayout(LayoutKind.Sequential)]
    private struct Entry { public int Id; public IntPtr Name; public int State; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct Info
    {
        public int State, Id, IncomingBytes, OutgoingBytes, IncomingFrames, OutgoingFrames;
        public int IncomingCompressedBytes, OutgoingCompressedBytes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string Station;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] public string Domain;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string Username;
        public long ConnectTime, DisconnectTime, LastInputTime, LogonTime, CurrentTime;
    }

    [DllImport("wtsapi32.dll", EntryPoint = "WTSEnumerateSessionsW", SetLastError = true)]
    private static extern bool Enumerate(IntPtr server, uint reserved, uint version, out IntPtr buffer, out int count);
    [DllImport("wtsapi32.dll", EntryPoint = "WTSQuerySessionInformationW", SetLastError = true)]
    private static extern bool Query(IntPtr server, int session, int infoClass, out IntPtr buffer, out int size);
    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQueryUserToken(uint sessionId, out SafeAccessTokenHandle token);
    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr buffer);

    internal static IReadOnlyList<Session>? Snapshot()
    {
        if (!Enumerate(IntPtr.Zero, 0, 1, out var buffer, out var count)) return null;
        try
        {
            var sessions = new List<Session>();
            for (var i = 0; i < count; i++)
            {
                var entry = Marshal.PtrToStructure<Entry>(buffer + i * Marshal.SizeOf<Entry>());
                if (entry.Id == 0 || entry.State is 6 or 7 or 8 or 9) continue;
                if (!Query(IntPtr.Zero, entry.Id, 24, out var data, out var size)) continue;
                Info info;
                try
                {
                    if (size < Marshal.SizeOf<Info>()) continue;
                    info = Marshal.PtrToStructure<Info>(data);
                }
                finally { WTSFreeMemory(data); }
                if (info.Id != entry.Id || info.LogonTime <= 0 ||
                    info.LogonTime > DateTime.MaxValue.ToFileTimeUtc() ||
                    string.IsNullOrWhiteSpace(info.Username)) continue;
                if (!WTSQueryUserToken((uint)entry.Id, out var token))
                {
                    token?.Dispose();
                    continue;
                }
                using (token)
                using (var user = new WindowsIdentity(token.DangerousGetHandle()))
                {
                    if (user.User is not { } sid) continue;
                    var transport = "unknown";
                    if (Query(IntPtr.Zero, entry.Id, 16, out var protocol, out var bytes))
                    {
                        try
                        {
                            if (bytes >= 2)
                                transport = Marshal.ReadInt16(protocol) switch { 0 => "console", 2 => "rdp", _ => "unknown" };
                        }
                        finally { WTSFreeMemory(protocol); }
                    }
                    var name = string.IsNullOrWhiteSpace(info.Domain)
                        ? info.Username : $@"{info.Domain}\{info.Username}";
                    sessions.Add(new(entry.Id, sid.Value, name, DateTimeOffset.FromFileTime(info.LogonTime),
                        transport, info.State switch { 0 => "active", 1 => "connected", 4 => "disconnected", _ => "other" }));
                }
            }
            return sessions.Count <= 128 ? sessions : null;
        }
        finally { WTSFreeMemory(buffer); }
    }
}
