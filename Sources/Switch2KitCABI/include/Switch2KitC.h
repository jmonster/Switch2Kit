#ifndef SWITCH2KIT_C_H
#define SWITCH2KIT_C_H
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** C ABI v1. Only fixed-width scalars and caller-owned structs cross this boundary. */
#define S2K_ABI_VERSION 1u
/** Maximum physical controllers in one snapshot; unrelated to emulator player count. */
#define S2K_MAX_CONTROLLERS 64u
/** Default and maximum queued events. Overflow discards history, never current state. */
#define S2K_EVENT_CAPACITY 256u
/** Opaque owning handle. Do not copy ownership or call any API concurrently with destroy. */
typedef struct S2KContext S2KContext;
/** Synchronous result; asynchronous controller errors are S2K_EVENT_ERROR events. */
typedef int32_t S2KResult;
enum {
    S2K_OK = 0, S2K_INVALID_ARGUMENT = 1, S2K_ABI_MISMATCH = 2,
    S2K_UNSUPPORTED_PLATFORM = 3, S2K_WRONG_THREAD = 4, S2K_BUSY = 5,
    S2K_NOT_READY = 6, S2K_UNSUPPORTED_OPERATION = 7, S2K_QUEUE_FULL = 8,
    S2K_BLUETOOTH_UNAVAILABLE = 9, S2K_PROTOCOL_FAILURE = 10,
    S2K_TIMEOUT = 11, S2K_CONNECTION_FAILED = 12, S2K_INTERNAL_ERROR = 13
};
/** Bluetooth state values, independent of support being started. */
enum { S2K_BT_UNKNOWN, S2K_BT_RESETTING, S2K_BT_UNSUPPORTED,
       S2K_BT_UNAUTHORIZED, S2K_BT_OFF, S2K_BT_ON };
/** Discovery state values. */
enum { S2K_DISCOVERY_STOPPED, S2K_DISCOVERY_SCANNING, S2K_DISCOVERY_CONNECTING,
       S2K_DISCOVERY_PAUSED, S2K_DISCOVERY_CAPACITY };
/** Controller model numbers match Nintendo product IDs. */
enum { S2K_JOYCON_RIGHT = 0x2066, S2K_JOYCON_LEFT = 0x2067,
       S2K_PRO = 0x2069, S2K_GAMECUBE = 0x2073 };
/** Capability bits match Switch2ControllerCapabilities; preserve unknown future bits. */
enum {
    S2K_CAP_BUTTONS = 1u << 0, S2K_CAP_LEFT_STICK = 1u << 1,
    S2K_CAP_RIGHT_STICK = 1u << 2, S2K_CAP_ANALOG_TRIGGERS = 1u << 3,
    S2K_CAP_BATTERY = 1u << 4, S2K_CAP_RAW_MOTION = 1u << 5,
    S2K_CAP_OPTICAL = 1u << 6, S2K_CAP_FEEDBACK = 1u << 7,
    S2K_CAP_PLAYER_LEDS = 1u << 8, S2K_CAP_CONTINUOUS_RUMBLE = 1u << 9,
    S2K_CAP_RUMBLE_PRESETS = 1u << 10
};
/** Button report bits. Analog trigger travel is independent of ZL/ZR clicks. */
enum {
    S2K_BUTTON_Y=0x1, S2K_BUTTON_X=0x2, S2K_BUTTON_B=0x4, S2K_BUTTON_A=0x8,
    S2K_BUTTON_SR_R=0x10, S2K_BUTTON_SL_R=0x20, S2K_BUTTON_R=0x40,
    S2K_BUTTON_ZR=0x80, S2K_BUTTON_MINUS=0x100, S2K_BUTTON_PLUS=0x200,
    S2K_BUTTON_R_STICK=0x400, S2K_BUTTON_L_STICK=0x800, S2K_BUTTON_HOME=0x1000,
    S2K_BUTTON_CAPTURE=0x2000, S2K_BUTTON_C=0x4000,
    S2K_BUTTON_DOWN=0x10000, S2K_BUTTON_UP=0x20000,
    S2K_BUTTON_RIGHT=0x40000, S2K_BUTTON_LEFT=0x80000,
    S2K_BUTTON_SR_L=0x100000, S2K_BUTTON_SL_L=0x200000,
    S2K_BUTTON_L=0x400000, S2K_BUTTON_ZL=0x800000,
    S2K_BUTTON_GR=0x1000000, S2K_BUTTON_GL=0x2000000
};
/** Optional state fields. A zero value is not a substitute for an absent field. */
enum { S2K_HAS_LEFT_STICK=1u, S2K_HAS_RIGHT_STICK=2u, S2K_HAS_LEFT_TRAVEL=4u,
       S2K_HAS_RIGHT_TRAVEL=8u, S2K_HAS_VOLTAGE=16u, S2K_HAS_MOTION=32u,
       S2K_HAS_OPTICAL=64u };
