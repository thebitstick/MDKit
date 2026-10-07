// Minimal PCM I/O backend for atracdenc: reads/writes 16-bit PCM WAV only.
// Replaces libsndfile so the encoder can be built as a single self-contained binary.
#include "wav.h"

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

uint32_t rd32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
uint16_t rd16(const uint8_t* p) { return p[0] | (p[1] << 8); }
void wr32(uint8_t* p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (v >> (8 * i)) & 0xff; }
void wr16(uint8_t* p, uint16_t v) { p[0] = v & 0xff; p[1] = v >> 8; }

class TPCMIOWav16 : public IPCMProviderImpl {
public:
    explicit TPCMIOWav16(const std::string& path) : F(fopen(path.c_str(), "rb")) {
        if (!F) throw std::runtime_error("unable to open input file '" + path + "'");
        uint8_t hdr[12];
        if (fread(hdr, 1, 12, F) != 12 || memcmp(hdr, "RIFF", 4) || memcmp(hdr + 8, "WAVE", 4))
            throw std::runtime_error("input is not a RIFF/WAVE file");
        bool haveFmt = false;
        for (;;) {
            uint8_t ch[8];
            if (fread(ch, 1, 8, F) != 8) throw std::runtime_error("WAV: no data chunk");
            uint32_t size = rd32(ch + 4);
            if (!memcmp(ch, "fmt ", 4)) {
                std::vector<uint8_t> fmt(size);
                if (fread(fmt.data(), 1, size, F) != size || size < 16) throw std::runtime_error("WAV: bad fmt chunk");
                uint16_t tag = rd16(&fmt[0]);
                Channels = rd16(&fmt[2]);
                Rate = rd32(&fmt[4]);
                uint16_t bits = rd16(&fmt[14]);
                if ((tag != 1 && tag != 0xfffe) || bits != 16) throw std::runtime_error("WAV: only 16-bit PCM is supported");
                haveFmt = true;
                if (size & 1) fseek(F, 1, SEEK_CUR);
            } else if (!memcmp(ch, "data", 4)) {
                if (!haveFmt) throw std::runtime_error("WAV: data before fmt");
                Frames = size / (2 * Channels);
                break;
            } else {
                fseek(F, size + (size & 1), SEEK_CUR);
            }
        }
    }

    TPCMIOWav16(const std::string& path, int channels, int rate)
        : F(fopen(path.c_str(), "wb")), Channels(channels), Rate(rate), Writing(true) {
        if (!F) throw std::runtime_error("unable to open output file '" + path + "'");
        uint8_t hdr[44] = {};
        fwrite(hdr, 1, sizeof(hdr), F);
    }

    ~TPCMIOWav16() override {
        if (!F) return;
        if (Writing) {
            uint32_t dataBytes = Written * Channels * 2;
            uint8_t h[44];
            memcpy(h, "RIFF", 4); wr32(h + 4, 36 + dataBytes); memcpy(h + 8, "WAVEfmt ", 8);
            wr32(h + 16, 16); wr16(h + 20, 1); wr16(h + 22, Channels); wr32(h + 24, Rate);
            wr32(h + 28, Rate * Channels * 2); wr16(h + 32, Channels * 2); wr16(h + 34, 16);
            memcpy(h + 36, "data", 4); wr32(h + 40, dataBytes);
            fseek(F, 0, SEEK_SET);
            fwrite(h, 1, 44, F);
        }
        fclose(F);
    }

    size_t GetChannelsNum() const override { return Channels; }
    size_t GetSampleRate() const override { return Rate; }
    size_t GetTotalSamples() const override { return Frames; }

    size_t Read(TPCMBuffer& buf, size_t sz) override {
        std::vector<uint8_t> raw(sz * Channels * 2);
        size_t got = fread(raw.data(), 1, raw.size(), F) / (Channels * 2);
        float* out = buf[0];
        for (size_t i = 0; i < got * Channels; i++) out[i] = (int16_t)rd16(&raw[i * 2]) / 32768.0f;
        return got;
    }

    size_t Write(const TPCMBuffer& buf, size_t sz) override {
        std::vector<uint8_t> raw(sz * Channels * 2);
        const float* in = buf[0];
        for (size_t i = 0; i < sz * Channels; i++) {
            float v = in[i] * 32768.0f;
            v = v > 32767.0f ? 32767.0f : (v < -32768.0f ? -32768.0f : v);
            wr16(&raw[i * 2], (uint16_t)(int16_t)v);
        }
        fwrite(raw.data(), 1, raw.size(), F);
        Written += sz;
        return sz;
    }

private:
    FILE* F = nullptr;
    size_t Channels = 0, Rate = 0, Frames = 0, Written = 0;
    bool Writing = false;
};

} // namespace

IPCMProviderImpl* CreatePCMIOReadImpl(const std::string& path) { return new TPCMIOWav16(path); }
IPCMProviderImpl* CreatePCMIOWriteImpl(const std::string& path, int channels, int sampleRate) {
    return new TPCMIOWav16(path, channels, sampleRate);
}
