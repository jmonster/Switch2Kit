#include <Switch2KitMotionProfile.h>
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#ifdef __cplusplus
#define CHECK_LAYOUT static_assert
#define ZERO {}
#else
#define CHECK_LAYOUT _Static_assert
#define ZERO {0}
#endif
CHECK_LAYOUT(sizeof(S2KState) == 120, "existing state ABI");
CHECK_LAYOUT(sizeof(S2KController) == 160, "existing controller ABI");
CHECK_LAYOUT(sizeof(S2KSensorCalibration) == 64, "sensor layout");
CHECK_LAYOUT(sizeof(S2KMotionCalibration) == 136, "calibration layout");
CHECK_LAYOUT(sizeof(S2KCalibratedMotion) == 64, "motion layout");
CHECK_LAYOUT(sizeof(S2KMotionProfile) == 256, "versioned physical profile");
CHECK_LAYOUT(offsetof(S2KMotionProfile, device) == 8, "versioned header");

static uint8_t bytes[S2K_MOTION_PROFILE_MAX_BYTES + 1];
static uint32_t length;
static S2KController selection(void) {
    S2KController value = ZERO;
    const uint8_t uuid[16] = {0x00,0x11,0x22,0x33,0x44,0x55,0x66,0x77,0x88,0x99,0xaa,0xbb,0xcc,0xdd,0xee,0xff};
    memcpy(value.id.bytes, uuid, sizeof(uuid));
    value.model = S2K_PRO; value.capabilities = S2K_CAP_RAW_MOTION;
    return value;
}
static void decode_failure(const uint8_t *input, uint32_t count, uint32_t size, S2KResult expected) {
    S2KMotionProfile output, before;
    memset(&output, 0xa5, sizeof(output)); memcpy(&before, &output, sizeof(output));
    assert(s2k_decode_motion_profile(input, count, &output, size) == expected);
    assert(memcmp(&before, &output, sizeof(output)) == 0);
}
static void profile_failure(const S2KMotionProfile *profile, const S2KController *controller,
                            uint32_t size, S2KResult expected) {
    S2KMotionCalibration output, before;
    memset(&output, 0xa5, sizeof(output)); memcpy(&before, &output, sizeof(output));
    assert(s2k_motion_profile_calibration(profile, controller, &output, size) == expected);
    assert(memcmp(&before, &output, sizeof(output)) == 0);
}
static int converted_sample(void) {
    S2KController controller = selection();
    S2KMotionProfile profile = ZERO;
    S2KMotionCalibration calibration = ZERO;
    if (s2k_decode_motion_profile(bytes, length, &profile, sizeof(profile)) != S2K_OK ||
        s2k_motion_profile_calibration(&profile, &controller, &calibration, sizeof(calibration)) != S2K_OK) return 1;
    S2KState state = ZERO, before;
    state.present = S2K_HAS_MOTION; state.received_at = 123.25; state.sequence = 99; state.buttons = S2K_BUTTON_A;
    state.accel[0] = 100; state.accel[1] = -8040; state.accel[2] = 25; /* +X gravity fixture */
    state.gyro[0] = 11; state.gyro[1] = -2007; state.gyro[2] = 3; /* +Z 1 rad/s fixture */
    memcpy(&before, &state, sizeof(state));
    S2KCalibratedMotion motion = ZERO;
    if (s2k_convert_motion(&state, &calibration, &motion, sizeof(motion)) != S2K_OK) return 2;
    if (fabs(motion.acceleration[0] - 9.80665) > 1e-10 || fabs(motion.acceleration[1]) > 1e-10 ||
        fabs(motion.acceleration[2]) > 1e-10 || fabs(motion.angular_velocity[0]) > 1e-10 ||
        fabs(motion.angular_velocity[1]) > 1e-10 || fabs(motion.angular_velocity[2] - 1) > 1e-10) return 3;
    if (motion.received_at != state.received_at || motion.sequence != state.sequence || memcmp(&state, &before, sizeof(state))) return 4;
    S2KCalibratedMotion sentinel;
    memcpy(&sentinel, &motion, sizeof(motion)); state.present = 0;
    if (s2k_convert_motion(&state, &calibration, &motion, sizeof(motion)) != S2K_NOT_READY ||
        memcmp(&sentinel, &motion, sizeof(motion))) return 5;
    return 0;
}
static void *worker(void *opaque) {
    int *result = (int *)opaque;
    *result = 0;
    for (unsigned i = 0; i < 512 && *result == 0; ++i) *result = converted_sample();
    return NULL;
}
int main(int argc, char **argv) {
    assert(argc == 2);
    FILE *input = fopen(argv[1], "rb"); assert(input);
    length = (uint32_t)fread(bytes, 1, sizeof(bytes), input);
    assert(!ferror(input) && length > 0 && length <= S2K_MOTION_PROFILE_MAX_BYTES);
    assert(fclose(input) == 0);
    assert(converted_sample() == 0);
    decode_failure(NULL, length, sizeof(S2KMotionProfile), S2K_INVALID_ARGUMENT);
    decode_failure(bytes, 0, sizeof(S2KMotionProfile), S2K_INVALID_ARGUMENT);
    decode_failure(bytes, S2K_MOTION_PROFILE_MAX_BYTES + 1, sizeof(S2KMotionProfile), S2K_INVALID_ARGUMENT);
    decode_failure(bytes, length, 0, S2K_ABI_MISMATCH);
    assert(s2k_decode_motion_profile(bytes, length, NULL, sizeof(S2KMotionProfile)) == S2K_INVALID_ARGUMENT);
    const uint8_t malformed[] = {'{', '}'};
    decode_failure(malformed, sizeof(malformed), sizeof(S2KMotionProfile), S2K_INVALID_ARGUMENT);
    S2KMotionProfile profile = ZERO, bad;
    S2KController controller = selection(), wrong = controller;
    assert(s2k_decode_motion_profile(bytes, length, &profile, sizeof(profile)) == S2K_OK);
    profile_failure(NULL, &controller, sizeof(S2KMotionCalibration), S2K_INVALID_ARGUMENT);
    profile_failure(&profile, &controller, 0, S2K_ABI_MISMATCH);
    wrong.model = S2K_GAMECUBE;
    profile_failure(&profile, &wrong, sizeof(S2KMotionCalibration), S2K_INVALID_ARGUMENT);
    wrong = controller; wrong.id.bytes[0]++;
    profile_failure(&profile, &wrong, sizeof(S2KMotionCalibration), S2K_INVALID_ARGUMENT);
    wrong = controller; wrong.capabilities = 0;
    profile_failure(&profile, &wrong, sizeof(S2KMotionCalibration), S2K_UNSUPPORTED_OPERATION);
    bad = profile; bad.version++;
    profile_failure(&bad, &controller, sizeof(S2KMotionCalibration), S2K_ABI_MISMATCH);
    bad = profile; bad.struct_size--;
    profile_failure(&bad, &controller, sizeof(S2KMotionCalibration), S2K_ABI_MISMATCH);
    bad = profile; bad.configuration++;
    profile_failure(&bad, &controller, sizeof(S2KMotionCalibration), S2K_INVALID_ARGUMENT);
    bad = profile; bad.feature_flags = 0;
    profile_failure(&bad, &controller, sizeof(S2KMotionCalibration), S2K_INVALID_ARGUMENT);
    bad = profile; bad.holding_axes[0] = -1;
    profile_failure(&bad, &controller, sizeof(S2KMotionCalibration), S2K_INVALID_ARGUMENT);
    pthread_t threads[8]; int results[8];
    for (unsigned i = 0; i < 8; ++i) assert(pthread_create(&threads[i], NULL, worker, &results[i]) == 0);
    for (unsigned i = 0; i < 8; ++i) { assert(pthread_join(threads[i], NULL) == 0); assert(results[i] == 0); }
    puts("PASS fitter output -> published profile -> shared Swift converter; C ABI and 4096 concurrent loads/conversions");
    return 0;
}
