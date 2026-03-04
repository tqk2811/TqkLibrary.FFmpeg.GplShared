using System;
using System.IO;
using System.Runtime.InteropServices;

class Program
{
    static void Main(string[] args)
    {
        string outputDir = AppContext.BaseDirectory;
        Console.WriteLine($"Output directory: {outputDir}");
        Console.WriteLine($"OS: {RuntimeInformation.OSDescription}");
        Console.WriteLine($"Arch: {RuntimeInformation.OSArchitecture}");
        Console.WriteLine();

        bool isWindows = RuntimeInformation.IsOSPlatform(OSPlatform.Windows);

        string[] expectedLibs = isWindows
            ? new[] { "avcodec-62.dll", "avdevice-62.dll", "avfilter-11.dll",
                       "avformat-62.dll", "avutil-60.dll", "swresample-6.dll", "swscale-9.dll" }
            : new[] { "libavcodec.so.62.11.100", "libavdevice.so.62.1.100", "libavfilter.so.11.4.100",
                       "libavformat.so.62.3.100", "libavutil.so.60.8.100", "libswresample.so.6.1.100", "libswscale.so.9.1.100" };

        string[] expectedExes = isWindows
            ? new[] { "ffmpeg.exe", "ffplay.exe", "ffprobe.exe" }
            : new[] { "ffmpeg", "ffplay", "ffprobe" };

        Console.WriteLine("=== GplShared Libraries ===");
        foreach (var lib in expectedLibs)
        {
            bool exists = File.Exists(Path.Combine(outputDir, lib));
            Console.WriteLine($"  {lib}: {(exists ? "OK" : "MISSING!")}");
        }

        Console.WriteLine();
        Console.WriteLine("=== Runtime Executables ===");
        foreach (var exe in expectedExes)
        {
            bool exists = File.Exists(Path.Combine(outputDir, exe));
            Console.WriteLine($"  {exe}: {(exists ? "OK" : "MISSING!")}");
        }
    }
}
