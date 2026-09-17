/* Private, dynamically loaded bindings to the documented libsystemd sd-bus C ABI.
 * Only opaque handles and fixed-width values cross into Swift. Keeping this
 * optional at load time preserves radio-free consumers without libsystemd.
 * Interface reference: https://systemd.io/ and systemd's src/systemd/sd-bus.h.
 * No implementation or header from systemd is copied into this repository.
 */
#include "Switch2KitDBus.h"
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>

struct sd_bus_error { const char *name; const char *message; int need_free; };
#define FUNCTIONS(X) \
 X(int, sd_bus_open_system, (S2KBus **)) \
 X(S2KBus *, sd_bus_close_unref, (S2KBus *)) \
 X(int, sd_bus_set_method_call_timeout, (S2KBus *, uint64_t)) \
 X(int, sd_bus_get_fd, (S2KBus *)) \
 X(int, sd_bus_get_events, (S2KBus *)) \
 X(int, sd_bus_get_timeout, (S2KBus *, uint64_t *)) \
 X(int, sd_bus_process, (S2KBus *, S2KBusMessage **)) \
 X(int, sd_bus_add_match_async, (S2KBus *, S2KBusSlot **, const char *, S2KBusHandler, S2KBusHandler, void *)) \
 X(S2KBusSlot *, sd_bus_slot_unref, (S2KBusSlot *)) \
 X(int, sd_bus_message_new_method_call, (S2KBus *, S2KBusMessage **, const char *, const char *, const char *, const char *)) \
 X(int, sd_bus_call_async, (S2KBus *, S2KBusSlot **, S2KBusMessage *, S2KBusHandler, void *, uint64_t)) \
 X(S2KBusMessage *, sd_bus_message_unref, (S2KBusMessage *)) \
 X(int, sd_bus_message_open_container, (S2KBusMessage *, char, const char *)) \
 X(int, sd_bus_message_close_container, (S2KBusMessage *)) \
 X(int, sd_bus_message_append_basic, (S2KBusMessage *, char, const void *)) \
 X(int, sd_bus_message_append_array, (S2KBusMessage *, char, const void *, size_t)) \
 X(int, sd_bus_message_peek_type, (S2KBusMessage *, char *, const char **)) \
 X(int, sd_bus_message_enter_container, (S2KBusMessage *, char, const char *)) \
 X(int, sd_bus_message_exit_container, (S2KBusMessage *)) \
 X(int, sd_bus_message_read_basic, (S2KBusMessage *, char, void *)) \
 X(int, sd_bus_message_read_array, (S2KBusMessage *, char, const void **, size_t *)) \
 X(int, sd_bus_message_skip, (S2KBusMessage *, const char *)) \
 X(const S2KBusError *, sd_bus_message_get_error, (S2KBusMessage *)) \
 X(const char *, sd_bus_message_get_path, (S2KBusMessage *)) \
 X(const char *, sd_bus_message_get_interface, (S2KBusMessage *)) \
 X(const char *, sd_bus_message_get_member, (S2KBusMessage *))
