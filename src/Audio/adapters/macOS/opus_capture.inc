// Capture-worker conversion/encoding only. The real-time tap never calls this.
#import <AVFAudio/AVFAudio.h>
#include <opus.h>
#include <vector>
#include <algorithm>
#include <cmath>

class OpusCapture {
    AVAudioFormat *__strong inputFormat = nil;
    AVAudioFormat *__strong outputFormat = nil;
    AVAudioConverter *__strong converter = nil;
    OpusEncoder *encoder = nullptr;
    std::vector<float> pending;
    uint64_t encodedPosition = 0;
    opus_int32 lookahead = 0;
public:
    ~OpusCapture() { if (encoder) opus_encoder_destroy(encoder); }
    void format(const uint8_t *data, uint32_t size) {
        if (size != 44) throw Failure{-1, "Invalid capture metadata"};
        AudioStreamBasicDescription asbd{};
        memcpy(&asbd.mSampleRate, data, 8);
        UInt32 *fields[] = {&asbd.mFormatID, &asbd.mFormatFlags, &asbd.mBytesPerPacket,
            &asbd.mFramesPerPacket, &asbd.mBytesPerFrame, &asbd.mChannelsPerFrame, &asbd.mBitsPerChannel};
        for (int i = 0; i < 7; ++i) memcpy(fields[i], data + 8 + i * 4, 4);
        if (asbd.mChannelsPerFrame < 1 || asbd.mChannelsPerFrame > 2)
            throw Failure{-1, "Opus comparison supports mono/stereo input"};
        inputFormat = [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
        outputFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
            sampleRate:48000 channels:2 interleaved:YES];
        converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:outputFormat];
        int error = OPUS_OK;
        encoder = opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &error);
        if (!converter || !encoder || error != OPUS_OK) throw Failure{-1, "Cannot prepare Opus encoder"};
        opus_encoder_ctl(encoder, OPUS_SET_BITRATE(192000));
        opus_encoder_ctl(encoder, OPUS_SET_VBR(1));
        opus_encoder_ctl(encoder, OPUS_SET_DTX(0));
        check(opus_encoder_ctl(encoder, OPUS_GET_LOOKAHEAD(&lookahead)), "Read Opus lookahead");
    }
    void captured(const uint8_t *data, uint32_t size) {
        if (!converter || size < 32) throw Failure{-1, "Missing capture format"};
        UInt32 count; memcpy(&count, data + 28, 4);
        const uint8_t *cursor = data + 32, *end = data + size;
        if (!count || cursor + 8 > end) throw Failure{-1, "Invalid capture block"};
        UInt32 firstSize; memcpy(&firstSize, cursor + 4, 4);
        auto frames = firstSize / inputFormat.streamDescription->mBytesPerFrame;
        // Preserve OS timing/position before conversion. Erlang interprets it;
        // this worker only reports input observations and encoded sample indices.
        std::array<uint8_t, 44> observation{};
        memcpy(observation.data(), data, 32);
        memcpy(observation.data() + 32, &frames, 4);
        const uint64_t outputPosition = encodedPosition + pending.size() / 2;
        memcpy(observation.data() + 36, &outputPosition, 8);
        wirePacket(8, observation.data(), uint32_t(observation.size()));
        AVAudioPCMBuffer *input = [[AVAudioPCMBuffer alloc] initWithPCMFormat:inputFormat frameCapacity:frames];
        input.frameLength = frames;
        AudioBufferList *list = input.mutableAudioBufferList;
        if (count != list->mNumberBuffers) throw Failure{-1, "Capture buffer count changed"};
        for (UInt32 i = 0; i < count; ++i) {
            UInt32 channels, bytes;
            if (cursor + 8 > end) throw Failure{-1, "Invalid capture block"};
            memcpy(&channels, cursor, 4); memcpy(&bytes, cursor + 4, 4); cursor += 8;
            if (cursor + bytes > end || bytes != list->mBuffers[i].mDataByteSize ||
                channels != list->mBuffers[i].mNumberChannels) throw Failure{-1, "Capture format changed"};
            memcpy(list->mBuffers[i].mData, cursor, bytes); cursor += bytes;
        }
        AVAudioPCMBuffer *output = [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat
            frameCapacity:AVAudioFrameCount(ceil(frames * 48000.0 / inputFormat.sampleRate) + 64)];
        __block BOOL supplied = NO;
        NSError *error = nil;
        [converter convertToBuffer:output error:&error withInputFromBlock:
            ^AVAudioBuffer *(AVAudioPacketCount requested, AVAudioConverterInputStatus *status) {
                (void)requested;
                if (supplied) { *status = AVAudioConverterInputStatus_NoDataNow; return nil; }
                supplied = YES; *status = AVAudioConverterInputStatus_HaveData; return input;
            }];
        if (error) throw Failure{-1, "Audio conversion failed"};
        const float *samples = static_cast<const float *>(output.audioBufferList->mBuffers[0].mData);
        pending.insert(pending.end(), samples, samples + output.frameLength * 2);
        while (pending.size() >= 960 * 2) {
            uint8_t encoded[1275];
            int bytes = opus_encode_float(encoder, pending.data(), 960, encoded, sizeof(encoded));
            if (bytes < 0) throw Failure{bytes, "Opus encode failed"};
            const auto prime = converter.primeInfo;
            std::vector<uint8_t> timed(20 + bytes);
            memcpy(timed.data(), &encodedPosition, 8);
            memcpy(timed.data() + 8, &lookahead, 4);
            memcpy(timed.data() + 12, &prime.leadingFrames, 4);
            memcpy(timed.data() + 16, &prime.trailingFrames, 4);
            memcpy(timed.data() + 20, encoded, bytes);
            wirePacket(6, timed.data(), uint32_t(timed.size()));
            encodedPosition += 960;
            pending.erase(pending.begin(), pending.begin() + 960 * 2);
        }
    }
};
static std::unique_ptr<OpusCapture> opusCapture;
static void packet(uint8_t type, const void *data, uint32_t bytes) {
    @autoreleasepool {
        if (type == 1) {
            opusCapture = std::make_unique<OpusCapture>();
            opusCapture->format(static_cast<const uint8_t *>(data), bytes);
        } else if (type == 2) {
            opusCapture->captured(static_cast<const uint8_t *>(data), bytes); return;
        }
        wirePacket(type, data, bytes);
    }
}