/** UUID bytes in RFC 4122 order, not a string or an integer in host byte order. */
typedef struct S2KID { uint8_t bytes[16]; } S2KID;
/** Complete calibrated input. Sticks: -1..1, right/up positive. Travel: 0..1.
 * Motion is sensor-native signed raw counts, NOT rad/s or m/s^2.
 * received_at is host monotonic seconds since boot, NOT sensor sampling time.
 * sequence is per connection. Padding/reserved fields are zero; do not interpret them.
 */
typedef struct S2KState {
    uint64_t sequence;
    double received_at;
    uint32_t buttons;
    uint32_t present;
    double left_x, left_y, right_x, right_y;
    double left_travel, right_travel;
    double temperature_celsius;
    int16_t accel[3], gyro[3], magnetometer[3];
    int16_t battery_current_raw;
    uint16_t battery_millivolts;
    uint16_t optical_x, optical_y, surface_quality, lift_distance;
    uint8_t left_pressed, right_pressed, charge_state_raw;
    uint8_t reserved[3];
} S2KState;
/** Physical identity persists locally; connection_id changes on every reconnect.
 * No serial number or advertisement payload is exported. */
typedef struct S2KController {
    S2KID id, connection_id;
    uint32_t model, capabilities;
    S2KState state;
} S2KController;
/** Current manager state; only controllers[0..count) are valid. */
typedef struct S2KSnapshot {
    uint32_t abi_version, count;
    uint32_t bluetooth, discovery;
    uint32_t running, stopping;
    double discovery_deadline; /**< Monotonic seconds; zero means no known deadline. */
    S2KController controllers[S2K_MAX_CONTROLLERS];
} S2KSnapshot;
/** Event kinds. A resynchronization is signalled by S2K_READ_RESYNC, not queued events. */
enum { S2K_EVENT_INPUT=1, S2K_EVENT_CONNECTED, S2K_EVENT_DISCONNECTED,
       S2K_EVENT_STATUS, S2K_EVENT_CONNECTION, S2K_EVENT_ERROR, S2K_EVENT_RSSI };
/** Ordered event. controller is complete for INPUT/CONNECTED, otherwise only its id is valid.
 * detail: S2KResult for ERROR, signed dBm for RSSI, connection/disconnection values below.
 */
typedef struct S2KEvent {
    uint32_t kind;
    int32_t detail;
    S2KController controller;
} S2KEvent;
/** Connection phase values in S2K_EVENT_CONNECTION.detail. */
enum { S2K_CONNECTING=1, S2K_HANDSHAKING, S2K_READY, S2K_DISCONNECTED };
/** Disconnection reasons in S2K_EVENT_DISCONNECTED.detail. */
enum { S2K_LINK_LOST=1, S2K_REQUESTED, S2K_FORGOTTEN, S2K_STOPPED,
       S2K_RADIO_UNAVAILABLE, S2K_DISCONNECT_TIMEOUT, S2K_DISCONNECT_PROTOCOL };
/** Read flags. RESYNC: apply snapshot and discard local held controls absent from it.
 * MORE: further queued events remain. Snapshot always represents current state but must
 * not overwrite ordinary events before they have been processed. */
enum { S2K_READ_RESYNC=1u, S2K_READ_MORE=2u };
/** Creation configuration; initialize every field. Event capacity is 1..256, controllers 1..64.
 * The facade defaults to on-demand discovery and does not persist identities or preferences. */
typedef struct S2KConfig {
    uint32_t abi_version, struct_size, maximum_controllers, event_capacity;
} S2KConfig;

/** Returns S2K_ABI_VERSION. Struct layouts are frozen within an ABI version. */
uint32_t s2k_abi_version(void);
/** Create on the main thread; does not start Bluetooth. NULL config uses defaults.
 * On failure returns NULL and writes result when non-NULL. No callbacks into C are used.
 * macOS uses CoreBluetooth; Linux uses BlueZ. Creation opens neither radio.
 * Other host platforms return UNSUPPORTED_PLATFORM.
 */
