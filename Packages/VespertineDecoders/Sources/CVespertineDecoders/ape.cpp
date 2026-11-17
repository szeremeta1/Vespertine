//
// Vespertine: Monkey's Audio (APE), with the Monkey's Audio SDK. Read as SFBAudioEngine reads it on the Mac, so the
// samples are the same.
// SPDX-License-Identifier: GPL-3.0-or-later WITH LicenseRef-Vespertine-App-Store-Exception
//

#include "decoder.h"

// The SDK's headers are told the platform by whoever includes them.
#ifndef PLATFORM_APPLE
#define PLATFORM_APPLE
#endif
#include <MAC/All.h>
#include <MAC/APETag.h>
#include <MAC/IAPEIO.h>
#include <MAC/MACLib.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

namespace {

/// The file, as the SDK reads one.
class CursorIO final : public APE::IAPEIO {
  public:
    explicit CursorIO(vsp_cursor *cursor) : cursor_(cursor) {}

    int Open(const APE::str_utfn *, bool) override { return ERROR_INVALID_INPUT_FILE; }
    int Close() override { return ERROR_SUCCESS; }

    int Read(void *buffer, unsigned int count, unsigned int *read) override {
        int64_t got = vsp_cursor_read(cursor_, buffer, count);
        if (read) *read = static_cast<unsigned int>(got);
        return cursor_->failed ? ERROR_IO_READ : ERROR_SUCCESS;
    }

    int Write(const void *, unsigned int, unsigned int *) override { return ERROR_IO_WRITE; }

    int Seek(APE::int64 position, APE::SeekMethod method) override {
        int whence = method == APE::SeekFileBegin ? SEEK_SET : method == APE::SeekFileCurrent ? SEEK_CUR : SEEK_END;
        return vsp_cursor_seek(cursor_, position, whence) == 0 ? ERROR_SUCCESS : ERROR_IO_READ;
    }

    int Create(const APE::str_utfn *) override { return ERROR_IO_WRITE; }
    int Delete() override { return ERROR_IO_WRITE; }
    int SetEOF() override { return ERROR_IO_WRITE; }
    unsigned char *GetBuffer(int *) override { return nullptr; }
    APE::int64 GetPosition() override { return cursor_->at; }
    APE::int64 GetSize() override { return cursor_->source.size; }
    int GetName(APE::str_utfn *) override { return ERROR_SUCCESS; }

  private:
    vsp_cursor *cursor_;
};

struct ApeState {
    std::unique_ptr<CursorIO> io;
    std::unique_ptr<APE::IAPEDecompress> decompress;
    std::vector<unsigned char> buffer;
    int bytes = 0;
    bool isFloat = false;
    bool unsigned8 = false;
};

// A decoder's state is always the C allocator's, as in the C decoders beside this one, so this one is built in place in
// such a block and handed back to it the same way.
struct ApeStateDrop {
    void operator()(ApeState *state) const {
        if (!state) return;
        state->~ApeState();
        std::free(state);
    }
};

std::unique_ptr<ApeState, ApeStateDrop> makeApeState() {
    void *block = std::calloc(1, sizeof(ApeState));
    if (!block) throw std::bad_alloc();
    try {
        return std::unique_ptr<ApeState, ApeStateDrop>(new (block) ApeState());
    } catch (...) {
        std::free(block);
        throw;
    }
}

const int kChunk = 4096;

int64_t apeRead(vsp_decoder *decoder, int64_t count, uint8_t *out) {
    auto *state = static_cast<ApeState *>(decoder->state);
    int64_t wanted = count > kChunk ? kChunk : count;
    APE::int64 got = 0;
    try {
        if (state->decompress->GetData(state->buffer.data(), wanted, &got) != ERROR_SUCCESS) return -1;
    } catch (...) {
        return -1;
    }
    const int bytes = state->bytes;
    const size_t total = static_cast<size_t>(got) * static_cast<size_t>(decoder->info.channels);
    const unsigned char *in = state->buffer.data();
    // The SDK gives a WAV file's samples: the lowest byte first, and 8-bit ones without a sign.
    for (size_t i = 0; i < total; i++) {
        for (int b = bytes - 1; b >= 0; b--) *out++ = in[b];
        if (state->unsigned8) out[-1] ^= 0x80;
        in += bytes;
    }
    return got;
}

int apeSeek(vsp_decoder *decoder, int64_t frame) {
    auto *state = static_cast<ApeState *>(decoder->state);
    try {
        return state->decompress->Seek(frame) == ERROR_SUCCESS ? 0 : -1;
    } catch (...) {
        return -1;
    }
}

void apeClose(vsp_decoder *decoder) {
    ApeStateDrop()(static_cast<ApeState *>(decoder->state));
    decoder->state = nullptr;
}

void addTag(vsp_decoder *decoder, APE::IAPETag *tag, const wchar_t *field, const char *name) {
    // Asked for with room to spare: a tag longer than this is not a title or a name.
    std::vector<char> text(4096);
    int characters = static_cast<int>(text.size()) - 1;
    if (tag->GetFieldString(field, text.data(), &characters, true) != ERROR_SUCCESS) return;
    text[text.size() - 1] = 0;
    if (text[0] != 0) vsp_tags_add(&decoder->tags, name, text.data());
}

} // namespace

