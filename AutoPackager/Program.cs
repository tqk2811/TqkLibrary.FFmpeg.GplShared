using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace AutoPackager
{
    class Program
    {
        static async Task Main(string[] args)
        {
            string rootDir = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", ".."));
            string artifactsDir = Path.Combine(rootDir, "FFmpegBuildSubmodule", "FFmpeg-Builds", "artifacts");
            string packagesDir = Path.Combine(rootDir, "Packages");
            string tempDir = Path.Combine(rootDir, "TempOutput");
            string nugetExe = Path.Combine(rootDir, "nuget.exe");

            if (!Directory.Exists(artifactsDir))
            {
                Console.WriteLine($"Error: Artifacts directory not found at {artifactsDir}");
                return;
            }

            Directory.CreateDirectory(packagesDir);

            if (!File.Exists(nugetExe))
            {
                Console.WriteLine("nuget.exe not found. Downloading...");
                using (var client = new HttpClient())
                {
                    var response = await client.GetAsync("https://dist.nuget.org/win-x86-commandline/latest/nuget.exe");
                    response.EnsureSuccessStatusCode();
                    await using var fs = new FileStream(nugetExe, FileMode.Create, FileAccess.Write, FileShare.None);
                    await response.Content.CopyToAsync(fs);
                }
                Console.WriteLine("nuget.exe downloaded.");
            }

            var zipFiles = Directory.GetFiles(artifactsDir, "*-win*.zip");
            if (zipFiles.Length == 0)
            {
                Console.WriteLine("No zip files found.");
                return;
            }

            // Regex ex: ffmpeg-n4.4.6-86-g810c930d7a-win64-gpl-shared-4.4.zip
            // group 1: 4.4.6
            // group 2: win64
            var regex = new Regex(@"ffmpeg-n([\d\.]+).*-(win32|win64|winarm64)-gpl-shared-[^\s]+\.zip", RegexOptions.IgnoreCase);

            string gplSharedNuspecTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.GplShared.nuspec"));
            string runtimeNuspecTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Runtime.nuspec"));
            
            // Clean temp
            if (Directory.Exists(tempDir))
            {
                Directory.Delete(tempDir, true);
            }

            foreach (var zipFile in zipFiles)
            {
                var match = regex.Match(Path.GetFileName(zipFile));
                if (!match.Success)
                {
                    Console.WriteLine($"Skipping unrecognised zip file: {zipFile}");
                    continue;
                }

                string version = match.Groups[1].Value;
                string winArch = match.Groups[2].Value; // win32, win64, winarm64

                string arch = winArch switch
                {
                    "win32" => "x86",
                    "win64" => "x64",
                    "winarm64" => "arm64",
                    _ => throw new Exception($"Unknown arch {winArch}")
                };

                Console.WriteLine($"Processing Version: {version}, Arch: {arch}");

                string extractPath = Path.Combine(tempDir, $"{version}-{arch}");
                if (Directory.Exists(extractPath))
                    Directory.Delete(extractPath, true);

                Directory.CreateDirectory(extractPath);

                Console.WriteLine("Extracting...");
                ZipFile.ExtractToDirectory(zipFile, extractPath);

                // The extracted folder usually has a subfolder named identical to the zip name without .zip
                // e.g., ffmpeg-n4.4.6-86-g810c930d7a-win64-gpl-shared-4.4
                string extractedBaseDir = Directory.GetDirectories(extractPath).FirstOrDefault();
                if (string.IsNullOrEmpty(extractedBaseDir))
                {
                    extractedBaseDir = extractPath; // Fallback
                }
                
                string relativeBaseDir = ".";

                // GplShared nuspec
                string gplSharedNuspec = gplSharedNuspecTemplate
                    .Replace("<id>TqkLibrary.FFmpeg.GplShared</id>", $"<id>TqkLibrary.FFmpeg.GplShared.Window.{arch}</id>")
                    .Replace("$version$", version)
                    .Replace("$os$", "Window")
                    .Replace("$arch$", arch)
                    .Replace("$basePath$", relativeBaseDir);

                // Runtime nuspec
                string runtimeNuspec = runtimeNuspecTemplate
                    .Replace("<id>TqkLibrary.FFmpeg.Runtimes</id>", $"<id>TqkLibrary.FFmpeg.Runtime.Window.{arch}</id>")
                    .Replace("[$version$,$version$]", $"[{version},{version}]")
                    .Replace("$version$", version)
                    .Replace("$os$", "Window")
                    .Replace("$arch$", arch)
                    .Replace("$path$", $@"{relativeBaseDir}\bin");
                
                // Ensure dependencies point to Window.<arch>
                runtimeNuspec = runtimeNuspec.Replace("<dependency id=\"TqkLibrary.FFmpeg.GplShared\"", $"<dependency id=\"TqkLibrary.FFmpeg.GplShared.Window.{arch}\"");

                string gplSharedNuspecPath = Path.Combine(extractPath, "TqkLibrary.FFmpeg.GplShared.nuspec");
                string runtimeNuspecPath = Path.Combine(extractPath, "TqkLibrary.FFmpeg.Runtime.nuspec");

                File.WriteAllText(gplSharedNuspecPath, gplSharedNuspec);
                File.WriteAllText(runtimeNuspecPath, runtimeNuspec);

                // Copy README and props to the extracted directory so they can be found by nuget without changing the base path
                string readmeContent = $"# TqkLibrary.FFmpeg.GplShared\n\n{Path.GetFileNameWithoutExtension(zipFile)}";
                File.WriteAllText(Path.Combine(extractedBaseDir, "README.md"), readmeContent);
                File.Copy(Path.Combine(rootDir, "TqkLibrary.FFmpeg.GplShared.props"), Path.Combine(extractedBaseDir, "TqkLibrary.FFmpeg.GplShared.props"), true);
                File.Copy(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Runtime.props"), Path.Combine(extractedBaseDir, "TqkLibrary.FFmpeg.Runtime.props"), true);

                Console.WriteLine("Packing GplShared...");
                RunCommand(nugetExe, $"pack \"{gplSharedNuspecPath}\" -OutputDirectory \"{packagesDir}\" -NoPackageAnalysis -BasePath \"{extractedBaseDir}\"");

                Console.WriteLine("Packing Runtime...");
                RunCommand(nugetExe, $"pack \"{runtimeNuspecPath}\" -OutputDirectory \"{packagesDir}\" -NoPackageAnalysis -BasePath \"{extractedBaseDir}\"");
                
                Console.WriteLine($"Done {version} {arch}.");
            }

            Console.WriteLine("All packages generated successfully.");

            // Commit to git
            Console.WriteLine("Committing changes to git...");
            RunCommand("git", "add .", rootDir);
            RunCommand("git", "commit -m \"Auto-generated packager and modified nuspec process\"", rootDir);
        }

        static void RunCommand(string exe, string args, string workingDir = null)
        {
            var psi = new ProcessStartInfo(exe, args)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            if (workingDir != null)
            {
                psi.WorkingDirectory = workingDir;
            }

            using var process = Process.Start(psi);
            process.WaitForExit();

            if (process.ExitCode != 0)
            {
                var error = process.StandardError.ReadToEnd();
                var output = process.StandardOutput.ReadToEnd();
                Console.WriteLine($"Error running {exe} {args}:");
                Console.WriteLine(error);
                Console.WriteLine(output);
            }
        }
    }
}
