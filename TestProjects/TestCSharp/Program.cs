using System;
using System.IO;
using System.Runtime.InteropServices;

namespace TestCSharp
{
    class Program
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
        private static extern IntPtr LoadLibrary(string libname);

        static void Main(string[] args)
        {
            Console.WriteLine($"Running C# SDK Test...");
            Console.WriteLine($".NET Runtime:   {RuntimeInformation.FrameworkDescription}");
            Console.WriteLine($"OS Description: {RuntimeInformation.OSDescription}");
            Console.WriteLine($"OS Arch:        {RuntimeInformation.OSArchitecture}");
            Console.WriteLine($"Process Arch:   {RuntimeInformation.ProcessArchitecture}");
            
            bool isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);
            bool isLinux = RuntimeInformation.IsOSPlatform(OSPlatform.Linux);
            
            Console.WriteLine($"Current Directory: {Environment.CurrentDirectory}");
            Console.WriteLine("Listing Native Libraries locally:");
            
            string[] expectedFiles;
            if (isWindows)
            {
                expectedFiles = new[]
                {
                    "avcodec-*.dll", "avdevice-*.dll", "avfilter-*.dll",
                    "avformat-*.dll", "avutil-*.dll", "swresample-*.dll", "swscale-*.dll",
                    "ffmpeg.exe", "ffplay.exe", "ffprobe.exe"
                };
            }
            else if (isLinux)
            {
                expectedFiles = new[]
                {
                    "libavcodec.so.*", "libavdevice.so.*", "libavfilter.so.*",
                    "libavformat.so.*", "libavutil.so.*", "libswresample.so.*", "libswscale.so.*",
                    "ffmpeg", "ffplay", "ffprobe"
                };
            }
            else
            {
                Console.WriteLine("Unsupported OS Platform for this test.");
                return;
            }

            bool allFound = true;
            foreach (var f in expectedFiles)
            {
                var files = Directory.GetFiles(AppDomain.CurrentDomain.BaseDirectory, f, SearchOption.AllDirectories);
                if (files.Length > 0)
                {
                    Console.WriteLine($"  [OK] Found: {files[0]}");
                }
                else
                {
                    Console.WriteLine($"  [MISSING!] {f}");
                    allFound = false;
                }
            }

            if (allFound)
            {
                Console.WriteLine("ALL NATIVE LIBRARIES COPIED CORRECTLY!");
                
                // Test loading one DLL (avutil) on Windows
                if (isWindows)
                {
                    var avutilFiles = Directory.GetFiles(AppDomain.CurrentDomain.BaseDirectory, "avutil-*.dll", SearchOption.AllDirectories);
                    if (avutilFiles.Length > 0)
                    {
                        string avutilDllPath = avutilFiles[0];
                        IntPtr handle = LoadLibrary(avutilDllPath);
                        if (handle != IntPtr.Zero)
                        {
                            Console.WriteLine($"Successfully loaded {avutilDllPath} using LoadLibrary");
                        }
                        else
                        {
                            Console.WriteLine($"Failed to load {avutilDllPath}. Error Code: {Marshal.GetLastWin32Error()}");
                        }
                    }
                }
            }
            else
            {
                Environment.ExitCode = 1;
            }
        }
    }
}
