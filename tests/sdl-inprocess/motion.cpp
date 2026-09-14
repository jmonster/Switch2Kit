#include <Switch2KitSDL3.hpp>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <limits>
#include <vector>
extern "C" {
S2KContext* test_input_create();
void test_input_report(S2KContext*, int32_t, uint32_t, const S2KState*);
void test_input_retire(S2KContext*, int32_t);
}
using Switch2Kit::SDL3Adapter;
using Switch2Kit::SDL3MotionStatus;
static S2KID physical(int index) { S2KID id{}; id.bytes[15] = static_cast<uint8_t>(index + 1); return id; }
static std::vector<SDL_GamepadSensorEvent> events() {
    std::vector<SDL_GamepadSensorEvent> result;
    SDL_Event event{};
    while (SDL_PollEvent(&event)) if (event.type == SDL_EVENT_GAMEPAD_SENSOR_UPDATE) result.push_back(event.gsensor);
    return result;
}
static S2KMotionProfile synthetic(int index, uint32_t model) {
    S2KMotionProfile p{}; p.version = 1; p.struct_size = sizeof(p); p.device = physical(index);
    p.model = model; p.configuration = S2K_MOTION_CONFIGURATION_BT_V1;
    p.feature_flags = model == S2K_JOYCON_LEFT || model == S2K_JOYCON_RIGHT ? 0xb7 : 0xa7;
    p.calibration.version = 1; p.calibration.struct_size = sizeof(p.calibration);
    for (int i = 0; i < 3; ++i) {
        p.holding_axes[i] = i + 1;
        p.calibration.acceleration.axes[i] = i + 1;
        p.calibration.angular_velocity.axes[i] = i + 1;
        p.calibration.acceleration.units_per_count[i] = 9.80665 / 1000;
        p.calibration.angular_velocity.units_per_count[i] = 0.001;
        p.calibration.acceleration.offset[i] = i + 10;
        p.calibration.angular_velocity.offset[i] = i + 20;
    }
    std::strcpy(p.orientation, "synthetic-test-only");
    return p;
}
int main() {
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    assert(SDL_Init(SDL_INIT_GAMEPAD));
    auto* context = test_input_create(); assert(context && s2k_start(context) == S2K_OK);
    {
        SDL3Adapter adapter(context);
        constexpr std::array<uint32_t, 4> models{S2K_PRO, S2K_GAMECUBE, S2K_JOYCON_LEFT, S2K_JOYCON_RIGHT};
        std::array<S2KState, 4> state{};
        std::array<SDL_Gamepad*, 4> pads{};
        const auto submit = [&](int index, bool fresh = true) {
            if (fresh) { ++state[index].sequence; state[index].received_at = s2k_monotonic_time(); }
            test_input_report(context, index, models[index], &state[index]);
        };
        const auto pump = [&] { assert(adapter.pump() == S2K_OK); };
        for (int i = 0; i < 4; ++i) {
            state[i].present = S2K_HAS_MOTION;
            for (int a = 0; a < 3; ++a) { state[i].accel[a] = static_cast<int16_t>(a + 10); state[i].gyro[a] = static_cast<int16_t>(a + 20); }
            state[i].accel[1] += 1000; state[i].gyro[0] += 1000;
            submit(i);
        }
        pump();
        for (int i = 0; i < 4; ++i) {
            pads[i] = SDL_OpenGamepad(adapter.instance(physical(i))); assert(pads[i]);
            assert(!SDL_GamepadHasSensor(pads[i], SDL_SENSOR_ACCEL));
            assert(SDL3Adapter::motionState(adapter.instance(physical(i))).status == SDL3MotionStatus::UnavailableProfile);
            assert(adapter.installMotionProfile(synthetic(i, models[i])) == S2K_OK);
        }
        pump(); // Deliberate attachment change, preserving physical identity.
        for (int i = 0; i < 4; ++i) {
            assert(!SDL_GamepadConnected(pads[i])); SDL_CloseGamepad(pads[i]);
            pads[i] = SDL_OpenGamepad(adapter.instance(physical(i))); assert(pads[i]);
            assert(SDL_GamepadHasSensor(pads[i], SDL_SENSOR_ACCEL) && SDL_GamepadHasSensor(pads[i], SDL_SENSOR_GYRO));
            assert(SDL_GetGamepadSensorDataRate(pads[i], SDL_SENSOR_GYRO) == 0); // Unknown, never guessed.
            assert(!SDL_GamepadSensorEnabled(pads[i], SDL_SENSOR_ACCEL));
            assert(SDL_SetGamepadSensorEnabled(pads[i], SDL_SENSOR_ACCEL, true));
            assert(SDL_SetGamepadSensorEnabled(pads[i], SDL_SENSOR_GYRO, true));
        }
        assert(events().empty());
        for (int i = 0; i < 4; ++i) submit(i);
        pump(); assert(events().empty()); // Each stream independently seeds; snapshots never deliver sensors.
        for (int i = 0; i < 4; ++i) submit(i);
        pump();
        auto received = events(); assert(received.size() == 8);
        std::array<Uint64, 4> times{};
        for (const auto& event : received) {
            int index = -1;
            for (int i = 0; i < 4; ++i) if (event.which == adapter.instance(physical(i))) index = i;
            assert(index >= 0);
            assert(event.sensor_timestamp > 0 && event.sensor_timestamp <= event.timestamp);
            assert(event.timestamp - event.sensor_timestamp < 100000000);
            if (times[index]) assert(times[index] == event.sensor_timestamp);
            times[index] = event.sensor_timestamp;
            assert(std::abs(event.data[0] - (event.sensor == SDL_SENSOR_GYRO ? 1.0f : 0.0f)) < 1e-6);
            assert(std::abs(event.data[1] - (event.sensor == SDL_SENSOR_ACCEL ? 9.80665f : 0.0f)) < 1e-6);
            assert(event.data[2] == 0);
            const auto timing = SDL3Adapter::motionStateAt(event.which, event.sensor_timestamp);
            assert(timing.status == SDL3MotionStatus::Active && timing.sequence == state[index].sequence);
            assert(timing.validSinceSequence + 1 == timing.sequence);
            assert(SDL3Adapter::motionStateAt(event.which, event.sensor_timestamp - 1).status == SDL3MotionStatus::Waiting);
        }
        std::puts("PASS four independent physical profiles: exact real-SDL SI/gravity/positive-rotation payloads and receive clocks");
        pump(); assert(events().empty()); // No replay on host frame/pump.
        const auto id = adapter.instance(physical(0));
        auto meta = SDL3Adapter::motionState(id); assert(meta.status == SDL3MotionStatus::Active);
        assert(meta.timestampNS == times[0] && meta.validSinceNS < meta.timestampNS && meta.sequence == state[0].sequence);
        // Identical install is a no-op; malformed replacement leaves both profile and device intact.
        assert(adapter.installMotionProfile(synthetic(0, models[0])) == S2K_OK); pump();
        assert(adapter.instance(physical(0)) == id);
        auto bad = synthetic(0, models[0]); bad.holding_axes[0] = -1;
        assert(adapter.installMotionProfile(bad) == S2K_INVALID_ARGUMENT); pump(); assert(adapter.instance(physical(0)) == id);
        bad = synthetic(0, S2K_GAMECUBE);
        assert(adapter.installMotionProfile(bad) == S2K_INVALID_ARGUMENT);
        // Per-type disable is honored even while the other type remains enabled.
        assert(SDL_SetGamepadSensorEnabled(pads[0], SDL_SENSOR_GYRO, false));
        submit(0); pump(); assert(events().empty()); submit(0); pump(); received = events();
        assert(received.size() == 1 && received[0].sensor == SDL_SENSOR_ACCEL);
        assert(SDL_SetGamepadSensorEnabled(pads[0], SDL_SENSOR_GYRO, true));
        submit(0); pump(); assert(events().empty()); submit(0); pump(); assert(events().size() == 2);
        assert(SDL_SetGamepadSensorEnabled(pads[0], SDL_SENSOR_GYRO, false));
        assert(SDL_SetGamepadSensorEnabled(pads[0], SDL_SENSOR_ACCEL, false));
        assert(SDL3Adapter::motionState(id).status == SDL3MotionStatus::Disabled);
        submit(0); pump(); assert(events().empty());
        assert(SDL_SetGamepadSensorEnabled(pads[0], SDL_SENSOR_ACCEL, true));
        assert(SDL_SetGamepadSensorEnabled(pads[0], SDL_SENSOR_GYRO, true));
        submit(0); pump(); assert(events().empty()); submit(0); pump(); assert(events().size() == 2);
        std::puts("PASS sensor enable/disable, profile validation and no frame-based replay");
        const auto rearm = [&] {
            submit(0); pump(); assert(events().empty());
            submit(0); pump(); assert(events().size() == 2);
        };
        // Duplicates/out-of-order/time faults invalidate. Lower sequences cannot seed a stale stream.
        submit(0, false); pump(); assert(events().empty());
        const auto sequence = state[0].sequence;
        state[0].sequence -= 2; state[0].received_at = s2k_monotonic_time();
        submit(0, false); pump(); assert(events().empty());
        state[0].sequence = sequence; rearm();
        for (double timestamp : {state[0].received_at, state[0].received_at - 0.01, -1.0,
                                 std::numeric_limits<double>::infinity(), std::numeric_limits<double>::quiet_NaN(),
                                 std::numeric_limits<double>::max(), s2k_monotonic_time() - 0.2,
                                 s2k_monotonic_time() + 1000}) {
            ++state[0].sequence; state[0].received_at = timestamp; submit(0, false); pump();
            assert(events().empty()); rearm();
        }
        state[0].sequence += 5; submit(0); pump(); assert(events().empty()); // Fresh gap report can seed, not integrate.
        submit(0); pump(); assert(events().size() == 2);
        state[0].present = 0; submit(0); pump(); assert(events().empty());
        state[0].present = S2K_HAS_MOTION; rearm();
        state[0].gyro[0] = 32767; submit(0); pump(); assert(events().empty());
        state[0].gyro[0] = 1020; rearm();
        SDL_Delay(110); // Inactivity does not leave cached active telemetry available to an emulator.
        assert(SDL3Adapter::motionState(id).status == SDL3MotionStatus::Waiting);
        pump(); assert(events().empty()); rearm();
        assert(adapter.pump(false) == S2K_OK); assert(events().empty());
        submit(0); assert(adapter.pump(false) == S2K_OK); assert(events().empty()); rearm();
        std::puts("PASS sequence/time faults, bounded clock conversion, missing/clipped motion, stalls and inactivity rearming");
        // The last segment's timestamp floor lets an emulator reject earlier queued events
        // even when a discontinuity and new samples share one native batch.
        submit(0); const auto oldReceive = state[0].received_at;
        state[0].sequence += 4; submit(0); submit(0); pump(); received = events();
        const auto final = SDL3Adapter::motionState(id);
        assert(final.status == SDL3MotionStatus::Active && final.epoch != meta.epoch);
        assert(received.size() == 4 && received[0].sensor_timestamp < final.validSinceNS && received[2].sensor_timestamp > final.validSinceNS);
        assert(SDL3Adapter::motionStateAt(id, received[0].sensor_timestamp).status == SDL3MotionStatus::Waiting);
        assert(SDL3Adapter::motionStateAt(id, received[2].sensor_timestamp).sequence == state[0].sequence);
        assert(oldReceive < state[0].received_at);
        // A native overflow snapshot only reconciles controls; it is not 256 new motion samples.
        for (int n = 0; n < 300; ++n) submit(0);
        pump(); assert(events().empty()); rearm();
        Uint64 priorReceive = SDL3Adapter::motionState(id).timestampNS;
        for (int n = 0; n < 5000; ++n) {
            const auto beforeReceive = state[0].received_at;
            submit(0); pump();
            const auto pair = events(); assert(pair.size() == 2);
            const auto timestamp = pair[0].sensor_timestamp;
            assert(timestamp > priorReceive && timestamp == pair[1].sensor_timestamp);
            // The same segment preserves receive intervals, not per-call clock jitter.
            const auto expected = static_cast<Uint64>(std::llround((state[0].received_at - beforeReceive) * 1e9));
            assert(timestamp - priorReceive == expected);
            priorReceive = timestamp;
        }
        std::puts("PASS same-batch discontinuity floor, overflow snapshot exclusion and 5000 bounded per-report sensor pairs");
        // Measured reference signs differ from holding orientation. Apply a proper
        // rotation exactly once to both already-independent sensor calibrations.
        auto changed = synthetic(0, models[0]); changed.holding_axes[0] = -2; changed.holding_axes[1] = 1;
        assert(adapter.installMotionProfile(changed) == S2K_OK); pump(); assert(events().empty());
        assert(!SDL_GamepadConnected(pads[0])); SDL_CloseGamepad(pads[0]);
        pads[0] = SDL_OpenGamepad(adapter.instance(physical(0))); assert(pads[0]);
        assert(SDL_SetGamepadSensorEnabled(pads[0], SDL_SENSOR_ACCEL, true));
        assert(SDL_SetGamepadSensorEnabled(pads[0], SDL_SENSOR_GYRO, true));
        submit(0); pump(); assert(events().empty()); submit(0); pump(); received = events(); assert(received.size() == 2);
        assert(std::abs(received[0].data[0] + 9.80665f) < 1e-6 && received[0].data[1] == 0);
        assert(received[1].data[0] == 0 && received[1].data[1] == 1);
        // Retirement discards queued reports through the real hub/C generation filter.
        submit(0); test_input_retire(context, 0); state[0].sequence = 0; submit(0); pump();
        assert(events().empty() && !SDL_GamepadConnected(pads[0])); SDL_CloseGamepad(pads[0]);
        pads[0] = SDL_OpenGamepad(adapter.instance(physical(0))); assert(pads[0]);
        assert(SDL_GamepadHasSensor(pads[0], SDL_SENSOR_GYRO)); // Physical profile survived reconnect.
        adapter.removeMotionProfile(physical(0)); pump(); assert(events().empty());
        assert(!SDL_GamepadConnected(pads[0])); SDL_CloseGamepad(pads[0]);
        pads[0] = SDL_OpenGamepad(adapter.instance(physical(0))); assert(pads[0]);
        assert(!SDL_GamepadHasSensor(pads[0], SDL_SENSOR_GYRO));
        // The cache is bounded across disconnected physical identities too.
        for (int i = 4; i < 64; ++i) assert(adapter.installMotionProfile(synthetic(i, S2K_PRO)) == S2K_OK);
        assert(adapter.installMotionProfile(synthetic(0, S2K_PRO)) == S2K_OK);
        assert(adapter.installMotionProfile(synthetic(64, S2K_PRO)) == S2K_QUEUE_FULL);
        for (auto* pad : pads) SDL_CloseGamepad(pad);
        assert(s2k_stop(context) == S2K_OK); pump(); assert(events().empty());
        std::puts("PASS proper orientation replacement, generation retirement, physical reconnect, removal and bounded profile cache");
    }
    s2k_destroy(context); SDL_Quit();
}
