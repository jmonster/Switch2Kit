#include <Switch2KitC.h>
#include <Switch2KitMotion.h>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <type_traits>
extern "C" {
S2KContext* s2k_fixture_create();
void s2k_fixture_emit(S2KContext*, int32_t, uint32_t, uint64_t, uint32_t);
void s2k_fixture_retire(S2KContext*, int32_t);
void s2k_fixture_finish_stop(S2KContext*);
uint32_t s2k_fixture_calls(S2KContext*);
}
static_assert(std::is_standard_layout_v<S2KState> && std::is_trivially_copyable_v<S2KSnapshot>);
static_assert(sizeof(S2KID) == 16 && offsetof(S2KState, left_x) == 24);
static void check_motion_calibration() {
    S2KState state{};
    state.present = S2K_HAS_MOTION; state.received_at = 123.5; state.sequence = UINT64_MAX;
    state.accel[0] = 14; state.accel[1] = -17; state.accel[2] = 26;
    state.gyro[0] = 10; state.gyro[1] = -5;
    S2KMotionCalibration profile{};
    profile.version = S2K_MOTION_CALIBRATION_VERSION; profile.struct_size = sizeof(profile);
    profile.acceleration = {{10, -20, 30}, {0.5, 2, 0.25}, {-2, 3, 1}, 0};
    profile.angular_velocity = {{0, 0, 0}, {0.1, 0.2, 0.3}, {1, 2, 3}, 0};
    S2KCalibratedMotion result{};
    assert(s2k_convert_motion(&state, &profile, &result, sizeof(result)) == S2K_OK);
    assert(result.acceleration[0] == -6 && result.acceleration[1] == -1 && result.acceleration[2] == 2);
    assert(result.angular_velocity[0] == 1 && result.angular_velocity[1] == -1 && result.angular_velocity[2] == 0);
    assert(result.received_at == 123.5 && result.sequence == UINT64_MAX);
    profile.acceleration.axes[0] = 3;
    assert(s2k_convert_motion(&state, &profile, &result, sizeof(result)) == S2K_INVALID_ARGUMENT);
    assert(result.received_at == 123.5 && result.sequence == UINT64_MAX);
    assert(s2k_convert_motion(&state, &profile, &result, sizeof(result) - 1) == S2K_ABI_MISMATCH);
    state.present = 0;
    assert(s2k_convert_motion(&state, &profile, &result, sizeof(result)) == S2K_NOT_READY);
    std::puts("PASS native motion calibration, SI values, timestamps and invalid-profile boundaries");
}
int main() {
    check_motion_calibration();
    // Assertions remain enabled for Release integration tests.
    assert(s2k_abi_version() == S2K_ABI_VERSION);
    S2KResult status{};
    S2KConfig config{S2K_ABI_VERSION, sizeof(S2KConfig), 16, S2K_EVENT_CAPACITY};
    auto* real = s2k_create(&config, &status); // Create only; no Bluetooth starts.
#ifdef __APPLE__
    assert(real && status == S2K_OK);
#else
    assert(!real && status == S2K_UNSUPPORTED_PLATFORM);
#endif
    s2k_destroy(real);
    auto* context = s2k_fixture_create();
    assert(context && s2k_start(context) == S2K_OK);
    std::array<S2KEvent, 256> events{};
    S2KSnapshot snapshot{};
    uint32_t count{}, flags{};
    auto read = [&] {
        assert(s2k_read(context, events.data(), events.size(), sizeof(S2KEvent), &count,
                        &snapshot, sizeof(snapshot), &flags) == S2K_OK);
    };
    s2k_fixture_emit(context, 0, S2K_GAMECUBE, 1, 0);
    s2k_fixture_emit(context, 1, S2K_PRO, 1, 0);
    read();
    assert(snapshot.count == 2 && count == 0 && flags & S2K_READ_RESYNC);
    const auto gc = snapshot.controllers[0];
    const auto pro = snapshot.controllers[1];
    assert(gc.state.left_travel == 0.25 && gc.state.left_pressed == 0);
    assert(gc.state.left_x == -0.5 && gc.state.left_y == 1);
    assert(gc.state.battery_millivolts == 3900 && gc.state.accel[0] == -100);
    assert(s2k_play_feedback(context, &gc.id, &gc.connection_id, 0.25) == S2K_OK);
    assert(s2k_set_rumble(context, &gc.id, &gc.connection_id, 1, 0) == S2K_UNSUPPORTED_OPERATION);
    assert(s2k_set_rumble(context, &pro.id, &pro.connection_id, 0.5, 0.25) == S2K_OK);
    assert(s2k_set_rumble(context, &pro.id, &pro.connection_id, NAN, 0) == S2K_INVALID_ARGUMENT);
    assert(s2k_fixture_calls(context) == 2);
    s2k_fixture_emit(context, 0, S2K_GAMECUBE, 2, 1);
    s2k_fixture_emit(context, 0, S2K_GAMECUBE, 3, 0);
    read();
    assert(count == 2 && !(flags & S2K_READ_RESYNC));
    assert(events[0].controller.state.left_pressed && !events[1].controller.state.left_pressed);
    for (uint64_t n = 4; n < 10004; ++n) s2k_fixture_emit(context, 0, S2K_GAMECUBE, n, 0);
    read(); assert(count == 0 && flags & S2K_READ_RESYNC);
    s2k_fixture_retire(context, 0);
    s2k_fixture_emit(context, 0, S2K_GAMECUBE, 1, 0);
    assert(s2k_play_feedback(context, &gc.id, &gc.connection_id, 1) == S2K_NOT_READY);
    assert(s2k_stop(context) == S2K_OK && s2k_start(context) == S2K_BUSY);
    read(); assert(snapshot.count == 0 && snapshot.stopping && !snapshot.running);
    s2k_fixture_finish_stop(context); read(); assert(!snapshot.stopping);
    s2k_destroy(context);
    std::puts("PASS C++ ABI: real creation, fake input, full fields, ordered edges, overflow, rumble, generations and stop");
}
