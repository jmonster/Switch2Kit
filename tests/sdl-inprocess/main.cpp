#include <Switch2KitSDL3.hpp>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <vector>
extern "C" {
S2KContext* test_input_create();
void test_input_report(S2KContext*, int32_t, uint32_t, const S2KState*);
void test_input_retire(S2KContext*, int32_t);
uint32_t test_input_rumble(S2KContext*, int32_t, double*, double*);
}
static S2KID physical(int index) { S2KID id{}; id.bytes[15] = static_cast<uint8_t>(index + 1); return id; }
static void discardEvents() { SDL_Event e; while (SDL_PollEvent(&e)) {} }
int main() {
    SDL_SetHint(SDL_HINT_JOYSTICK_HIDAPI, "0");
    SDL_SetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");
    assert(SDL_Init(SDL_INIT_GAMEPAD));
    auto* context = test_input_create(); assert(context && s2k_start(context) == S2K_OK);
    {
        Switch2Kit::SDL3Adapter adapter(context);
        std::array<uint32_t, 4> models{S2K_PRO, S2K_GAMECUBE, S2K_JOYCON_LEFT, S2K_JOYCON_RIGHT};
        std::array<S2KState, 4> input{};
        for (int i = 0; i < 4; ++i) { input[i].sequence = 1; test_input_report(context, i, models[i], &input[i]); }
        assert(adapter.pump() == S2K_OK && adapter.snapshot().count == 4);
        std::array<SDL_Gamepad*, 4> pads{};
        for (int i = 0; i < 4; ++i) {
            auto instance = adapter.instance(physical(i)); assert(instance && SDL_IsGamepad(instance));
            pads[i] = SDL_OpenGamepad(instance); assert(pads[i]);
            S2KID id{}, connection{}; assert(adapter.identity(instance, &id, &connection));
            assert(id.bytes[15] == i + 1);
            assert(!SDL_GamepadHasSensor(pads[i], SDL_SENSOR_GYRO));
        }
        assert(!SDL_GamepadHasAxis(pads[2], SDL_GAMEPAD_AXIS_RIGHTX));
        assert(!SDL_GamepadHasAxis(pads[3], SDL_GAMEPAD_AXIS_LEFTX));
        std::puts("PASS actual SDL3 enumeration, all four models, physical identity and field availability");
        discardEvents();
        input[0].sequence++; input[0].buttons = S2K_BUTTON_A;
        test_input_report(context, 0, models[0], &input[0]);
        input[0].sequence++; input[0].buttons = 0;
        test_input_report(context, 0, models[0], &input[0]);
        assert(adapter.pump() == S2K_OK);
        std::vector<bool> edges;
        SDL_Event event{};
        while (SDL_PollEvent(&event)) {
            if ((event.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN || event.type == SDL_EVENT_GAMEPAD_BUTTON_UP) &&
                event.gbutton.which == adapter.instance(physical(0)) && event.gbutton.button == SDL_GAMEPAD_BUTTON_EAST)
                edges.push_back(event.gbutton.down);
        }
        assert((edges == std::vector<bool>{true, false}));
        std::puts("PASS press and release in one native batch cross distinct SDL update boundaries");
        for (int n = 0; n < 256; ++n) {
            auto& s = input[1]; ++s.sequence; s.left_travel = n / 255.0; s.right_travel = (255 - n) / 255.0;
            s.left_pressed = n % 2; s.buttons = s.left_pressed ? S2K_BUTTON_ZL : 0;
            s.left_y = 1; s.right_x = -1;
            test_input_report(context, 1, models[1], &s); assert(adapter.pump() == S2K_OK);
            assert(std::abs(SDL_GetGamepadAxis(pads[1], SDL_GAMEPAD_AXIS_LEFT_TRIGGER) / 32767.0 - s.left_travel) < 0.0001);
            assert(SDL_GetGamepadButton(pads[1], SDL_GAMEPAD_BUTTON_MISC3) == (n % 2 != 0));
            assert(SDL_GetGamepadAxis(pads[1], SDL_GAMEPAD_AXIS_LEFTY) == -32768);
            assert(SDL_GetGamepadAxis(pads[1], SDL_GAMEPAD_AXIS_RIGHTX) == -32768);
        }
        input[0].left_pressed = 1; input[0].buttons = S2K_BUTTON_ZL; ++input[0].sequence;
        test_input_report(context, 0, models[0], &input[0]); assert(adapter.pump() == S2K_OK);
        assert(SDL_GetGamepadAxis(pads[0], SDL_GAMEPAD_AXIS_LEFT_TRIGGER) == 32767);
        assert(SDL_GetGamepadButton(pads[0], SDL_GAMEPAD_BUTTON_MISC3));
        input[0].buttons = 0; input[0].left_pressed = 0;
        input[2].buttons = S2K_BUTTON_SL_L | S2K_BUTTON_C; ++input[2].sequence;
        test_input_report(context, 2, models[2], &input[2]); assert(adapter.pump() == S2K_OK);
        assert(SDL_GetGamepadButton(pads[2], SDL_GAMEPAD_BUTTON_LEFT_PADDLE1));
        assert(SDL_GetGamepadButton(pads[2], SDL_GAMEPAD_BUTTON_MISC2));
        std::puts("PASS 256 independent GameCube trigger travels/clicks, digital triggers, axis orientation and extra buttons");
        for (int n = 0; n < 10000; ++n) {
            ++input[0].sequence; input[0].buttons = n % 2 ? 0 : S2K_BUTTON_A;
            test_input_report(context, 0, models[0], &input[0]);
        }
        assert(adapter.pump() == S2K_OK);
        assert(!SDL_GetGamepadButton(pads[0], SDL_GAMEPAD_BUTTON_EAST));
        std::puts("PASS 10,000-report overflow resynchronizes actual SDL held controls");
        discardEvents();
        double strong{}, weak{};
        assert(SDL_RumbleGamepad(pads[0], 32768, 16384, 5000));
        assert(test_input_rumble(context, 0, &strong, &weak) > 0);
        assert(strong > 0.49 && weak > 0.24);
        // Renewal and stall boundaries are tested with the clocked adapter in
        // motion.cpp. A descheduled clock-read bracket legitimately fails closed
        // in this production-clock consumer, even without a 500 ms host stall.
        assert(SDL_RumbleGamepad(pads[0], 30000, 20000, 20));
        SDL_Delay(40); assert(adapter.pump() == S2K_OK);
        test_input_rumble(context, 0, &strong, &weak); assert(strong == 0 && weak == 0);
        assert(SDL_GetBooleanProperty(SDL_GetGamepadProperties(pads[1]), SDL_PROP_GAMEPAD_CAP_RUMBLE_BOOLEAN, false));
        assert(SDL_RumbleGamepad(pads[1], 30000, 0, 20));
        test_input_rumble(context, 1, &strong, &weak); assert(strong > 0 && weak == 0);
        SDL_Delay(40); assert(adapter.pump() == S2K_OK);
        test_input_rumble(context, 1, &strong, &weak); assert(strong == 0 && weak == 0);
        auto gc = adapter.snapshot().controllers[1];
        assert(s2k_play_feedback(context, &gc.id, &gc.connection_id, 0.25) == S2K_OK);
        std::puts("PASS real-clock SDL rumble delivery, duration expiry and distinct GameCube feedback capability");
        input[0].buttons = S2K_BUTTON_A; ++input[0].sequence;
        test_input_report(context, 0, models[0], &input[0]); assert(adapter.pump() == S2K_OK);
        assert(SDL_GetGamepadButton(pads[0], SDL_GAMEPAD_BUTTON_EAST));
        assert(adapter.pump(false) == S2K_OK && !SDL_GetGamepadButton(pads[0], SDL_GAMEPAD_BUTTON_EAST));
        assert(adapter.pump(true) == S2K_OK);
        ++input[0].sequence; test_input_report(context, 0, models[0], &input[0]); assert(adapter.pump() == S2K_OK);
        assert(!SDL_GetGamepadButton(pads[0], SDL_GAMEPAD_BUTTON_EAST));
        input[0].buttons = 0; ++input[0].sequence; test_input_report(context, 0, models[0], &input[0]); assert(adapter.pump() == S2K_OK);
        input[0].buttons = S2K_BUTTON_A; ++input[0].sequence; test_input_report(context, 0, models[0], &input[0]); assert(adapter.pump() == S2K_OK);
        assert(SDL_GetGamepadButton(pads[0], SDL_GAMEPAD_BUTTON_EAST));
        std::puts("PASS inactive release and per-controller neutral rearming");
        SDL_VirtualJoystickDesc otherDesc{}; SDL_INIT_INTERFACE(&otherDesc);
        otherDesc.type = SDL_JOYSTICK_TYPE_GAMEPAD; otherDesc.nbuttons = 4;
        auto other = SDL_AttachVirtualJoystick(&otherDesc); assert(other);
        assert(!adapter.identity(other, nullptr, nullptr));
        auto oldInstance = adapter.instance(physical(0));
        test_input_retire(context, 0);
        input[0] = S2KState{}; input[0].sequence = 1; test_input_report(context, 0, models[0], &input[0]);
        assert(adapter.pump() == S2K_OK);
        assert(!SDL_GamepadConnected(pads[0]) && adapter.instance(physical(0)) != oldInstance);
        assert(SDL_IsJoystickVirtual(other));
        for (auto* pad : pads) SDL_CloseGamepad(pad);
        // Reverse reconnect order for identical models; physical identity must not swap.
        S2KState neutralState{}; neutralState.sequence = 1;
        test_input_report(context, 4, S2K_PRO, &neutralState); test_input_report(context, 5, S2K_PRO, &neutralState);
        assert(adapter.pump() == S2K_OK);
        test_input_retire(context, 4); test_input_retire(context, 5);
        test_input_report(context, 5, S2K_PRO, &neutralState); test_input_report(context, 4, S2K_PRO, &neutralState);
        assert(adapter.pump() == S2K_OK);
        for (int i : {4, 5}) {
            S2KID id{}; assert(adapter.identity(adapter.instance(physical(i)), &id, nullptr)); assert(id.bytes[15] == i + 1);
        }
        assert(s2k_stop(context) == S2K_OK && adapter.pump() == S2K_OK);
        assert(adapter.instance(physical(0)) == 0 && SDL_IsJoystickVirtual(other));
        SDL_DetachVirtualJoystick(other);
        std::puts("PASS generation replacement, reverse reconnect, stop and unrelated SDL device preservation");
    }
    s2k_destroy(context); SDL_Quit();
}
