#pragma once
#include <mach-o/loader.h>
#include <stdint.h>
#include <string.h>
static uint32_t FDOriginalSDK(const void *data, size_t length) {
    struct mach_header_64 h;
    if (length < sizeof(h)) return 0;
    memcpy(&h, data, sizeof(h));
    if (h.magic != MH_MAGIC_64 || h.filetype != MH_EXECUTE ||
        h.sizeofcmds > length - sizeof(h) || h.ncmds > h.sizeofcmds / sizeof(struct load_command)) return 0;
    const uint8_t *bytes = data;
    size_t offset = sizeof(h), end = offset + h.sizeofcmds;
    uint32_t sdk = 0;
    for (uint32_t i = 0; i < h.ncmds; ++i) {
        struct load_command c;
        if (end - offset < sizeof(c)) return 0;
        memcpy(&c, bytes + offset, sizeof(c));
        if (c.cmdsize < sizeof(c) || c.cmdsize > end - offset) return 0;
        uint32_t found = 0;
        if (c.cmd == LC_BUILD_VERSION) {
            struct build_version_command v;
            if (c.cmdsize < sizeof(v)) return 0;
            memcpy(&v, bytes + offset, sizeof(v));
            if (v.platform != PLATFORM_IOS || v.ntools > (c.cmdsize - sizeof(v)) / sizeof(struct build_tool_version)) return 0;
            found = v.sdk;
        } else if (c.cmd == LC_VERSION_MIN_IPHONEOS) {
            struct version_min_command v;
            if (c.cmdsize < sizeof(v)) return 0;
            memcpy(&v, bytes + offset, sizeof(v));
            found = v.sdk;
        }
        if (found) {
            if (sdk && sdk != found) return 0;
            sdk = found;
        }
        offset += c.cmdsize;
    }
    if (offset != end || (sdk >> 16) < 1 || (sdk >> 16) > 99 ||
        ((sdk >> 8) & 255) > 99 || (sdk & 255) > 99) return 0;
    return sdk;
}
