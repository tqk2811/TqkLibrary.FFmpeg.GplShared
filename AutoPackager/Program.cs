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

            // Android pipeline is a separate, additive mode: `dotnet run -- android`.
            // It reads artifacts-android/ and writes into the same Packages/ folder
            // without wiping it, so it can run after the desktop pass.
            if (args.Length > 0 && args[0].Equals("android", StringComparison.OrdinalIgnoreCase))
            {
                PackAndroid(rootDir);
                return;
            }

            string artifactsDir = Path.Combine(rootDir, "artifacts");
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
            // group 1: 4.4.6   (base version)
            // group 2: 86      (build number)
            // group 3: win64   (arch)
            // group 4: gpl     (license variant: gpl|lgpl|gpl2|lgpl2, longest match first)
            var regex = new Regex(@"ffmpeg-n([\d\.]+)-(\d+)-.*-(win32|win64|winarm64|linuxarm64|linux64|mac64)-(lgpl3|lgpl2|lgpl|gpl3|gpl2|gpl)-shared-[^\s]+\.(zip|tar\.xz)", RegexOptions.IgnoreCase);

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

                // License variant -> package-id segment + SPDX expression.
                // BtbN default "gpl"/"lgpl" builds pass --enable-version3 => v3. "gpl2"/"lgpl2" are custom v2 builds.
                // Note: FFmpeg's LGPL base is 2.1 (there is no LGPL-2.0), so "lgpl2" maps to LGPL-2.1-or-later.
                string licenseVariant = match.Groups[4].Value.ToLowerInvariant();
                (string licenseSegment, string licenseSpdx) = licenseVariant switch
                {
                    "gpl" or "gpl3" => ("Gpl3", "GPL-3.0-or-later"),
                    "lgpl" or "lgpl3" => ("Lgpl3", "LGPL-3.0-or-later"),
                    "gpl2" => ("Gpl2", "GPL-2.0-or-later"),
                    "lgpl2" => ("Lgpl2", "LGPL-2.1-or-later"),
                    _ => throw new Exception($"Unknown license variant {licenseVariant}")
                };

                Console.WriteLine($"Processing Version: {version}, Arch: {arch}, License: {licenseSegment}");

                string extractPath = Path.Combine(tempDir, $"{version}-{arch}-{licenseSegment}");
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
                
                // Linux: the .NET runtime resolves inter-library loads by SONAME (e.g. libavformat
                // dlopens libavcodec.so.62), but the archive ships the real binary as the fully
                // versioned libavcodec.so.62.11.103 and exposes the SONAME only via a symlink - and
                // symlinks are lost when the archive is extracted on Windows. So materialise the real
                // binary UNDER its SONAME name (libX.so.MAJOR); the versioned file is renamed, not
                // copied, so there is no size penalty. The bare ".so" dev symlink is dropped (broken
                // after extraction and unused at runtime).
                if (osName == "Linux")
                {
                    string libDir = Path.Combine(extractedBaseDir, "lib");
                    if (Directory.Exists(libDir))
                    {
                        foreach (var path in Directory.GetFiles(libDir))
                        {
                            // Match the real versioned binary libX.so.MAJOR.MINOR[.PATCH]; the >=2
                            // numeric components skip the SONAME symlinks (single component) themselves.
                            var m = Regex.Match(Path.GetFileName(path), @"^(?<base>.+\.so)\.(?<major>\d+)\.\d+");
                            if (!m.Success) continue;
                            string sonamePath = Path.Combine(libDir, $"{m.Groups["base"].Value}.{m.Groups["major"].Value}");
                            File.Delete(sonamePath);      // no-op if absent; drops any extracted SONAME symlink/stub
                            File.Move(path, sonamePath);  // rename versioned binary -> SONAME
                        }
                        foreach (var path in Directory.GetFiles(libDir))
                            if (Path.GetFileName(path).EndsWith(".so", StringComparison.Ordinal))
                                File.Delete(path);        // drop leftover bare ".so" dev symlink
                    }
                }
                
                string relativeBaseDir = ".";

                string idNative = $"TqkLibrary.FFmpeg.{licenseSegment}.Native.{osName}.{arch}";
                string idTools = $"TqkLibrary.FFmpeg.{licenseSegment}.Tools.{osName}.{arch}";

                // Native nuspec
                string nativeNuspec = nativeNuspecTemplate
                    .Replace("<id>TqkLibrary.FFmpeg.Native</id>", $"<id>{idNative}</id>")
                    .Replace("$idNative$", idNative)
                    .Replace("$version$", version)
                    .Replace("$osName$", osName)
                    .Replace("$os$", osId)
                    .Replace("$arch$", arch)
                    .Replace("$license$", licenseSpdx)
                    .Replace("$basePath$", relativeBaseDir);

                // Tools nuspec
                string toolsNuspec = toolsNuspecTemplate
                    .Replace("<id>TqkLibrary.FFmpeg.Tools</id>", $"<id>{idTools}</id>")
                    .Replace("<dependency id=\"TqkLibrary.FFmpeg.Native\"", $"<dependency id=\"{idNative}\"")
                    .Replace("$idTools$", idTools)
                    .Replace("[$version$,$version$]", $"[{version},{version}]")
                    .Replace("$version$", version)
                    .Replace("$osName$", osName)
                    .Replace("$os$", osId)
                    .Replace("$arch$", arch)
                    .Replace("$license$", licenseSpdx)
                    .Replace("$path$", $@"{relativeBaseDir}\bin");

                string nativeNuspecPath = Path.Combine(extractPath, "TqkLibrary.FFmpeg.Native.nuspec");
                string toolsNuspecPath = Path.Combine(extractPath, "TqkLibrary.FFmpeg.Tools.nuspec");

                File.WriteAllText(nativeNuspecPath, nativeNuspec);
                File.WriteAllText(toolsNuspecPath, toolsNuspec);

                // Generate README (shared by the Native + Tools package of this combo)
                string osLabel = osName switch { "Win" => "Windows", "Linux" => "Linux", _ => "macOS" };
                string rid = $"{osId}-{arch}";
                string tag = Regex.Replace(Path.GetFileName(archiveFile), @"\.(zip|tar\.xz)$", "", RegexOptions.IgnoreCase);
                bool isV2 = licenseSegment.EndsWith("2", StringComparison.Ordinal);
                bool hasFfplay = !(osName == "Linux" && isV2);
                string nativeExtra = osName == "Win" ? " + import libraries (`.lib`) + C headers" : " + C headers";
                string toolsList = hasFfplay ? "ffmpeg, ffplay, ffprobe" : "ffmpeg, ffprobe";
                string v2Note = isV2
                    ? "\n> **Note:** `Gpl2`/`Lgpl2` builds have OpenSSL and its dependents (srt, libssh, libcurl, libaribcaption, pulseaudio) disabled for license compatibility. On Linux, `sdl2` is also disabled, so `ffplay` is **not** included.\n"
                    : "";

                string readmeContent = string.Join("\n", new[]
                {
                    $"# TqkLibrary.FFmpeg.{licenseSegment} — {osLabel} {arch}",
                    "",
                    $"**FFmpeg {version}** shared build · {osLabel} {arch} · `{licenseSpdx}`  ",
                    $"Upstream build tag: `{tag}`",
                    "",
                    "This FFmpeg build is published as two NuGet packages:",
                    "",
                    "| Package | Contents |",
                    "|---|---|",
                    $"| `{idNative}` | Shared libraries: avcodec, avdevice, avfilter, avformat, avutil, swresample, swscale{nativeExtra} |",
                    $"| `{idTools}` | Command-line tools: {toolsList}; depends on `{idNative}` |",
                    "",
                    "## How the binaries are delivered",
                    "",
                    $"Native binaries ship under `runtimes/{rid}/native/`:",
                    "",
                    $"- **.NET SDK-style projects** resolve them automatically when the build/publish RID matches `{rid}` (e.g. `dotnet publish -r {rid}`, or a matching `<RuntimeIdentifier>`).",
                    "- **.NET Framework projects** get them copied next to the build output by the bundled MSBuild targets.",
                    "- **C++ (MSBuild) projects** (Native package): the `build/native` targets add `include/` to the compiler include path and the import libraries to the linker automatically.",
                    "",
                    "## Package matrix",
                    "",
                    "Pick the sibling package that matches your target:",
                    "",
                    "```",
                    "TqkLibrary.FFmpeg.{Gpl3|Lgpl3|Gpl2|Lgpl2}.{Native|Tools}.{Win|Linux}.{x64|x86|arm64}",
                    "```",
                    "",
                    "- **License:** `Gpl3`/`Lgpl3` = built with `--enable-version3` (GPL-3.0 / LGPL-3.0); `Gpl2`/`Lgpl2` = GPL-2.0 / LGPL-2.1.",
                    "- **`x86` (win32) is not available for FFmpeg 5.0 and 6.1** (those versions fail to compile the 32-bit Vulkan code).",
                    "",
                    "## License",
                    "",
                    $"This package is `{licenseSpdx}`. FFmpeg is free software and redistributing these binaries carries that license's obligations — in particular, linking your application against a **GPL** build places your application under the GPL. Use an **`Lgpl*`** variant if you need to keep your application under a different license.",
                    v2Note,
                    "See `docs/LICENSE.txt` in the package for the full license text.",
                    "",
                    "## Source",
                    "",
                    "- Packaging & build scripts: https://github.com/tqk2811/FFmpegBuild",
                    "- Prebuilt binaries: https://github.com/tqk2811/FFmpegBuild/releases",
                    "- Built on top of [BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds).",
                });
                File.WriteAllText(Path.Combine(extractedBaseDir, "README.md"), readmeContent);
                
                // Write props and targets dynamically

                string platformCondition = (arch, osName) switch
                {
                    ("x64", "Win") => " And ('$(Platform.ToLower())' == 'x64' Or '$(Platform.ToLower())' == 'win64' Or '$(PlatformTarget.ToLower())' == 'x64')",
                    ("x86", "Win") => " And ('$(Platform.ToLower())' == 'x86' Or '$(Platform.ToLower())' == 'win32' Or '$(PlatformTarget.ToLower())' == 'x86')",
                    ("x64", _) => " And '$(Platform.ToLower())' == 'x64'",
                    ("x86", _) => " And '$(Platform.ToLower())' == 'x86'",
                    ("arm64", "Win") => " And ('$(Platform.ToLower())' == 'arm64' Or '$(Platform.ToLower())' == 'winarm64' Or '$(PlatformTarget.ToLower())' == 'arm64')",
                    ("arm64", _) => " And '$(Platform.ToLower())' == 'arm64'",
                    _ => ""
                };

                string osCondition = osName switch
                {
                    "Win" => " And ('$(OS)' == 'Windows_NT' And ('$(ApplicationType)' == '' Or '$(ApplicationType)' == 'Windows'))",
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
			<AdditionalLibraryDirectories>$(MSBuildThisFileDirectory)win\" + arch + @"\lib;%(AdditionalLibraryDirectories)</AdditionalLibraryDirectories>
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

        static void PackAndroid(string rootDir)
        {
            string artifactsDir = Path.Combine(rootDir, "artifacts-android");
            string packagesDir = Path.Combine(rootDir, "Packages");
            string tempDir = Path.Combine(rootDir, "TempOutputAndroid");

            if (!Directory.Exists(artifactsDir))
            {
                Console.WriteLine($"Error: Android artifacts directory not found at {artifactsDir}");
                return;
            }

            Directory.CreateDirectory(packagesDir);

            var archiveFiles = Directory.EnumerateFiles(artifactsDir, "*.tar.xz").ToArray();
            if (archiveFiles.Length == 0)
            {
                Console.WriteLine("No android archive files found.");
                return;
            }

            // ffmpeg-n4.4.8-1-g32782865b2-android-arm64-v8a-gpl-shared-full.tar.xz
            // group 1: 4.4.8            (base version)
            // group 2: 1               (build number, optional -> defaults to 0)
            // group 3: arm64-v8a       (abi)
            // group 4: gpl             (license variant: gpl|lgpl|gpl2|lgpl2, longest match first)
            var regex = new Regex(@"ffmpeg-n([\d\.]+)(?:-(\d+)-g[0-9a-f]+)?-android-(arm64-v8a|x86_64)-(lgpl2|lgpl|gpl2|gpl)-shared-full\.tar\.xz", RegexOptions.IgnoreCase);

            string nativeNuspecTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Native.Android.nuspec"));
            string toolsNuspecTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Tools.Android.nuspec"));

            string nativePropsTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Native.props"));
            string nativeTargetsTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Native.targets"));
            string toolsPropsTemplate = File.ReadAllText(Path.Combine(rootDir, "TqkLibrary.FFmpeg.Tools.props"));

            // Clean only this pipeline's temp; Packages/ is left intact (additive).
            if (Directory.Exists(tempDir))
                Directory.Delete(tempDir, true);

            const string osName = "Android";
            const string osId = "android";

            foreach (var archiveFile in archiveFiles)
            {
                var match = regex.Match(Path.GetFileName(archiveFile));
                if (!match.Success)
                {
                    Console.WriteLine($"Skipping unrecognised archive file: {archiveFile}");
                    continue;
                }

                string baseVersion = match.Groups[1].Value;
                string buildVersion = match.Groups[2].Success ? match.Groups[2].Value : "0";
                string abi = match.Groups[3].Value; // arm64-v8a, x86_64

                string version = $"{baseVersion}.{buildVersion}";

                string arch = abi switch
                {
                    "arm64-v8a" => "arm64",
                    "x86_64" => "x64",
                    _ => throw new Exception($"Unknown abi {abi}")
                };

                string licenseVariant = match.Groups[4].Value.ToLowerInvariant();
                (string licenseSegment, string licenseSpdx) = licenseVariant switch
                {
                    "gpl" => ("Gpl3", "GPL-3.0-or-later"),
                    "lgpl" => ("Lgpl3", "LGPL-3.0-or-later"),
                    "gpl2" => ("Gpl2", "GPL-2.0-or-later"),
                    "lgpl2" => ("Lgpl2", "LGPL-2.1-or-later"),
                    _ => throw new Exception($"Unknown license variant {licenseVariant}")
                };

                Console.WriteLine($"Processing Android Version: {version}, Abi: {abi} ({arch}), License: {licenseSegment}");

                string extractPath = Path.Combine(tempDir, $"{version}-{arch}-{licenseSegment}");
                if (Directory.Exists(extractPath))
                    Directory.Delete(extractPath, true);
                Directory.CreateDirectory(extractPath);

                Console.WriteLine("Extracting...");
                RunCommand("tar", $"-xf \"{archiveFile}\" -C \"{extractPath}\"", null, true);

                // Android archives extract directly to lib/ bin/ include/ (no wrapper subfolder),
                // unlike the desktop BtbN archives. So the base dir is the extract root itself.
                string extractedBaseDir = extractPath;

                string relativeBaseDir = ".";

                string idNative = $"TqkLibrary.FFmpeg.{licenseSegment}.Native.{osName}.{arch}";
                string idTools = $"TqkLibrary.FFmpeg.{licenseSegment}.Tools.{osName}.{arch}";

                // Native nuspec
                string nativeNuspec = nativeNuspecTemplate
                    .Replace("<id>TqkLibrary.FFmpeg.Native.Android</id>", $"<id>{idNative}</id>")
                    .Replace("$idNative$", idNative)
                    .Replace("$version$", version)
                    .Replace("$osName$", osName)
                    .Replace("$os$", osId)
                    .Replace("$arch$", arch)
                    .Replace("$license$", licenseSpdx)
                    .Replace("$basePath$", relativeBaseDir);

                // Tools nuspec
                string toolsNuspec = toolsNuspecTemplate
                    .Replace("<id>TqkLibrary.FFmpeg.Tools.Android</id>", $"<id>{idTools}</id>")
                    .Replace("<dependency id=\"TqkLibrary.FFmpeg.Native.Android\"", $"<dependency id=\"{idNative}\"")
                    .Replace("$idTools$", idTools)
                    .Replace("[$version$,$version$]", $"[{version},{version}]")
                    .Replace("$version$", version)
                    .Replace("$osName$", osName)
                    .Replace("$os$", osId)
                    .Replace("$arch$", arch)
                    .Replace("$license$", licenseSpdx)
                    .Replace("$path$", $@"{relativeBaseDir}\bin");

                string nativeNuspecPath = Path.Combine(extractPath, "TqkLibrary.FFmpeg.Native.Android.nuspec");
                string toolsNuspecPath = Path.Combine(extractPath, "TqkLibrary.FFmpeg.Tools.Android.nuspec");

                File.WriteAllText(nativeNuspecPath, nativeNuspec);
                File.WriteAllText(toolsNuspecPath, toolsNuspec);

                // Generate README (shared by the Native + Tools package of this combo)
                string rid = $"{osId}-{arch}";
                string tag = Regex.Replace(Path.GetFileName(archiveFile), @"\.tar\.xz$", "", RegexOptions.IgnoreCase);
                bool isV2 = licenseSegment.EndsWith("2", StringComparison.Ordinal);
                string v2Note = isV2
                    ? "\n> **Note:** `Gpl2`/`Lgpl2` builds have OpenSSL and its dependents (srt, libssh, libcurl, libaribcaption) disabled for license compatibility.\n"
                    : "";

                string readmeContent = string.Join("\n", new[]
                {
                    $"# TqkLibrary.FFmpeg.{licenseSegment} — Android {abi}",
                    "",
                    $"**FFmpeg {version}** shared build · Android {abi} (`{rid}`) · `{licenseSpdx}`  ",
                    $"Upstream build tag: `{tag}`",
                    "",
                    "Built with the Android NDK (r26d, API 21). This FFmpeg build is published as two NuGet packages:",
                    "",
                    "| Package | Contents |",
                    "|---|---|",
                    $"| `{idNative}` | Shared libraries: avcodec, avdevice, avfilter, avformat, avutil, postproc, swresample, swscale + the NDK C++ runtime `libc++_shared.so` + C headers |",
                    $"| `{idTools}` | Command-line executables: ffmpeg, ffprobe; depends on `{idNative}` |",
                    "",
                    "## How the binaries are delivered",
                    "",
                    $"All binaries ship under `runtimes/{rid}/native/`.",
                    "",
                    $"- **.NET for Android (MAUI / Xamarin.Android)** projects resolve the `.so` files automatically when the target ABI matches `{abi}`; they are bundled into the APK/AAB `lib/{abi}/` folder and loadable via `[DllImport]` / `dlopen`.",
                    "- **C++ (MSBuild, `ApplicationType=Android`)** projects (Native package): the `build/native` targets add `include/` to the compiler include path. Link against the `.so` in `runtimes/`.",
                    "",
                    "## ABI matrix",
                    "",
                    "Pick the sibling package that matches your target:",
                    "",
                    "```",
                    "TqkLibrary.FFmpeg.{Gpl3|Lgpl3|Gpl2|Lgpl2}.{Native|Tools}.Android.{arm64|x64}",
                    "```",
                    "",
                    "- **`arm64`** = ABI `arm64-v8a`, **`x64`** = ABI `x86_64`. (32-bit `armeabi-v7a` / `x86` are not built.)",
                    "- **License:** `Gpl3`/`Lgpl3` = built with `--enable-version3` (GPL-3.0 / LGPL-3.0); `Gpl2`/`Lgpl2` = GPL-2.0 / LGPL-2.1.",
                    "",
                    "## Tools package caveat (raw executables)",
                    "",
                    "`ffmpeg` and `ffprobe` are raw ELF executables (no `lib*.so` name), so on a **stock, non-rooted** device Android does not extract them to an executable location automatically. They are intended for:",
                    "",
                    "- development / CI via `adb push` + `chmod +x`, or",
                    "- rooted devices, or",
                    "- apps that copy them out of the package and run them from their own writable, executable-permitted directory.",
                    "",
                    $"For normal in-app media processing, call the shared libraries from `{idNative}` directly (P/Invoke) instead of shelling out to these executables.",
                    "",
                    "## License",
                    "",
                    $"This package is `{licenseSpdx}`. FFmpeg is free software and redistributing these binaries carries that license's obligations — in particular, linking your application against a **GPL** build places your application under the GPL. Use an **`Lgpl*`** variant if you need to keep your application under a different license.",
                    v2Note,
                    "See `docs/LICENSE.txt` in the package for the full license text.",
                    "",
                    "## Source",
                    "",
                    "- Packaging & build scripts: https://github.com/tqk2811/FFmpegBuild",
                    "- Prebuilt binaries: https://github.com/tqk2811/FFmpegBuild/releases",
                });
                File.WriteAllText(Path.Combine(extractedBaseDir, "README.md"), readmeContent);

                // Write props and targets dynamically
                string platformCondition = arch switch
                {
                    "arm64" => " And '$(Platform.ToLower())' == 'arm64'",
                    "x64" => " And '$(Platform.ToLower())' == 'x64'",
                    _ => ""
                };
                // Android C++ (vcxproj) projects set ApplicationType=Android.
                string osCondition = " And '$(ApplicationType)' == 'Android'";
                string finalCondition = platformCondition + osCondition;

                string safeIdNative = idNative.Replace(".", "_");
                string safeIdTools = idTools.Replace(".", "_");
                string runtimesRelPath = $"runtimes/{osId}-{arch}/native";

                string nativeProps = nativePropsTemplate.Replace("TqkLibrary.FFmpeg.Native", idNative);

                // Native targets for non-SDK (.NET Framework) managed projects. Harmless on
                // .NET-for-Android (SDK-style), where the condition below is false.
                string nativeTargets = $@"<?xml version=""1.0"" encoding=""utf-8""?>
<Project ToolsVersion=""4.0"" xmlns=""http://schemas.microsoft.com/developer/msbuild/2003"">
	<Target Name=""CopyNativeLibs_{safeIdNative}"" AfterTargets=""Build"" Condition=""'$(UsingMicrosoftNETSdk)' != 'true'"">
		<ItemGroup>
			<_{safeIdNative}_NativeFiles Include=""$(MSBuildThisFileDirectory)../{runtimesRelPath}/*.*"" />
		</ItemGroup>
		<Copy SourceFiles=""@(_{safeIdNative}_NativeFiles)"" DestinationFolder=""$(OutDir){runtimesRelPath.Replace('/', '\\')}\"" SkipUnchangedFiles=""true"" />
	</Target>
</Project>";

                // Native targets for C++ (Android NDK) projects: expose the headers. The .so
                // themselves live under runtimes/ and are resolved by the Android build; we do
                // not fabricate a lib dir here to avoid duplicating the shared libraries.
                string nativeCppTargetTemplate = @"
	<ItemDefinitionGroup Condition=""('$(Language)' == 'C++' Or '$(Language)' == '')" + finalCondition + @""">
		<ClCompile>
			<AdditionalIncludeDirectories>$(MSBuildThisFileDirectory)include;%(AdditionalIncludeDirectories)</AdditionalIncludeDirectories>
		</ClCompile>
	</ItemDefinitionGroup>
</Project>";
                string nativeCppTargetsBase = nativeTargetsTemplate.Replace("TqkLibrary.FFmpeg.Native", idNative);
                string nativeCppTargets = nativeCppTargetsBase.Replace("</Project>", nativeCppTargetTemplate);

                string toolsProps = toolsPropsTemplate.Replace("TqkLibrary.FFmpeg.Tools", idTools);

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

                Console.WriteLine($"Done {version} {arch} {licenseSegment}.");
            }

            Console.WriteLine("All Android packages generated successfully.");
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
