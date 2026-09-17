#include <Switch2KitC.h>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>

static void require(bool condition, const char* description) {
    if (!condition) { std::fprintf(stderr, "FAIL: %s\n", description); std::exit(1); }
}
int main(int argc, char** argv) {
    require(argc == 3, "scenario and model required");
    const char* scenario = argv[1];
    const auto model = static_cast<uint32_t>(std::strtoul(argv[2], nullptr, 0));
    S2KResult result = -1;
    auto* context = s2k_create(nullptr, &result);
    require(context && result == S2K_OK, "Linux live context creation");
    S2KSnapshot snapshot{};
    std::array<S2KEvent, S2K_EVENT_CAPACITY> events{};
    uint32_t count{}, flags{};
    bool pressed = false, released = false, disconnected = false;
    auto read = [&] {
        require(s2k_read(context, events.data(), events.size(), sizeof(S2KEvent), &count,
                        &snapshot, sizeof(snapshot), &flags) == S2K_OK, "read");
        for (uint32_t i = 0; i < count; ++i) {
            if (events[i].kind == S2K_EVENT_INPUT) {
                if (events[i].controller.state.buttons & S2K_BUTTON_A) pressed = true;
                else if (pressed) released = true;
            }
            if (events[i].kind == S2K_EVENT_DISCONNECTED) disconnected = true;
        }
    };
    auto until = [&](auto predicate, double seconds, const char* description) {
        const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
        do {
            read(); if (predicate()) return;
            std::this_thread::sleep_for(std::chrono::milliseconds(2));
        } while (std::chrono::steady_clock::now() < end);
        std::fprintf(stderr, "status: running=%u stopping=%u bt=%u discovery=%u controllers=%u\n",
                     snapshot.running, snapshot.stopping, snapshot.bluetooth, snapshot.discovery, snapshot.count);
        require(false, description);
    };
    read(); require(!snapshot.running && !snapshot.count, "creation does not start radio");
    require(s2k_start(context) == S2K_OK, "start");
    if (!std::strcmp(scenario, "no-adapter") || !std::strcmp(scenario, "denied") || !std::strcmp(scenario, "match-denied") || !std::strcmp(scenario, "no-bus") || !std::strcmp(scenario, "oversized")) {
        const uint32_t expected = (!std::strcmp(scenario, "denied") || !std::strcmp(scenario, "match-denied")) ? S2K_BT_UNAUTHORIZED : S2K_BT_UNSUPPORTED;
        until([&] { return snapshot.bluetooth == expected; }, 3, "explicit unavailable/permission status");
    } else {
        until([&] { return snapshot.bluetooth == S2K_BT_ON; }, 3, "adapter on");
        require(s2k_discover(context, 5) == S2K_OK, "discover");
        if (!std::strcmp(scenario, "cached") || !std::strcmp(scenario, "foreign") || !std::strcmp(scenario, "wrong-company") || !std::strcmp(scenario, "adapter-switch")) {
            std::this_thread::sleep_for(std::chrono::milliseconds(400)); read();
            require(snapshot.count == 0, "cached/foreign/unrecognized device not claimed");
            if (!std::strcmp(scenario, "adapter-switch")) {
                // Radio reset closes the manual discovery window by policy.
                until([&] { return snapshot.bluetooth == S2K_BT_ON; }, 2, "replacement adapter ready");
                require(s2k_discover(context, 5) == S2K_OK, "discover on replacement adapter");
                std::this_thread::sleep_for(std::chrono::milliseconds(600));
            }
        } else if (!std::strcmp(scenario, "cancel-connect") || !std::strcmp(scenario, "cancel-scan")) {
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
        } else if (!std::strcmp(scenario, "notify-denied") || !std::strcmp(scenario, "short-mtu") || !std::strcmp(scenario, "write-error")) {
            until([&] { return disconnected; }, 3, "failed handshake disconnects");
            require(snapshot.count == 0, "failed handshake cannot become ready");
        } else {
            until([&] { return snapshot.count == 1 && pressed && released; }, 5, "handshake and ordered input edges");
            if (!std::strcmp(scenario, "service-reset")) {
                until([&] { return disconnected && snapshot.count == 0; }, 3, "service invalidation retires controller");
                require(s2k_stop(context) == S2K_OK, "stop after invalidation");
                s2k_destroy(context);
                std::this_thread::sleep_for(std::chrono::milliseconds(200));
                std::puts("PASS service invalidation neutralizes input");
                return 0;
            }
            const auto first = snapshot.controllers[0];
            require(first.model == model, "model round trip");
            require(first.state.present & S2K_HAS_MOTION, "raw motion preserved");
            require(first.state.accel[0] == 123 && first.state.gyro[0] == -456, "motion values preserved");
            if (model == S2K_GAMECUBE) require(first.state.left_travel > 0 && first.state.left_travel < 1, "analog trigger");
            require(s2k_pulse_rumble(context, &first.id, &first.connection_id, 1, 0, 0.05) == S2K_OK, "rumble");
            std::this_thread::sleep_for(std::chrono::milliseconds(180));
            require(s2k_disconnect(context, &first.id, &first.connection_id, 0) == S2K_OK, "disconnect");
            until([&] { return snapshot.count == 0; }, 2, "disconnect clears controller state");
            require(s2k_set_rumble(context, &first.id, &first.connection_id, 1, 0) == S2K_NOT_READY, "stale generation rejected");
            // The transport deliberately throttles reconnects. Discovery remains explicit.
            std::this_thread::sleep_for(std::chrono::milliseconds(2150));
            pressed = false; released = false;
            require(s2k_discover(context, 5) == S2K_OK, "rediscover");
            until([&] { return snapshot.count == 1 && pressed && released; }, 4, "reconnect");
            require(std::memcmp(&first.id, &snapshot.controllers[0].id, sizeof(S2KID)) == 0, "stable physical identity");
            require(std::memcmp(&first.connection_id, &snapshot.controllers[0].connection_id, sizeof(S2KID)) != 0, "new connection identity");
            require(s2k_set_rumble(context, &first.id, &first.connection_id, 1, 0) == S2K_NOT_READY, "old handle cannot control replacement");
        }
    }
    require(s2k_stop(context) == S2K_OK, "stop");
    until([&] { return !snapshot.running && !snapshot.stopping && !snapshot.count; }, 3, "terminal stop snapshot");
    // Delayed Connect/StartDiscovery completions must not republish input after stop.
    std::this_thread::sleep_for(std::chrono::milliseconds(700)); read();
    require(!snapshot.running && !snapshot.count, "no post-stop input");
    s2k_destroy(context);
    std::this_thread::sleep_for(std::chrono::milliseconds(150));
    std::printf("PASS Linux BlueZ: %s, model 0x%x\n", scenario, model);
}
