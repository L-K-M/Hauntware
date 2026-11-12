#!/usr/bin/env python3
"""Exercise the plugin's actual detach bodies without Android or an app.

Requires Python 3 and a JDK. On macOS set JAVA_HOME to the installed JDK;
this avoids invoking the system Java installer stub. Only temporary JVM
fixtures are compiled. This is not an Android/device lifecycle smoke test.
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


SOURCE = (
    Path(__file__).resolve().parents[1]
    / "android/src/main/java/ch/lkmc/ghost/keepalive/GhostKeepAlivePlugin.java"
)


def method_body(source, name):
    matches = list(re.finditer(r"\bpublic\s+void\s+" + name + r"\s*\([^)]*\)\s*\{", source))
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one production callback: {name}")
    start = matches[0].end()
    i, depth, state = start, 1, "code"
    while i < len(source):
        char = source[i]
        pair = source[i:i + 2]
        if state == "line":
            if char == "\n":
                state = "code"
        elif state == "block":
            if pair == "*/":
                state = "code"
                i += 1
        elif state in ('"', "'"):
            if char == "\\":
                i += 1
            elif char == state:
                state = "code"
        elif pair == "//":
            state = "line"
            i += 1
        elif pair == "/*":
            state = "block"
            i += 1
        elif char in ('"', "'"):
            state = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return source[start:i]
        i += 1
    raise ValueError(f"Unclosed production callback: {name}")


def java_tool(name):
    home = os.environ.get("JAVA_HOME")
    if home:
        path = Path(home) / "bin" / (name + (".exe" if os.name == "nt" else ""))
        if not path.is_file():
            raise ValueError(f"JAVA_HOME has no {name}: {path}")
        return str(path)
    if sys.platform == "darwin":
        raise ValueError("Set JAVA_HOME to an installed JDK to run the lifecycle fixture")
    path = shutil.which(name)
    if path is None:
        raise ValueError(f"Install a JDK or set JAVA_HOME: {name} was not found")
    return path


FIXTURE = r"""
public final class KeepAliveLifecycleFixture {
    static class Context {}
    static final class Activity extends Context {}
    static final class Binding {
        final Activity value;
        Binding(Activity value) { this.value = value; }
        Activity getActivity() { return value; }
    }
    static final class Channel {
        boolean handlerCleared;
        void setMethodCallHandler(Object handler) { handlerCleared = handler == null; }
    }
    static final class KeepAliveService {
        static boolean active;
        static int stops;
        static Context lastContext;
        static void reset() { active = true; stops = 0; lastContext = null; }
        static void stop(Context context) {
            check(context != null, "stop lost its application context");
            active = false;
            stops++;
            lastContext = context;
        }
    }
    Context applicationContext = new Context();
    Activity activity = new Activity();
    Channel channel = new Channel();
    void engineDetach() { @ENGINE@ }
    void activityDetach() { @ACTIVITY@ }
    void configDetach() { @CONFIG@ }
    void configReattach(Binding binding) { @REATTACH@ }
    static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    static KeepAliveLifecycleFixture fresh() {
        KeepAliveService.reset();
        return new KeepAliveLifecycleFixture();
    }
    static void configThenDestroy() {
        KeepAliveLifecycleFixture f = fresh();
        Context context = f.applicationContext;
        Channel channel = f.channel;
        f.configDetach();
        check(f.activity == null && KeepAliveService.active,
              "temporary config detach must preserve the anchor");
        f.engineDetach();
        check(!KeepAliveService.active, "config detach then engine destruction left anchor active");
        check(KeepAliveService.lastContext == context, "engine teardown used the wrong context");
        check(f.applicationContext == null && f.channel == null && channel.handlerCleared,
              "engine teardown retained its bindings");
    }
    static void normalThenDestroy() {
        KeepAliveLifecycleFixture f = fresh();
        f.activityDetach();
        check(!KeepAliveService.active && f.activity == null, "activity teardown left anchor active");
        f.engineDetach();
        check(!KeepAliveService.active, "engine teardown reactivated the anchor");
    }
    static void temporaryReattach() {
        KeepAliveLifecycleFixture f = fresh();
        Activity next = new Activity();
        f.configDetach();
        f.configReattach(new Binding(next));
        check(f.activity == next && KeepAliveService.active && KeepAliveService.stops == 0,
              "a surviving engine lost its anchor across config reattachment");
        f.engineDetach();
    }
    static void noActivity() {
        KeepAliveLifecycleFixture f = fresh();
        f.activity = null;
        f.engineDetach();
        check(!KeepAliveService.active, "engine without an activity left anchor active");
    }
    static void repeatedDetach() {
        KeepAliveLifecycleFixture f = fresh();
        f.engineDetach();
        f.engineDetach();
        check(!KeepAliveService.active && KeepAliveService.stops >= 1,
              "repeat teardown did not remain stopped");
    }
    public static void main(String[] args) {
        configThenDestroy(); normalThenDestroy(); temporaryReattach(); noActivity(); repeatedDetach();
        System.out.println("PASS: keep-alive lifecycle, 5 JVM scenarios");
    }
}
"""


def main():
    source = SOURCE.read_text(encoding="utf-8")
    fixture = FIXTURE
    for token, name in {
        "@ENGINE@": "onDetachedFromEngine",
        "@ACTIVITY@": "onDetachedFromActivity",
        "@CONFIG@": "onDetachedFromActivityForConfigChanges",
        "@REATTACH@": "onReattachedToActivityForConfigChanges",
    }.items():
        fixture = fixture.replace(token, method_body(source, name))
    with tempfile.TemporaryDirectory(prefix="keepalive-lifecycle-") as directory:
        path = Path(directory) / "KeepAliveLifecycleFixture.java"
        path.write_text(fixture, encoding="utf-8")
        subprocess.run([java_tool("javac"), str(path)], check=True)
        subprocess.run([java_tool("java"), "-cp", directory, path.stem], check=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        print(f"Keep-alive lifecycle fixture failed: {error}", file=sys.stderr)
        raise SystemExit(1)
