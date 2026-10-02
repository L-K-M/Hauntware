#ifndef RUNNER_DOCUMENT_WINDOWS_H_
#define RUNNER_DOCUMENT_WINDOWS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter_windows.h>
#include <windows.h>

#include <cstdint>
#include <map>
#include <memory>
#include <set>

class DocumentFlutterWindow;

// The document windows' host: serves "planchette/windows" on the app's
// engine (the protocol is the library doc of lib/services/window_host.dart).
//
// Every extra window is a top-level window holding a view the app's own
// engine renders (FlutterDesktopEngineCreateViewController), so it runs in
// the same isolate as the main window and shares its state. Closing one
// only reports "closeRequested"; Dart drops the window's widgets and then
// asks for "destroy", which removes the view from the engine.
//
// The extra windows do not pass their messages to the plugins'
// top-level window procs, as the main window does: window_manager's proc
// takes every message it is given for the main window's (a close, a
// minimize, full screen), whichever window sent it. They pass them to the
// engine's lifecycle only.
//
// The file pickers the app asks for belong to the window that asked, so a
// dialog never opens on the main window while another window made the
// request — and never on a hidden main window at all.
//
// Owned by the main window, and destroyed before its engine.
class DocumentWindowsHost {
 public:
  DocumentWindowsHost(HWND main_window, flutter::BinaryMessenger* messenger);
  ~DocumentWindowsHost();

  DocumentWindowsHost(const DocumentWindowsHost&) = delete;
  DocumentWindowsHost& operator=(const DocumentWindowsHost&) = delete;

  // The main window's messages this host listens to: its activation.
  void HandleMainWindowMessage(UINT message, WPARAM wparam);

  // An extra window's Flutter view HWND by its view id, or nullptr.
  HWND ViewFor(int64_t view_id) const;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void Create(
      const flutter::EncodableMap* arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void PickOpenFiles(
      HWND owner,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void PickSavePath(
      HWND owner,
      const flutter::EncodableMap* arguments,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  void SendEvent(const char* event, int64_t view_id);
  HWND WindowFor(int64_t view_id) const;
  DocumentFlutterWindow* ExtraWindow(int64_t view_id) const;

  // Shows the windows created since the last frame; the engine calls it
  // on the next frame it presents.
  void ShowPending();

  HWND main_window_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::map<int64_t, std::unique_ptr<DocumentFlutterWindow>> windows_;
  std::set<int64_t> pending_show_;
};

#endif  // RUNNER_DOCUMENT_WINDOWS_H_
