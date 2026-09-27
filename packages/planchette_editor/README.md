# planchette_editor

The shared Flutter editing surface used by Planchette, Poltergeist, and Séance.
It depends on `planchette_core` for document formats, safe file writes, language
detection, tokenization, and literal search.

`EditorController` owns one buffer, search/replacement fields, selection, focus,
scroll position, saved digest, and dirty/busy state. `PlanchetteEditor` renders
the buffer with optional line numbers and status. Hosts retain their menus,
window/tab lifecycle, file picking, remote checkout ownership, publishing,
notifications, and discard dialogs.

```dart
final editor = EditorController(
  displayPath: file.path,
  loadDocument: () => loadTextDocument(file),
  saveDocument: (text, baseline) {
    final loaded = baseline!; // This controller opens an existing document.
    return saveTextDocument(
      loaded.file,
      text,
      hasUtf8Bom: loaded.hasUtf8Bom,
      lineEnding: loaded.lineEnding,
      expectedSha256: loaded.sha256,
    );
  },
);

PlanchetteEditor(controller: editor);
```

The view initializes its controller automatically. Hosts may instead await
`initialize()` before mounting; repeated calls share the same initialization.
For a new document, supply `initialText: ''` and a host save callback that chooses
and safely creates its destination. Adopt Save As metadata with `adoptDocument`
and update `displayPath` without replacing the buffer or selection.

Keep each tab's editor mounted in an `IndexedStack` or equivalent and set
`isActive` appropriately. Flutter's undo stack belongs to the mounted text field,
so retaining only its controller does not retain undo history. Dispose the
controller when the document actually closes.

`save()` returns an outcome for the host's notification and throws on failure.
A primary save publishes when `onPublish` exists; a local save never publishes.
`onSaved` must reconcile a committed local write without throwing. It runs when
publishing was absent, declined, or failed, including after widget disposal.
These hooks are mutable for reconnects and are captured at save start.

`confirmClose` accepts the host's discard question, coalesces duplicate questions,
and rechecks busy state and the buffer revision afterward. Set `editingLocked`
while coordinating application shutdown. Ordinary save and replace commands are
then blocked; an explicit Save choice in that shutdown flow can use
`EditorSaveAccess.confirmedClose`.

`EditorStrings` adapts existing host localization resources. Token colors,
monospace style, an external-change banner, and the status row can be supplied
without introducing application dependencies into the package. The surface
installs find/replace shortcuts only; Save, Open, New, Close, and Quit belong to
the host.

Run `flutter analyze` and `flutter test` from this directory.
