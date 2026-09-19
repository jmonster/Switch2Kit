#!/usr/bin/env python3
"""Reproduce the EWMH readiness race on an owned Xvfb/Openbox display.

The small Xlib window is an observer fixture, not an emulator or controller.
Real extracted application qualification remains a separate required job.
"""
import importlib.util
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import threading

spec = importlib.util.spec_from_file_location("linux_launch", Path(__file__).with_name("linux.py"))
linux = importlib.util.module_from_spec(spec)
spec.loader.exec_module(linux)

WINDOW = r'''
#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <string.h>
#include <unistd.h>
int main(void) {
  char start;
  if (read(STDIN_FILENO, &start, 1) != 1) return 4;
  Display* d = XOpenDisplay(NULL);
  if (!d) return 2;
  Window w = XCreateSimpleWindow(d, DefaultRootWindow(d), 0, 0, 400, 300, 0, 0, 0);
  unsigned long pid = (unsigned long)getpid();
  Atom type = XInternAtom(d, "_NET_WM_WINDOW_TYPE_NORMAL", False);
  XChangeProperty(d, w, XInternAtom(d, "_NET_WM_PID", False), XA_CARDINAL, 32,
                  PropModeReplace, (unsigned char*)&pid, 1);
  XChangeProperty(d, w, XInternAtom(d, "_NET_WM_WINDOW_TYPE", False), XA_ATOM, 32,
                  PropModeReplace, (unsigned char*)&type, 1);
  Atom close = XInternAtom(d, "WM_DELETE_WINDOW", False);
  XSetWMProtocols(d, w, &close, 1);
  XStoreName(d, w, "Switch2Kit observer fixture - no controller input");
  char hostname[256] = {0};
  if (gethostname(hostname, sizeof(hostname) - 1) != 0) return 3;
  XTextProperty machine = {(unsigned char*)hostname, XA_STRING, 8, strlen(hostname)};
  XSetWMClientMachine(d, w, &machine);
  XClassHint hint = {"s2k-observer-fixture", "S2KObserverFixture"};
  XSetClassHint(d, w, &hint);
  XMapWindow(d, w);
  XFlush(d);
  for (;;) {
    XEvent e;
    XNextEvent(d, &e);
    if (e.type == ClientMessage && (Atom)e.xclient.data.l[0] == close) break;
  }
  XDestroyWindow(d, w);
  XCloseDisplay(d);
  return 0;
}
'''


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def main():
    display = manager = child = None
    with tempfile.TemporaryDirectory(prefix="s2k native observer ") as directory:
        root = Path(directory)
        source, binary = root / "window.c", root / "window"
        source.write_text(WINDOW)
        subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", str(source), "-lX11", "-o", str(binary)],
                       check=True, timeout=30)
        read_fd, write_fd = os.pipe()
        try:
            display = subprocess.Popen(["Xvfb", "-displayfd", str(write_fd), "-screen", "0", "1024x768x24",
                                        "-nolisten", "tcp"], pass_fds=(write_fd,), stdout=subprocess.DEVNULL)
        finally:
            os.close(write_fd)
        try:
            require(bool(select.select([read_fd], [], [], 5)[0]), "The private Xvfb did not start")
            number = os.read(read_fd, 32).decode().strip()
            require(number.isdecimal(), "Invalid private display number")
            env = {"PATH": "/usr/bin:/bin", "HOME": str(root), "DISPLAY": ":" + number, "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8"}
            with (root / "openbox.log").open("w") as log:
                manager = subprocess.Popen(["openbox", "--sm-disable"], env=env, stdout=log, stderr=log)
                linux.wait_window_manager(manager, env)
                # Reproduce the observed intermediate startup state: identity
                # published, but client-list property not published yet.
                linux.command(["xprop", "-root", "-remove", "_NET_CLIENT_LIST"], env)
                linux.command(["wmctrl", "-m"], env)
                child = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE)
                try:
                    linux.windows(child.pid, env)
                except linux.LaunchFailure:
                    print("PASS reproduced original identity-only readiness failure", flush=True)
                else:
                    raise RuntimeError("The missing-list negative control was ineffective")
                def release_window():
                    child.stdin.write(b"x")
                    child.stdin.close()
                started = time.monotonic()
                release = threading.Timer(0.3, release_window)
                release.start()
                try:
                    linux.wait_window_manager(manager, env)
                except Exception:
                    print("manager", manager.poll(), "child", child.poll(), flush=True)
                    for args in (["wmctrl", "-m"], ["wmctrl", "-lp"], ["xprop", "-root", "_NET_CLIENT_LIST"], ["xwininfo", "-root", "-tree"]):
                        print(subprocess.run(args, env=env, capture_output=True, text=True, timeout=5), flush=True)
                    print((root / "openbox.log").read_text(), flush=True)
                    raise
                finally:
                    release.join(timeout=2)
                require(time.monotonic() - started >= 0.2, "Readiness returned before the client list existed")
                for attempt in (1, 2):
                    if attempt == 2:
                        # A ready empty list must not require another fixture window.
                        require(linux.command(["wmctrl", "-lp"], env).strip() == "", "Owned window was not removed")
                        linux.wait_window_manager(manager, env)
                        child = subprocess.Popen([str(binary)], env=env, stdin=subprocess.PIPE)
                        release_window()
                    observed = []
                    def inspect():
                        observed[:] = linux.windows(child.pid, env)
                        return {"matched": bool(observed), "finished": bool(observed), "windows": len(observed)}
                    def close():
                        linux.command(["wmctrl", "-ic", observed[0]], env)
                        return {"quit_requested": True}
                    result = linux.supervise(child, inspect, close)
                    print(json.dumps({"attempt": attempt, **result}), flush=True)
                    require(result["status"] == "passed" and not result["forced_cleanup"],
                            "Native window observation/normal shutdown failed")
                    child = None
        finally:
            os.close(read_fd)
            stop(child)
            stop(manager)
            stop(display)
    print("PASS owned X11 readiness, real normal-window observation, normal close and relaunch; no emulator/hardware claim")


if __name__ == "__main__":
    main()
