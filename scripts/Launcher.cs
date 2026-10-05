using System;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Threading;
using System.Windows.Forms;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

[assembly: AssemblyTitle("BHops Optimizer")]
[assembly: AssemblyDescription("Open-source Windows, gaming and Wi-Fi tuning with backups and undo")]
[assembly: AssemblyCompany("Bh0ps")]
[assembly: AssemblyProduct("BHops Optimizer")]
[assembly: AssemblyVersion("0.2.0.0")]
[assembly: AssemblyFileVersion("0.2.0.0")]

internal static class Launcher
{
    private static void AssertLocalPath(string path)
    {
        string current = Path.GetFullPath(path);
        if (current.Length < 3 || current[1] != ':' || current[2] != Path.DirectorySeparatorChar)
            throw new InvalidDataException("Runtime storage requires a local Windows drive.");
        while (!String.IsNullOrEmpty(current))
        {
            try
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Runtime paths cannot contain symbolic links or junctions.");
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
            string parent = Path.GetDirectoryName(current);
            if (parent == current) break;
            current = parent;
        }
    }

    [STAThread]
    private static int Main(string[] args)
    {
        string baseDirectory = Path.GetFullPath(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BHopsOptimizer", "Runtime"));
        string runDirectory = Path.Combine(baseDirectory, Guid.NewGuid().ToString("N"));
        bool runtimeCreated = false;
        try
        {
            bool demo = false, smoke = false;
            string screenshot = null, page = "Overview";
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "--demo") demo = true;
                else if (args[i] == "--smoke-test") smoke = true;
                else if (args[i] == "--screenshot" && i + 1 < args.Length) screenshot = Path.GetFullPath(args[++i]);
                else if (args[i] == "--page" && i + 1 < args.Length) page = args[++i];
                else throw new ArgumentException("Unknown argument. The EXE opens the UI. Use BHopsOptimizer.ps1 for CLI presets and automation.");
            }
            AssertLocalPath(runDirectory);
            if (Directory.Exists(runDirectory) || File.Exists(runDirectory)) throw new InvalidDataException("Runtime directory already exists.");
            Directory.CreateDirectory(runDirectory);
            runtimeCreated = true;
            AssertLocalPath(runDirectory);
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("BHopsOptimizer.payload.zip"))
            {
                if (stream == null) throw new InvalidOperationException("The embedded source bundle is missing.");
                using (ZipArchive archive = new ZipArchive(stream, ZipArchiveMode.Read))
                {
                    foreach (ZipArchiveEntry entry in archive.Entries)
                    {
                        string target = Path.GetFullPath(Path.Combine(runDirectory, entry.FullName));
                        if (!target.StartsWith(runDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Invalid bundled path.");
                        AssertLocalPath(target);
                        if (String.IsNullOrEmpty(entry.Name)) { Directory.CreateDirectory(target); continue; }
                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        AssertLocalPath(target);
                        using (Stream source = entry.Open())
                        using (FileStream destination = new FileStream(target, FileMode.CreateNew, FileAccess.Write)) { source.CopyTo(destination); }
                    }
                }
            }
            using (Runspace runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                Runspace.DefaultRunspace = runspace;
                // Process-scoped only; the app does not change the user's execution policy.
                using (PowerShell policy = PowerShell.Create())
                {
                    policy.Runspace = runspace;
                    policy.AddCommand("Set-ExecutionPolicy").AddParameter("Scope", "Process").AddParameter("ExecutionPolicy", "Bypass").AddParameter("Force");
                    policy.Invoke();
                    if (policy.HadErrors) throw new InvalidOperationException("Windows execution policy prevented the app from starting. Use the source instructions or contact your administrator.");
                }
                using (PowerShell powershell = PowerShell.Create())
                {
                    powershell.Runspace = runspace;
                    powershell.AddCommand(Path.Combine(runDirectory, "BHopsOptimizer.ps1")).AddParameter("Action", "Gui");
                    if (demo) powershell.AddParameter("Demo");
                    if (smoke) powershell.AddParameter("SmokeTest");
                    if (screenshot != null) powershell.AddParameter("ScreenshotPath", screenshot);
                    powershell.AddParameter("PreviewPage", page);
                    powershell.Invoke();
                    if (powershell.HadErrors)
                    {
                        string errors = String.Join(Environment.NewLine, powershell.Streams.Error);
                        throw new InvalidOperationException(errors);
                    }
                }
            }
            return 0;
        }
        catch (Exception error)
        {
            string errorDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BHopsOptimizer");
            try { AssertLocalPath(errorDirectory); Directory.CreateDirectory(errorDirectory); string errorFile = Path.Combine(errorDirectory, "startup-error.txt"); AssertLocalPath(errorFile); File.WriteAllText(errorFile, error.ToString()); } catch { }
            MessageBox.Show(error.Message, "BHops Optimizer — startup error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            // This folder was uniquely created by this process, under the fixed runtime root.
            string resolved = Path.GetFullPath(runDirectory);
            if (runtimeCreated && resolved.StartsWith(baseDirectory + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                try { AssertLocalPath(resolved); if (Directory.Exists(resolved)) Directory.Delete(resolved, true); } catch { }
            }
        }
    }
}
