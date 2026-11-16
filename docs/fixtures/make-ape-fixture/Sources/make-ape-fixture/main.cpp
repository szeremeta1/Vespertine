//
// Vespertine: makes a Monkey's Audio (APE) fixture from a WAV file, and tags it.
// SPDX-License-Identifier: GPL-3.0-or-later
//

// The SDK's headers are told the platform by whoever includes them.
#ifndef PLATFORM_APPLE
#define PLATFORM_APPLE
#endif
#include <MAC/All.h>
#include <MAC/APETag.h>
#include <MAC/MACLib.h>

#include <cstdio>
#include <string>

static std::wstring wide(const char *text) {
    std::wstring out;
    for (const char *c = text; *c; c++) out.push_back(static_cast<wchar_t>(static_cast<unsigned char>(*c)));
    return out;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: make-ape-fixture in.wav out.ape [title artist album track]\n");
        return 2;
    }
    const std::wstring in = wide(argv[1]), out = wide(argv[2]);
    if (int result = CompressFileW(in.c_str(), out.c_str(), APE_COMPRESSION_LEVEL_NORMAL); result != ERROR_SUCCESS) {
        std::fprintf(stderr, "compressing failed: %d\n", result);
        return 1;
    }
    if (argc >= 7) {
        APE::CAPETag tag(out.c_str());
        tag.SetFieldString(APE_TAG_FIELD_TITLE, wide(argv[3]).c_str());
        tag.SetFieldString(APE_TAG_FIELD_ARTIST, wide(argv[4]).c_str());
        tag.SetFieldString(APE_TAG_FIELD_ALBUM, wide(argv[5]).c_str());
        tag.SetFieldString(APE_TAG_FIELD_TRACK, wide(argv[6]).c_str());
        if (int result = tag.Save(); result != ERROR_SUCCESS) {
            std::fprintf(stderr, "tagging failed: %d\n", result);
            return 1;
        }
    }
    return 0;
}
