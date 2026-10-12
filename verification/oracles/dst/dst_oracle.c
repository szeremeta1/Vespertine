//
// Vespertine verification: decodes DST frames with the MPEG-4 Audio reference decoder (libdstdec, fetched by
// tools/fetch_oracles.py; never vendored). This is an oracle: a second implementation to compare with, not the
// standard.
// SPDX-License-Identifier: GPL-3.0-or-later
//
//   dst_oracle <channels> <frame.dst> <out.dsd>
//
// Writes channels × 4704 bytes: DSD64 channel bytes interleaved by channel, most significant bit first in time,
// as libdstdec produces them. Exit status 0 when libdstdec reports no error, 2 when it rejects the frame.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dst_fram.h"
#include "dst_init.h"

int main(int argc, char **argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: dst_oracle <channels> <frame.dst> <out.dsd>\n");
        return 64;
    }
    const int channels = atoi(argv[1]);
    FILE *in = fopen(argv[2], "rb");
    if (!in) { perror(argv[2]); return 66; }
    fseek(in, 0, SEEK_END);
    const long size = ftell(in);
    fseek(in, 0, SEEK_SET);
    // libdstdec may read a little past the frame while unpacking; give it zeroed slack.
    uint8_t *frame = calloc((size_t)size + 64, 1);
    if (!frame || fread(frame, 1, (size_t)size, in) != (size_t)size) { fprintf(stderr, "read %s\n", argv[2]); return 66; }
    fclose(in);

    static ebunch D;
    if (DST_InitDecoder(&D, channels, 64) != 0) { fprintf(stderr, "DST_InitDecoder(%d)\n", channels); return 70; }
    const size_t outBytes = (size_t)channels * 4704;
    uint8_t *out = calloc(outBytes, 1);
    const int error = DST_FramDSTDecode(frame, out, (int)size, 0, &D);
    DST_CloseDecoder(&D);

    FILE *o = fopen(argv[3], "wb");
    if (!o || fwrite(out, 1, outBytes, o) != outBytes) { perror(argv[3]); return 73; }
    fclose(o);
    free(out);
    free(frame);
    if (error != 0) { fprintf(stderr, "libdstdec error %d\n", error); return 2; }
    return 0;
}