S2KContext *s2k_create(const S2KConfig *config, S2KResult *result);
/** Release one owning handle (NULL is allowed). Discards pending delivery synchronously,
 * requests transport shutdown, and never calls host code. Stop polling/other calls first.
 * The host must keep the dynamic library loaded for the process lifetime. */
void s2k_destroy(S2KContext *context);
/** Start idempotently from any thread. BUSY while a previous asynchronous stop is finishing. */
S2KResult s2k_start(S2KContext *context);
/** Stop idempotently, immediately suppressing input; transport teardown finishes asynchronously.
 * Poll until snapshot.running == 0 && snapshot.stopping == 0 for the teardown boundary.
 * Never block the main run loop waiting for stop. */
S2KResult s2k_stop(S2KContext *context);
/** Open/replace a 0.1..300 second scan window after start; ready controllers are unaffected. */
S2KResult s2k_discover(S2KContext *context, double seconds);
/** Opt in to continuous discovery of available supported controllers (enabled=1),
 * including reconnect after link loss; enabled=0 restores on-demand discovery.
 * Default is 0. Any other value is INVALID_ARGUMENT. Idempotent and thread-safe.
 * Configuration is queued; it does not start Bluetooth or revive stopped support.
 * Call start separately. BUSY while asynchronous stop is finishing.
 * Switching to 0 cancels automatic scanning, not ready connections. An already
 * admitted handshake may finish. Use stop to cancel attempts and disconnect all.
 * Automatic mode has no discovery-window deadline and resumes scanning when the
 * radio/capacity permits. The host need not periodically renew discover calls.
 * The choice survives stop/start on this context, not destroy/create. Hosts own
 * user consent and persistence. New additive ABI-v1 symbol; link a matching SDK.
 */
S2KResult s2k_set_automatic_discovery(S2KContext *context, uint32_t enabled);
/** Read without blocking or invoking callbacks. One logical reader per handle.
 * events may be NULL only when capacity is zero. event_stride must equal sizeof(S2KEvent);
 * snapshot_size must equal sizeof(S2KSnapshot). count/snapshot/flags must be non-NULL.
 * Output storage belongs to the caller and may be discarded after return. On initial read,
 * overflow, or retired queued input: RESYNC is set, count is zero, snapshot is authoritative.
 * Normal reads preserve FIFO transitions. Capacity zero reads state without consuming history.
 * Sizes/arguments are checked before writing outputs. No event contains a borrowed pointer.
 */
S2KResult s2k_read(S2KContext *context, S2KEvent *events, uint32_t capacity,
                 uint32_t event_stride, uint32_t *count, S2KSnapshot *snapshot,
                 uint32_t snapshot_size, uint32_t *flags);
/** Disconnect only the specified connection, never a replacement with the same physical id.
 * forget != 0 also removes it from the manager's remembered set, not controller-stored bonds. */
S2KResult s2k_disconnect(S2KContext *context, const S2KID *id, const S2KID *connection_id, uint32_t forget);
/** Short feedback, intensity 0..1. Pro/Joy-Con: 400 ms HD pulse; GameCube: device-timed clip.
 * GameCube clips cannot be cancelled or assigned arbitrary duration. */
S2KResult s2k_play_feedback(S2KContext *context, const S2KID *id, const S2KID *connection_id, double intensity);
/** Motor intent, normalized channels 0..1; zero stops. Renew before 500 ms to sustain.
 * Pro/Joy-Con support amplitude; GameCube combines channels into motor on/off.
 * Call only while the host's input loop is live. */
S2KResult s2k_set_rumble(S2KContext *context, const S2KID *id, const S2KID *connection_id, double strong, double weak);
/** Motor pulse of 0.01..0.5 seconds; replaced by later intent. GameCube is on/off. */
S2KResult s2k_pulse_rumble(S2KContext *context, const S2KID *id, const S2KID *connection_id,
                         double strong, double weak, double seconds);
/** Set the physical controller's 1..8 player-light pattern; no logical grouping is implied. */
S2KResult s2k_set_player(S2KContext *context, const S2KID *id, const S2KID *connection_id, uint32_t player);
#ifdef __cplusplus
}
#endif
#endif