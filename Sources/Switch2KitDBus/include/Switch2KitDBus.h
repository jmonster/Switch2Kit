#ifndef SWITCH2KIT_DBUS_H
#define SWITCH2KIT_DBUS_H
#include <stdint.h>
#include <stddef.h>
/* Private Linux binding. No controller protocol or public SDK ABI lives here. */
typedef struct sd_bus S2KBus;
typedef struct sd_bus_message S2KBusMessage;
typedef struct sd_bus_slot S2KBusSlot;
typedef struct sd_bus_error S2KBusError;
typedef int (*S2KBusHandler)(S2KBusMessage *, void *, S2KBusError *);
#pragma GCC visibility push(hidden)
int s2k_bus_open(S2KBus **bus);
void s2k_bus_close(S2KBus *bus);
int s2k_bus_fd(S2KBus *bus);
int s2k_bus_events(S2KBus *bus);
int s2k_bus_timeout(S2KBus *bus, uint64_t *usec);
int s2k_bus_process(S2KBus *bus);
int s2k_bus_match(S2KBus *bus, S2KBusSlot **slot, const char *rule, S2KBusHandler handler, void *context);
void s2k_bus_cancel(S2KBusSlot *slot);
int s2k_bus_method(S2KBus *bus, S2KBusMessage **message, const char *destination,
                   const char *path, const char *interface, const char *member);
int s2k_bus_call(S2KBus *bus, S2KBusSlot **slot, S2KBusMessage *message,
                 S2KBusHandler handler, void *context, uint64_t timeout_usec);
void s2k_bus_message_release(S2KBusMessage *message);
int s2k_bus_open_container(S2KBusMessage *message, char type, const char *contents);
int s2k_bus_close_container(S2KBusMessage *message);
int s2k_bus_append_string(S2KBusMessage *message, char type, const char *value);
int s2k_bus_append_bool(S2KBusMessage *message, int value);
int s2k_bus_append_bytes(S2KBusMessage *message, const void *bytes, size_t length);
int s2k_bus_peek(S2KBusMessage *message, char *type, const char **contents);
int s2k_bus_enter(S2KBusMessage *message, char type, const char *contents);
int s2k_bus_exit(S2KBusMessage *message);
int s2k_bus_read_string(S2KBusMessage *message, char type, const char **value);
int s2k_bus_read_integer(S2KBusMessage *message, char type, int64_t *value);
int s2k_bus_read_bytes(S2KBusMessage *message, const void **bytes, size_t *length);
int s2k_bus_skip_scalar(S2KBusMessage *message, char type);
const char *s2k_bus_error_name(S2KBusMessage *message);
const char *s2k_bus_path(S2KBusMessage *message);
const char *s2k_bus_interface(S2KBusMessage *message);
const char *s2k_bus_member(S2KBusMessage *message);
#pragma GCC visibility pop
#endif
