using System;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;

// Compiled together with the real launcher by test-launcher.ps1. No windows open.
internal static class LauncherTests
{
    private static object Call(string name, params object[] args)
    {
        return typeof(PortableLauncher).GetMethod(name, BindingFlags.NonPublic | BindingFlags.Static).Invoke(null, args);
    }
    private static void Check(bool result, string message)
    {
        if (!result) throw new Exception(message);
        Console.WriteLine("PASS " + message);
    }
    private static string Hash(string file)
    {
        using (var stream = File.OpenRead(file))
        using (var sha = SHA256.Create())
            return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
    }
    private static void Pointer(string root, string version, string hash)
    {
        File.WriteAllText(Path.Combine(root, "pending-update.json"), "{\"version\":\"" + version + "\",\"sha256\":\"" + hash + "\"}");
    }
    public static int Main(string[] args)
    {
        var root = args[0];
        var fallback = Path.Combine(root, "builds", "previous", "ieum_flutter.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(fallback));
        File.Copy(args[1], fallback);
        Check(Call("ValidFallback", root, fallback) != null, "known previous build accepted");
        Check(Call("ValidFallback", root, args[1]) == null, "outside path rejected");
        var zipFallback = Path.Combine(Path.GetDirectoryName(root), "zip-install", "ieum_flutter.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(zipFallback));
        File.Copy(args[1], zipFallback);
        Check(Call("ValidExplicitFallback", zipFallback) != null, "explicit ZIP installation accepted");
        Check(Call("ValidExplicitFallback", args[1]) == null, "invalid fallback filename rejected");
        Check(Call("ValidFallback", root, zipFallback) == null, "cached external path remains rejected");
        var asset = Path.Combine(root, "updates", "0.2.1+6", "Ieum-Windows-x64.exe");
        Directory.CreateDirectory(Path.GetDirectoryName(asset));
        File.WriteAllText(asset, "fixture");
        Pointer(root, "0.2.1+6", Hash(asset));
        Check((string)Call("FindUpdate", root) == asset, "verified newer asset selected");
        File.WriteAllText(asset, "tampered");
        Check(Call("FindUpdate", root) == null, "tampered asset ignored");
        Pointer(root, "0.2.1+6", Hash(asset));
        Call("Quarantine", root, "0.2.1+6");
        Check(!File.Exists(Path.Combine(root, "pending-update.json")), "failed update pointer retired");
        Pointer(root, "0.2.1+6", Hash(asset));
        Check(Call("FindUpdate", root) == null, "same failed asset cannot loop");
        // Embedded fixture exits before startup acknowledgement. Recover the old exe.
        Pointer(root, "0.2.0+5", Hash(asset));
        var code = (int)Call("Run", new string[] { "--wait-for", "2147483647", "--fallback", fallback }, root);
        Check(code == 0 && File.Exists(Path.Combine(Path.GetDirectoryName(fallback), "restored.txt")), "startup failure restores previous app");
        Check(!File.Exists(Path.Combine(root, "pending-update.json")), "startup failure quarantines pending package");
        Pointer(root, "0.2.0+5", Hash(asset));
        code = (int)Call("Run", new string[] { "--wait-for", "2147483647", "--fallback", zipFallback }, root);
        Check(code == 0 && File.Exists(Path.Combine(Path.GetDirectoryName(zipFallback), "restored.txt")), "startup failure restores ZIP app after old process exited");

        var workingMarker = Path.Combine(root, "last-working-app.txt");
        var restoredMarker = Path.Combine(Path.GetDirectoryName(fallback), "restored.txt");
        File.WriteAllText(workingMarker, fallback);
        try
        {
            foreach (var mode in new[] { "early-crash", "late-crash" })
            {
                File.Delete(restoredMarker);
                Pointer(root, "0.2.0+5", Hash(asset));
                Environment.SetEnvironmentVariable("IEUM_TEST_STARTUP_MODE", mode);
                code = (int)Call("Run", new string[] { "--wait-for", "2147483647" }, root);
                Check(code == 0 && File.Exists(restoredMarker), mode + " after marker restores prior app");
                Check(File.ReadAllText(workingMarker) == fallback, mode + " preserves last known working build");
                Check(!File.Exists(Path.Combine(root, "pending-update.json")), mode + " cannot repeat pending update");
            }
            File.Delete(restoredMarker);
            Pointer(root, "0.2.0+5", Hash(asset));
            Environment.SetEnvironmentVariable("IEUM_TEST_STARTUP_MODE", "early-close");
            code = (int)Call("Run", new string[] { "--wait-for", "2147483647" }, root);
            Check(code == 0 && !File.Exists(restoredMarker) && File.Exists(Path.Combine(root, "pending-update.json")), "normal early close does not trigger rollback");
        }
        finally { Environment.SetEnvironmentVariable("IEUM_TEST_STARTUP_MODE", null); }
        return 0;
    }
}
