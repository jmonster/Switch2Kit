// Compile the pinned emulator's real motion classes, not a copied/fake integrator.
// These aliases and standard includes supply the context normally provided by
// Cemu's application PCH; no math or sensor implementation is replaced here.
#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <optional>
#include <sstream>
#include <string>
#include <vector>
#include <boost/algorithm/string/predicate.hpp>
namespace fs = std::filesystem;
using uint8 = uint8_t;
using uint32 = uint32_t;
using uint64 = uint64_t;
using sint32 = int32_t;
using DWORD = uint32_t;
#include "CemuMotion.hpp"
extern "C" {
S2KContext* test_input_create();
void test_input_report(S2KContext*, int32_t, uint32_t, const S2KState*);
void test_input_retire(S2KContext*, int32_t);
}
using namespace Switch2Kit;
static S2KID physical() { S2KID id{}; id.bytes[15] = 1; return id; }
static S2KMotionProfile synthetic() {
    S2KMotionProfile p{}; p.version = 1; p.struct_size = sizeof(p); p.device = physical();
    p.model = S2K_PRO; p.configuration = S2K_MOTION_CONFIGURATION_BT_V1; p.feature_flags = 0xa7;
    p.calibration.version = 1; p.calibration.struct_size = sizeof(p.calibration);
    for (int i = 0; i < 3; ++i) {
        p.holding_axes[i] = p.calibration.acceleration.axes[i] = p.calibration.angular_velocity.axes[i] = i + 1;
        p.calibration.acceleration.units_per_count[i] = 9.80665 / 1000;
        p.calibration.angular_velocity.units_per_count[i] = 0.001;
    }
    std::strcpy(p.orientation, "synthetic-test-only");
    return p;
}
static void equivalent(MotionSample a, MotionSample b) {
    float x[9]{}, y[9]{};
    a.getVPADAttitudeMatrix(x); b.getVPADAttitudeMatrix(y);
    for (int i = 0; i < 9; ++i) assert(std::isfinite(x[i]) && std::abs(x[i] - y[i]) < 1e-6f);
    a.getVPADOrientation(x); b.getVPADOrientation(y);
    for (int i = 0; i < 3; ++i) assert(std::abs(x[i] - y[i]) < 1e-6f);
    a.getAccelerometer(x); b.getAccelerometer(y);
    for (int i = 0; i < 3; ++i) assert(std::abs(x[i] - y[i]) < 1e-6f);
    a.getGyrometer(x); b.getGyrometer(y);
    for (int i = 0; i < 3; ++i) assert(std::abs(x[i] - y[i]) < 1e-6f);
}
int main() {
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    assert(SDL_Init(SDL_INIT_GAMEPAD));
    auto* context = test_input_create(); assert(context && s2k_start(context) == S2K_OK);
    {
        SDL3Adapter adapter(context);
        assert(adapter.installMotionProfile(synthetic()) == S2K_OK);
        S2KState state{}; state.present = S2K_HAS_MOTION;
        state.accel[1] = 1000;
        state.gyro[0] = 1000; state.gyro[1] = 2000; state.gyro[2] = 3000;
        const auto submit = [&] {
            ++state.sequence; state.received_at = s2k_monotonic_time();
            test_input_report(context, 0, S2K_PRO, &state);
            assert(adapter.pump() == S2K_OK);
        };
        submit();
        const auto id = adapter.instance(physical());
        auto* pad = SDL_OpenGamepad(id); assert(pad);
        CemuSensorPolicy owner, settingsView;
        assert(owner.update(pad, true));
        const auto enabledEpoch = SDL3Adapter::motionState(id).epoch;
        assert(settingsView.update(pad, true));
        assert(owner.update(pad, false));
        assert(SDL3Adapter::motionState(id).epoch == enabledEpoch);
        assert(SDL_GamepadSensorEnabled(pad, SDL_SENSOR_GYRO));
        assert(settingsView.update(pad, false));
        assert(SDL3Adapter::motionState(id).status == SDL3MotionStatus::Disabled);
        assert(!SDL_GamepadSensorEnabled(pad, SDL_SENSOR_ACCEL));
        assert(owner.update(pad, true));
        assert(SDL3Adapter::motionState(id).epoch != enabledEpoch);
        CemuMotion consumer;
        assert(!consumer.availableSample());
        const auto drain = [&](bool drop = false, bool half = false) {
            std::vector<SDL_GamepadSensorEvent> result;
            SDL_Event event{};
            while (SDL_PollEvent(&event)) if (event.type == SDL_EVENT_GAMEPAD_SENSOR_UPDATE) {
                result.push_back(event.gsensor);
                if (!drop && !(half && event.gsensor.sensor == SDL_SENSOR_GYRO)) {
                    // Poison event delivery time: integration must use mapped receive time.
                    event.gsensor.timestamp = UINT64_MAX;
                    consumer.consume(SDL3Adapter::motionStateAt(id, event.gsensor.sensor_timestamp), event.gsensor);
                }
            }
            return result;
        };
        assert(drain().empty());
        submit(); assert(drain().empty()); // Seed, not a measurement replay.
        Uint64 previous = SDL3Adapter::motionState(id).validSinceNS;
        WiiUMotionHandler reference;
        for (int i = 0; i < 30; ++i) {
            SDL_Delay(1); submit(); const auto events = drain(); assert(events.size() == 2);
            const auto stamp = events.front().sensor_timestamp;
            reference.processMotionSample(static_cast<float>((stamp - previous) / 1e9), 1, -2, -3, 0, 1, 0);
            previous = stamp;
            equivalent(consumer.snapshot(), reference.getMotionSample());
        }
        assert(consumer.availableSample());
        float data[3]{}; auto current = consumer.snapshot();
        current.getAccelerometer(data); assert(data[0] == 0 && data[1] == 1 && data[2] == 0);
        current.getGyrometer(data); assert(data[0] == 1 && data[1] == -2 && data[2] == -3);
        // Merely reading cached game state cannot integrate again.
        for (int i = 0; i < 1000; ++i) {
            consumer.synchronize(SDL3Adapter::motionState(id));
            equivalent(current, consumer.snapshot());
        }
        const auto nextFresh = [&] {
            const auto baseline = SDL3Adapter::motionState(id).timestampNS;
            SDL_Delay(1); submit(); const auto events = drain(); assert(events.size() == 2);
            WiiUMotionHandler fresh;
            fresh.processMotionSample(static_cast<float>((events[0].sensor_timestamp - baseline) / 1e9), 1, -2, -3, 0, 1, 0);
            equivalent(consumer.snapshot(), fresh.getMotionSample());
        };
        // Lost complete SDL pair: sequence metadata forces a real Mahony reset.
        submit(); assert(drain(true).size() == 2);
        submit(); assert(drain().size() == 2); // New report rearms, not integrates across loss.
        assert(!consumer.availableSample());
        equivalent(consumer.snapshot(), MotionSample{});
        nextFresh();
        // Lost gyro half must not borrow acceleration from a different report.
        submit(); assert(drain(false, true).size() == 2);
        submit(); assert(drain().size() == 2);
        assert(!consumer.availableSample());
        equivalent(consumer.snapshot(), MotionSample{}); nextFresh();
        // Missing raw telemetry and overflow are state reconciliation, not samples.
        state.present = 0; submit(); assert(drain().empty());
        consumer.synchronize(SDL3Adapter::motionState(id));
        assert(!consumer.availableSample());
        equivalent(consumer.snapshot(), MotionSample{});
        state.present = S2K_HAS_MOTION; submit(); assert(drain().empty());
        const auto baseline = SDL3Adapter::motionState(id).validSinceNS;
        submit(); const auto renewed = drain(); assert(renewed.size() == 2);
        WiiUMotionHandler fresh;
        fresh.processMotionSample(static_cast<float>((renewed[0].sensor_timestamp - baseline) / 1e9), 1, -2, -3, 0, 1, 0);
        equivalent(consumer.snapshot(), fresh.getMotionSample());
        // Event-free inactivity resets the existing downstream solver immediately.
        SDL_Delay(110); consumer.synchronize(SDL3Adapter::motionState(id));
        assert(!consumer.availableSample());
        equivalent(consumer.snapshot(), MotionSample{});
        // Retirement rejects queued measurements even if a host kept the old handle.
        submit(); test_input_retire(context, 0); assert(adapter.pump() == S2K_OK);
        consumer.synchronize(SDL3Adapter::motionState(id));
        assert(!SDL_GamepadConnected(pad)); equivalent(consumer.snapshot(), MotionSample{});
        SDL_CloseGamepad(pad);
    }
    s2k_destroy(context); SDL_Quit();
    std::puts("PASS Swift hub/C ABI/real SDL -> pinned Cemu Mahony/VPAD: units, receive dt, sequence loss, missing half, gaps, inactivity and retirement reset");
}
