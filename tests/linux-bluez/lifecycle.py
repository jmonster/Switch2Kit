"""Run BlueZ lifecycle method bodies without opening a bus or physical radio.

Only imports and access control change in generated Swift sources. The tests
replace the sd-bus class, not the production central/peripheral method bodies.
The package's actual values, protocol constants and identity code are linked.
"""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bin', required=True, type=Path)
    args = parser.parse_args()
    binary_directory = args.bin.resolve()
    with tempfile.TemporaryDirectory(prefix='switch2kit-bluez-lifecycle-') as temporary:
        work = Path(temporary)
        sources = []
        for name in ('Central', 'RadioTypes'):
            source = (ROOT / f'Sources/Switch2Kit/Platform/BlueZ/{name}.swift').read_text()
            source = source.replace('import Foundation', 'import Foundation\n@testable import Switch2Kit', 1)
            source = re.sub(r'\bprivate\(set\)\s*|\bprivate\s+', '', source)
            destination = work / f'{name}.swift'
            destination.write_text(source)
            sources.append(str(destination))
        binary = work / 'lifecycle'
        subprocess.run([
            os.environ.get('SWIFTC', 'swiftc'), '-swift-version', '6', '-package-name', 'Switch2Kit', '-warnings-as-errors',
            '-I', str(binary_directory / 'Modules'),
            '-I', str(ROOT / 'Sources/Switch2KitDBus/include'),
            *sources, str(ROOT / 'tests/linux-bluez/LifecycleTests.swift'),
            '-L', str(binary_directory), '-lSwitch2KitC',
            '-Xlinker', '-rpath', '-Xlinker', str(binary_directory), '-o', str(binary)
        ], check=True)
        subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == '__main__':
    main()
