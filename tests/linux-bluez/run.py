"""Run the real native C ABI against an isolated synthetic BlueZ D-Bus service."""
import argparse
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]

def run_case(binary, scenario, model):
    with tempfile.TemporaryDirectory(prefix='switch2kit-bluez-') as work:
        daemon_args = ['--session']
        if scenario == 'match-denied':
            config = Path(work) / 'bus.conf'
            config.write_text('<busconfig><type>session</type><listen>unix:tmpdir=' + work + '</listen>'
                '<policy context="default"><allow send_destination="*"/><allow receive_sender="*"/>'
                '<allow own="*"/><deny send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus" send_member="AddMatch"/>'
                '</policy></busconfig>')
            daemon_args = ['--config-file=' + str(config)]
        daemon = subprocess.Popen(['dbus-daemon', *daemon_args, '--nofork', '--print-address=1'], stdout=subprocess.PIPE, text=True)
        service = None
        try:
            address = daemon.stdout.readline().strip()
            if not address.startswith('unix:'): raise RuntimeError('private D-Bus daemon did not start')
            env = dict(os.environ, DBUS_SYSTEM_BUS_ADDRESS=address)
            log = Path(work) / 'calls.json'
            if scenario != 'no-bus':
                service = subprocess.Popen([sys.executable, str(Path(__file__).with_name('fake_bluez.py')), scenario, str(model), str(log)], env=env, stdout=subprocess.PIPE, text=True)
                with selectors.DefaultSelector() as selector:
                    selector.register(service.stdout, selectors.EVENT_READ)
                    if not selector.select(5) or service.stdout.readline().strip() != 'READY': raise RuntimeError('fake service did not start')
            else:
                env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=' + work + '/absent'
            subprocess.run([str(binary), scenario, str(model)], env=env, check=True, timeout=20)
        finally:
            if service:
                service.terminate()
                try: service.wait(3)
                except subprocess.TimeoutExpired: service.kill(); service.wait(); raise
            daemon.terminate()
            try: daemon.wait(3)
            except subprocess.TimeoutExpired: daemon.kill(); daemon.wait(); raise
        if service:
            data = json.loads(log.read_text()); assert service.returncode == 0 and data['fatal'] is None, data
            calls = data['calls']; names = [x['member'] for x in calls]
            assert not {'Pair', 'RemoveDevice', 'Set'} & set(names), names
            if scenario in ('cached', 'foreign', 'wrong-company', 'denied', 'no-adapter'): assert 'Connect' not in names
            if scenario == 'adapter-switch':
                for adapter in ('/org/bluez/hci0', '/org/bluez/hci1'):
                    owned = [x['member'] for x in calls if x['path'] == adapter]
                    assert 'StartDiscovery' in owned and 'StopDiscovery' in owned, (adapter, owned)
            if scenario == 'cancel-connect': assert 'Disconnect' in names
            if scenario == 'cancel-scan': assert 'StopDiscovery' in names and 'Connect' not in names
            if scenario in ('live', 'early-ack'):
                assert names.count('Connect') >= 2 and names.count('Disconnect') >= 2
                assert any(x['path'].endswith('char0005') and x['member'] == 'WriteValue' for x in calls), 'motor not written'
                print('PASS D-Bus ownership, framing, notifications, motor routing and bounded writes')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--scenario')
    args = parser.parse_args()
    cases = [(args.scenario, 0x2073)] if args.scenario else [('live', m) for m in (0x2069, 0x2067, 0x2066, 0x2073)] + [(s, 0x2073) for s in ('no-bus', 'no-adapter', 'denied', 'cached', 'foreign', 'wrong-company', 'notify-denied', 'short-mtu', 'cancel-connect', 'cancel-scan', 'early-ack', 'write-error', 'service-reset', 'oversized', 'match-denied', 'adapter-switch')]
    for scenario, model in cases: run_case(args.binary.resolve(), scenario, model)
    print(f'PASS {len(cases)} isolated BlueZ scenarios; no physical radio used')

if __name__ == '__main__': main()
