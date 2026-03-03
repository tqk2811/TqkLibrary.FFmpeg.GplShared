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

            var archiveFiles = Directory.EnumerateFiles(artifactsDir, "*.*").Where(s => s.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) || s.EndsWith(".tar.xz", StringComparison.OrdinalIgnoreCase)).ToArray();
            if (archiveFiles.Length == 0)
            {
                Console.WriteLine("No archive files found.");
                return;
            }

            // Regex ex: ffmpeg-n4.4.6-86-g810c930d7a-win64-gpl-shared-4.4.zip
            // group 1: 4.4.6
            // group 2: 86
            // group 3: win64
            var regex = new Regex(@"ffmpeg-n([\d\.]+)-(\d+)-.*-(win32|win64|winarm64|linuxarm64|linux64|mac64)-gpl-shared-[^\s]+\.(zip|tar\.xz)", RegexOptions.IgnoreCase);

            string gplSharedNuspecTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.GplShared.nuspec"));
            string runtimeNuspecTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Runtime.nuspec"));
            
            string gplSharedPropsTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.GplShared.props"));
            string gplSharedTargetsTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.GplShared.targets"));
            string runtimePropsTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Runtime.props"));
            
            // Clean temp
            if (Directory.Exists(tempDir))
            {
                Directory.Delete(tempDir, true);
            }

            foreach (var archiveFile in archiveFiles)
            {
                var match = regex.Match(Path.GetFileName(archiveFile));
                if (!match.Success)
                {
                    Console.WriteLine($"Skipping unrecognised archive file: {archiveFile}");
                    continue;
                }

                string baseVersion = match.Groups[1].Value;
                string buildVersion = match.Groups[2].Value; // e.g., 86
                string winArch = match.Groups[3].Value; // win32, win64, winarm64

                string version = $"{baseVersion}.{buildVersion}";

                string arch = winArch switch
                {
                    "win32" => "x86",
                    "win64" => "x64",
                    "winarm64" => "arm64",
                    "linux64" => "x64",
                    "linuxarm64" => "arm64",
                    "mac64" => "x64",
                    _ => throw new Exception($"Unknown arch {winArch}")
                };

                string osName = winArch.StartsWith("win") ? "Win" : (winArch.StartsWith("linux") ? "Linux" : "Mac");
                string osId = winArch.StartsWith("win") ? "win" : (winArch.StartsWith("linux") ? "linux" : "osx");

                Console.WriteLine($"Processing Version: {version}, Arch: {arch}");

                string extractPath = Path.Combine(tempDir, $"{version}-{arch}");
                if (Directory.Exists(extractPath))
                    Directory.Delete(extractPath, true);

                Directory.CreateDirectory(extractPath);

                Console.WriteLine("Extracting...");
                if (archiveFile.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
                {
                    ZipFile.ExtractToDirectory(archiveFile, extractPath);
                }
                else if (archiveFile.EndsWith(".tar.xz", StringComparison.OrdinalIgnoreCase))
                {
                    RunCommand("tar", $"-xf \"{archiveFile}\" -C \"{extractPath}\"", null, true);
                }

                // The extracted folder usually has a subfolder named identical to the zip name without .zip
                // e.g., ffmpeg-n4.4.6-86-g810c930d7a-win64-gpl-shared-4.4
                string extractedBaseDir = Directory.GetDirectories(extractPath).FirstOrDefault();
                if (string.IsNullOrEmpty(extractedBaseDir))
                {
                    extractedBaseDir = extractPath; // Fallback
                }
                
                // Fix Linux/Mac symlinks missing on Windows extraction
                if (osName == "Linux" || osName == "Mac")
                {
                    string libDir = Path.Combine(extractedBaseDir, "lib");
                    if (Directory.Exists(libDir))
                    {
                        var libFiles = Directory.GetFiles(libDir, "*.*");
                        foreach (var libFile in libFiles)
                        {
                            string fileName = Path.GetFileName(libFile);
                            string baseName = null;
                            
                            var soMatch = Regex.Match(fileName, @"^(.*?\.so)\.");
                            if (soMatch.Success) baseName = soMatch.Groups[1].Value;
                            
                            var dylibMatch = Regex.Match(fileName, @"^(.*?)\.\d+\.dylib$");
                            if (dylibMatch.Success) baseName = dylibMatch.Groups[1].Value + ".dylib";
                            
                            if (baseName != null)
                            {
                                string basePath = Path.Combine(libDir, baseName);
                                if (!File.Exists(basePath))
                                {
                                    File.Copy(libFile, basePath);
                                }
                            }
                        }
                    }
                }
                
                string relativeBaseDir = ".";

                // GplShared nuspec
                string gplSharedNuspec = gplSharedNuspecTemplate
                    .Replace("<id>TqkLibrary.FFmpeg.GplShared</id>", $"<id>TqkLibrary.FFmpeg.GplShared.{osName}.{arch}</id>")
                    .Replace("$version$", version)
                    .Replace("$osName$", osName)
                    .Replace("$os$", osId)
                    .Replace("$arch$", arch)
                    .Replace("$basePath$", relativeBaseDir);

                // Runtime nuspec
                string runtimeNuspec = runtimeNuspecTemplate
                    .Replace("<id>TqkLibrary.FFmpeg.Runtimes</id>", $"<id>TqkLibrary.FFmpeg.Runtime.{osName}.{arch}</id>")
                    .Replace("[$version$,$version$]", $"[{version},{version}]")
                    .Replace("$version$", version)
                    .Replace("$osName$", osName)
                    .Replace("$os$", osId)
                    .Replace("$arch$", arch)
                    .Replace("$path$", $@"{relativeBaseDir}\bin");
                
                // Ensure dependencies point to OS.<arch>
                runtimeNuspec = runtimeNuspec.Replace("<dependency id=\"TqkLibrary.FFmpeg.GplShared\"", $"<dependency id=\"TqkLibrary.FFmpeg.GplShared.{osName}.{arch}\"");

                string gplSharedNuspecPath = Path.Combine(extractPath, "TqkLibrary.FFmpeg.GplShared.nuspec");
                string runtimeNuspecPath = Path.Combine(extractPath, "TqkLibrary.FFmpeg.Runtime.nuspec");

                File.WriteAllText(gplSharedNuspecPath, gplSharedNuspec);
                File.WriteAllText(runtimeNuspecPath, runtimeNuspec);

                // Generate README
                string readmeContent = $"# TqkLibrary.FFmpeg.GplShared\n\n{Path.GetFileNameWithoutExtension(archiveFile)}";
                File.WriteAllText(Path.Combine(extractedBaseDir, "README.md"), readmeContent);
                
                // Write props and targets dynamically
                string idShared = $"TqkLibrary.FFmpeg.GplShared.{osName}.{arch}";
                string idRuntime = $"TqkLibrary.FFmpeg.Runtime.{osName}.{arch}";

                string gplSharedProps = gplSharedPropsTemplate.Replace("TqkLibrary.FFmpeg.GplShared", idShared);
                string gplSharedTargets = gplSharedTargetsTemplate.Replace("TqkLibrary.FFmpeg.GplShared", idShared);
                
                string nativeTargetTemplate = osName == "Win" 
? @"
	<ItemDefinitionGroup Condition=""'$(Language)' == 'C++'"">
		<ClCompile>
			<AdditionalIncludeDirectories>$(MSBuildThisFileDirectory)include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
		</ClCompile>
		<Link>
			<AdditionalLibraryDirectories>$(MSBuildThisFileDirectory)win\" + arch + @"\lib;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
			<AdditionalDependencies>avcodec.lib;avdevice.lib;avfilter.lib;avformat.lib;avutil.lib;swresample.lib;swscale.lib;%(AdditionalDependencies)</AdditionalDependencies>
		</Link>
	</ItemDefinitionGroup>
</Project>"
: @"
	<ItemDefinitionGroup Condition=""'$(Language)' == 'C++'"">
		<ClCompile>
			<AdditionalIncludeDirectories>$(MSBuildThisFileDirectory)include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
		</ClCompile>
		<Link>
			<AdditionalLibraryDirectories>$(MSBuildThisFileDirectory)" + osId + @"\" + arch + @"\lib;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
		</Link>
	</ItemDefinitionGroup>
</Project>";

                string gplSharedNativeTargets = gplSharedTargets.Replace("</Project>", nativeTargetTemplate);

                string runtimeProps = runtimePropsTemplate.Replace("TqkLibrary.FFmpeg.Runtimes", idRuntime);

                File.WriteAllText(Path.Combine(extractedBaseDir, $"{idShared}.props"), gplSharedProps);
                File.WriteAllText(Path.Combine(extractedBaseDir, $"{idShared}.targets"), gplSharedTargets);
                File.WriteAllText(Path.Combine(extractedBaseDir, $"{idShared}.native.targets"), gplSharedNativeTargets);
                File.WriteAllText(Path.Combine(extractedBaseDir, $"{idRuntime}.props"), runtimeProps);

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

        static void RunCommand(string exe, string args, string workingDir = null, bool ignoreErrors = false)
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
            
            var outputTask = process.StandardOutput.ReadToEndAsync();
            var errorTask = process.StandardError.ReadToEndAsync();
            
            process.WaitForExit();

            if (process.ExitCode != 0 && !ignoreErrors)
            {
                var error = errorTask.Result;
                var output = outputTask.Result;
                Console.WriteLine($"Error running {exe} {args}:");
                Console.WriteLine(error);
                Console.WriteLine(output);
            }
        }
    }
}
