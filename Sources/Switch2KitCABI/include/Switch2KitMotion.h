#ifndef SWITCH2KIT_MOTION_H
#define SWITCH2KIT_MOTION_H
#include "Switch2KitC.h"

#ifdef __cplusplus
extern "C" {
#endif

/** Version of the explicit motion-calibration structs; independent of S2KState layout. */
#define S2K_MOTION_CALIBRATION_VERSION 1u
/** One sensor's measured offsets and gains in native X/Y/Z order. Gains must be
 * positive; output axes select signed native components: +1/-1 = X, +2/-2 = Y,
 * +3/-3 = Z, each native axis exactly once. Bias is removed before scaling and
 * axis selection. No controller-model scale or axis convention is guessed. */
typedef struct S2KSensorCalibration {
    double offset[3], units_per_count[3];
    int32_t axes[3];
    uint32_t reserved; /**< Must be zero. */
} S2KSensorCalibration;
/** Initialize every field, including version, struct_size and sensor reserved words.
 * Acceleration gains are m/s^2 per count; gyro gains are rad/s per count.
 * The host selects measured calibration for the physical device and sensor range. */
typedef struct S2KMotionCalibration {
    uint32_t version, struct_size;
    S2KSensorCalibration acceleration, angular_velocity;
} S2KMotionCalibration;
/** SI values in the body-frame axes specified by the profile. Acceleration includes
 * gravity; no orientation fusion or filtering is performed. Time and sequence are
 * copied from S2KState, never replaced by conversion time or claimed as device time. */
typedef struct S2KCalibratedMotion {
    double acceleration[3], angular_velocity[3];
    double received_at;
    uint64_t sequence;
} S2KCalibratedMotion;
/** Convert a motion-present input using explicit calibration. No context, Bluetooth,
 * callbacks, timer or history is required; safe on any thread with caller-owned data.
 * NOT_READY if S2K_HAS_MOTION is absent; ABI_MISMATCH for version/size mismatch;
 * INVALID_ARGUMENT for NULL pointers, non-finite/negative receive time, malformed
 * axes, invalid offsets/gains or nonzero reserved fields. Output is unchanged on error.
 * offset must be finite in -32768..32767. Gain must be finite, positive, and small
 * enough to avoid overflow for the complete signed-16-bit input range.
 * This function does NOT make the controller an SDL motion device automatically. */
S2KResult s2k_convert_motion(const S2KState *state, const S2KMotionCalibration *calibration,
                           S2KCalibratedMotion *output, uint32_t output_size);

#ifdef __cplusplus
}
#endif
#endif
