using Microsoft.Win32;
using System.Management;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.Json;

if (args is ["--version"])
{
    Console.WriteLine("YES Desk Windows Agent 1.0.1");
    return;
}
ServiceBase.Run(new AgentService());

sealed class AgentService : ServiceBase
{
    private static readonly string Root = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "YESDeskAgent");
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };
    private readonly CancellationTokenSource stop = new();
    private readonly SemaphoreSlim changed = new(0, 1);
    private Task? worker;

    public AgentService()
    {
        ServiceName = "YESDeskAgent";
        CanHandleSessionChangeEvent = true;
        AutoLog = false;
    }

    protected override void OnStart(string[] args) => worker = Task.Run(RunAsync);

    protected override void OnSessionChange(SessionChangeDescription change)
    {
        try { changed.Release(); } catch (SemaphoreFullException) { }
    }

    protected override void OnStop()
    {
        stop.Cancel();
        worker?.Wait(TimeSpan.FromSeconds(15));
    }

    private async Task RunAsync()
    {
        using var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false })
        { Timeout = TimeSpan.FromSeconds(12) };
        var delay = 5;
        var reportedFailure = false;
        while (!stop.IsCancellationRequested)
        {
            try
            {
                var config = ReadConfig();
                var guid = Guid.Parse((string)Registry.GetValue(
                    @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography", "MachineGuid", "")!);
                var token = await CredentialAsync(client, config, guid, stop.Token);
                var machine = Wmi("SELECT Model,Domain,TotalPhysicalMemory FROM Win32_ComputerSystem",
                    "Model", "Domain", "TotalPhysicalMemory");
                var cpu = Wmi("SELECT Name FROM Win32_Processor", "Name");
                var os = Wmi("SELECT Caption,Version FROM Win32_OperatingSystem", "Caption", "Version");
                var disks = DriveInfo.GetDrives().Where(d => d.DriveType == DriveType.Fixed && d.IsReady)
                    .Take(32).Select(d => new { Name = d.Name, Bytes = d.TotalSize }).ToArray();
                using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint(config, "inventory"));
                request.Headers.Authorization = new("Bearer", token);
                request.Content = JsonContent.Create(new
                {
                    MachineGuid = guid, Hostname = Environment.MachineName, Domain = machine[1],
                    Model = machine[0], RamBytes = long.Parse(machine[2]), Cpu = cpu[0],
                    Os = $"{os[0]} {os[1]}", Disks = disks, Sessions = Wts.Snapshot(),
                    AgentVersion = "1.0.1",
                    Addresses = NetworkInterface.GetAllNetworkInterfaces()
                        .Where(adapter => adapter.OperationalStatus == OperationalStatus.Up)
                        .SelectMany(adapter => adapter.GetIPProperties().UnicastAddresses)
                        .Select(address => address.Address)
                        .Where(address => !IPAddress.IsLoopback(address) && !address.IsIPv6LinkLocal)
                        .Select(address => address.ToString()).Distinct().Take(64).ToArray()
                }, options: Json);
                using var response = await client.SendAsync(request, stop.Token);
                response.EnsureSuccessStatusCode();
                if (reportedFailure) WriteStatus("Inventory reporting recovered.");
                reportedFailure = false;
                delay = 30;
            }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { break; }
            catch (Exception)
            {
                if (!reportedFailure) WriteStatus("Inventory reporting failed. The service will retry.");
                reportedFailure = true;
                delay = Math.Min(300, delay * 2);
            }
            try
            {
                if (reportedFailure)
                    await Task.Delay(TimeSpan.FromSeconds(delay + Random.Shared.Next(0, 5)), stop.Token);
                else
                    await changed.WaitAsync(TimeSpan.FromSeconds(delay), stop.Token);
            }
            catch (OperationCanceledException) when (stop.IsCancellationRequested) { break; }
        }
    }

    private sealed record Config(string Api, string? Broker, string? ClientCertificateIssuer);

    private static Config ReadConfig()
    {
        var directory = new DirectoryInfo(Root);
        if (!directory.Exists || directory.Attributes.HasFlag(FileAttributes.ReparsePoint))
            throw new InvalidDataException();
        var acl = directory.GetAccessControl();
        if (!acl.AreAccessRulesProtected || !TrustedAcl(acl)) throw new InvalidDataException();
        foreach (var file in directory.EnumerateFiles())
            if (file.Attributes.HasFlag(FileAttributes.ReparsePoint) || !TrustedAcl(file.GetAccessControl()))
                throw new InvalidDataException();
        var config = JsonSerializer.Deserialize<Config>(File.ReadAllText(Path.Combine(Root, "config.json")), Json)
            ?? throw new InvalidDataException();
        ValidateHttps(config.Api);
        if (config.Broker is not null)
        {
            ValidateHttps(config.Broker);
            if (string.IsNullOrWhiteSpace(config.ClientCertificateIssuer)) throw new InvalidDataException();
        }
        return config;
    }

    private static void ValidateHttps(string address)
    {
        var uri = new Uri(address);
        if (uri.Scheme != "https" || uri.UserInfo.Length + uri.Query.Length + uri.Fragment.Length != 0)
            throw new InvalidDataException();
    }

    private static bool TrustedAcl(FileSystemSecurity acl)
    {
        const string system = "S-1-5-18";
        const string admins = "S-1-5-32-544";
        return acl.GetOwner(typeof(SecurityIdentifier))?.Value is (system or admins)
            && acl.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>()
                .All(rule => rule.IdentityReference.Value is (system or admins));
    }

    private static Uri Endpoint(Config config, string path) =>
        new(config.Api.TrimEnd('/') + "/v2/agents/" + path);

    private static async Task<string> CredentialAsync(HttpClient client, Config config, Guid guid, CancellationToken cancel)
    {
        var state = Path.Combine(Root, "agent.token");
        if (File.Exists(state)) return Unprotect(state);
        if (config.Broker is not null) return await BrokerCredentialAsync(config, guid, state, cancel);
        var enrollment = Path.Combine(Root, "enrollment.token");
        using var response = await client.PostAsJsonAsync(Endpoint(config, "enroll"),
            new { DeviceId = guid, EnrollmentCode = Unprotect(enrollment) }, Json, cancel);
        response.EnsureSuccessStatusCode();
        using var body = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancel));
        var token = body.RootElement.GetProperty("agent_token").GetString() ?? throw new InvalidDataException();
        if (token.Length != 43 || token.Any(c => !(char.IsAsciiLetterOrDigit(c) || c is '_' or '-')))
            throw new InvalidDataException();
        Protect(state, token);
        File.Delete(enrollment);
        return token;
    }

    private static async Task<string> BrokerCredentialAsync(Config config, Guid guid, string state, CancellationToken cancel)
    {
        using var store = new X509Store(StoreName.My, StoreLocation.LocalMachine);
        store.Open(OpenFlags.ReadOnly);
        var available = store.Certificates;
        try
        {
            var now = DateTime.Now;
            var matching = available.Cast<X509Certificate2>().Where(cert =>
                cert.HasPrivateKey && cert.NotBefore <= now && cert.NotAfter > now &&
                string.Equals(cert.Issuer, config.ClientCertificateIssuer, StringComparison.OrdinalIgnoreCase) &&
                cert.Extensions.OfType<X509EnhancedKeyUsageExtension>().Any(usage =>
                    usage.EnhancedKeyUsages.Cast<Oid>().Any(oid => oid.Value == "1.3.6.1.5.5.7.3.2"))).ToArray();
            if (matching.Length != 1) throw new InvalidDataException();
            using var handler = new HttpClientHandler { AllowAutoRedirect = false };
            handler.ClientCertificates.Add(matching[0]);
            using var broker = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(12) };
            var pending = state + ".pending";
            if (!File.Exists(pending))
            {
                var fresh = Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
                    .TrimEnd('=').Replace('+', '-').Replace('/', '_');
                Protect(pending, fresh);
            }
            var token = Unprotect(pending);
            var hash = Convert.ToHexString(SHA256.HashData(Encoding.ASCII.GetBytes(token))).ToLowerInvariant();
            using var response = await broker.PostAsJsonAsync(config.Broker!.TrimEnd('/') + "/enroll",
                new { MachineGuid = guid, TokenHash = hash }, Json, cancel);
            response.EnsureSuccessStatusCode();
            using var body = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancel));
            if (!body.RootElement.GetProperty("registered").GetBoolean()) throw new InvalidDataException();
            File.Move(pending, state, false);
            return token;
        }
        finally { foreach (var cert in available) cert.Dispose(); }
    }

    private static void Protect(string path, string token)
    {
        var pending = path + ".new";
        File.WriteAllBytes(pending, ProtectedData.Protect(Encoding.ASCII.GetBytes(token), null, DataProtectionScope.LocalMachine));
        File.Move(pending, path, true);
    }

    private static string Unprotect(string path) =>
        Encoding.ASCII.GetString(ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.LocalMachine));

    private static string[] Wmi(string query, params string[] fields)
    {
        using var search = new ManagementObjectSearcher(query) { Options = { Timeout = TimeSpan.FromSeconds(5) } };
        using var rows = search.Get();
        foreach (ManagementBaseObject row in rows)
            using (row) return fields.Select(field => Convert.ToString(row[field]) ?? "").ToArray();
        throw new InvalidDataException();
    }

    private static void WriteStatus(string message)
    {
        try { System.Diagnostics.EventLog.WriteEntry("YESDeskAgent", message); }
        catch (System.ComponentModel.Win32Exception) { }
        catch (InvalidOperationException) { }
    }
}
