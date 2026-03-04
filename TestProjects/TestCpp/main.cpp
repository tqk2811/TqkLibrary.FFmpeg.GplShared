#include <stdio.h>

// Test that FFmpeg headers are accessible via NuGet package
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
}

int main()
{
    printf("=== FFmpeg C++ Link Test ===\n");
    printf("avcodec version: %u\n", avcodec_version());
    printf("avformat version: %u\n", avformat_version());
    printf("avutil version: %u\n", avutil_version());
    printf("\nAll headers included and linked successfully!\n");
    return 0;
}
