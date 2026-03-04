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

            if (!Directory.Exists(artifactsDir))
            {
                Console.WriteLine($"Error: Artifacts directory not found at {artifactsDir}");
                return;
            }

            Directory.CreateDirectory(packagesDir);

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

            string nativeNuspecTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Native.nuspec"));
            string toolsNuspecTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Tools.nuspec"));
            
            string nativePropsTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Native.props"));
            string nativeTargetsTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Native.targets"));
            string toolsPropsTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Tools.props"));
            
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

                // Native nuspec
                string nativeNuspec = nativeNuspecTemplate
                    .Replace("<id>TqkLibrary.FFmpeg.Native</id>", $"<id>TqkLibrary.FFmpeg.Native.{osName}.{arch}</id>")
                    .Replace("$version$", version)
                    .Replace("$osName$", osName)
                    .Replace("$os$", osId)
                    .Replace("$arch$", arch)
                    .Replace("$basePath$", relativeBaseDir);

                // Tools nuspec
                string toolsNuspec = toolsNuspecTemplate
                    .Replace("<id>TqkLibrary.FFmpeg.Tools</id>", $"<id>TqkLibrary.FFmpeg.Tools.{osName}.{arch}</id>")
                    .Replace("<dependency id=\"TqkLibrary.FFmpeg.Native\"", $"<dependency id=\"TqkLibrary.FFmpeg.Native.{osName}.{arch}\"")
                    .Replace("[$version$,$version$]", $"[{version},{version}]")
                    .Replace("$version$", version)
                    .Replace("$osName$", osName)
                    .Replace("$os$", osId)
                    .Replace("$arch$", arch)
                    .Replace("$path$", $@"{relativeBaseDir}\bin");

                string nativeNuspecPath = Path.Combine(extractPath, "TqkLibrary.FFmpeg.Native.nuspec");
                string toolsNuspecPath = Path.Combine(extractPath, "TqkLibrary.FFmpeg.Tools.nuspec");

                File.WriteAllText(nativeNuspecPath, nativeNuspec);
                File.WriteAllText(toolsNuspecPath, toolsNuspec);

                // Generate README
                string readmeContent = $"# TqkLibrary.FFmpeg.Native\n\n{Path.GetFileNameWithoutExtension(archiveFile)}";
                File.WriteAllText(Path.Combine(extractedBaseDir, "README.md"), readmeContent);
                
                // Write props and targets dynamically
                string idNative = $"TqkLibrary.FFmpeg.Native.{osName}.{arch}";
                string idTools = $"TqkLibrary.FFmpeg.Tools.{osName}.{arch}";

                string platformCondition = (arch, osName) switch
                {
                    ("x64", "Win") => " And ('$(Platform.ToLower())' == 'x64' Or '$(Platform.ToLower())' == 'win64')",
                    ("x86", "Win") => " And ('$(Platform.ToLower())' == 'x86' Or '$(Platform.ToLower())' == 'win32')",
                    ("x64", _) => " And '$(Platform.ToLower())' == 'x64'",
                    ("x86", _) => " And '$(Platform.ToLower())' == 'x86'",
                    ("arm64", _) => " And '$(Platform.ToLower())' == 'arm64'",
                    _ => ""
                };

                string osCondition = osName switch
                {
                    "Win" => " And ('$(OS)' == 'Windows_NT' And '$(ApplicationType)' == '')",
                    "Linux" => " And ('$(OS)' == 'Unix' Or '$(ApplicationType)' == 'Linux')",
                    "Mac" => " And ('$(OS)' == 'OSX' Or '$(ApplicationType)' == 'Mac')",
                    _ => ""
                };

                string finalCondition = platformCondition + osCondition;

                string nativeProps = nativePropsTemplate.Replace("TqkLibrary.FFmpeg.Native", idNative);
                
                string runtimesRelPath = $"runtimes/{osId}-{arch}/native";
                string safeIdNative = idNative.Replace(".", "_");
                string safeIdTools = idTools.Replace(".", "_");
                
                // Native targets for managed projects (with .NET Framework copy support)
                string nativeTargets = $@"<?xml version=""1.0"" encoding=""utf-8""?>
