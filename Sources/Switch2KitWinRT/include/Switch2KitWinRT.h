#ifndef SWITCH2KIT_WINRT_H
#define SWITCH2KIT_WINRT_H
#include <stdint.h>
#ifdef __cplusplus
// HRESULT definitions belong to the C++ implementation, not the Swift C module.
#include <windows.h>
extern "C" {
#endif
/* Private transport ABI. No C++ or WinRT objects cross into Swift. */
typedef struct S2WRadio S2WRadio;
enum { S2W_STATE=1, S2W_ADVERTISEMENT, S2W_CONNECTED, S2W_CHARACTERISTIC,
       S2W_SERVICES, S2W_NOTIFICATION, S2W_VALUE, S2W_WRITABLE,
       S2W_DISCONNECTED, S2W_FAILED, S2W_MTU, S2W_OVERFLOW };
enum { S2W_WRITE=1, S2W_NOTIFY=2, S2W_INDICATE=4 };
typedef struct S2WEvent {
    uint32_t kind;
    int32_t status;
    uint64_t token, address, host_address;
    uint32_t address_type, characteristic, flags, length;
    int32_t rssi;
    char uuid[37];
    uint8_t bytes[512];
} S2WEvent;
/* Create starts asynchronous adapter initialization, never scans. Destroy must
 * not race other calls. All other calls copy their input and are nonblocking.
 * Commands return 1 when admitted, 0 when rejected. next returns 1 for an event.
 * Tokens must be nonzero and must never be reused within a radio's lifetime. */
S2WRadio *s2w_create(void);
void s2w_destroy(S2WRadio *radio);
int32_t s2w_scan(S2WRadio *radio, uint32_t enabled);
int32_t s2w_connect(S2WRadio *radio, uint64_t token, uint64_t address, uint32_t address_type);
int32_t s2w_cancel(S2WRadio *radio, uint64_t token);
int32_t s2w_discover(S2WRadio *radio, uint64_t token);
int32_t s2w_notify(S2WRadio *radio, uint64_t token, uint32_t characteristic, uint32_t enabled);
int32_t s2w_write(S2WRadio *radio, uint64_t token, uint32_t characteristic, const uint8_t *bytes, uint32_t length);
int32_t s2w_next(S2WRadio *radio, S2WEvent *event);
#ifdef __cplusplus
}
#endif
#endif
