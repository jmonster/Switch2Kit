#include <Switch2KitC.h>
_Static_assert(sizeof(S2KID) == 16, "C11 header layout");
int s2k_c_header_check(void) { return (int)s2k_abi_version(); }
