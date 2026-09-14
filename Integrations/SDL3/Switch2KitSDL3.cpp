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
constexpr Uint64 motionGapNS = 100000000; // Admission bound, not a claimed sensor rate.
constexpr const char* motionOwner = "Switch2Kit.motion.owner";
constexpr const char* motionStatus = "Switch2Kit.motion.status";
constexpr const char* motionEpoch = "Switch2Kit.motion.epoch";
constexpr const char* motionFloor = "Switch2Kit.motion.valid-since-ns";
constexpr const char* motionTime = "Switch2Kit.motion.receive-ns";
constexpr const char* motionSequence = "Switch2Kit.motion.sequence";
constexpr const char* motionLedger = "Switch2Kit.motion.event-ledger";
// Sequence metadata only, never sensor contents. This bounded lookup lets a host
// detect SDL event loss as well as engine gaps after draining a multi-report batch.
struct MotionLedger {
    struct Entry { Uint64 timestamp{}, sequence{}; };
    std::array<Entry, S2K_EVENT_CAPACITY> entries{};
    size_t next{};
    Uint64 floorSequence{};
};
void SDLCALL deleteMotionLedger(void*, void* value) { delete static_cast<MotionLedger*>(value); }
void invalidateProperties(SDL_PropertiesID properties, SDL3MotionStatus status) {
    if (auto* ledger = static_cast<MotionLedger*>(SDL_GetPointerProperty(properties, motionLedger, nullptr)))
        *ledger = {};
    const auto previous = SDL_GetNumberProperty(properties, motionEpoch, 0);
    SDL_SetNumberProperty(properties, motionEpoch, previous == SDL_MAX_SINT64 ? 1 : previous + 1);
    SDL_SetNumberProperty(properties, motionStatus, static_cast<Sint64>(status));
    SDL_SetNumberProperty(properties, motionFloor, 0);
    SDL_SetNumberProperty(properties, motionTime, 0);
    SDL_SetNumberProperty(properties, motionSequence, 0);
}
// Correlate clocks after reading the input batch. Do not cast uptime (or Unix time)
// to SDL nanoseconds. Only a bounded recent receive-time delta is converted. A
// slow bracket is unusable, and sleep/wake clock disagreement breaks continuity.
// The lower bracket is conservative: a receive timestamp cannot become future
// delivery time due to midpoint estimation. A segment advances from one seed
// using bounded receive deltas, so repeated correlations do not add clock jitter.
struct ClockPair {
    double receive{};
    Uint64 ticks{};
    bool valid{};
    static ClockPair sample() {
        const auto before = SDL_GetTicksNS();
        const auto receive = s2k_monotonic_time();
        const auto after = SDL_GetTicksNS();
        return {receive, before,
                std::isfinite(receive) && receive >= 0 && after >= before && after - before <= 1000000};
    }
    bool map(double received, Uint64& result) const {
        if (!valid || !std::isfinite(received) || received < 0 || received > receive) return false;
        const double age = (receive - received) * 1e9;
        if (!std::isfinite(age) || age > static_cast<double>(motionGapNS)) return false;
        const auto delta = static_cast<Uint64>(age);
        if (delta >= ticks || ticks > static_cast<Uint64>(SDL_MAX_SINT64)) return false;
        result = ticks - delta;
        return true;
    }
};
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
    // These fields are accessed only under SDL's joystick lock, never on Bluetooth.
    SDL_PropertiesID motionProperties{};
    Uint64 sensorRevision{};
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
static bool SDLCALL sensors(void* data, bool enabled) {
    auto& c = **static_cast<SharedControl*>(data);
    std::lock_guard<std::mutex> lock(c.mutex);
    if (!c.context) return false;
    ++c.sensorRevision;
    if (c.motionProperties)
        invalidateProperties(c.motionProperties, enabled ? SDL3MotionStatus::Waiting : SDL3MotionStatus::Disabled);
    // The C context uses the compatibility sensor setup, recorded by the profile.
    // This callback gates delivery, not a second protocol/configuration backend.
    // SDL calls it for the aggregate first-enable/last-disable, not for each type.
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
        S2KMotionCalibration calibration{};
        bool hasProfile = false;
        unsigned sensorMask{};
        Uint64 sensorRevision{}, previousTime{}, previousSequence{}, lastArrival{};
        double previousReceive{}, highReceive{};
        uint64_t highSequence{};
        bool seeded = false;

    };
    S2KContext* context;
    std::map<Key, Device> devices;
    std::map<Key, S2KMotionProfile> profiles;
    std::map<Key, bool> replacements; // At most one pending replacement per retained device.
    ClockPair previousClock{};
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
        invalidate(d, SDL3MotionStatus::Waiting);
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
        const auto selected = profiles.find(key(c.id));
        if (selected != profiles.end()) {
            const auto result = s2k_motion_profile_calibration(&selected->second, &c, &d.calibration, sizeof(d.calibration));
            d.hasProfile = result == S2K_OK;
            if (!d.hasProfile) error = result;
        }
        const SDL_VirtualJoystickSensorDesc sensorDescriptions[] = {{SDL_SENSOR_ACCEL, 0}, {SDL_SENSOR_GYRO, 0}};
        if (d.hasProfile) {
            desc.nsensors = 2; desc.sensors = sensorDescriptions; desc.SetSensorsEnabled = sensors;
        }
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
        d.control->motionProperties = SDL_GetJoystickProperties(d.joystick);
        if (d.hasProfile && !SDL_SetPointerPropertyWithCleanup(d.control->motionProperties, motionLedger,
                new MotionLedger{}, deleteMotionLedger, nullptr)) {
            // SDL invokes the cleanup callback even when setting the property fails.
            SDL_CloseJoystick(d.joystick); SDL_DetachVirtualJoystick(d.instance);
            error = S2K_INTERNAL_ERROR; return nullptr;
        }
        SDL_SetBooleanProperty(d.control->motionProperties, motionOwner, true);
        invalidate(d, d.hasProfile ? SDL3MotionStatus::Disabled : selected == profiles.end() ?
                   SDL3MotionStatus::UnavailableProfile : SDL3MotionStatus::InvalidCalibration);
        auto [added, inserted] = devices.emplace(key(c.id), std::move(d));
        (void)inserted;
        return &added->second;
    }
    void invalidate(Device& d, SDL3MotionStatus status) {
        d.seeded = false; d.previousTime = d.previousSequence = d.lastArrival = 0;
        d.previousReceive = 0;
        if (d.control->motionProperties) invalidateProperties(d.control->motionProperties, status);
    }
    unsigned enabledSensors(const Device& d) const {
        auto* gamepad = SDL_GetGamepadFromID(d.instance); // Borrowed; no extra open/enable.
        return !d.hasProfile || !gamepad ? 0 :
            (SDL_GamepadSensorEnabled(gamepad, SDL_SENSOR_ACCEL) ? 1u : 0u) |
            (SDL_GamepadSensorEnabled(gamepad, SDL_SENSOR_GYRO) ? 2u : 0u);
    }
    void refreshSensors(Device& d, bool active, Uint64 now) {
        if (!d.hasProfile) return;
        const auto mask = enabledSensors(d);
        if (mask != d.sensorMask || d.sensorRevision != d.control->sensorRevision) {
            d.sensorMask = mask; d.sensorRevision = d.control->sensorRevision;
            invalidate(d, mask ? SDL3MotionStatus::Waiting : SDL3MotionStatus::Disabled);
        } else if ((!active && d.seeded) || (d.lastArrival && (now < d.lastArrival || now - d.lastArrival > motionGapNS))) {
            invalidate(d, mask ? SDL3MotionStatus::Waiting : SDL3MotionStatus::Disabled);
        }
    }
    void motion(Device& d, const S2KState& s, bool active, const ClockPair& clock) {
        refreshSensors(d, active, clock.ticks);
        if (!d.hasProfile || !d.sensorMask || !active) return;
        const auto fail = [&] { invalidate(d, SDL3MotionStatus::Waiting); };
        Uint64 timestamp{};
        if (!s.sequence || s.sequence <= d.highSequence || !std::isfinite(s.received_at) || s.received_at <= d.highReceive) { fail(); return; }
        d.highSequence = s.sequence;
        // Do not poison the receive high-water with a future or non-monotonic clock.
        if (clock.map(s.received_at, timestamp)) d.highReceive = s.received_at;
        if (!(s.present & S2K_HAS_MOTION) || !s.sequence || !clock.map(s.received_at, timestamp)) { fail(); return; }
        // The known raw format is signed-16-bit. Rail hits are unusable; absence or
        // clipping is not a stationary zero. Neither raw values nor identifiers log.
        for (const auto value : {s.accel[0], s.accel[1], s.accel[2], s.gyro[0], s.gyro[1], s.gyro[2]})
            if (value == -32768 || value == 32767) { fail(); return; }
        if (d.seeded) {
            // Advance from the segment's existing correlation. Re-correlating each
            // fast report can move a timestamp backwards merely due to call jitter.
            const double elapsed = (s.received_at - d.previousReceive) * 1e9;
            if (s.sequence - d.previousSequence != 1 || elapsed > motionGapNS) fail();
            else {
                const auto delta = static_cast<Uint64>(std::llround(elapsed));
                if (!delta || d.previousTime > static_cast<Uint64>(SDL_MAX_SINT64) - delta) { fail(); return; }
                const auto stable = d.previousTime + delta;
                const auto disagreement = stable > timestamp ? stable - timestamp : timestamp - stable;
                if (disagreement > 5000000) fail();
                else timestamp = stable;
            }
        }
        S2KCalibratedMotion sample{};
        if (s2k_convert_motion(&s, &d.calibration, &sample, sizeof(sample)) != S2K_OK) { fail(); return; }
        const float acceleration[] = {static_cast<float>(sample.acceleration[0]), static_cast<float>(sample.acceleration[1]), static_cast<float>(sample.acceleration[2])};
        const float gyro[] = {static_cast<float>(sample.angular_velocity[0]), static_cast<float>(sample.angular_velocity[1]), static_cast<float>(sample.angular_velocity[2])};
        for (const auto value : {acceleration[0], acceleration[1], acceleration[2], gyro[0], gyro[1], gyro[2]})
            if (!std::isfinite(value)) { fail(); return; }
        d.previousSequence = s.sequence; d.previousReceive = s.received_at;
        d.previousTime = timestamp; d.lastArrival = clock.ticks;
        if (!d.seeded) {
            d.seeded = true;
            SDL_SetNumberProperty(d.control->motionProperties, motionFloor, static_cast<Sint64>(timestamp));
            auto* ledger = static_cast<MotionLedger*>(SDL_GetPointerProperty(d.control->motionProperties, motionLedger, nullptr));
            ledger->floorSequence = s.sequence;
            return; // First report establishes a receive-time baseline; never integrate across a gap.
        }
        bool sent = true;
        if (d.sensorMask & 1) sent = SDL_SendJoystickVirtualSensorData(d.joystick, SDL_SENSOR_ACCEL, timestamp, acceleration, 3);
        if (sent && (d.sensorMask & 2)) sent = SDL_SendJoystickVirtualSensorData(d.joystick, SDL_SENSOR_GYRO, timestamp, gyro, 3);
        if (!sent) { fail(); error = S2K_INTERNAL_ERROR; }
        else {
            auto* ledger = static_cast<MotionLedger*>(SDL_GetPointerProperty(d.control->motionProperties, motionLedger, nullptr));
            ledger->entries[ledger->next] = {timestamp, s.sequence};
            ledger->next = (ledger->next + 1) % ledger->entries.size();
            SDL_SetNumberProperty(d.control->motionProperties, motionTime, static_cast<Sint64>(timestamp));
            SDL_SetNumberProperty(d.control->motionProperties, motionSequence, static_cast<Sint64>(std::min(s.sequence, static_cast<uint64_t>(SDL_MAX_SINT64))));
            SDL_SetNumberProperty(d.control->motionProperties, motionStatus, static_cast<Sint64>(SDL3MotionStatus::Active));
        }
        // The caller's per-report input flush also commits at most these two sensor
        // entries. No unbounded SDL virtual-sensor staging accumulates across reports.
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
            if (auto* d = ensure(c, active, now)) {
                if (d->hasProfile) invalidate(*d, enabledSensors(*d) ? SDL3MotionStatus::Waiting : SDL3MotionStatus::Disabled);
                d->highSequence = std::max(d->highSequence, c.state.sequence);
                if (std::isfinite(c.state.received_at) && c.state.received_at <= s2k_monotonic_time())
                    d->highReceive = std::max(d->highReceive, c.state.received_at);
                apply(*d, c.state, active); // State reconciliation is never a fresh motion sample.
            }
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
            if (stalled || active != wasActive) {
                stopEffect(d, active, now);
                if (d.hasProfile) invalidate(d, enabledSensors(d) ? SDL3MotionStatus::Waiting : SDL3MotionStatus::Disabled);
            }
            refreshSensors(d, active, now);
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
        const auto clock = ClockPair::sample();
        bool clockGap = !clock.valid;
        if (previousClock.valid && clock.valid) {
            const double hostDelta = clock.receive - previousClock.receive;
            const double sdlDelta = clock.ticks >= previousClock.ticks ? (clock.ticks - previousClock.ticks) / 1e9 : -1;
            clockGap = hostDelta < 0 || sdlDelta < 0 || std::abs(hostDelta - sdlDelta) > 0.005;
        }
        previousClock = clock;
        if (clockGap) for (auto& [id, d] : devices) {
            (void)id;
            if (d.hasProfile) invalidate(d, enabledSensors(d) ? SDL3MotionStatus::Waiting : SDL3MotionStatus::Disabled);
        }
        for (const auto& [id, unused] : replacements) {
            (void)unused;
            const auto found = devices.find(id); if (found != devices.end()) remove(found);
        }
        if (!replacements.empty()) {
            for (uint32_t i = 0; i < snapshot.count; ++i) {
                const auto& c = snapshot.controllers[i];
                if (replacements.count(key(c.id))) if (auto* d = ensure(c, active, now)) {
                    d->highSequence = c.state.sequence;
                    if (std::isfinite(c.state.received_at) && c.state.received_at <= clock.receive) d->highReceive = c.state.received_at;
                    apply(*d, c.state, active);
                }
            }
            replacements.clear();
        }
        if (flags & S2K_READ_RESYNC) reconcile(active, now);
        else for (uint32_t i = 0; i < count; ++i) {
            const auto& event = events[i];
            if (event.kind == S2K_EVENT_CONNECTED || event.kind == S2K_EVENT_INPUT) {
                if (auto* d = ensure(event.controller, active, now)) {
                    if (event.kind == S2K_EVENT_INPUT && !clockGap) motion(*d, event.controller.state, active, clock);
                    apply(*d, event.controller.state, active);
                }
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
S2KResult SDL3Adapter::installMotionProfile(const S2KMotionProfile& profile) {
    JoystickLock lock;
    if (impl->pumping) return S2K_BUSY;
    S2KMotionCalibration calibration{};
    const auto result = s2k_motion_profile_calibration(&profile, nullptr, &calibration, sizeof(calibration));
    if (result != S2K_OK) return result;
    const auto id = key(profile.device);
    for (uint32_t i = 0; i < impl->snapshot.count; ++i) {
        const auto& controller = impl->snapshot.controllers[i];
        if (key(controller.id) == id) {
            const auto compatible = s2k_motion_profile_calibration(&profile, &controller, &calibration, sizeof(calibration));
            if (compatible != S2K_OK) return compatible;
        }
    }
    const auto old = impl->profiles.find(id);
    if (old != impl->profiles.end() && std::memcmp(&old->second, &profile, sizeof(profile)) == 0) return S2K_OK;
    if (old == impl->profiles.end() && impl->profiles.size() >= S2K_MAX_CONTROLLERS) return S2K_QUEUE_FULL;
    impl->profiles[id] = profile;
    if (impl->devices.count(id)) impl->replacements[id] = true;
    return S2K_OK;
}
void SDL3Adapter::removeMotionProfile(const S2KID& physical) {
    JoystickLock lock;
    const auto id = key(physical);
    if (impl->profiles.erase(id) && impl->devices.count(id)) impl->replacements[id] = true;
}
SDL3MotionState SDL3Adapter::motionState(SDL_JoystickID instance) {
    JoystickLock lock;
    SDL3MotionState state{};
    auto* joystick = SDL_GetJoystickFromID(instance);
    if (!joystick || !SDL_JoystickConnected(joystick)) return state;
    const auto properties = SDL_GetJoystickProperties(joystick);
    state.owned = SDL_GetBooleanProperty(properties, motionOwner, false);
    if (!state.owned) return state;
    state.status = static_cast<SDL3MotionStatus>(SDL_GetNumberProperty(properties, motionStatus, 0));
    state.epoch = static_cast<Uint64>(SDL_GetNumberProperty(properties, motionEpoch, 0));
    state.validSinceNS = static_cast<Uint64>(SDL_GetNumberProperty(properties, motionFloor, 0));
    state.timestampNS = static_cast<Uint64>(SDL_GetNumberProperty(properties, motionTime, 0));
    state.sequence = static_cast<Uint64>(SDL_GetNumberProperty(properties, motionSequence, 0));
    if (const auto* ledger = static_cast<const MotionLedger*>(SDL_GetPointerProperty(properties, motionLedger, nullptr)))
        state.validSinceSequence = ledger->floorSequence;
    const auto now = SDL_GetTicksNS();
    if (state.status == SDL3MotionStatus::Active && (!state.timestampNS || now < state.timestampNS || now - state.timestampNS > motionGapNS))
        state.status = SDL3MotionStatus::Waiting;
    return state;
}
SDL3MotionState SDL3Adapter::motionStateAt(SDL_JoystickID instance, Uint64 sensorTimestamp) {
    JoystickLock lock;
    auto state = motionState(instance);
    if (state.status != SDL3MotionStatus::Active) return state;
    const auto now = SDL_GetTicksNS();
    if (!sensorTimestamp || now < sensorTimestamp || now - sensorTimestamp > motionGapNS) {
        state.status = SDL3MotionStatus::Waiting; state.timestampNS = state.sequence = 0;
        return state; // A fresh latest report does not make an older queued event fresh.
    }
    auto* joystick = SDL_GetJoystickFromID(instance);
    const auto* ledger = static_cast<const MotionLedger*>(SDL_GetPointerProperty(SDL_GetJoystickProperties(joystick), motionLedger, nullptr));
    if (ledger && sensorTimestamp > state.validSinceNS) {
        const auto entry = std::find_if(ledger->entries.begin(), ledger->entries.end(),
            [sensorTimestamp](const auto& value) { return value.timestamp == sensorTimestamp; });
        if (entry != ledger->entries.end()) {
            state.timestampNS = entry->timestamp; state.sequence = entry->sequence;
            return state;
        }
    }
    state.status = SDL3MotionStatus::Waiting; state.timestampNS = state.sequence = 0;
    return state; // Unknown/evicted/old-epoch events are not measurements to integrate.
}
const char* SDL3Adapter::motionStatusText(SDL3MotionStatus status) {
    switch (status) {
    case SDL3MotionStatus::UnavailableProfile: return "Motion unavailable: choose a measured device profile";
    case SDL3MotionStatus::Disabled: return "Motion sensor disabled";
    case SDL3MotionStatus::Waiting: return "Waiting for usable motion samples";
    case SDL3MotionStatus::Active: return "Calibrated motion active (host receive timing)";
    case SDL3MotionStatus::InvalidCalibration: return "Invalid or incompatible motion calibration";
    }
    return "Motion unavailable";
}

}
