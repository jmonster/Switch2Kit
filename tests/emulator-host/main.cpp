#include <SDLHost.hpp>
#include <cassert>
#include <atomic>
#include <thread>
#include <cstdio>
extern "C" {
S2KContext* test_input_create();
void test_input_report(S2KContext*, int32_t, uint32_t, const S2KState*);
void test_input_retire(S2KContext*, int32_t);
uint32_t test_input_automatic_discovery(S2KContext*);
uint32_t test_input_discovery_configuration_count(S2KContext*);
uint32_t test_input_start_count(S2KContext*);
uint32_t test_input_discovery_count(S2KContext*);
uint32_t test_input_finish_stop(S2KContext*);
}
// Execute the production SDLHost, C context and SDL3 adapter. Only the radio
// source is controlled; this is not physical Bluetooth qualification.
static void onDemandPolicyTests() {
    auto* fixture = test_input_create(); assert(fixture);
    Switch2Kit::SDLHost host(fixture);
    // No saved consent: selecting the default policy must not touch the radio.
    assert(host.setAutomaticDiscovery(false) == S2K_OK);
    assert(test_input_discovery_configuration_count(fixture) == 0);
    assert(test_input_start_count(fixture) == 0 && !host.snapshot().running);
    assert(host.start() == S2K_OK && host.start() == S2K_OK);
    for (int i = 0; i < 100; ++i) assert(host.pump() == S2K_OK);
    assert(host.snapshot().running && test_input_start_count(fixture) == 1);
    assert(test_input_automatic_discovery(fixture) == 0);
    assert(test_input_discovery_count(fixture) == 0);
    assert(host.stop() == S2K_OK && host.snapshot().stopping);
    assert(host.discover() == S2K_BUSY);
    assert(test_input_start_count(fixture) == 1 && test_input_discovery_count(fixture) == 0);
    assert(test_input_finish_stop(fixture) == 1);
    // Changing either policy while stopped is configuration, not a restart.
    assert(host.setAutomaticDiscovery(true) == S2K_OK);
    assert(host.setAutomaticDiscovery(false) == S2K_OK);
    assert(!host.snapshot().running && !host.snapshot().stopping);
    assert(test_input_start_count(fixture) == 1);
    assert(host.start() == S2K_OK && test_input_start_count(fixture) == 2);
    assert(test_input_automatic_discovery(fixture) == 0);
    assert(test_input_discovery_count(fixture) == 0);
    assert(host.stop() == S2K_OK && test_input_finish_stop(fixture) == 1);
    host.shutdown();
    std::puts("PASS policy-only start defaults to on-demand, busy discovery and stopped opt-out");
}
static void automaticDiscoveryTests() {
    auto* fixture = test_input_create(); assert(fixture);
    Switch2Kit::SDLHost host(fixture);
    assert(host.initialize() == S2K_OK && !host.snapshot().running);
    assert(test_input_automatic_discovery(fixture) == 0);
    assert(test_input_start_count(fixture) == 0);
    assert(host.setAutomaticDiscovery(true) == S2K_OK);
    assert(host.setAutomaticDiscovery(true) == S2K_OK);
    assert(test_input_automatic_discovery(fixture) == 1);
    assert(test_input_discovery_configuration_count(fixture) == 1);
    assert(!host.snapshot().running && test_input_start_count(fixture) == 0);
    assert(host.start() == S2K_OK && host.start() == S2K_OK);
    assert(host.snapshot().running && test_input_start_count(fixture) == 1);
    assert(test_input_discovery_count(fixture) == 0);

    S2KState state{}; state.sequence = 1;
    test_input_report(fixture, 0, S2K_PRO, &state);
    test_input_report(fixture, 1, S2K_PRO, &state);
    assert(host.pump() == S2K_OK);
    const std::string first = "s2k:00000000000000000000000000000001";
    const std::string second = "s2k:00000000000000000000000000000002";
    const auto original = host.instance(first), other = host.instance(second);
    assert(original && other && original != other);
    auto* pad = SDL_OpenGamepad(original); assert(pad);
    state.sequence++; state.buttons = S2K_BUTTON_A;
    test_input_report(fixture, 0, S2K_PRO, &state);
    assert(host.pump() == S2K_OK && SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_EAST));
    state.sequence++; state.buttons = 0;
    test_input_report(fixture, 0, S2K_PRO, &state);
    // A policy change must neither consume the queued release nor detach input.
    assert(host.setAutomaticDiscovery(false) == S2K_OK);
    assert(test_input_automatic_discovery(fixture) == 0);
    assert(SDL_GamepadConnected(pad) && SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_EAST));
    assert(host.instance(first) == original && host.instance(second) == other);
    assert(host.pump() == S2K_OK && !SDL_GetGamepadButton(pad, SDL_GAMEPAD_BUTTON_EAST));
    assert(host.setAutomaticDiscovery(true) == S2K_OK);
    for (int i = 0; i < 1000; ++i) {
        assert(host.pump() == S2K_OK && host.snapshot().count == 2);
    }
    assert(test_input_start_count(fixture) == 1 && test_input_discovery_count(fixture) == 0);
    assert(test_input_discovery_configuration_count(fixture) == 3);

    // Settings can change policy while the input loop and enumeration are live.
    // Exercise the production SDL-before-host lock order without timing sleeps.
    std::atomic<bool> inputReady{false}, policyDone{false};
    std::thread settings([&] {
        while (!inputReady.load()) std::this_thread::yield();
        for (int i = 0; i < 500; ++i) {
            assert(host.setAutomaticDiscovery(false) == S2K_OK);
            assert(host.setAutomaticDiscovery(true) == S2K_OK);
            assert(host.instance(first) == original && host.instance(second) == other);
        }
        policyDone.store(true);
    });
    inputReady.store(true);
    do {
        assert(host.pump() == S2K_OK && host.snapshot().count == 2);
        assert(SDL_GamepadConnected(pad));
    } while (!policyDone.load());
    settings.join();
    assert(test_input_discovery_configuration_count(fixture) == 1003);
    assert(test_input_start_count(fixture) == 1 && test_input_discovery_count(fixture) == 0);

    assert(host.stop() == S2K_OK && !host.snapshot().running);
    assert(!SDL_GamepadConnected(pad));
    SDL_CloseGamepad(pad);
    assert(host.instance(first) == 0 && host.instance(second) == 0);
    assert(host.start() == S2K_BUSY && host.setAutomaticDiscovery(false) == S2K_BUSY);
    assert(test_input_automatic_discovery(fixture) == 1);
    assert(test_input_finish_stop(fixture) == 1 && test_input_finish_stop(fixture) == 0);
    assert(host.setAutomaticDiscovery(true) == S2K_OK);
    for (int i = 0; i < 1000; ++i) {
        assert(host.pump() == S2K_OK && !host.snapshot().running);
    }
    assert(test_input_start_count(fixture) == 1 && test_input_discovery_count(fixture) == 0);
    assert(host.start() == S2K_OK && test_input_start_count(fixture) == 2);
    assert(test_input_automatic_discovery(fixture) == 1);
    // A reverse-order new generation still resolves each original physical key.
    state = {}; state.sequence = 1;
    test_input_report(fixture, 1, S2K_PRO, &state);
    test_input_report(fixture, 0, S2K_PRO, &state);
    assert(host.pump() == S2K_OK);
    assert(host.instance(first) && host.instance(first) != original);
    assert(host.instance(second) && host.instance(second) != other);
    assert(host.identity(host.instance(first)) == first && host.identity(host.instance(second)) == second);
    assert(host.setAutomaticDiscovery(false) == S2K_OK && host.discover() == S2K_OK);
    assert(test_input_start_count(fixture) == 2 && test_input_discovery_count(fixture) == 1);
    assert(host.stop() == S2K_OK && test_input_finish_stop(fixture) == 1);
    host.shutdown(); host.shutdown();
    assert(host.pump() == S2K_OK);
    std::puts("PASS real SDLHost automatic policy, queued input, live opt-out, stop/busy/restart and physical identity");
}
int main() {
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    assert(SDL_Init(SDL_INIT_GAMEPAD));
    onDemandPolicyTests();
    automaticDiscoveryTests();
    auto* fixture = test_input_create();
    Switch2Kit::SDLHost host(fixture);
    assert(host.initialize() == S2K_OK && host.snapshot().running == 0);
    assert(host.discover() == S2K_OK && host.snapshot().running == 1);
    S2KState state{}; state.sequence = 1;
    test_input_report(fixture, 0, S2K_PRO, &state);
    assert(host.pump() == S2K_OK);
    int count{}; auto* ids = SDL_GetGamepads(&count); assert(count == 1);
    const auto original = ids[0]; SDL_free(ids);
    const auto identity = host.identity(original);
    assert(identity == "s2k:00000000000000000000000000000001");
    assert(host.instance(identity) == original);
    assert(host.instance("s2k:not-an-identity") == 0 && host.identity(0).empty());
    assert(host.instance("s2k:0000000000000000000000000000000g") == 0);
    assert(host.feedback(original, .25) == S2K_OK);
    // Enumeration and status queries may originate in an emulator's hotplug thread.
    std::thread enumeration([&] {
        for (int i = 0; i < 1000; ++i) {
            assert(host.identity(original) == identity);
            assert(host.snapshot().count == 1);
        }
    });
    for (int i = 0; i < 1000; ++i) assert(host.pump() == S2K_OK);
    enumeration.join();
    test_input_retire(fixture, 0);
    test_input_report(fixture, 0, S2K_PRO, &state);
    assert(host.pump() == S2K_OK);
    assert(host.instance(identity) != 0 && host.instance(identity) != original);
    assert(host.identity(original).empty() && host.feedback(original) == S2K_NOT_READY);
    assert(host.stop() == S2K_OK && host.snapshot().running == 0);
    assert(host.instance(identity) == 0 && host.stop() == S2K_OK);
    host.shutdown(); host.shutdown();
    assert(host.pump() == S2K_OK);
    SDL_Quit();
    std::puts("PASS emulator ownership, explicit discovery, status, persistent identity, concurrent enumeration and terminal shutdown");
}
