#pragma once
#include "SDLMotionPair.hpp"
#include "SDLSensorRequest.hpp"
#include <array>

namespace Switch2Kit {
/** A bounded per-device report stream for Dolphin's polling emulated Wiimotes.
 * SDL's existing event thread supplies complete pairs; each Wiimote has an
 * independent cursor. No frame poll creates/repeats a measurement or runs fusion.
 * All access is under the existing SDL joystick lock. Nothing runs on Bluetooth. */
class DolphinMotionStream final {
public:
    using Sample = SDLMotionPair::Sample;
    struct Cursor {
        Uint64 epoch{}, sequence{}, readTime{};
        SDL_JoystickID instance{};
        std::optional<Sample> latest;
    };
    struct Batch {
        std::array<Sample, S2K_EVENT_CAPACITY> samples{};
        size_t count{};
        bool reset{};
        std::optional<Sample> latest;
    };
    static void handle(const SDL_GamepadSensorEvent& event) {
        Lock lock;
        const auto state = SDL3Adapter::motionStateAt(event.which, event.sensor_timestamp);
        auto* stream = get(event.which, false);
        if (!stream) return;
        stream->synchronize(state);
        const auto sample = stream->pair_.consume(event);
        if (stream->pair_.takeReset()) {
            stream->invalidate(); stream->floorSequence_ = state.sequence;
        }
        if (sample) {
            stream->samples_[stream->next_] = *sample;
            stream->next_ = (stream->next_ + 1) % stream->samples_.size();
            stream->count_ = std::min(stream->count_ + 1, stream->samples_.size());
        }
    }
    static Batch read(SDL_JoystickID id, Cursor& cursor) {
        Lock lock;
        Batch batch;
        const auto now = SDL_GetTicksNS();
        const auto state = SDL3Adapter::motionState(id);
        auto* stream = get(id, true);
        if (!stream) { batch.reset = cursor.instance != 0; cursor = {}; return batch; }
        stream->synchronize(state);
        const bool changedDevice = cursor.instance != id;
        const bool stalled = cursor.readTime && (now < cursor.readTime || now - cursor.readTime > gapNS);
        const bool changedEpoch = cursor.epoch != stream->epoch_;
        cursor.instance = id; cursor.readTime = now;
        if (changedDevice || changedEpoch || stalled) {
            batch.reset = true;
            cursor.epoch = stream->epoch_; cursor.latest.reset();
            cursor.sequence = stream->floorSequence_;
            // A newly assigned or stalled consumer must not replay a backlog
            // accumulated for a different Wiimote. The next report can rearm.
            if ((changedDevice || stalled) && stream->count_)
                cursor.sequence = stream->newest().sequence;
        }
        if (state.status != SDL3MotionStatus::Active) {
            if (cursor.latest) batch.reset = true;
            cursor.latest.reset(); return batch;
        }
        const auto first = (stream->next_ + stream->samples_.size() - stream->count_) % stream->samples_.size();
        if (stream->count_ && stream->samples_[first].sequence > cursor.sequence &&
            stream->samples_[first].sequence - cursor.sequence > 1) {
            batch.reset = true; cursor.latest.reset(); cursor.sequence = stream->newest().sequence;
            return batch; // Ring overflow cannot bridge a missing interval.
        }
        for (size_t i = 0; i < stream->count_; ++i) {
            const auto& sample = stream->samples_[(first + i) % stream->samples_.size()];
            if (sample.sequence <= cursor.sequence) continue;
            if (now < sample.timestampNS || now - sample.timestampNS > gapNS ||
                sample.sequence - cursor.sequence != 1) {
                batch.reset = true; batch.count = 0; cursor.latest.reset();
                cursor.sequence = sample.sequence; continue;
            }
            batch.samples[batch.count++] = sample;
            cursor.sequence = sample.sequence; cursor.latest = sample;
        }
        if (cursor.latest && (now < cursor.latest->timestampNS || now - cursor.latest->timestampNS > gapNS)) {
            batch.reset = true; cursor.latest.reset();
        }
        batch.latest = cursor.latest;
        return batch;
    }
private:
    static constexpr Uint64 gapNS = 100000000;
    static constexpr const char* property = "Switch2Kit.Dolphin.motion.stream";
    struct Lock { Lock() { SDL_LockJoysticks(); } ~Lock() { SDL_UnlockJoysticks(); } };
    static void SDLCALL cleanup(void*, void* stream) { delete static_cast<DolphinMotionStream*>(stream); }
    static DolphinMotionStream* get(SDL_JoystickID id, bool create) {
        auto* joystick = SDL_GetJoystickFromID(id);
        if (!joystick || !SDL_JoystickConnected(joystick) || !SDL3Adapter::motionState(id).owned) return nullptr;
        const auto properties = SDL_GetJoystickProperties(joystick);
        auto* stream = static_cast<DolphinMotionStream*>(SDL_GetPointerProperty(properties, property, nullptr));
        if (!stream && create) {
            stream = new DolphinMotionStream;
            if (!SDL_SetPointerPropertyWithCleanup(properties, property, stream, cleanup, nullptr)) return nullptr;
        }
        return stream;
    }
    const Sample& newest() const { return samples_[(next_ + samples_.size() - 1) % samples_.size()]; }
    void synchronize(const SDL3MotionState& state) {
        if (pair_.synchronize(state)) { invalidate(); floorSequence_ = state.validSinceSequence; }
    }
    void invalidate() {
        next_ = count_ = 0;
        epoch_ = epoch_ == UINT64_MAX ? 1 : epoch_ + 1;
    }
    SDLMotionPair pair_;
    Uint64 epoch_ = 1, floorSequence_{};
    std::array<Sample, S2K_EVENT_CAPACITY> samples_{};
    size_t next_{}, count_{};
};

/** One Wiimote's enablement and read cursor, not a controller manager/session.
 * Switching default device, disabling its input gate, and destruction release
 * this request without disabling other Wiimotes using the same physical device. */
class DolphinMotionReader final {
public:
    using Batch = DolphinMotionStream::Batch;
    Batch read(SDL_JoystickID id, bool enabled) {
        struct Lock { Lock() { SDL_LockJoysticks(); } ~Lock() { SDL_UnlockJoysticks(); } } lock;
        auto* gamepad = enabled && id ? SDL_GetGamepadFromID(id) : nullptr;
        if (!gamepad || !SDL3Adapter::motionState(id).owned || !request_.update(gamepad, true)) {
            Batch batch; batch.reset = cursor_.instance != 0;
            reset(); return batch;
        }
        return DolphinMotionStream::read(id, cursor_);
    }
    void reset() { request_.update(nullptr, false); cursor_ = {}; }
private:
    SDLSensorRequest request_;
    DolphinMotionStream::Cursor cursor_;
};
}