extern "C" int vsp_open_ape(vsp_decoder *decoder) {
    try {
        auto state = makeApeState();
        state->io = std::make_unique<CursorIO>(&decoder->cursor);
        int error = ERROR_SUCCESS;
        state->decompress.reset(CreateIAPEDecompressEx(state->io.get(), &error));
        if (!state->decompress) return VSP_UNREADABLE;
        auto *decompress = state->decompress.get();
        const int channels = static_cast<int>(decompress->GetInfo(APE::IAPEDecompress::APE_INFO_CHANNELS));
        const int bits = static_cast<int>(decompress->GetInfo(APE::IAPEDecompress::APE_INFO_BITS_PER_SAMPLE));
        const int bytes = static_cast<int>(decompress->GetInfo(APE::IAPEDecompress::APE_INFO_BYTES_PER_SAMPLE));
        const int64_t flags = decompress->GetInfo(APE::IAPEDecompress::APE_INFO_FORMAT_FLAGS);
        const int64_t frames = decompress->GetInfo(APE::IAPEDecompress::APE_DECOMPRESS_TOTAL_BLOCKS);
        if (channels < 1 || channels > 64 || bytes < 1 || bytes > 4 || bits != bytes * 8 || frames < 0) return VSP_UNREADABLE;
        state->bytes = bytes;
        state->isFloat = (flags & APE_FORMAT_FLAG_FLOATING_POINT) != 0 && bytes == 4;
        state->unsigned8 = bytes == 1 && (flags & APE_FORMAT_FLAG_SIGNED_8_BIT) == 0;
        state->buffer.resize(static_cast<size_t>(kChunk) * static_cast<size_t>(channels) * static_cast<size_t>(bytes));
        decoder->info.sample_rate = static_cast<double>(decompress->GetInfo(APE::IAPEDecompress::APE_INFO_SAMPLE_RATE));
        decoder->info.channels = channels;
        decoder->info.bit_depth = bits;
        decoder->info.sample_bytes = state->isFloat ? 0 : bytes;
        decoder->info.frames = frames;

        if (auto *tag = reinterpret_cast<APE::IAPETag *>(decompress->GetInfo(APE::IAPEDecompress::APE_INFO_TAG))) {
            addTag(decoder, tag, APE_TAG_FIELD_TITLE, "title");
            addTag(decoder, tag, APE_TAG_FIELD_ARTIST, "artist");
            addTag(decoder, tag, APE_TAG_FIELD_ALBUM_ARTIST, "album artist");
            addTag(decoder, tag, APE_TAG_FIELD_ALBUM, "album");
            addTag(decoder, tag, APE_TAG_FIELD_GENRE, "genre");
            addTag(decoder, tag, APE_TAG_FIELD_TRACK, "track");
            addTag(decoder, tag, APE_TAG_FIELD_DISC, "disc");
            addTag(decoder, tag, APE_TAG_FIELD_YEAR, "year");
        }
        decoder->state = state.release();
        decoder->read = apeRead;
        decoder->seek = apeSeek;
        decoder->close = apeClose;
        return VSP_OPENED;
    } catch (...) {
        return VSP_UNREADABLE;
    }
}
