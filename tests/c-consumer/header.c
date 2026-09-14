#include <Switch2KitC.h>
#include <Switch2KitMotion.h>
#include <Switch2KitMotionProfile.h>
#include <stddef.h>
_Static_assert(sizeof(S2KID) == 16, "C11 header layout");
_Static_assert(sizeof(S2KSensorCalibration) == 64, "C11 sensor calibration layout");
_Static_assert(sizeof(S2KMotionCalibration) == 136, "C11 motion calibration layout");
_Static_assert(sizeof(S2KCalibratedMotion) == 64, "C11 calibrated output layout");
_Static_assert(sizeof(S2KMotionProfile) == 256, "C11 physical profile layout");
_Static_assert(offsetof(S2KMotionProfile, calibration) == 40, "C11 profile calibration offset");
_Static_assert(offsetof(S2KMotionProfile, orientation) == 192, "C11 profile label offset");
int s2k_c_header_check(void) { return (int)s2k_abi_version(); }
