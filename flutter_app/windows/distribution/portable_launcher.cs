using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Text.RegularExpressions;
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
            if (args.Length == 2 && args[0] == "--wait-for")
            {
                var oldPid = Int32.Parse(args[1]);
                if (oldPid <= 0 || oldPid == Process.GetCurrentProcess().Id) throw new ArgumentException("Invalid application process.");
                Process previous = null;
                try { previous = Process.GetProcessById(oldPid); }
                catch (ArgumentException) { /* The old app has already closed. */ }
                if (previous != null && !previous.WaitForExit(60000))
                    throw new IOException("The previous app is still running.");
                if (previous != null) previous.Dispose();
            }
            else if (args.Length != 0) throw new ArgumentException("Unsupported arguments.");

            var appRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ieum");
            var updatedLauncher = FindUpdate(appRoot);
            if (updatedLauncher != null)
            {
                using (var updated = Process.Start(new ProcessStartInfo { FileName = updatedLauncher, UseShellExecute = false }))
                {
                    if (updated == null) throw new IOException("Could not start the update.");
                    updated.WaitForExit();
                    return updated.ExitCode;
                }
            }
            var root = Path.Combine(appRoot, "builds");
            var destination = Path.Combine(root, BuildId);
            if (!File.Exists(Path.Combine(destination, ".complete")))
            {
                Directory.CreateDirectory(root);
                var staging = Path.Combine(root, BuildId + "-" + Guid.NewGuid().ToString("N"));
                Extract(staging);
                File.WriteAllText(Path.Combine(staging, ".complete"), BuildId);
                Directory.Move(staging, destination);
            }
            // Relative DLLs and Flutter data resolve from the extracted app folder.
            var app = Process.Start(new ProcessStartInfo
            {
                FileName = Path.Combine(destination, "ieum_flutter.exe"),
                WorkingDirectory = destination,
                UseShellExecute = false
            });
            if (app == null) throw new IOException("Could not start IEUM.");
            app.WaitForExit();
            return app.ExitCode;
        }
        catch (Exception error)
        {
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

    private static Version ParseVersion(string value)
    {
        var match = Regex.Match(value ?? "", @"^([0-9]+)\.([0-9]+)\.([0-9]+)(?:\+([0-9]+))?$");
        if (!match.Success) throw new FormatException("Invalid update version.");
        return new Version(Int32.Parse(match.Groups[1].Value), Int32.Parse(match.Groups[2].Value),
            Int32.Parse(match.Groups[3].Value), match.Groups[4].Success ? Int32.Parse(match.Groups[4].Value) : 0);
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
}
