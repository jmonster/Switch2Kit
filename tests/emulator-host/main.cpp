#include <SDLHost.hpp>
#include <cassert>
#include <thread>
#include <cstdio>
extern "C" {
S2KContext* test_input_create();
void test_input_report(S2KContext*, int32_t, uint32_t, const S2KState*);
void test_input_retire(S2KContext*, int32_t);
}
int main() {
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    assert(SDL_Init(SDL_INIT_GAMEPAD));
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
