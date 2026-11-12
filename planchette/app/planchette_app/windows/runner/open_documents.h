#ifndef RUNNER_OPEN_DOCUMENTS_H_
#define RUNNER_OPEN_DOCUMENTS_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>
#include <vector>

// The document opens' host: serves "planchette/documents" on the app's
// engine. A second launch's forwarded argv arrives over WM_COPYDATA and
// queues until the Dart intake's 'ready' drains it; later forwards arrive
// as 'open' calls, the macOS runner's handshake (AppDelegate.swift).
// Owned by the main window, and destroyed before its engine.
class OpenDocumentsHost {
 public:
  explicit OpenDocumentsHost(flutter::BinaryMessenger* messenger);
  ~OpenDocumentsHost();

  OpenDocumentsHost(const OpenDocumentsHost&) = delete;
  OpenDocumentsHost& operator=(const OpenDocumentsHost&) = delete;

  // Handles the WM_COPYDATA a second launch sends; returns true when the
  // message was a document forward.
  bool HandleWindowMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
          result);
  void Deliver(const std::vector<std::string>& documents);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::vector<std::string> pending_;
  bool ready_ = false;
};

#endif  // RUNNER_OPEN_DOCUMENTS_H_
