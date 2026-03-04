using System;
using System.IO;
using System.Reflection;

class Program
{
    static void Main(string[] args)
    {
        string outputDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location)!;
        Console.WriteLine($"Output directory: {outputDir}");
        Console.WriteLine();

        // Check for FFmpeg DLLs (from GplShared package)
        string[] expectedDlls = { "avcodec-62.dll", "avdevice-62.dll", "avfilter-11.dll",
                                   "avformat-62.dll", "avutil-60.dll", "swresample-6.dll", "swscale-9.dll" };

        Console.WriteLine("=== GplShared DLLs ===");
        foreach (var dll in expectedDlls)
        {
            string path = Path.Combine(outputDir, dll);
            bool exists = File.Exists(path);
            Console.WriteLine($"  {dll}: {(exists ? "OK" : "MISSING!")}");
        }

        // Check for FFmpeg executables (from Runtime package)
        string[] expectedExes = { "ffmpeg.exe", "ffplay.exe", "ffprobe.exe" };

        Console.WriteLine();
        Console.WriteLine("=== Runtime Executables ===");
        foreach (var exe in expectedExes)
        {
            string path = Path.Combine(outputDir, exe);
            bool exists = File.Exists(path);
            Console.WriteLine($"  {exe}: {(exists ? "OK" : "MISSING!")}");
        }
    }
}
