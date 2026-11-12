#include "open_documents.h"

#include <flutter/standard_method_codec.h>

#include "single_instance.h"

namespace {

constexpr char kChannel[] = "planchette/documents";
constexpr char kReadyMethod[] = "ready";
constexpr char kOpenMethod[] = "open";

// The WM_COPYDATA payload is UTF-16; the channel strings are UTF-8.
std::string Utf8FromWide(const wchar_t* wide, size_t length) {
  if (length == 0) {
    return std::string();
  }
  const int size = ::WideCharToMultiByte(
      CP_UTF8, 0, wide, static_cast<int>(length), nullptr, 0, nullptr,
      nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string utf8(size, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide, static_cast<int>(length),
                      utf8.data(), size, nullptr, nullptr);
  return utf8;
}

}  // namespace

OpenDocumentsHost::OpenDocumentsHost(flutter::BinaryMessenger* messenger) {
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannel, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

OpenDocumentsHost::~OpenDocumentsHost() {
  channel_->SetMethodCallHandler(nullptr);
}

void OpenDocumentsHost::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != kReadyMethod) {
    result->NotImplemented();
    return;
  }
  ready_ = true;
  flutter::EncodableList pending;
  for (const std::string& document : pending_) {
    pending.push_back(flutter::EncodableValue(document));
  }
  pending_.clear();
  result->Success(flutter::EncodableValue(pending));
}

bool OpenDocumentsHost::HandleWindowMessage(UINT message, WPARAM wparam,
                                            LPARAM lparam) {
  if (message != WM_COPYDATA) {
    return false;
  }
  const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
  if (data->dwData != kOpenDocumentsCopyDataId || data->lpData == nullptr) {
    return false;
  }
  // NUL-separated UTF-16 entries, as single_instance.cpp sends them; the
  // buffer is not required to end with one.
  const wchar_t* raw = static_cast<const wchar_t*>(data->lpData);
  const size_t length = data->cbData / sizeof(wchar_t);
  std::vector<std::string> documents;
  size_t start = 0;
  for (size_t i = 0; i < length; i++) {
    if (raw[i] != L'\0') {
      continue;
    }
    if (i > start) {
      documents.push_back(Utf8FromWide(raw + start, i - start));
    }
    start = i + 1;
  }
  if (start < length) {
    documents.push_back(Utf8FromWide(raw + start, length - start));
  }
  Deliver(documents);
  return true;
}

void OpenDocumentsHost::Deliver(const std::vector<std::string>& documents) {
  if (documents.empty()) {
    return;
  }
  if (!ready_) {
    pending_.insert(pending_.end(), documents.begin(), documents.end());
    return;
  }
  flutter::EncodableList arguments;
  for (const std::string& document : documents) {
    arguments.push_back(flutter::EncodableValue(document));
  }
  channel_->InvokeMethod(
      kOpenMethod,
      std::make_unique<flutter::EncodableValue>(arguments));
}