<Project ToolsVersion=""4.0"" xmlns=""http://schemas.microsoft.com/developer/msbuild/2003"">
	<Target Name=""CopyNativeLibs_{safeIdNative}"" AfterTargets=""Build"" Condition=""'$(UsingMicrosoftNETSdk)' != 'true'"">
		<ItemGroup>
			<_{safeIdNative}_NativeFiles Include=""$(MSBuildThisFileDirectory)../{runtimesRelPath}/*.*"" />
		</ItemGroup>
		<Copy SourceFiles=""@(_{safeIdNative}_NativeFiles)"" DestinationFolder=""$(OutDir){runtimesRelPath.Replace('/', '\\')}\"" SkipUnchangedFiles=""true"" />
	</Target>
</Project>";

                // Native targets for C++ projects (include/lib linking)
                string nativeTargetTemplate = osName == "Win" 
? @"
	<ItemDefinitionGroup Condition=""('$(Language)' == 'C++' Or '$(Language)' == '')" + finalCondition + @""">
		<ClCompile>
			<AdditionalIncludeDirectories>$(MSBuildThisFileDirectory)include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
		</ClCompile>
		<Link>
			<AdditionalLibraryDirectories>$(MSBuildThisFileDirectory)win/" + arch + @"/lib;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
			<AdditionalDependencies>avcodec.lib;avdevice.lib;avfilter.lib;avformat.lib;avutil.lib;swresample.lib;swscale.lib;%(AdditionalDependencies)</AdditionalDependencies>
		</Link>
	</ItemDefinitionGroup>
</Project>"
: @"
	<ItemDefinitionGroup Condition=""('$(Language)' == 'C++' Or '$(Language)' == '')" + finalCondition + @""">
		<ClCompile>
			<AdditionalIncludeDirectories>$(MSBuildThisFileDirectory)include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
		</ClCompile>
		<Link>
			<AdditionalLibraryDirectories>$(MSBuildThisFileDirectory)" + osId + @"/" + arch + @"/lib;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
			<LibraryDependencies>avcodec;avdevice;avfilter;avformat;avutil;swresample;swscale;%(LibraryDependencies)</LibraryDependencies>
		</Link>
	</ItemDefinitionGroup>
	
	<!-- Fallback for Mock Build on Windows where ApplicationType=Linux is passed but MSBuild still uses CL.exe -->
	<ItemDefinitionGroup Condition=""'$(OS)' == 'Windows_NT' And '$(ApplicationType)' == 'Linux'" + platformCondition + @""">
		<ClCompile>
			<AdditionalIncludeDirectories>$(MSBuildThisFileDirectory)include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
		</ClCompile>
	</ItemDefinitionGroup>
</Project>";

                // Build native targets from base template + C++ config  
                string nativeCppTargetsBase = nativeTargetsTemplate.Replace("TqkLibrary.FFmpeg.Native", idNative);
                string nativeCppTargets = nativeCppTargetsBase.Replace("</Project>", nativeTargetTemplate);

                string toolsProps = toolsPropsTemplate.Replace("TqkLibrary.FFmpeg.Tools", idTools);
                
                // Tools targets for managed projects (with .NET Framework copy support)
                string toolsTargets = $@"<?xml version=""1.0"" encoding=""utf-8""?>
<Project ToolsVersion=""4.0"" xmlns=""http://schemas.microsoft.com/developer/msbuild/2003"">
	<Target Name=""CopyNativeLibs_{safeIdTools}"" AfterTargets=""Build"" Condition=""'$(UsingMicrosoftNETSdk)' != 'true'"">
		<ItemGroup>
			<_{safeIdTools}_NativeFiles Include=""$(MSBuildThisFileDirectory)../{runtimesRelPath}/*.*"" />
		</ItemGroup>
		<Copy SourceFiles=""@(_{safeIdTools}_NativeFiles)"" DestinationFolder=""$(OutDir){runtimesRelPath.Replace('/', '\\')}\"" SkipUnchangedFiles=""true"" />
	</Target>
</Project>";

                File.WriteAllText(Path.Combine(extractedBaseDir, $"{idNative}.props"), nativeProps);
                File.WriteAllText(Path.Combine(extractedBaseDir, $"{idNative}.targets"), nativeTargets);
                File.WriteAllText(Path.Combine(extractedBaseDir, $"{idNative}.native.targets"), nativeCppTargets);
                File.WriteAllText(Path.Combine(extractedBaseDir, $"{idTools}.props"), toolsProps);
                File.WriteAllText(Path.Combine(extractedBaseDir, $"{idTools}.targets"), toolsTargets);

                Console.WriteLine("Packing Native...");
                RunCommand("nuget", $"pack \"{nativeNuspecPath}\" -OutputDirectory \"{packagesDir}\" -NoPackageAnalysis -BasePath \"{extractedBaseDir}\"");

                Console.WriteLine("Packing Tools...");
                RunCommand("nuget", $"pack \"{toolsNuspecPath}\" -OutputDirectory \"{packagesDir}\" -NoPackageAnalysis -BasePath \"{extractedBaseDir}\"");
                
                Console.WriteLine($"Done {version} {arch}.");
            }

            Console.WriteLine("All packages generated successfully.");
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
