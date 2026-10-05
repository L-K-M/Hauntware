#!/usr/bin/env python3
"""Launch a desktop release build and check that Dart brings up its UI.

Unit tests run with asserts on and cannot see a release-only startup
failure. Such a launch leaves a running app without its UI: macOS keeps
the window hidden until Dart shows it, and the Linux and Windows runners
show theirs on the first frame. This starts the built app under a
throwaway home and waits for

  * a visible window of the process (on macOS, on screen and taller than
    the menu bar strips the app also owns),
  * with --title, a window title matching the pattern (the runners set a
    plain default; a document title is Dart's),
  * with --menu (macOS), a menu bar title the app's Dart menus install,

then requires the app to stay up a few seconds and its output to hold no
unhandled Dart exception. After a crash on macOS it prints the crash
report. A check this process may not read (window titles need Screen
Recording, menus Accessibility) is reported as skipped, never as passed.

  scripts/test-desktop-launch.py APP [--title REGEX] [--menu TITLE]

APP is the .app bundle on macOS, the bundle's binary on Linux (needs an
X display, e.g. under xvfb-run, and xdotool) and the .exe on Windows.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

# Generous for a cold first launch on a CI runner; a healthy one takes seconds.
LAUNCH_TIMEOUT_SECONDS = 60
# A launch that dies a few seconds in is as broken as one that never shows.
STABLE_SECONDS = 5
POLL_SECONDS = 0.25
# macOS: the app's other layer-0 windows, its menu bar strips, are 24 pt.
MINIMUM_MAC_WINDOW_HEIGHT = 100
CRASH_REPORT_WAIT_SECONDS = 20
CRASH_REPORT_FRAMES = 30
# What the engine prints for an error that escapes Dart's main() or a zone;
# the process keeps running, so only the output shows it.
UNHANDLED_DART_ERROR = "Unhandled Exception"


@dataclass(frozen=True)
class Window:
    title: str | None  # None: this process may not read it.


@dataclass(frozen=True)
class Snapshot:
    windows: list[Window]
    menus: list[str] | None  # None: not readable here, or not macOS.

    def describe(self) -> str:
        titles = ", ".join(
            repr(w.title) if w.title is not None else "(unreadable title)"
            for w in self.windows
        )
        text = f"windows [{titles}]" if self.windows else "no window"
        if self.menus is not None:
            text += f", menus [{', '.join(self.menus)}]"
        return text


class MacProbe:
    """On-screen windows and menus through scripts/macos-launch-probe.swift."""

    def __init__(self, work: Path) -> None:
        self._binary = work / "macos-launch-probe"
        subprocess.run(
            [
                "xcrun",
                "swiftc",
                str(SCRIPT_DIR / "macos-launch-probe.swift"),
                "-o",
                str(self._binary),
            ],
            check=True,
        )

    def look(self, pid: int) -> Snapshot:
        result = subprocess.run(
            [str(self._binary), str(pid)], capture_output=True, text=True, check=True
        )
        report = json.loads(result.stdout)
        windows = [
            Window(window["title"])
            for window in report["windows"]
            if window["height"] >= MINIMUM_MAC_WINDOW_HEIGHT
        ]
        return Snapshot(windows, report["menus"])


class LinuxProbe:
    """Mapped X11 windows of the process, through xdotool."""

    def __init__(self) -> None:
        if not os.environ.get("DISPLAY"):
            sys.exit("No X display: run this under xvfb-run on a headless machine.")
        if shutil.which("xdotool") is None:
            sys.exit("xdotool is required on Linux.")
        # Titles are UTF-8 (an em dash in Planchette's); decode them as such.
        self._env = {**os.environ, "LC_ALL": "C.UTF-8"}

    def look(self, pid: int) -> Snapshot:
        found = subprocess.run(
            ["xdotool", "search", "--onlyvisible", "--pid", str(pid)],
            capture_output=True,
            text=True,
            env=self._env,
        )
        windows = []
        for window_id in found.stdout.split():
            name = subprocess.run(
                ["xdotool", "getwindowname", window_id],
                capture_output=True,
                encoding="utf-8",
                errors="replace",
                env=self._env,
            )
            title = name.stdout.rstrip("\n") if name.returncode == 0 else None
            windows.append(Window(title))
        return Snapshot(windows, None)


class WindowsProbe:
    """Visible top-level windows of the process, through user32."""

    def __init__(self) -> None:
        import ctypes
        from ctypes import wintypes

        self._ctypes = ctypes
        self._user32 = ctypes.WinDLL("user32", use_last_error=True)
        self._callback_type = ctypes.WINFUNCTYPE(
            wintypes.BOOL, wintypes.HWND, wintypes.LPARAM
        )
        self._user32.EnumWindows.argtypes = [self._callback_type, wintypes.LPARAM]
        self._user32.GetWindowThreadProcessId.argtypes = [
            wintypes.HWND,
            ctypes.POINTER(wintypes.DWORD),
        ]
        self._user32.GetWindowThreadProcessId.restype = wintypes.DWORD
        self._user32.IsWindowVisible.argtypes = [wintypes.HWND]
        self._user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
        self._user32.GetWindowTextW.argtypes = [
            wintypes.HWND,
            wintypes.LPWSTR,
            ctypes.c_int,
        ]
        self._dword = wintypes.DWORD

    def look(self, pid: int) -> Snapshot:
        ctypes = self._ctypes
        user32 = self._user32
        windows: list[Window] = []

        def visit(hwnd, _):
            owner = self._dword()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
            if owner.value == pid and user32.IsWindowVisible(hwnd):
                length = user32.GetWindowTextLengthW(hwnd)
                buffer = ctypes.create_unicode_buffer(length + 1)
                user32.GetWindowTextW(hwnd, buffer, length + 1)
                windows.append(Window(buffer.value))
            return True

        user32.EnumWindows(self._callback_type(visit), 0)
        return Snapshot(windows, None)


@dataclass(frozen=True)
class Outcome:
    passed: bool
    message: str
    crashed: bool = False


def executable(app: Path) -> Path:
    if sys.platform != "darwin":
        return app
    with (app / "Contents" / "Info.plist").open("rb") as plist:
        name = plistlib.load(plist)["CFBundleExecutable"]
    return app / "Contents" / "MacOS" / name


def throwaway_env(home: Path) -> dict[str, str]:
    """Keeps this machine's settings and remembered window frames out of
    the launch, and the launch's out of them."""
    places = {
        "HOME": home,
        "XDG_CONFIG_HOME": home / ".config",
        "XDG_DATA_HOME": home / ".local" / "share",
        "XDG_STATE_HOME": home / ".local" / "state",
        "XDG_CACHE_HOME": home / ".cache",
        "APPDATA": home / "AppData" / "Roaming",
        "LOCALAPPDATA": home / "AppData" / "Local",
    }
    for place in places.values():
        place.mkdir(parents=True, exist_ok=True)
    return {**os.environ, **{key: str(place) for key, place in places.items()}}


