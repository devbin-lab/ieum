#include "flutter_window.h"

#include <optional>
#include <wincred.h>
#include <flutter/standard_method_codec.h>

namespace {
// Only this application's credential is accessible through the channel.
constexpr wchar_t kCredentialTarget[] = L"Ieum/GitHub/OAuth/Ov23liDTP1YEtuI7SAx0";
void HandleCredential(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "read") {
    PCREDENTIALW stored = nullptr;
    if (!CredReadW(kCredentialTarget, CRED_TYPE_GENERIC, 0, &stored)) {
      if (GetLastError() == ERROR_NOT_FOUND) result->Success();
      else result->Error("vault_read", "Windows 인증 정보를 읽지 못했습니다.");
      return;
    }
    const std::string value(reinterpret_cast<const char*>(stored->CredentialBlob),
                            stored->CredentialBlobSize);
    CredFree(stored);
    result->Success(flutter::EncodableValue(value));
  } else if (call.method_name() == "write") {
    const auto* value = call.arguments()
        ? std::get_if<std::string>(call.arguments()) : nullptr;
    if (!value || value->empty() || value->size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
      result->Error("vault_value", "저장할 인증 정보가 올바르지 않습니다.");
      return;
    }
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<wchar_t*>(kCredentialTarget);
    credential.CredentialBlobSize = static_cast<DWORD>(value->size());
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<char*>(value->data()));
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    if (!CredWriteW(&credential, 0)) {
      result->Error("vault_write", "Windows에 인증 정보를 안전하게 저장하지 못했습니다.");
      return;
    }
    result->Success();
  } else if (call.method_name() == "delete") {
    if (!CredDeleteW(kCredentialTarget, CRED_TYPE_GENERIC, 0) &&
        GetLastError() != ERROR_NOT_FOUND) {
      result->Error("vault_delete", "Windows에 저장된 로그인을 지우지 못했습니다.");
      return;
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}
}  // namespace

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  credentials_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ieum/oauth_credentials",
      &flutter::StandardMethodCodec::GetInstance());
  credentials_->SetMethodCallHandler(HandleCredential);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Dart configures the custom title bar through window_manager before showing
  // the window, avoiding a flash of the native Windows caption.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  credentials_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
