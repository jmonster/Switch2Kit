#include "DolphinMotion.hpp"
#include "../sdl-inprocess/Clock.hpp"
#include "Core/HW/WiimoteEmu/Dynamics.h"
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <thread>
#include <sstream>
#include "Common/IniFile.h"
#include <vector>
extern "C" {
S2KContext* test_input_create();
void test_input_report(S2KContext*, int32_t, uint32_t, const S2KState*);
void test_input_retire(S2KContext*, int32_t);
}
using namespace Switch2Kit;
static S2KID physical(int index = 0) { S2KID id{}; id.bytes[15] = static_cast<uint8_t>(index + 1); return id; }
static S2KMotionProfile synthetic(int index = 0) {
    S2KMotionProfile p{}; p.version = 1; p.struct_size = sizeof(p); p.device = physical(index);
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
static void equivalent(const Common::Quaternion& a, const Common::Quaternion& b) {
    const auto x = Common::Matrix33::FromQuaternion(a);
    const auto y = Common::Matrix33::FromQuaternion(b);
    for (size_t i = 0; i < x.data.size(); ++i) assert(std::abs(x.data[i] - y.data[i]) < 1e-5f);
}
int main() {
    // Exercise the pinned INI parser with a bounded, already-read host settings
    // stream. Profile edits do not reinterpret or remove physical assignments.
    const std::string key = "s2k:00000000000000000000000000000001";
    const std::string chosen = "/chosen path/device \"quoted\".s2kmotion ";
    std::istringstream settings("[Controllers]\n0 = " + key +
        "\n[MotionProfiles]\n" + key + " = \"" + chosen + "\"\n[Other]\nvalue = preserve\n");
    Common::IniFile ini; assert(ini.Load(settings));
    std::string value;
    assert(ini.GetOrCreateSection("MotionProfiles")->Get(key, &value) && value == chosen);
    assert(ini.GetOrCreateSection("Controllers")->Get("0", &value) && value == key);
    assert(ini.DeleteKey("MotionProfiles", key));
    assert(ini.GetOrCreateSection("Controllers")->Get("0", &value) && value == key);
    assert(ini.GetOrCreateSection("Other")->Get("value", &value) && value == "preserve");
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    assert(SDL_Init(SDL_INIT_GAMEPAD));
    auto* context = test_input_create(); assert(context && s2k_start(context) == S2K_OK);
    {
        SDL3Adapter adapter(context);
        assert(adapter.installMotionProfile(synthetic()) == S2K_OK);
        S2KState state{}; state.present = S2K_HAS_MOTION; state.accel[1] = 1000; state.gyro[0] = 1000;
        const auto submit = [&] {
            ++state.sequence; state.received_at = s2k_monotonic_time();
            test_input_report(context, 0, S2K_PRO, &state);
            assert(adapter.pump() == S2K_OK);
        };
        const auto drain = [&](bool drop = false, bool half = false) {
            std::vector<SDL_GamepadSensorEvent> events;
            SDL_Event event{};
            while (SDL_PollEvent(&event)) if (event.type == SDL_EVENT_GAMEPAD_SENSOR_UPDATE) {
                events.push_back(event.gsensor);
                if (!drop && !(half && event.gsensor.sensor == SDL_SENSOR_GYRO)) {
                    event.gsensor.timestamp = UINT64_MAX; // Delivery time cannot drive motion.
                    DolphinMotionStream::handle(event.gsensor);
                }
            }
            return events;
        };
        submit(); const auto id = adapter.instance(physical());
        auto* pad = SDL_OpenGamepad(id); assert(pad);
        DolphinMotionReader reader, second;
        WiimoteEmu::IMUCursorState imu, independent;
        auto batch = reader.read(id, true); assert(batch.reset && !batch.count && !batch.latest);
        assert(drain().empty()); submit(); assert(drain().empty());
        double angle = 0;
        for (int i = 0; i < 30; ++i) {
            SDL_Delay(1); submit(); assert(drain().size() == 2);
            batch = reader.read(id, true); assert(batch.count == 1 && batch.latest);
            const auto accel = WiimoteEmu::Switch2MotionFrame(batch.latest->acceleration);
            assert(accel.x == 0 && accel.y == 0 && std::abs(accel.z - 9.80665f) < 1e-6f);
            const auto gyro = WiimoteEmu::Switch2MotionFrame(batch.latest->angularVelocity);
            assert(gyro.x == -1 && gyro.y == 0 && gyro.z == 0);
            angle += batch.samples[0].deltaSeconds;
            WiimoteEmu::EmulateSwitch2Motion(&imu, batch, 0, 6.2831853f, false);
            equivalent(imu.rotation, Common::Quaternion::RotateX(static_cast<float>(angle)));
        }
        const auto held = imu.rotation;
        for (int i = 0; i < 1000; ++i) {
            batch = reader.read(id, true); assert(!batch.count && !batch.reset && batch.latest);
            WiimoteEmu::EmulateSwitch2Motion(&imu, batch, 0.02f, 6.2831853f, false);
            equivalent(imu.rotation, held); // Neither gyro nor correction replays per frame.
        }
        auto other = second.read(id, true); assert(other.reset && !other.count && !other.latest);
        submit(); assert(drain().size() == 2);
        batch = reader.read(id, true); other = second.read(id, true);
        assert(batch.count == 1 && other.count == 1);
        WiimoteEmu::EmulateSwitch2Motion(&independent, other, 0, 6.2831853f, false);
        equivalent(independent.rotation, Common::Quaternion::RotateX(static_cast<float>(other.samples[0].deltaSeconds)));
        // Every report in a multi-report batch crosses the actual Dolphin filter once.
        for (int i = 0; i < 5; ++i) { SDL_Delay(1); submit(); }
        assert(drain().size() == 10);
        batch = reader.read(id, true); assert(batch.count == 5);
        other = second.read(id, true); assert(other.count == 5);
        // Complete SDL event loss and missing halves reset the actual orientation.
        submit(); assert(drain(true).size() == 2);
        submit(); assert(drain().size() == 2);
        batch = reader.read(id, true); assert(batch.reset && !batch.count && !batch.latest);
        WiimoteEmu::EmulateSwitch2Motion(&imu, batch, 0, 6.2831853f, false);
        equivalent(imu.rotation, Common::Quaternion::Identity());
        submit(); assert(drain().size() == 2);
        batch = reader.read(id, true); assert(batch.count == 1);
        WiimoteEmu::EmulateSwitch2Motion(&imu, batch, 0, 6.2831853f, false);
        equivalent(imu.rotation, Common::Quaternion::RotateX(static_cast<float>(batch.samples[0].deltaSeconds)));
        submit(); assert(drain(false, true).size() == 2); submit(); assert(drain().size() == 2);
        batch = reader.read(id, true); assert(batch.reset && !batch.count);
        // A bounded ring must detect a consumer that misses more than its capacity.
        for (int i = 0; i < 600; ++i) { submit(); drain(); }
        batch = reader.read(id, true); assert(batch.reset && !batch.count && !batch.latest);
        submit(); drain(); batch = reader.read(id, true); assert(batch.count == 1);
        // Actual filter gravity correction runs per sample, not per consumer poll.
        WiimoteEmu::EmulateSwitch2Motion(&imu, batch, 0.02f, 6.2831853f, false);
        const auto corrected = imu.rotation;
        batch = reader.read(id, true); WiimoteEmu::EmulateSwitch2Motion(&imu, batch, 0.02f, 6.2831853f, false);
        equivalent(imu.rotation, corrected);
        // A suspend-aware guard resets Dolphin's existing cursor even before
        // its input pump resumes, while its SDL/receive clocks may both be paused.
        const auto sleepEpoch = SDL3Adapter::motionState(id).epoch;
        TestClock::suspend(30000000000ULL);
        batch = reader.read(id, true); assert(batch.reset && !batch.count && !batch.latest);
        WiimoteEmu::EmulateSwitch2Motion(&imu, batch, 0, 6.2831853f, false);
        equivalent(imu.rotation, Common::Quaternion::Identity());
        submit(); assert(drain().empty());
        assert(SDL3Adapter::motionState(id).epoch != sleepEpoch);
        submit(); assert(drain().empty());
        submit(); assert(drain().size() == 2);
        batch = reader.read(id, true); assert(batch.reset && batch.count == 1 && batch.latest);
        WiimoteEmu::EmulateSwitch2Motion(&imu, batch, 0, 6.2831853f, false);
        equivalent(imu.rotation, Common::Quaternion::RotateX(static_cast<float>(batch.samples[0].deltaSeconds)));
        reader.reset(); assert(SDL_GamepadSensorEnabled(pad, SDL_SENSOR_GYRO)); // Second reader still owns its request.
        second.reset(); assert(!SDL_GamepadSensorEnabled(pad, SDL_SENSOR_GYRO));
        reader.read(id, true); submit(); drain(); submit(); drain(); reader.read(id, true);
        SDL_Delay(110); batch = reader.read(id, true);
        assert(batch.reset && !batch.latest && !batch.count);
        WiimoteEmu::EmulateSwitch2Motion(&imu, batch, 0, 6.2831853f, false);
        equivalent(imu.rotation, Common::Quaternion::Identity());
        state.present = 0; submit(); drain(); batch = reader.read(id, true); assert(!batch.latest);
        state.present = S2K_HAS_MOTION; submit(); drain(); submit(); drain();
        test_input_retire(context, 0); assert(adapter.pump() == S2K_OK); drain();
        batch = reader.read(id, true); assert(batch.reset && !batch.count && !batch.latest);
        SDL_CloseGamepad(pad);
        static_assert(sizeof(DolphinMotionStream::Cursor) < 160);
        static_assert(sizeof(DolphinMotionStream::Batch) < 22000);
    }
    s2k_destroy(context); SDL_Quit();
    std::puts("PASS Swift hub/C ABI/real SDL -> actual Dolphin cursor: SI frame, positive rotation, receive dt, independent readers, no frame replay, lost events, overflow, stalls and retirement");
}