class Readiness:
    """Whether a snapshot shows the UI Dart puts up, per the requested checks."""

    def __init__(self, title: re.Pattern[str] | None, menu: str | None) -> None:
        self._title = title
        self._menu = menu
        self._skipped: set[str] = set()

    def _skip(self, check: str, reason: str) -> None:
        if check in self._skipped:
            return
        self._skipped.add(check)
        print(f"{check} check skipped: {reason}")

    def met(self, snapshot: Snapshot) -> bool:
        if not snapshot.windows:
            return False

        if self._title is not None:
            readable = [w.title for w in snapshot.windows if w.title is not None]
            if not readable:
                self._skip("Title", "this process may not read window titles.")
            elif not any(self._title.search(title) for title in readable):
                return False

        if self._menu is not None:
            if snapshot.menus is None:
                self._skip("Menu", "this process is not trusted for accessibility.")
            elif self._menu not in snapshot.menus:
                return False

        return True


def watch(process: subprocess.Popen, probe, readiness: Readiness, name: str) -> Outcome:
    deadline = time.monotonic() + LAUNCH_TIMEOUT_SECONDS
    window_seen = False
    snapshot = Snapshot([], None)
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return Outcome(
                False,
                f"{name} exited during launch with status {process.returncode}.",
                crashed=True,
            )

        snapshot = probe.look(process.pid)
        window_seen = window_seen or bool(snapshot.windows)
        if readiness.met(snapshot):
            print(f"{name} is up: {snapshot.describe()}.")
            stable_until = time.monotonic() + STABLE_SECONDS
            while time.monotonic() < stable_until:
                if process.poll() is not None:
                    return Outcome(
                        False,
                        f"{name} exited after coming up, with status "
                        f"{process.returncode}.",
                        crashed=True,
                    )
                time.sleep(POLL_SECONDS)
            return Outcome(True, f"{name} stayed up for {STABLE_SECONDS} s.")
        time.sleep(POLL_SECONDS)

    seen = "a window came up" if window_seen else "no window ever came up"
    return Outcome(
        False,
        f"{name} did not come up within {LAUNCH_TIMEOUT_SECONDS} s ({seen}); "
        f"last seen: {snapshot.describe()}.",
    )


