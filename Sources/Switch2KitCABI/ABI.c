#include "Switch2KitC.h"
_Static_assert(sizeof(S2KID) == 16, "S2KID ABI");
_Static_assert(sizeof(double) == 8, "S2K requires IEEE 754 binary64");
_Static_assert(offsetof(S2KState, left_x) == 24, "S2KState ABI");
