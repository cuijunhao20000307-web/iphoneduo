#include <assert.h>
#include <stdio.h>
#include "../overlay/ForceDuoApp/Sources/FDOriginalSDK.h"
int main(void) {
    struct { struct mach_header_64 h; struct build_version_command v; } modern = {0};
    modern.h.magic = MH_MAGIC_64; modern.h.filetype = MH_EXECUTE;
    modern.h.ncmds = 1; modern.h.sizeofcmds = sizeof(modern.v);
    modern.v.cmd = LC_BUILD_VERSION; modern.v.cmdsize = sizeof(modern.v);
    modern.v.platform = PLATFORM_IOS; modern.v.sdk = (26 << 16) | (2 << 8) | 1;
    assert(FDOriginalSDK(&modern, sizeof(modern)) == modern.v.sdk);
    for (size_t n = 0; n < sizeof(modern); ++n) assert(!FDOriginalSDK(&modern, n));
    modern.v.platform = PLATFORM_IOSSIMULATOR;
    assert(!FDOriginalSDK(&modern, sizeof(modern)));
    modern.v.platform = PLATFORM_IOS; modern.v.cmdsize = 0;
    assert(!FDOriginalSDK(&modern, sizeof(modern)));
    modern.v.cmdsize = sizeof(modern.v); modern.v.ntools = 100;
    assert(!FDOriginalSDK(&modern, sizeof(modern)));
    struct { struct mach_header_64 h; struct version_min_command v; } legacy = {0};
    legacy.h.magic = MH_MAGIC_64; legacy.h.filetype = MH_EXECUTE;
    legacy.h.ncmds = 1; legacy.h.sizeofcmds = sizeof(legacy.v);
    legacy.v.cmd = LC_VERSION_MIN_IPHONEOS; legacy.v.cmdsize = sizeof(legacy.v);
    legacy.v.sdk = (18 << 16) | (5 << 8);
    assert(FDOriginalSDK(&legacy, sizeof(legacy)) == legacy.v.sdk);
    legacy.v.sdk = 0; assert(!FDOriginalSDK(&legacy, sizeof(legacy)));
    struct { struct mach_header_64 h; struct version_min_command v[2]; } conflict = {0};
    conflict.h = legacy.h; conflict.h.ncmds = 2; conflict.h.sizeofcmds = sizeof(conflict.v);
    conflict.v[0] = legacy.v; conflict.v[1] = legacy.v;
    conflict.v[0].sdk = 18 << 16; conflict.v[1].sdk = 26 << 16;
    assert(!FDOriginalSDK(&conflict, sizeof(conflict)));
    puts("PASS: modern/legacy SDK, truncation, wrong platform, invalid bounds, absent/conflicting SDK");
}
