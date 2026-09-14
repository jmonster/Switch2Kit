#ifndef SWITCH2KIT_MOTION_PROFILE_H
#define SWITCH2KIT_MOTION_PROFILE_H
#include "Switch2KitMotion.h"

#ifdef __cplusplus
extern "C" {
#endif

#define S2K_MOTION_PROFILE_VERSION 1u
#define S2K_MOTION_PROFILE_MAX_BYTES 4096u
#define S2K_MOTION_CONFIGURATION_BT_V1 1u
/** Host-owned physical-device profile. No implicit persistence or discovery occurs.
 * configuration identifies the existing signed-16-bit Bluetooth report layout and
 * compatibility handshake. feature_flags must match that setup for model (0xa7 for
 * Pro/GameCube, 0xb7 for either Joy-Con). This is NOT a hardware range/ODR readback.
 * Native gains also define the SI response at 32768 raw counts (the profile's range
 * records). Requalify after firmware/configuration changes. No built-in gains exist.
 * holding_axes is a proper signed-axis rotation (determinant +1), applied equally
 * to acceleration and angular velocity after independently measured native axes.
 * orientation is a NUL-terminated 1...63-character ASCII label; unused bytes and
 * reserved words must be zero. Neither identifiers nor sensor values belong in
 * default application logs. Existing C ABI structures are unchanged. */
typedef struct S2KMotionProfile {
    uint32_t version, struct_size;
    S2KID device;
    uint32_t model, configuration, feature_flags, reserved;
    S2KMotionCalibration calibration;
    int32_t holding_axes[3];
    uint32_t reserved2;
    char orientation[64];
} S2KMotionProfile;
/** Decode bounded version-1 profile bytes through the shared Swift validator.
 * The host must bound its file read; this function does not read files or keep a
 * cache. INVALID_ARGUMENT for malformed, incompatible or oversized input;
 * ABI_MISMATCH for output size. Output is unchanged on every failure. */
S2KResult s2k_decode_motion_profile(const uint8_t *bytes, uint32_t byte_count,
                                  S2KMotionProfile *output, uint32_t output_size);
/** Validate a profile and compose its holding rotation into the shared converter.
 * Optional controller checks physical identity, model and motion capability, never
 * SDL instance, player index or connection generation. NULL checks only the profile
 * (useful when loading a host-selected profile before connecting that device).
 * Call s2k_convert_motion with the returned calibration; do not rotate again.
 * ABI_MISMATCH for version/size; INVALID_ARGUMENT for invalid data/device mismatch;
 * UNSUPPORTED_OPERATION for a controller without raw motion capability.
 * Output is unchanged on every failure. Thread-safe with caller-owned values. */
S2KResult s2k_motion_profile_calibration(const S2KMotionProfile *profile,
                                       const S2KController *controller,
                                       S2KMotionCalibration *output, uint32_t output_size);
/** Current host monotonic receive clock, in seconds; same clock as received_at.
 * Not Unix time, not hardware sampling time, not SDL's epoch. A host correlates
 * clocks explicitly (for example by bracketing this call with its own clock reads).
 * Safe on any thread. Does not open Bluetooth or require a context. */
double s2k_monotonic_time(void);

#ifdef __cplusplus
}
#endif
#endif
