#include "Switch2KitSDL3.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <stdexcept>
#include <string>

namespace Switch2Kit {
namespace {
struct JoystickLock {
    JoystickLock() { SDL_LockJoysticks(); }
    ~JoystickLock() { SDL_UnlockJoysticks(); }
};
using Key = std::array<uint8_t, 16>;
Key key(const S2KID& id) { Key k{}; std::copy_n(id.bytes, 16, k.begin()); return k; }
bool equal(const S2KID& a, const S2KID& b) { return std::memcmp(a.bytes, b.bytes, 16) == 0; }
constexpr Uint64 staleNS = 500000000;
constexpr Uint64 refreshNS = 200000000;
Sint16 axis(double value) {
    if (!std::isfinite(value)) return 0;
    value = std::clamp(value, -1.0, 1.0);
    return static_cast<Sint16>(std::lround(value * (value < 0 ? 32768.0 : 32767.0)));
}
Sint16 travel(double value) {
    return axis(2 * std::clamp(std::isfinite(value) ? value : 0.0, 0.0, 1.0) - 1);
}
bool neutral(const S2KState& s) {
    return !s.buttons && !s.left_pressed && !s.right_pressed &&
        std::abs(s.left_x) < 0.15 && std::abs(s.left_y) < 0.15 &&
        std::abs(s.right_x) < 0.15 && std::abs(s.right_y) < 0.15 &&
        s.left_travel < 0.05 && s.right_travel < 0.05;
}
const char* name(uint32_t model) {
    switch (model) {
    case S2K_JOYCON_LEFT: return "Switch2Kit Joy-Con 2 (L)";
    case S2K_JOYCON_RIGHT: return "Switch2Kit Joy-Con 2 (R)";
    case S2K_GAMECUBE: return "Switch2Kit GameCube";
    default: return "Switch2Kit Pro Controller 2";
    }
}
// SDL callbacks run under SDL's joystick lock, possibly on another host thread.
// The shared control record outlives detach and is invalidated before context dies.
struct Control {
    S2KContext* context{};
    S2KID id{}, connection{};
    std::mutex mutex;
    bool active = true;
    bool callbackCleaned = false; // Only accessed under SDL joystick lock.
    Uint64 heartbeat{}, renewed{};
    Uint16 strong{}, weak{};
    S2KResult error = S2K_OK;
};
using SharedControl = std::shared_ptr<Control>;
static bool SDLCALL rumble(void* data, Uint16 strong, Uint16 weak) {
    auto& c = **static_cast<SharedControl*>(data);
    std::lock_guard<std::mutex> lock(c.mutex);
    if (!c.context) return false;
    if ((strong || weak) && (!c.active || SDL_GetTicksNS() - c.heartbeat > staleNS)) {
        c.error = S2K_BUSY; return false;
    }
    c.error = s2k_set_rumble(c.context, &c.id, &c.connection, strong / 65535.0, weak / 65535.0);
    if (c.error != S2K_OK) return false;
    c.strong = strong; c.weak = weak; c.renewed = SDL_GetTicksNS();
    return true;
}
static void SDLCALL player(void* data, int number) {
    auto& c = **static_cast<SharedControl*>(data);
    std::lock_guard<std::mutex> lock(c.mutex);
    if (c.context && number >= 0 && number < 8)
        c.error = s2k_set_player(c.context, &c.id, &c.connection, static_cast<uint32_t>(number + 1));
}
static void SDLCALL cleanup(void* data) {
    auto* holder = static_cast<SharedControl*>(data);
    (*holder)->callbackCleaned = true;
    delete holder;
}
}

struct SDL3Adapter::Impl {
    struct Device {
        SDL_JoystickID instance{};
        SDL_Joystick* joystick{};
        SharedControl control;
        std::array<uint32_t, SDL_GAMEPAD_BUTTON_COUNT> buttons{};
        std::array<int, SDL_GAMEPAD_AXIS_COUNT> axes{};
        int buttonCount{}, axisCount{};
        bool armed = true;
        uint64_t lastSequence{};
        uint32_t capabilities{};
    };
    S2KContext* context;
    std::map<Key, Device> devices;
    S2KSnapshot snapshot{};
    S2KResult error = S2K_OK;
    bool wasActive = true;
    bool pumping = false;
    Uint64 lastPump{};
    explicit Impl(S2KContext* value) : context(value) {}

