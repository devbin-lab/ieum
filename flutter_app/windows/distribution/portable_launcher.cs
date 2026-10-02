using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

// Windows 10/11 include .NET Framework 4.x. No SDK or global installation.
internal static class PortableLauncher
{
    private const string BuildId = "__BUILD_ID__";
    private const string AppVersion = "__APP_VERSION__";

    [DataContract]
    private sealed class PendingUpdate
    {
        [DataMember(Name = "version")] public string Version;
        [DataMember(Name = "sha256")] public string Hash;
    }

    [STAThread]
    private static int Main(string[] args)
    {
        var appRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ieum");
        return Run(args, appRoot);
    }

    private static int Run(string[] args, string appRoot)
    {
        string fallback = null;
        string previousWorking = null;
        string recordedWorkingPath = null;
        bool recordedWorking = false;
        bool previousStillRunning = false;
        try
        {
            if (args.Length == 2 && args[0] == "--extract-only")
            {
                var target = Path.GetFullPath(args[1]);
                if (Directory.Exists(target) || File.Exists(target))
                    throw new IOException("Extraction destination must be new.");
                Extract(target);
                return 0;
            }
            if ((args.Length == 2 || args.Length == 4) && args[0] == "--wait-for")
            {
                if (args.Length == 4)
                {
                    if (args[2] != "--fallback") throw new ArgumentException("Unsupported arguments.");
                    // This path comes directly from the running app's trusted command
                    // line. ZIP installations are allowed outside our builds folder.
                    fallback = ValidExplicitFallback(args[3]);
                }
                var oldPid = Int32.Parse(args[1]);
                if (oldPid <= 0 || oldPid == Process.GetCurrentProcess().Id) throw new ArgumentException("Invalid application process.");
                Process previous = null;
                try { previous = Process.GetProcessById(oldPid); }
                catch (ArgumentException) { /* The old app has already closed. */ }
                if (previous != null && fallback == null)
                {
                    try { fallback = ValidExplicitFallback(previous.MainModule.FileName); }
                    catch { /* A protected process cannot supply a fallback. */ }
                }
                if (previous != null && !previous.WaitForExit(60000))
                {
                    previousStillRunning = true;
                    previous.Dispose();
                    throw new IOException("The previous app is still running.");
                }
                if (previous != null) previous.Dispose();
            }
            else if (args.Length != 0) throw new ArgumentException("Unsupported arguments.");

            // Capture the known working path before this version can replace it.
            try { previousWorking = ValidFallback(appRoot, File.ReadAllText(Path.Combine(appRoot, "last-working-app.txt"))); }
            catch { }
            if (fallback == null) fallback = previousWorking;

            var updatedLauncher = Environment.GetEnvironmentVariable("IEUM_DISABLE_UPDATES") == "1" ? null : FindUpdate(appRoot);
            if (updatedLauncher != null)
            {
                try
                {
                    using (var updated = Process.Start(new ProcessStartInfo { FileName = updatedLauncher, UseShellExecute = false }))
                    {
                        if (updated == null) throw new IOException("Could not start the update.");
                        updated.WaitForExit();
                        if (updated.ExitCode == 0) return 0;
                    }
                }
                catch { /* Fall through to this launcher's embedded version. */ }
                Quarantine(appRoot, Path.GetFileName(Path.GetDirectoryName(updatedLauncher)));
            }
            var destination = PrepareInstallation(appRoot);
            // Relative DLLs and Flutter data resolve from the extracted app folder.
            var startupMarker = Path.Combine(destination, ".startup-" + Guid.NewGuid().ToString("N"));
            var start = new ProcessStartInfo
            {
                FileName = Path.Combine(destination, "ieum_flutter.exe"),
                WorkingDirectory = destination,
                UseShellExecute = false
            };
            start.EnvironmentVariables["IEUM_STARTUP_MARKER"] = startupMarker;
            using (var app = Process.Start(start))
            {
                if (app == null) throw new IOException("Could not start IEUM.");
                var timer = Stopwatch.StartNew();
                while (!File.Exists(startupMarker) && !app.HasExited && timer.ElapsedMilliseconds < 45000)
                    System.Threading.Thread.Sleep(100);
                if (!File.Exists(startupMarker))
                {
                    if (!app.HasExited)
                    {
                        app.CloseMainWindow();
                        if (!app.WaitForExit(3000)) app.Kill();
                    }
                    throw new IOException("The updated application did not finish starting.");
                }
                try { File.Delete(startupMarker); } catch { }
                // Rendering one frame is not sufficient: native or asynchronous
                // initialization may still fail immediately after the marker.
                if (app.WaitForExit(5000))
                {
                    if (app.ExitCode != 0) throw new IOException("The updated application failed during startup.");
                    return 0; // An ordinary early user close is not a failed update.
                }
                try
                {
                    File.WriteAllText(Path.Combine(appRoot, "last-working-app.txt"), start.FileName);
                    recordedWorkingPath = start.FileName;
                    recordedWorking = true;
                }
                catch { }
                app.WaitForExit();
                if (app.ExitCode != 0) throw new IOException("The application exited unexpectedly.");
                return 0;
            }
        }
        catch (Exception error)
        {
            // A delayed close must not launch a second instance of the old app.
            if (previousStillRunning) return 1;
            if (!(args.Length == 2 && args[0] == "--extract-only"))
            {
                Quarantine(appRoot, AppVersion);
                if (recordedWorking)
                {
                    try
                    {
                        var marker = Path.Combine(appRoot, "last-working-app.txt");
                        if (String.Equals(File.ReadAllText(marker), recordedWorkingPath, StringComparison.OrdinalIgnoreCase))
                        {
                            if (previousWorking != null) File.WriteAllText(marker, previousWorking);
                            else File.Delete(marker);
                        }
                    }
                    catch { }
                }
                if (fallback == null)
                {
                    try { fallback = ValidFallback(appRoot, File.ReadAllText(Path.Combine(appRoot, "last-working-app.txt"))); }
                    catch { }
                }
                if (fallback != null && !fallback.StartsWith(Path.Combine(appRoot, "builds", BuildId) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                {
                    try
                    {
                        var start = new ProcessStartInfo { FileName = fallback, WorkingDirectory = Path.GetDirectoryName(fallback), UseShellExecute = false };
                        start.EnvironmentVariables["IEUM_DISABLE_UPDATES"] = "1";
                        start.EnvironmentVariables.Remove("IEUM_STARTUP_MARKER");
                        using (var restored = Process.Start(start))
                        {
                            if (restored != null) { restored.WaitForExit(); return restored.ExitCode; }
                        }
                    }
                    catch { }
                }
            }
            if (args.Length > 0)
            {
                Console.Error.WriteLine(error.ToString());
                return 1;
            }
            MessageBox.Show("이음을 실행하지 못했습니다.\n\n" + error.Message,
                "이음", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static string ValidExplicitFallback(string path)
    {
        try
        {
            var full = Path.GetFullPath(path);
            return String.Equals(Path.GetFileName(full), "ieum_flutter.exe", StringComparison.OrdinalIgnoreCase) &&
                File.Exists(full) ? full : null;
        }
        catch { return null; }
    }

    private static string ValidFallback(string root, string path)
    {
        try
        {
            var full = Path.GetFullPath(path);
            var builds = Path.GetFullPath(Path.Combine(root, "builds")) + Path.DirectorySeparatorChar;
            return full.StartsWith(builds, StringComparison.OrdinalIgnoreCase) &&
                String.Equals(Path.GetFileName(full), "ieum_flutter.exe", StringComparison.OrdinalIgnoreCase) &&
                File.Exists(full) ? full : null;
        }
        catch { return null; }
    }

    private static void Quarantine(string root, string version)
    {
        try
        {
            var pointer = Path.Combine(root, "pending-update.json");
            PendingUpdate update;
            using (var input = File.OpenRead(pointer))
                update = (PendingUpdate)new DataContractJsonSerializer(typeof(PendingUpdate)).ReadObject(input);
            if (update.Version != version) return;
            ParseVersion(version);
            var blocked = Path.Combine(root, "updates", version, "Ieum-Windows-x64.exe.blocked");
            Directory.CreateDirectory(Path.GetDirectoryName(blocked));
            File.WriteAllText(blocked, update.Hash);
            File.Move(pointer, pointer + ".failed-" + Guid.NewGuid().ToString("N"));
        }
        catch { /* Recovery must never prevent the previous version opening. */ }
    }

    private static Version ParseVersion(string value)
    {
        var match = Regex.Match(value ?? "", @"^([0-9]+)\.([0-9]+)\.([0-9]+)(?:\+([0-9]+))?$");
        if (!match.Success) throw new FormatException("Invalid update version.");
        // Accept old +build tags without treating build metadata as a release.
        if (match.Groups[4].Success) Int32.Parse(match.Groups[4].Value);
        return new Version(Int32.Parse(match.Groups[1].Value), Int32.Parse(match.Groups[2].Value),
            Int32.Parse(match.Groups[3].Value));
    }

    private static string FindUpdate(string appRoot)
    {
        var pointer = Path.Combine(appRoot, "pending-update.json");
        if (!File.Exists(pointer)) return null;
        try
        {
            PendingUpdate update;
            using (var input = File.OpenRead(pointer))
                update = (PendingUpdate)new DataContractJsonSerializer(typeof(PendingUpdate)).ReadObject(input);
            if (ParseVersion(update.Version).CompareTo(ParseVersion(AppVersion)) <= 0 ||
                !Regex.IsMatch(update.Hash ?? "", "^[a-f0-9]{64}$")) return null;
            var executable = Path.Combine(appRoot, "updates", update.Version, "Ieum-Windows-x64.exe");
            var blocked = executable + ".blocked";
            if (File.Exists(blocked) && File.ReadAllText(blocked).Trim() == update.Hash) return null;
            if (!File.Exists(executable)) return null;
            string actual;
            using (var input = File.OpenRead(executable))
            using (var hash = SHA256.Create())
                actual = BitConverter.ToString(hash.ComputeHash(input)).Replace("-", "").ToLowerInvariant();
            return actual == update.Hash ? executable : null;
        }
        catch { return null; } // Invalid/partial update leaves the embedded app usable.
    }

    private static void Extract(string destination)
    {
        using (var payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("Ieum.Payload.zip"))
        {
            if (payload == null) throw new IOException("Application payload is missing.");
            using (var archive = new ZipArchive(payload, ZipArchiveMode.Read))
                archive.ExtractToDirectory(destination);
        }
    }

    private static bool InstallationValid(string destination)
    {
        try
        {
            if (!File.Exists(Path.Combine(destination, ".complete"))) return false;
            var prefix = Path.GetFullPath(destination) + Path.DirectorySeparatorChar;
            using (var payload = Assembly.GetExecutingAssembly().GetManifestResourceStream("Ieum.Payload.zip"))
            using (var archive = new ZipArchive(payload, ZipArchiveMode.Read))
            {
                foreach (var entry in archive.Entries)
                {
                    if (entry.Name.Length == 0) continue;
                    var target = Path.GetFullPath(Path.Combine(destination, entry.FullName));
                    if (!target.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ||
                        !File.Exists(target) || new FileInfo(target).Length != entry.Length) return false;
                    using (var expected = entry.Open())
                    using (var actual = File.OpenRead(target))
                    using (var hash = SHA256.Create())
                        if (BitConverter.ToString(hash.ComputeHash(expected)) !=
                            BitConverter.ToString(hash.ComputeHash(actual))) return false;
                }
            }
            return true;
        }
        catch { return false; }
    }

    private static string PrepareInstallation(string appRoot)
    {
        var root = Path.GetFullPath(Path.Combine(appRoot, "builds"));
        var destination = Path.GetFullPath(Path.Combine(root, BuildId));
        if (!destination.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new IOException("Invalid application destination.");
        string lockName;
        using (var hash = SHA256.Create())
            lockName = "Local\\Ieum-Install-" + BitConverter.ToString(hash.ComputeHash(
                System.Text.Encoding.UTF8.GetBytes(destination.ToLowerInvariant()))).Replace("-", "");
        using (var gate = new Mutex(false, lockName))
        {
            bool locked;
            try { locked = gate.WaitOne(30000); }
            catch (AbandonedMutexException) { locked = true; }
            if (!locked) throw new IOException("Another IEUM installation is still being prepared. Try again.");
            try
            {
                if (InstallationValid(destination)) return destination;
                Directory.CreateDirectory(root);
                // Preserve damaged files for diagnosis, including user-added files.
                if (Directory.Exists(destination))
                    Directory.Move(destination, destination + "-damaged-" + Guid.NewGuid().ToString("N"));
                var staging = Path.Combine(root, BuildId + "-staging-" + Guid.NewGuid().ToString("N"));
                Extract(staging);
                File.WriteAllText(Path.Combine(staging, ".complete"), BuildId);
                if (!InstallationValid(staging)) throw new IOException("Application extraction verification failed.");
                Directory.Move(staging, destination);
                return destination;
            }
            finally { gate.ReleaseMutex(); }
        }
    }
}
