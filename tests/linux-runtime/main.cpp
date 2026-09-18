#include <Switch2KitC.h>
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>

int main()
{
    // Do not create a controller context or start Bluetooth in this loader test.
    if (s2k_abi_version() != S2K_ABI_VERSION)
        return 1;
    Dl_info information{};
    void* symbol = dlsym(RTLD_DEFAULT, "s2k_abi_version");
    if (!symbol || !dladdr(symbol, &information) || !information.dli_fname)
        return 2;
    char* path = realpath(information.dli_fname, nullptr);
    if (!path)
        return 3;
    const int result = std::puts(path);
    std::free(path);
    return result < 0 ? 4 : 0;
}
