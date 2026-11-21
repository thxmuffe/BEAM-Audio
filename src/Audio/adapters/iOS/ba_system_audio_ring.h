// iPhone system audio: the broadcast upload extension (another process) writes
// the audio iOS gives it into this ring, in a file both processes map from the
// app group container; the app's audio engine reads it as its "system" capture.
// Audio stays native: Erlang only starts and stops the capture.
//
// One writer (the extension) and one reader (the engine). The writer stores the
// samples, then the capture time, then the frame count (release); the reader
// loads the count (acquire) first. The format is fixed so the engine knows it
// before any sound arrives: 48 kHz interleaved stereo float32.
#pragma once
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define BA_SYSTEM_AUDIO_MAGIC 0x42415352u /* "BASR" */
#define BA_SYSTEM_AUDIO_VERSION 1u
#define BA_SYSTEM_AUDIO_RATE 48000u
#define BA_SYSTEM_AUDIO_FRAMES 65536u /* about 1.4 s; a power of two */
#define BA_SYSTEM_AUDIO_FILE "system-audio.ring"
// Info.plist key, in the app and the extension, naming their shared app group.
#define BA_SYSTEM_AUDIO_GROUP_KEY "BASystemAudioAppGroup"
// Darwin notification posted when the broadcast starts or stops.
#define BA_SYSTEM_AUDIO_CHANGED "org.beam-audio.system-audio.changed"

typedef struct {
    uint32_t magic, version, rate, channels;
    uint32_t running;      // writer: 1 while the broadcast runs
    uint32_t stop;         // reader: asks the writer to end the broadcast
    uint64_t written;      // frames written in total
    uint64_t end_host_ns;  // capture time just after the last written frame
    uint64_t heartbeat_ns; // host time of the writer's last sign of life
    float samples[BA_SYSTEM_AUDIO_FRAMES * 2];
} ba_system_audio_ring;

#define BA_RING_LOAD(p) __atomic_load_n((p), __ATOMIC_ACQUIRE)
#define BA_RING_STORE(p, v) __atomic_store_n((p), (v), __ATOMIC_RELEASE)

// Maps the ring at path; the writer creates it. Returns NULL when unavailable.
static inline ba_system_audio_ring *ba_system_audio_ring_map(const char *path, int create) {
    int fd = open(path, create ? O_RDWR | O_CREAT : O_RDWR, 0600);
    if (fd < 0) return NULL;
    if (create && ftruncate(fd, (off_t)sizeof(ba_system_audio_ring)) != 0) {
        close(fd);
        return NULL;
    }
    void *p = mmap(NULL, sizeof(ba_system_audio_ring), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return NULL;
    ba_system_audio_ring *ring = (ba_system_audio_ring *)p;
    if (create) {
        ring->magic = BA_SYSTEM_AUDIO_MAGIC, ring->version = BA_SYSTEM_AUDIO_VERSION;
        ring->rate = BA_SYSTEM_AUDIO_RATE, ring->channels = 2;
    } else if (ring->magic != BA_SYSTEM_AUDIO_MAGIC || ring->version != BA_SYSTEM_AUDIO_VERSION) {
        munmap(p, sizeof(ba_system_audio_ring));
        return NULL;
    }
    return ring;
}