def print_crash_report(executable_name: str, since: float) -> None:
    """The macOS crash report of this launch: exception, crash info and the
    faulting thread, so CI shows the cause and not only "exited"."""
    # ReportCrash writes to the user's real home, whatever HOME the app had.
    reports = Path.home() / "Library" / "Logs" / "DiagnosticReports"
    report = None
    for _ in range(CRASH_REPORT_WAIT_SECONDS):
        candidates = [
            path
            for path in reports.glob(f"{executable_name}*.ips")
            if path.stat().st_mtime >= since
        ]
        if candidates:
            report = max(candidates, key=lambda path: path.stat().st_mtime)
            break
        time.sleep(1)
    if report is None:
        print(f"No crash report appeared in {reports}.")
        return

    print(f"--- Crash report {report}")
    try:
        body = json.loads(report.read_text().split("\n", 1)[1])
    except (ValueError, IndexError) as error:
        print(f"(unreadable: {error})")
        return
    images = body.get("usedImages", [])

    def show(frames) -> None:
        for frame in frames[:CRASH_REPORT_FRAMES]:
            index = frame.get("imageIndex")
            image = images[index].get("name", "?") if index is not None else "?"
            symbol = frame.get("symbol", hex(frame.get("imageOffset", 0)))
            source = frame.get("sourceFile")
            where = f" ({source}:{frame.get('sourceLine')})" if source else ""
            print(f"  {image} {symbol}{where}")

    print("exception:", json.dumps(body.get("exception")))
    print("termination:", json.dumps(body.get("termination")))
    for key, value in (body.get("asi") or {}).items():
        print("crash info:", key, json.dumps(value))
    if "lastExceptionBacktrace" in body:
        print("last exception backtrace:")
        show(body["lastExceptionBacktrace"])
    faulting = body.get("faultingThread", 0)
    print(f"faulting thread {faulting}:")
    show(body["threads"][faulting]["frames"])


def main() -> int:
    # Titles are Unicode (Planchette's has an em dash); a Windows code page
    # would print them garbled in the CI log.
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("app", type=Path)
    parser.add_argument("--title", type=re.compile, help="window title regex")
    parser.add_argument("--menu", help="menu bar title Dart installs (macOS)")
    args = parser.parse_args()
    if args.menu is not None and sys.platform != "darwin":
        parser.error("--menu is macOS only")

    binary = executable(args.app)
    if not binary.is_file():
        sys.exit(f"Missing {binary}. Build the release app first.")

    # A killed app can still hold its output file open briefly on Windows.
    with tempfile.TemporaryDirectory(
        prefix="desktop-launch-", ignore_cleanup_errors=True
    ) as scratch:
        work = Path(scratch)
        if sys.platform == "darwin":
            probe = MacProbe(work)
        elif sys.platform == "win32":
            probe = WindowsProbe()
        else:
            probe = LinuxProbe()

        output = work / "output.txt"
        launched_at = time.time()
        with output.open("wb") as sink:
            process = subprocess.Popen(
                [str(binary)],
                stdout=sink,
                stderr=subprocess.STDOUT,
                env=throwaway_env(work / "home"),
            )
        try:
            outcome = watch(
                process, probe, Readiness(args.title, args.menu), binary.name
            )
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()

        text = output.read_text(encoding="utf-8", errors="replace")
        passed = outcome.passed
        print(outcome.message)
        if UNHANDLED_DART_ERROR in text:
            print("Dart reported an unhandled exception during launch.")
            passed = False
        if not passed:
            print(f"--- {binary.name} output")
            print(text)
            if outcome.crashed and sys.platform == "darwin":
                print_crash_report(binary.name, launched_at)
        return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