#define DECLARE(result, name, args) static result (*p_##name) args;
FUNCTIONS(DECLARE)
#undef DECLARE
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int available;
static void load(void) {
    /* Retain the library for the process lifetime: callbacks may outlive a host. */
    void *library = dlopen("libsystemd.so.0", RTLD_NOW | RTLD_LOCAL);
    if (!library) return;
#define LOAD(result, name, args) do { *(void **)(&p_##name) = dlsym(library, #name); if (!p_##name) return; } while (0);
    FUNCTIONS(LOAD)
#undef LOAD
    available = 1;
}
int s2k_bus_open(S2KBus **bus) {
    if (!bus) return -EINVAL;
    *bus = NULL;
    pthread_once(&once, load);
    if (!available) return -ENOSYS;
    int result = p_sd_bus_open_system(bus);
    if (result >= 0) p_sd_bus_set_method_call_timeout(*bus, 5000000);
    return result;
}
void s2k_bus_close(S2KBus *bus) { if (bus) p_sd_bus_close_unref(bus); }
int s2k_bus_fd(S2KBus *bus) { return p_sd_bus_get_fd(bus); }
int s2k_bus_events(S2KBus *bus) { return p_sd_bus_get_events(bus); }
int s2k_bus_timeout(S2KBus *bus, uint64_t *usec) { return p_sd_bus_get_timeout(bus, usec); }
int s2k_bus_process(S2KBus *bus) { return p_sd_bus_process(bus, NULL); }
int s2k_bus_match(S2KBus *bus, S2KBusSlot **slot, const char *rule, S2KBusHandler handler, void *context) {
    return p_sd_bus_add_match_async(bus, slot, rule, handler, handler, context);
}
void s2k_bus_cancel(S2KBusSlot *slot) { if (slot) p_sd_bus_slot_unref(slot); }
int s2k_bus_method(S2KBus *bus, S2KBusMessage **message, const char *destination,
                   const char *path, const char *interface, const char *member) {
    return p_sd_bus_message_new_method_call(bus, message, destination, path, interface, member);
}
int s2k_bus_call(S2KBus *bus, S2KBusSlot **slot, S2KBusMessage *message,
                 S2KBusHandler handler, void *context, uint64_t timeout_usec) {
    return p_sd_bus_call_async(bus, slot, message, handler, context, timeout_usec);
}
void s2k_bus_message_release(S2KBusMessage *message) { if (message) p_sd_bus_message_unref(message); }
int s2k_bus_open_container(S2KBusMessage *m, char t, const char *c) { return p_sd_bus_message_open_container(m,t,c); }
int s2k_bus_close_container(S2KBusMessage *m) { return p_sd_bus_message_close_container(m); }
int s2k_bus_append_string(S2KBusMessage *m, char t, const char *s) { return p_sd_bus_message_append_basic(m,t,s); }
int s2k_bus_append_bool(S2KBusMessage *m, int b) { return p_sd_bus_message_append_basic(m,'b',&b); }
int s2k_bus_append_bytes(S2KBusMessage *m, const void *p, size_t n) { return p_sd_bus_message_append_array(m,'y',p,n); }
int s2k_bus_peek(S2KBusMessage *m, char *t, const char **c) { return p_sd_bus_message_peek_type(m,t,c); }
int s2k_bus_enter(S2KBusMessage *m, char t, const char *c) { return p_sd_bus_message_enter_container(m,t,c); }
int s2k_bus_exit(S2KBusMessage *m) { return p_sd_bus_message_exit_container(m); }
int s2k_bus_read_string(S2KBusMessage *m, char t, const char **s) { return p_sd_bus_message_read_basic(m,t,s); }
int s2k_bus_read_integer(S2KBusMessage *m, char t, int64_t *v) {
    int result;
    switch (t) {
#define READ(code, T) case code: { T x = 0; result = p_sd_bus_message_read_basic(m,t,&x); *v = (int64_t)x; break; }
        READ('y', uint8_t) READ('b', int) READ('n', int16_t) READ('q', uint16_t)
        READ('i', int32_t) READ('u', uint32_t) READ('x', int64_t)
#undef READ
        default: return -ENOTSUP;
    }
    return result;
}
int s2k_bus_read_bytes(S2KBusMessage *m, const void **p, size_t *n) { return p_sd_bus_message_read_array(m,'y',p,n); }
int s2k_bus_skip_scalar(S2KBusMessage *m, char t) {
    if (t != 't' && t != 'd' && t != 'h') return -ENOTSUP;
    char signature[2] = { t, 0 };
    return p_sd_bus_message_skip(m, signature);
}
const char *s2k_bus_error_name(S2KBusMessage *m) {
    const S2KBusError *e = p_sd_bus_message_get_error(m);
    return e ? e->name : NULL;
}
const char *s2k_bus_path(S2KBusMessage *m) { return p_sd_bus_message_get_path(m); }
const char *s2k_bus_interface(S2KBusMessage *m) { return p_sd_bus_message_get_interface(m); }
const char *s2k_bus_member(S2KBusMessage *m) { return p_sd_bus_message_get_member(m); }
