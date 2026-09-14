#include <SDLHost.hpp>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <thread>
#include <vector>
extern "C" {
S2KContext* test_input_create();
void test_input_report(S2KContext*, int32_t, uint32_t, const S2KState*);
void test_input_retire(S2KContext*, int32_t);
}
// Explicitly synthetic. The production validator is used; no model coefficients
// are supplied by the fixture or by the reusable host.
static const char* text =
    "Switch2KitMotionProfile 1\n"
    "device 00000000-0000-0000-0000-000000000001\n"
    "model 0x2069\nconfiguration bt-report-v1 0xa7\nraw-range -32768 32767\n"
    "orientation synthetic-only 1 2 3\n"
    "acceleration m/s2\nbias 0 0 0\ngain 0.01 0.01 0.01\naxes 1 2 3\nrange-at-32768 327.68 327.68 327.68\n"
    "angular-velocity rad/s\nbias 0 0 0\ngain 0.001 0.001 0.001\naxes 1 2 3\nrange-at-32768 32.768 32.768 32.768\n";
int main() {
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    assert(SDL_Init(SDL_INIT_GAMEPAD));
    char temporary[] = "/tmp/S2K profile.XXXXXX";
    auto* directory = mkdtemp(temporary); assert(directory);
    const auto path = std::string(directory) + "/chosen device.s2km";
    const auto write = [&](const std::string& contents) { std::ofstream file(path, std::ios::binary); file << contents; assert(file.good()); };
    write(text);
    auto* fixture = test_input_create(); assert(fixture);
    Switch2Kit::SDLHost host(fixture);
    assert(host.loadMotionProfile(path) == S2K_OK); // Explicit loading before discovery/SDL attachment.
    assert(host.snapshot().running == 0);
    assert(host.discover() == S2K_OK);
    S2KState state{}; state.sequence = 1;
    test_input_report(fixture, 0, S2K_PRO, &state);
    assert(host.pump() == S2K_OK);
    const std::string identity = "s2k:00000000000000000000000000000001";
    S2KID physical{}; physical.bytes[15] = 1;
    const auto original = host.instance(identity); assert(original);
    auto* pad = SDL_OpenGamepad(original); assert(pad);
    assert(SDL_GamepadHasSensor(pad, SDL_SENSOR_ACCEL));
    assert(host.motionState(physical).status == Switch2Kit::SDL3MotionStatus::Disabled);
    for (const auto& invalid : {std::string(), std::string(4097, ' '), std::string(text) + "unknown 1\n"}) {
        write(invalid); assert(host.loadMotionProfile(path) == S2K_INVALID_ARGUMENT);
        assert(host.pump() == S2K_OK && host.instance(identity) == original);
        assert(SDL_GamepadHasSensor(pad, SDL_SENSOR_ACCEL));
    }
    assert(host.loadMotionProfile(path + ".missing") == S2K_INVALID_ARGUMENT);
    write(text);
    std::thread query([&] {
        for (int i = 0; i < 1000; ++i) {
            assert(host.motionState(physical).owned);
            assert(host.identity(original) == identity);
        }
    });
    for (int i = 0; i < 1000; ++i) { assert(host.loadMotionProfile(path) == S2K_OK); assert(host.pump() == S2K_OK); }
    query.join();
    assert(host.instance(identity) == original); // Same profile import is idempotent.
    test_input_retire(fixture, 0); test_input_report(fixture, 0, S2K_PRO, &state);
    assert(host.pump() == S2K_OK && host.instance(identity) != original);
    SDL_CloseGamepad(pad); pad = SDL_OpenGamepad(host.instance(identity)); assert(pad);
    assert(SDL_GamepadHasSensor(pad, SDL_SENSOR_ACCEL));
    host.clearMotionProfiles(); assert(host.pump() == S2K_OK);
    SDL_CloseGamepad(pad); pad = SDL_OpenGamepad(host.instance(identity)); assert(pad);
    assert(!SDL_GamepadHasSensor(pad, SDL_SENSOR_ACCEL));
    assert(host.motionState(physical).status == Switch2Kit::SDL3MotionStatus::UnavailableProfile);
    assert(host.identity(host.instance(identity)) == identity);
    SDL_CloseGamepad(pad);
    assert(host.stop() == S2K_OK); host.shutdown();
    assert(std::remove(path.c_str()) == 0); assert(std::remove(directory) == 0);
    SDL_Quit();
    std::puts("PASS explicit bounded host file loading (spaces), malformed import rollback, concurrent status, reconnect identity and profile removal");
}
