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
                    "avcodec-62.dll", "avdevice-62.dll", "avfilter-11.dll",
                    "avformat-62.dll", "avutil-60.dll", "swresample-6.dll", "swscale-9.dll",
                    "ffmpeg.exe", "ffplay.exe", "ffprobe.exe"
                };
            }
            else if (isLinux)
            {
                expectedFiles = new[]
                {
                    "libavcodec.so.62.11.100", "libavdevice.so.62.1.100", "libavfilter.so.11.4.100",
                    "libavformat.so.62.3.100", "libavutil.so.60.8.100", "libswresample.so.6.1.100", "libswscale.so.9.1.100",
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
                if (File.Exists(f))
                {
                    Console.WriteLine($"  [OK] Found: {f}");
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
                    IntPtr handle = LoadLibrary("avutil-60.dll");
                    if (handle != IntPtr.Zero)
                    {
                        Console.WriteLine("Successfully loaded avutil-60.dll using LoadLibrary");
                    }
                    else
                    {
                        Console.WriteLine($"Failed to load avutil-60.dll. Error Code: {Marshal.GetLastWin32Error()}");
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
