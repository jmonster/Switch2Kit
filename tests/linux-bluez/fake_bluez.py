"""Private D-Bus BlueZ service: synthetic radio, actual sd-bus and SDK engine.

No product source is copied or injected. Run only on the private bus started by
run.py. ctypes is used to avoid requiring Python D-Bus packages or development
headers. All C callbacks and method replies are retained until their completion.
"""
import ctypes as C
import heapq
import json
import os
from pathlib import Path
import signal
import sys
import time

L = C.CDLL('libsystemd.so.0')
P, I, S = C.c_void_p, C.c_int, C.c_char_p
Handler = C.CFUNCTYPE(I, P, P, P)
def bind(name, result, *args):
    fn = getattr(L, name); fn.restype = result; fn.argtypes = args; return fn
open_bus = bind('sd_bus_open_system', I, C.POINTER(P))
close_bus = bind('sd_bus_close_unref', P, P)
request_name = bind('sd_bus_request_name', I, P, S, C.c_uint64)
add_fallback = bind('sd_bus_add_fallback', I, P, C.POINTER(P), S, Handler, P)
process = bind('sd_bus_process', I, P, P)
wait = bind('sd_bus_wait', I, P, C.c_uint64)
flush = bind('sd_bus_flush', I, P)
new_reply = bind('sd_bus_message_new_method_return', I, P, C.POINTER(P))
new_signal = bind('sd_bus_message_new_signal', I, P, C.POINTER(P), S, S, S)
class Error(C.Structure):
    _fields_ = [('name', S), ('message', S), ('need_free', I)]
new_error = bind('sd_bus_message_new_method_error', I, P, C.POINTER(P), C.POINTER(Error))
ref = bind('sd_bus_message_ref', P, P)
unref = bind('sd_bus_message_unref', P, P)
send = bind('sd_bus_send', I, P, P, P)
open_container = bind('sd_bus_message_open_container', I, P, C.c_char, S)
close_container = bind('sd_bus_message_close_container', I, P)
append_basic = bind('sd_bus_message_append_basic', I, P, C.c_char, P)
append_array = bind('sd_bus_message_append_array', I, P, C.c_char, P, C.c_size_t)
read_array = bind('sd_bus_message_read_array', I, P, C.c_char, C.POINTER(P), C.POINTER(C.c_size_t))
read_basic = bind('sd_bus_message_read_basic', I, P, C.c_char, P)
enter = bind('sd_bus_message_enter_container', I, P, C.c_char, S)
exit_container = bind('sd_bus_message_exit_container', I, P)
path_of = bind('sd_bus_message_get_path', S, P)
member_of = bind('sd_bus_message_get_member', S, P)
interface_of = bind('sd_bus_message_get_interface', S, P)

def check(n):
    if n < 0: raise RuntimeError(f'sd-bus: {n}')
    return n

def types(sig):
    """Split a complete D-Bus signature into top-level types."""
    def end(i):
        if sig[i] == 'a': return end(i + 1)
        if sig[i] in '({':
            close = ')' if sig[i] == '(' else '}'; i += 1
            while sig[i] != close: i = end(i)
            return i + 1
        return i + 1
    i = 0
    while i < len(sig):
        j = end(i); yield sig[i:j]; i = j

def encode(m, sig, value):
    if sig in ('s', 'o', 'g'):
        data = value.encode(); check(append_basic(m, sig.encode(), C.cast(S(data), P)))
    elif sig in 'bynqiuxtd':
        cls = {'b': I, 'y': C.c_uint8, 'n': C.c_int16, 'q': C.c_uint16,
               'i': C.c_int32, 'u': C.c_uint32, 'x': C.c_int64, 't': C.c_uint64, 'd': C.c_double}[sig]
        data = cls(value); check(append_basic(m, sig.encode(), C.byref(data)))
    elif sig == 'ay':
        data = C.create_string_buffer(bytes(value)); check(append_array(m, b'y', data, len(value)))
    elif sig == 'v':
        subtype, data = value
        check(open_container(m, b'v', subtype.encode())); encode(m, subtype, data); check(close_container(m))
    elif sig.startswith('a'):
        check(open_container(m, b'a', sig[1:].encode()))
        for item in (value.items() if isinstance(value, dict) else value): encode(m, sig[1:], item)
        check(close_container(m))
    elif sig.startswith(('{', '(')):
        check(open_container(m, b'e' if sig[0] == '{' else b'r', sig[1:-1].encode()))
        for subtype, item in zip(types(sig[1:-1]), value): encode(m, subtype, item)
        check(close_container(m))
    else: raise ValueError(sig)

