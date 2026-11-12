#!/usr/bin/env bash
# Exercise the actual validation body without starting Flutter, an application
# or a window. AppKit's menu item objects are the only native UI objects here.
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo "This native menu test requires macOS." >&2
  exit 1
fi
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/seance-menu.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT

python3 - "$repo_root/app/seance_app/macos/Runner/MainFlutterWindow.swift" \
  "$test_dir/menu-validation.swift" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index('  override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {')
brace = source.index('{', start)
depth = 1
end = brace + 1
while depth:
    if source[end] == '{':
        depth += 1
    elif source[end] == '}':
        depth -= 1
    end += 1
method = source[start:end]

# Keep the production body intact. The host supplies only window/editor
# flags and menu identities, so validation cannot depend on a Dart engine.
program = r'''
import Cocoa

class ValidationBase {
  func validateMenuItem(_ item: NSMenuItem) -> Bool { false }
}

class ValidationFixture: ValidationBase {
  var isKeyWindow = false
  var editorActive = false
  let undoItem: NSMenuItem? = NSMenuItem(title: "Undo", action: nil, keyEquivalent: "")
  let redoItem: NSMenuItem? = NSMenuItem(title: "Redo", action: nil, keyEquivalent: "")
  let saveItem: NSMenuItem? = NSMenuItem(title: "Save", action: nil, keyEquivalent: "")
  let findItem: NSMenuItem? = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
''' + method + r'''
}

func require(_ condition: Bool, _ message: String) {
  if !condition {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

let window = ValidationFixture()
var checks = 0
for key in [false, true] {
  window.isKeyWindow = key
  for editor in [false, true] {
    window.editorActive = editor
    for item in [window.saveItem!, window.findItem!] {
      require(window.validateMenuItem(item) == (key && editor),
        "Save/Find must require the mounted main editor and key window")
      checks += 1
    }
  }
  for enabled in [false, true] {
    for item in [window.undoItem!, window.redoItem!] {
      item.isEnabled = enabled
      require(window.validateMenuItem(item) == enabled,
        "Dart-enabled Undo/Redo must retain its responder fallback when Settings is key")
      checks += 1
    }
  }
}
// AppKit can write validation back into isEnabled. A trip through Settings
// must not latch a still-valid history item off when the main window returns.
for item in [window.undoItem!, window.redoItem!] {
  item.isEnabled = true
  window.isKeyWindow = false
  item.isEnabled = window.validateMenuItem(item)
  window.isKeyWindow = true
  require(window.validateMenuItem(item), "Changing key windows latched history off")
  checks += 1
}
require(!window.validateMenuItem(NSMenuItem()), "Unknown items must use superclass validation")
checks += 1
print("Native menu validation: \(checks) checks passed")
'''
Path(sys.argv[2]).write_text(program)
PY

xcrun swift "$test_dir/menu-validation.swift"
