#include <Switch2KitC.h>
#include <Switch2KitMotion.h>
_Static_assert(sizeof(S2KID) == 16, "C11 header layout");
_Static_assert(sizeof(S2KSensorCalibration) == 64, "C11 sensor calibration layout");
_Static_assert(sizeof(S2KMotionCalibration) == 136, "C11 motion calibration layout");
_Static_assert(sizeof(S2KCalibratedMotion) == 64, "C11 calibrated output layout");
int s2k_c_header_check(void) { return (int)s2k_abi_version(); }