ADAPTER = '/org/bluez/hci0'
DEVICE = ADAPTER + '/dev_AA_BB_CC_DD_EE_FF'
SERVICE = DEVICE + '/service0001'
COMMAND = SERVICE + '/char0002'
RESPONSE = SERVICE + '/char0003'
INPUT = SERVICE + '/char0004'
MOTOR = SERVICE + '/char0005'
PROPS = 'org.freedesktop.DBus.Properties'
class BlueZ:
    def __init__(self, scenario, model, output):
        self.scenario, self.model, self.output = scenario, model, output
        self.bus, self.slot = P(), P(); self.log = []; self.scheduled = []; self.serial = 0
        self.running = True; self.fatal = None; self.connected = False; self.discovering = False
        self.notifying = set(); self.sequence = 0; self.pending_write = False
        self.started = time.monotonic()
        payload = bytearray(16); payload[3:5] = b'\x7e\x05'; payload[5:7] = model.to_bytes(2, 'little')
        company = 0x555 if scenario == 'wrong-company' else 0x553
        self.manufacturer = ('a{qv}', {company: ('ay', payload)})
        self.objects = {
            ADAPTER: {'org.bluez.Adapter1': {'Address': ('s', '12:34:56:78:9A:BC'), 'Powered': ('b', True)}},
            DEVICE: {'org.bluez.Device1': {'Adapter': ('o', ADAPTER), 'Address': ('s', 'AA:BB:CC:DD:EE:FF'),
                'AddressType': ('s', 'public'), 'RSSI': ('n', -42), 'Connected': ('b', scenario == 'foreign'),
                'ServicesResolved': ('b', False), 'ManufacturerData': self.manufacturer}}
        }
        if scenario == 'adapter-switch':
            self.objects['/org/bluez/hci1'] = {'org.bluez.Adapter1': {'Address': ('s', '98:76:54:32:10:FE'), 'Powered': ('b', True)}}
        if scenario == 'no-adapter': self.objects = {}
        if scenario == 'oversized': self.objects[ADAPTER]['org.bluez.Adapter1']['Unused'] = ('ay', bytes(65537))
        check(open_bus(C.byref(self.bus)))
        self.callback = Handler(self.method)
        check(add_fallback(self.bus, C.byref(self.slot), b'/', self.callback, None))
        check(request_name(self.bus, b'org.bluez', 0)); check(flush(self.bus))

    def later(self, delay, fn):
        self.serial += 1; heapq.heappush(self.scheduled, (time.monotonic() + delay, self.serial, fn))

    def reply(self, call, sig='', values=(), error=None):
        m = P()
        if error:
            e = Error(error.encode(), b'isolated test error', 0); check(new_error(call, C.byref(m), C.byref(e)))
        else:
            check(new_reply(call, C.byref(m)))
            for part, value in zip(types(sig), values): encode(m, part, value)
        try: check(send(self.bus, m, None))
        finally: unref(m)

    def changed(self, path, interface, changes, absent=()):
        self.objects.setdefault(path, {}).setdefault(interface, {}).update(changes)
        for key in absent: self.objects[path][interface].pop(key, None)
        m = P(); check(new_signal(self.bus, C.byref(m), path.encode(), PROPS.encode(), b'PropertiesChanged'))
        for sig, val in [('s', interface), ('a{sv}', changes), ('as', absent)]: encode(m, sig, val)
        try: check(send(self.bus, m, None))
        finally: unref(m)

    def announce(self):
        if self.discovering and not self.connected and self.scenario != 'cached':
            self.changed(DEVICE, 'org.bluez.Device1', {'ManufacturerData': self.manufacturer})

    def services(self):
        self.objects[SERVICE] = {'org.bluez.GattService1': {'Device': ('o', DEVICE), 'UUID': ('s', '00001800-0000-1000-8000-00805f9b34fb')}}
        motor = {0x2069: 'CC483F51-9258-427D-A939-630C31F72B05', 0x2066: 'FA19B0FB-CD1F-46A7-84A1-BBB09E00C149',
                 0x2067: '289326CB-A471-485D-A8F4-240C14F18241', 0x2073: '3F8FB670-AB25-45BF-B540-38C72834D064'}[self.model]
        for path, uuid, flags in [(COMMAND, '649D4AC9-8EB7-4E6C-AF44-1EA54FE5F005', ['write-without-response']),
                (RESPONSE, 'C765A961-D9D8-4D36-A20A-5315B111836A', ['notify']),
                (INPUT, 'AB7DE9BE-89FE-49AD-828F-118F09DF7FD2', ['notify']), (MOTOR, motor, ['write-without-response'])]:
            self.objects[path] = {'org.bluez.GattCharacteristic1': {'Service': ('o', SERVICE), 'UUID': ('s', uuid),
                'Flags': ('as', flags), 'MTU': ('q', 12 if self.scenario == 'short-mtu' else 247), 'Notifying': ('b', False)}}
        self.changed(DEVICE, 'org.bluez.Device1', {'ServicesResolved': ('b', True)})

    def report(self):
        if not self.connected or INPUT not in self.notifying: return
        self.sequence += 1
        if self.scenario == 'service-reset' and self.sequence == 6:
            self.changed(INPUT, 'org.bluez.GattCharacteristic1', {}, ['Flags'])
            return
        data = bytearray(63); data[:4] = self.sequence.to_bytes(4, 'little')
        data[4] = 8 if self.sequence % 2 else 0
        data[10:13] = data[13:16] = b'\x00\x08\x80'
        data[0x30:0x32] = (123).to_bytes(2, 'little', signed=True)
        data[0x36:0x38] = (-456).to_bytes(2, 'little', signed=True)
        data[0x3c] = 128
        self.changed(INPUT, 'org.bluez.GattCharacteristic1', {'Value': ('ay', data)})
        self.later(0.025, self.report)

    def command(self, data):
        assert RESPONSE in self.notifying, 'writes before response subscription'
        assert len(data) >= 8 and data[1] == 0x91 and data[2] == 1 and data[5] == len(data) - 8
        payload = b''
        if data[0] == 2:
            length = data[8]; address = int.from_bytes(data[12:16], 'little')
            memory = bytearray([255] * length)
            if address == 0x13000:
                memory = bytearray(length); memory[2:9] = b'fixture'
                memory[18:20] = b'\x7e\x05'; memory[20:22] = self.model.to_bytes(2, 'little')
            payload = data[8:16] + memory
        if data[0] == 0x15 and data[3] == 1:
            assert data[8:] == b'\x00\x02' + bytes.fromhex('bc9a78563412') * 2, 'wrong adapter address for protocol bond'
        response = bytes([data[0], 1, data[2], data[3], 0, len(payload), 0, 0]) + payload
        self.changed(RESPONSE, 'org.bluez.GattCharacteristic1', {'Value': ('ay', response)})

    def method(self, m, _context, _error):
        try:
            path, interface, member = path_of(m).decode(), interface_of(m).decode(), member_of(m).decode()
            self.log.append({'path': path, 'member': member, 'time': time.monotonic() - self.started})
            if member == 'GetManagedObjects':
                self.reply(m, 'a{oa{sa{sv}}}', [self.objects], error='org.freedesktop.DBus.Error.AccessDenied' if self.scenario == 'denied' else None)
            elif member == 'SetDiscoveryFilter':
                self.reply(m)
            elif member == 'StartDiscovery':
                self.discovering = True
                if self.scenario in ('cancel-scan', 'adapter-switch'):
                    call = ref(m)
                    def started(): self.reply(call); unref(call)
                    self.later(0.45, started)
                    if self.scenario == 'adapter-switch' and path == ADAPTER:
                        self.later(0.08, lambda: self.changed(ADAPTER, 'org.bluez.Adapter1', {'Powered': ('b', False)}))
                else:
                    self.reply(m); self.later(0.08, self.announce)
            elif member == 'StopDiscovery':
                self.discovering = False; self.reply(m)
            elif member == 'Connect':
                assert not self.connected
                if self.scenario == 'cancel-connect':
                    call = ref(m)
                    def late_reply():
                        self.reply(call, error='org.bluez.Error.Failed'); unref(call)
                    self.later(0.6, late_reply)
                else:
                    self.connected = True; self.reply(m)
                    self.changed(DEVICE, 'org.bluez.Device1', {'Connected': ('b', True)})
                    self.later(0.04, self.services)
            elif member == 'Disconnect':
                self.connected = False; self.notifying.clear(); self.reply(m)
                self.changed(DEVICE, 'org.bluez.Device1', {'Connected': ('b', False), 'ServicesResolved': ('b', False)})
                # BlueZ DuplicateData can repeatedly advertise during an existing scan.
                self.later(2.3, self.announce)
            elif member in ('StartNotify', 'StopNotify'):
                if self.scenario == 'notify-denied':
                    self.reply(m, error='org.bluez.Error.NotPermitted')
                else:
                    if member == 'StartNotify': self.notifying.add(path)
                    else: self.notifying.discard(path)
                    self.reply(m)
                    self.changed(path, 'org.bluez.GattCharacteristic1', {'Notifying': ('b', path in self.notifying)})
                    if path == INPUT and member == 'StartNotify': self.later(0.03, self.report)
            elif member == 'WriteValue':
                pointer, size = P(), C.c_size_t()
                check(read_array(m, b'y', C.byref(pointer), C.byref(size)))
                data = C.string_at(pointer, size.value)
                check(enter(m, b'a', b'{sv}')); check(enter(m, b'e', b'sv'))
                key, value = S(), S(); check(read_basic(m, b's', C.byref(key)))
                check(enter(m, b'v', b's')); check(read_basic(m, b's', C.byref(value)))
                assert key.value == b'type' and value.value == b'command'
                assert not self.pending_write, 'unbounded concurrent writes'
                assert len(data) <= (12 if self.scenario == 'short-mtu' else 247) - 3
                self.log[-1]['hex'] = data.hex(); self.pending_write = True
                if self.scenario == 'early-ack' and path == COMMAND: self.command(data)
                call = ref(m)
                def written():
                    self.pending_write = False
                    self.reply(call, error='org.bluez.Error.Failed' if self.scenario == 'write-error' else None); unref(call)
                    if self.connected and path == COMMAND and self.scenario not in ('early-ack', 'write-error'): self.command(data)
                self.later(0.005, written)
            elif member == 'Get': self.reply(m, 'v', [('n', -42)])
            else:
                raise AssertionError('Unexpected method ' + interface + '.' + member)
            return 1
        except Exception as error:
            self.fatal = repr(error); self.running = False
            print('FAKE BLUEZ FAILURE:', repr(error), file=sys.stderr)
            return -5

    def run(self):
        print('READY', flush=True)
        def stop(*_): self.running = False
        signal.signal(signal.SIGTERM, stop)
        try:
            while self.running:
                while self.scheduled and self.scheduled[0][0] <= time.monotonic(): heapq.heappop(self.scheduled)[2]()
                while check(process(self.bus, None)) > 0: pass
                check(wait(self.bus, 10000))
        finally:
            self.output.write_text(json.dumps({'calls': self.log, 'fatal': self.fatal}))
            close_bus(self.bus)
        return 1 if self.fatal else 0

if __name__ == '__main__':
    if not os.environ.get('DBUS_SYSTEM_BUS_ADDRESS', '').startswith('unix:'): raise SystemExit('Private bus address required')
    sys.exit(BlueZ(sys.argv[1], int(sys.argv[2], 0), Path(sys.argv[3])).run())