    void stopEffect(Device& d, bool active, Uint64 now) {
        // Cancel SDL's duration as well as native intent. SDL calls rumble with zero.
        if (d.capabilities & S2K_CAP_CONTINUOUS_RUMBLE) SDL_RumbleJoystick(d.joystick, 0, 0, 0);
        auto& c = *d.control;
        std::lock_guard<std::mutex> lock(c.mutex);
        if (c.context && (c.strong || c.weak))
            c.error = s2k_set_rumble(c.context, &c.id, &c.connection, 0, 0);
        c.strong = c.weak = 0; c.active = active; c.heartbeat = now;
    }
    void remove(std::map<Key, Device>::iterator it) {
        auto& d = it->second;
        stopEffect(d, false, SDL_GetTicksNS());
        { std::lock_guard<std::mutex> lock(d.control->mutex); d.control->context = nullptr; }
        SDL_CloseJoystick(d.joystick);
        if (SDL_IsJoystickVirtual(d.instance)) SDL_DetachVirtualJoystick(d.instance);
        devices.erase(it);
    }
    void clear() { JoystickLock lock; while (!devices.empty()) remove(devices.begin()); }

    Device* ensure(const S2KController& c, bool active, Uint64 now) {
        auto it = devices.find(key(c.id));
        if (it != devices.end()) {
            if (equal(it->second.control->connection, c.connection_id) && SDL_JoystickConnected(it->second.joystick))
                return &it->second;
            remove(it);
        }
        if (devices.size() >= S2K_MAX_CONTROLLERS) { error = S2K_QUEUE_FULL; return nullptr; }
        Device d{};
        d.capabilities = c.capabilities; d.armed = active;
        d.control = std::make_shared<Control>();
        d.control->context = context; d.control->id = c.id; d.control->connection = c.connection_id;
        d.control->heartbeat = now; d.control->active = active;
        SDL_VirtualJoystickDesc desc{}; SDL_INIT_INTERFACE(&desc);
        desc.type = SDL_JOYSTICK_TYPE_GAMEPAD; desc.vendor_id = 0x057e;
        desc.product_id = static_cast<Uint16>(c.model); desc.name = name(c.model);
        std::array<uint32_t, SDL_GAMEPAD_BUTTON_COUNT> bits{};
        const bool gc = c.model == S2K_GAMECUBE;
        bits[SDL_GAMEPAD_BUTTON_SOUTH] = gc ? S2K_BUTTON_A : S2K_BUTTON_B;
        bits[SDL_GAMEPAD_BUTTON_EAST] = gc ? S2K_BUTTON_X : S2K_BUTTON_A;
        bits[SDL_GAMEPAD_BUTTON_WEST] = gc ? S2K_BUTTON_B : S2K_BUTTON_Y;
        bits[SDL_GAMEPAD_BUTTON_NORTH] = gc ? S2K_BUTTON_Y : S2K_BUTTON_X;
        bits[SDL_GAMEPAD_BUTTON_BACK] = S2K_BUTTON_MINUS;
        bits[SDL_GAMEPAD_BUTTON_GUIDE] = S2K_BUTTON_HOME;
        bits[SDL_GAMEPAD_BUTTON_START] = S2K_BUTTON_PLUS;
        if (c.capabilities & S2K_CAP_LEFT_STICK) bits[SDL_GAMEPAD_BUTTON_LEFT_STICK] = S2K_BUTTON_L_STICK;
        if (c.capabilities & S2K_CAP_RIGHT_STICK) bits[SDL_GAMEPAD_BUTTON_RIGHT_STICK] = S2K_BUTTON_R_STICK;
        bits[SDL_GAMEPAD_BUTTON_LEFT_SHOULDER] = S2K_BUTTON_L;
        bits[SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER] = S2K_BUTTON_R;
        bits[SDL_GAMEPAD_BUTTON_DPAD_UP] = S2K_BUTTON_UP;
        bits[SDL_GAMEPAD_BUTTON_DPAD_DOWN] = S2K_BUTTON_DOWN;
        bits[SDL_GAMEPAD_BUTTON_DPAD_LEFT] = S2K_BUTTON_LEFT;
        bits[SDL_GAMEPAD_BUTTON_DPAD_RIGHT] = S2K_BUTTON_RIGHT;
        bits[SDL_GAMEPAD_BUTTON_MISC1] = S2K_BUTTON_CAPTURE;
        bits[SDL_GAMEPAD_BUTTON_MISC2] = S2K_BUTTON_C;
        bits[SDL_GAMEPAD_BUTTON_MISC3] = S2K_BUTTON_ZL;
        bits[SDL_GAMEPAD_BUTTON_MISC4] = S2K_BUTTON_ZR;
        bits[SDL_GAMEPAD_BUTTON_MISC5] = S2K_BUTTON_GL;
        bits[SDL_GAMEPAD_BUTTON_MISC6] = S2K_BUTTON_GR;
        if (c.model == S2K_JOYCON_LEFT) {
            bits[SDL_GAMEPAD_BUTTON_LEFT_PADDLE1] = S2K_BUTTON_SL_L;
            bits[SDL_GAMEPAD_BUTTON_LEFT_PADDLE2] = S2K_BUTTON_SR_L;
        }
        if (c.model == S2K_JOYCON_RIGHT) {
            bits[SDL_GAMEPAD_BUTTON_RIGHT_PADDLE1] = S2K_BUTTON_SR_R;
            bits[SDL_GAMEPAD_BUTTON_RIGHT_PADDLE2] = S2K_BUTTON_SL_R;
        }
        for (int i = 0; i < SDL_GAMEPAD_BUTTON_COUNT; ++i) if (bits[i]) {
            desc.button_mask |= 1u << i; d.buttons[d.buttonCount++] = bits[i];
        }
        if (c.capabilities & S2K_CAP_LEFT_STICK)
            desc.axis_mask |= (1u << SDL_GAMEPAD_AXIS_LEFTX) | (1u << SDL_GAMEPAD_AXIS_LEFTY);
        if (c.capabilities & S2K_CAP_RIGHT_STICK)
            desc.axis_mask |= (1u << SDL_GAMEPAD_AXIS_RIGHTX) | (1u << SDL_GAMEPAD_AXIS_RIGHTY);
        desc.axis_mask |= (1u << SDL_GAMEPAD_AXIS_LEFT_TRIGGER) | (1u << SDL_GAMEPAD_AXIS_RIGHT_TRIGGER);
        for (int i = 0; i < SDL_GAMEPAD_AXIS_COUNT; ++i) if (desc.axis_mask & (1u << i)) d.axes[d.axisCount++] = i;
        desc.naxes = static_cast<Uint16>(d.axisCount); desc.nbuttons = static_cast<Uint16>(d.buttonCount);
        desc.userdata = new SharedControl(d.control); desc.Cleanup = cleanup; desc.SetPlayerIndex = player;
        if (c.capabilities & S2K_CAP_CONTINUOUS_RUMBLE) desc.Rumble = rumble;
        d.instance = SDL_AttachVirtualJoystick(&desc);
        // SDL calls Cleanup after copying the descriptor, but early allocation or
        // unavailable-driver failures can return without taking that ownership.
        if (!d.instance) {
            if (!d.control->callbackCleaned) delete static_cast<SharedControl*>(desc.userdata);
            error = S2K_INTERNAL_ERROR; return nullptr;
        }
        d.joystick = SDL_OpenJoystick(d.instance);
        if (!d.joystick) { SDL_DetachVirtualJoystick(d.instance); error = S2K_INTERNAL_ERROR; return nullptr; }
        auto [added, inserted] = devices.emplace(key(c.id), std::move(d));
        (void)inserted;
        return &added->second;
    }
    void apply(Device& d, const S2KState& state, bool active) {
        if (!d.armed && neutral(state)) d.armed = true;
        const S2KState s = active && d.armed ? state : S2KState{};
        for (int i = 0; i < d.buttonCount; ++i)
            if (!SDL_SetJoystickVirtualButton(d.joystick, i, (s.buttons & d.buttons[i]) != 0)) error = S2K_INTERNAL_ERROR;
        const std::array<Sint16, SDL_GAMEPAD_AXIS_COUNT> values{
            axis(s.left_x), axis(-s.left_y), axis(s.right_x), axis(-s.right_y),
            travel(s.present & S2K_HAS_LEFT_TRAVEL ? s.left_travel : s.left_pressed ? 1.0 : 0.0),
            travel(s.present & S2K_HAS_RIGHT_TRAVEL ? s.right_travel : s.right_pressed ? 1.0 : 0.0)};
        for (int i = 0; i < d.axisCount; ++i)
            if (!SDL_SetJoystickVirtualAxis(d.joystick, i, values[d.axes[i]])) error = S2K_INTERNAL_ERROR;
        d.lastSequence = state.sequence;
        SDL_UpdateJoysticks(); // Commit this report BEFORE a subsequent release is staged.
    }
    void reconcile(bool active, Uint64 now) {
        for (auto it = devices.begin(); it != devices.end();) {
            auto found = std::find_if(snapshot.controllers, snapshot.controllers + snapshot.count,
                [&](const auto& c) { return key(c.id) == it->first && equal(c.connection_id, it->second.control->connection); });
            if (found == snapshot.controllers + snapshot.count) { auto old = it++; remove(old); }
            else { stopEffect(it->second, active, now); ++it; }
        }
        for (uint32_t i = 0; i < snapshot.count; ++i) {
            const auto& c = snapshot.controllers[i];
            if (auto* d = ensure(c, active, now)) apply(*d, c.state, active);
        }
    }
    S2KResult pump(bool active) {
        if (pumping) return S2K_BUSY;
        pumping = true;
        struct Reset { bool& value; ~Reset() { value = false; } } reset{pumping};
        JoystickLock lock;
        const auto now = SDL_GetTicksNS();
        error = S2K_OK;
        const bool stalled = lastPump && now - lastPump > staleNS;
        for (auto& [id, d] : devices) {
            (void)id;
            if (stalled || active != wasActive) stopEffect(d, active, now);
            { std::lock_guard<std::mutex> guard(d.control->mutex); d.control->heartbeat = now; d.control->active = active; }
            if (!active || active != wasActive) { d.armed = false; apply(d, S2KState{}, false); d.armed = false; }
        }
        lastPump = now; wasActive = active;
        // SDL first expires finished effects; renewal below must not resurrect one.
        SDL_UpdateJoysticks();
        std::array<S2KEvent, S2K_EVENT_CAPACITY> events{};
        uint32_t count{}, flags{};
        const auto result = s2k_read(context, events.data(), events.size(), sizeof(S2KEvent), &count,
                                     &snapshot, sizeof(snapshot), &flags);
        if (result != S2K_OK) { clear(); return error = result; }
        if (flags & S2K_READ_RESYNC) reconcile(active, now);
        else for (uint32_t i = 0; i < count; ++i) {
            const auto& event = events[i];
            if (event.kind == S2K_EVENT_CONNECTED || event.kind == S2K_EVENT_INPUT) {
                if (auto* d = ensure(event.controller, active, now)) apply(*d, event.controller.state, active);
            } else if (event.kind == S2K_EVENT_DISCONNECTED) {
                auto it = devices.find(key(event.controller.id)); if (it != devices.end()) remove(it);
            } else if (event.kind == S2K_EVENT_ERROR) error = event.detail;
        }
        for (auto& [id, d] : devices) {
            (void)id;
            auto& c = *d.control; std::lock_guard<std::mutex> guard(c.mutex);
            if (c.context && c.active && (c.strong || c.weak) && now >= c.renewed && now - c.renewed >= refreshNS) {
                c.error = s2k_set_rumble(context, &c.id, &c.connection, c.strong / 65535.0, c.weak / 65535.0);
                c.renewed = now;
                if (c.error != S2K_OK) c.strong = c.weak = 0;
            }
            if (c.error != S2K_OK) { error = c.error; c.error = S2K_OK; }
        }
        return error;
    }
};
SDL3Adapter::SDL3Adapter(S2KContext* context) {
    if (!context || !(SDL_WasInit(SDL_INIT_GAMEPAD) & SDL_INIT_GAMEPAD))
        throw std::invalid_argument("SDL3Adapter requires a context and initialized SDL gamepad subsystem");
    impl = std::make_unique<Impl>(context);
}
SDL3Adapter::~SDL3Adapter() { impl->clear(); }
S2KResult SDL3Adapter::pump(bool active) { return impl->pump(active); }
void SDL3Adapter::clear() { impl->clear(); }
const S2KSnapshot& SDL3Adapter::snapshot() const { return impl->snapshot; }
S2KResult SDL3Adapter::lastError() const { return impl->error; }
bool SDL3Adapter::identity(SDL_JoystickID instance, S2KID* physical, S2KID* connection) const {
    for (const auto& [id, d] : impl->devices) {
        (void)id;
        if (d.instance == instance) {
            if (physical) *physical = d.control->id;
            if (connection) *connection = d.control->connection;
            return true;
        }
    }
    return false;
}
SDL_JoystickID SDL3Adapter::instance(const S2KID& physical) const {
    auto it = impl->devices.find(key(physical)); return it == impl->devices.end() ? 0 : it->second.instance;
}
}
