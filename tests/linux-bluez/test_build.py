"""Linux integration build guards and relocation of the native install layout."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

def run(*args, cwd=None):
    return subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, check=False)

def backend_block(emulator):
    additions = '\n'.join(line[1:] for line in (ROOT / f'Integrations/Emulators/{emulator}.patch').read_text().splitlines()
                          if line.startswith('+') and not line.startswith('+++'))
    start = additions.index('if(ENABLE_SWITCH2KIT)', additions.index('option(ENABLE_SWITCH2KIT'))
    depth = 0; block = []
    for line in additions[start:].splitlines():
        block.append(line)
        if line.strip().startswith('if('): depth += 1
        if line.strip() == 'endif()': depth -= 1
        if depth == 0: return '\n'.join(block)
    raise AssertionError('unterminated integration condition')

class LinuxBuildTests(unittest.TestCase):
    def test_radio_runner_skips_other_platforms(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            uname = root / 'uname'
            uname.write_text('#!/bin/sh\nprintf "Darwin\\n"\n')
            uname.chmod(0o755)
            result = subprocess.run(['bash', str(ROOT/'tests/linux-bluez/run.sh')],
                env=dict(os.environ, PATH=str(root)+os.pathsep+os.environ['PATH']),
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn('SKIP Linux BlueZ', result.stdout)

    def test_cemu_native_loop_pumps_when_sdl_has_no_events(self):
        # Compile the actual revised event-loop hunk, not a copy of its logic.
        patch = (ROOT/'Integrations/Emulators/cemu.patch').read_text()
        match = re.search(r'@@[^\n]*SDLControllerProvider::event_thread\(\)\n(.*?)(?=\ndiff --git |\n@@|\Z)', patch, re.S)
        self.assertIsNotNone(match, 'Cemu must pump the native adapter in its non-Apple event loop')
        body = '\n'.join(line[1:] for line in match.group(1).splitlines() if line.startswith((' ', '+')))
        self.assertIn('while (s_running.load', body)
        fixture = r'''
#include <atomic>
#include <cassert>
std::atomic<bool> s_running{true};
int pumps=0, waits=0, handled=0, shut=0;
struct SDL_Event {};
struct Native { void pump() { ++pumps; } };
Native& nativeControllers() { static Native n; return n; }
int SDL_WaitEventTimeout(SDL_Event*, int timeout) {
    assert(timeout > 0 && timeout <= 16);
    ++waits;
    if (waits == 4) { s_running=false; return 1; }
    return 0;
}
int SDL_WaitEvent(SDL_Event*) { ++waits; s_running=false; return 1; }
void HandleSDLEvent(SDL_Event&) { ++handled; }
void ShutdownSDL() { ++shut; }
struct SDLControllerProvider { void event_thread(); };
void SDLControllerProvider::event_thread() {
''' + body + r'''
int main() {
    SDLControllerProvider{}.event_thread();
    assert(shut == 1 && handled == 1);
#ifdef HAVE_SWITCH2KIT
    assert(pumps == 4 && waits == 4);
#else
    assert(pumps == 0 && waits == 1);
#endif
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); (root/'loop.cpp').write_text(fixture)
            for enabled in (False, True):
                flags=['-DHAVE_SWITCH2KIT'] if enabled else []
                result=run('c++','-std=c++17','-Wall','-Wextra','-Werror',*flags,str(root/'loop.cpp'),'-o',str(root/'loop'))
                self.assertEqual(result.returncode,0,result.stdout)
                result=subprocess.run([str(root/'loop')],timeout=2,check=False)
                self.assertEqual(result.returncode,0)

    def test_optional_emulator_platform_guards(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); sdk = root / 'sdk/Integrations/SDL3'; sdk.mkdir(parents=True)
            (sdk / 'CMakeLists.txt').write_text('add_library(Switch2Kit::SDL3 INTERFACE IMPORTED GLOBAL)\n')
            (root / 'empty.c').write_text('void empty(void) {}\n')
            for emulator in ('dolphin', 'cemu'):
                for system, enabled, sdl, qt, bundle, expected in [
                    ('Linux', True, True, True, False, True),
                    ('Windows', True, True, True, False, False),
                    ('Windows', False, True, True, False, True),
                    ('Linux', True, False, True, False, False),
                    ('Darwin', True, True, True, True, True),
                    ('Darwin', True, True, True, False, emulator == 'dolphin'),
                    ('Linux', True, True, False, False, emulator == 'cemu')]:
                    with self.subTest(emulator=emulator, system=system, enabled=enabled, sdl=sdl, qt=qt, bundle=bundle):
                        def flag(b): return 'ON' if b else 'OFF'
                        text = 'cmake_minimum_required(VERSION 3.24)\nproject(Guard C)\nadd_library(inputcommon STATIC empty.c)\n'
                        values = dict(CMAKE_SYSTEM_NAME=system, APPLE=flag(system=='Darwin'), ENABLE_SWITCH2KIT=flag(enabled),
                                      ENABLE_SDL=flag(sdl), ENABLE_QT=flag(qt), MACOS_BUNDLE=flag(bundle), SWITCH2KIT_SOURCE_DIR=str(root/'sdk'))
                        text += ''.join(f'set({key} "{value}")\n' for key,value in values.items()) + backend_block(emulator)
                        (root/'CMakeLists.txt').write_text(text)
                        result=run('cmake','-S',str(root),'-B',str(root/'build'))
                        self.assertEqual(result.returncode == 0, expected, result.stdout)
                        shutil.rmtree(root/'build', ignore_errors=True)

    def test_installed_library_and_notices_relocate_with_host(self):
        with tempfile.TemporaryDirectory(prefix='Switch2Kit Linux install ') as temporary:
            root=Path(temporary)
            (root/'lib.c').write_text('int fixture(void) { return 42; }\n')
            (root/'main.c').write_text('extern int fixture(void); int main(void) { return fixture() != 42; }\n')
            (root/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.24)
project(InstallFixture C)
include(GNUInstallDirs)
add_library(Switch2KitC SHARED lib.c)
add_library(Switch2Kit::C ALIAS Switch2KitC)
add_executable(host main.c)
target_link_libraries(host PRIVATE Switch2Kit::C)
include("{ROOT}/Integrations/CMake/Linux.cmake")
switch2kit_install_linux(host)
install(TARGETS host RUNTIME DESTINATION "${{CMAKE_INSTALL_BINDIR}}")
''')
            for args in [('cmake','-S',str(root),'-B',str(root/'build')), ('cmake','--build',str(root/'build')),
                         ('cmake','--install',str(root/'build'),'--prefix',str(root/'installed'))]:
                result=run(*args); self.assertEqual(result.returncode,0,result.stdout)
            (root/'installed').rename(root/'relocated')
            shutil.rmtree(root/'build')
            result=run(str(root/'relocated/bin/host')); self.assertEqual(result.returncode,0,result.stdout)
            self.assertEqual((root/'relocated/share/Switch2KitNotices/CREDITS.md').read_bytes(), (ROOT/'CREDITS.md').read_bytes())
            for source in (ROOT/'LICENSES').glob('*'):
                if source.is_file(): self.assertEqual((root/'relocated/share/Switch2KitNotices/LICENSES'/source.name).read_bytes(),source.read_bytes())

if __name__ == '__main__': unittest.main()
