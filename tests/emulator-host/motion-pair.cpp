#include "SDLMotionPair.hpp"
#include <cassert>
#include <limits>
using namespace Switch2Kit;
int main() {
    SDLMotionPair pair;
    SDL3MotionState state{true, SDL3MotionStatus::Active, 1, 1000000, 2000000, 2, 1};
    assert(pair.synchronize(state));
    SDL_GamepadSensorEvent event{};
    event.timestamp = UINT64_MAX; // Must never influence integration.
    event.sensor_timestamp = state.timestampNS;
    event.sensor = SDL_SENSOR_ACCEL;
    event.data[0] = 1; event.data[1] = 9.80665f; event.data[2] = 3;
    assert(!pair.consume(event));
    assert(!pair.consume(event)); // Duplicate half.
    event.sensor = SDL_SENSOR_GYRO;
    event.data[0] = 0.1f; event.data[1] = -0.2f; event.data[2] = 0.3f;
    auto sample = pair.consume(event);
    assert(sample && sample->timestampNS == 2000000 && sample->deltaSeconds == 0.001);
    assert(sample->acceleration[1] == 9.80665f && sample->angularVelocity[1] == -0.2f);
    assert(!pair.consume(event) && !pair.takeReset());
    event.sensor_timestamp = 1000000; assert(!pair.consume(event));
    assert(!pair.synchronize(state));
    state.epoch++; state.validSinceNS = 5000000; state.validSinceSequence = 5;
    state.timestampNS = 6000000; state.sequence = 6;
    assert(pair.synchronize(state)); // Caller resets its real integrator here.
    event.sensor_timestamp = 4000000; assert(!pair.consume(event));
    event.sensor_timestamp = state.timestampNS; event.sensor = SDL_SENSOR_ACCEL;
    assert(!pair.consume(event));
    event.sensor = SDL_SENSOR_GYRO; sample = pair.consume(event);
    assert(sample && sample->deltaSeconds == 0.001);
    // Inactivity must reset even without another SDL event.
    state.status = SDL3MotionStatus::Waiting;
    assert(pair.synchronize(state)); assert(!pair.synchronize(state));
    event.sensor_timestamp = 7000000; assert(!pair.consume(event));
    state.status = SDL3MotionStatus::Active; state.validSinceNS = 8000000; state.validSinceSequence = 8;
    state.timestampNS = 9000000; state.sequence = 9; event.sensor_timestamp = state.timestampNS;
    assert(pair.synchronize(state));
    event.data[0] = std::numeric_limits<float>::infinity();
    assert(!pair.consume(event) && pair.takeReset()); event.data[0] = 1;
    state.timestampNS = 10000000; state.sequence = 10; event.sensor_timestamp = state.timestampNS;
    assert(!pair.synchronize(state));
    event.sensor = SDL_SENSOR_ACCEL; assert(!pair.consume(event));
    // Missing one half resets. It must not borrow acceleration across timestamps.
    state.timestampNS = 11000000; state.sequence = 11; event.sensor_timestamp = state.timestampNS;
    assert(!pair.synchronize(state));
    event.sensor = SDL_SENSOR_GYRO; assert(!pair.consume(event) && pair.takeReset());
    event.sensor = SDL_SENSOR_ACCEL; assert(!pair.consume(event));
    for (Uint64 i = 12; i < 10012; ++i) {
        state.timestampNS = i * 1000000; state.sequence = i;
        assert(!pair.synchronize(state)); event.sensor_timestamp = state.timestampNS;
        event.sensor = SDL_SENSOR_GYRO; assert(!pair.consume(event));
        event.sensor = SDL_SENSOR_ACCEL; sample = pair.consume(event);
        assert(sample && sample->deltaSeconds == 0.001 && !pair.takeReset());
    }
    // A lost complete pair is visible through the per-event report sequence.
    state.timestampNS += 2000000; state.sequence += 2; event.sensor_timestamp = state.timestampNS;
    assert(!pair.synchronize(state)); assert(!pair.consume(event) && pair.takeReset());
    static_assert(sizeof(SDLMotionPair) < 160, "Storage cannot grow with sample count");
    state.owned = false; assert(pair.synchronize(state)); assert(!pair.consume(event));
}
