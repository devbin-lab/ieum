#include "flutter_window.h"

#include <optional>
#include <algorithm>
#include <string>
#include <wincred.h>
#include <flutter/standard_method_codec.h>

namespace {
// Only this application's credential is accessible through the channel.
constexpr wchar_t kCredentialTarget[] = L"Ieum/GitHub/OAuth/Ov23liDTP1YEtuI7SAx0";

const std::string* CredentialText(const flutter::EncodableMap& map,
                                  const char* key) {
  const auto found = map.find(flutter::EncodableValue(key));
  return found == map.end() ? nullptr
      : std::get_if<std::string>(&found->second);
}

bool CredentialSegment(const std::string& value) {
  return !value.empty() && value.size() <= 96 &&
      std::all_of(value.begin(), value.end(), [](char c) {
        return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-';
      });
}

bool DiscordLockScope(const std::string& value) {
  return value.size() == 64 &&
      std::all_of(value.begin(), value.end(), [](char c) {
        return (c >= 'a' && c <= 'f') || (c >= '0' && c <= '9');
      });
}

bool DiscordLockClaim(const std::string& value) {
  if (value.size() != 36) return false;
  for (size_t i = 0; i < value.size(); ++i) {
    const char c = value[i];
    if (i == 8 || i == 13 || i == 18 || i == 23) {
      if (c != '-') return false;
    } else if (!((c >= 'a' && c <= 'f') || (c >= '0' && c <= '9'))) return false;
  }
  return true;
}

void HandleDiscordCredential(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "read" && call.method_name() != "write" &&
      call.method_name() != "delete") {
    result->NotImplemented();
    return;
  }
  const auto* map = call.arguments()
      ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
  const auto* account = map ? CredentialText(*map, "accountId") : nullptr;
  const auto* project = map ? CredentialText(*map, "projectScope") : nullptr;
  const auto* key = map ? CredentialText(*map, "key") : nullptr;
  if (!account || account->size() < 4 || account->size() > 23 ||
      account->substr(0, 3) != "gh-" ||
      !std::all_of(account->begin() + 3, account->end(),
                   [](char c) { return c >= '0' && c <= '9'; }) ||
      !project || !CredentialSegment(*project) ||
      !key || !CredentialSegment(*key)) {
    result->Error("discord_vault_scope", "Discord 인증 정보의 저장 범위가 올바르지 않습니다.");
    return;
  }
  // A fixed, separate prefix and slash-free scopes cannot address OAuth keys.
  const std::string target_text = "Ieum/Discord/" + *account + "/" + *project + "/" + *key;
  const std::wstring target(target_text.begin(), target_text.end());
  if (call.method_name() == "read") {
    PCREDENTIALW stored = nullptr;
    if (!CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &stored)) {
      if (GetLastError() == ERROR_NOT_FOUND) result->Success();
      else result->Error("discord_vault_read", "Windows 인증 정보를 읽지 못했습니다.");
      return;
    }
    if (stored->CredentialBlobSize > 2560) {
      SecureZeroMemory(stored->CredentialBlob, stored->CredentialBlobSize);
      CredFree(stored);
      result->Error("discord_vault_value", "저장된 Discord 인증 정보를 확인하지 못했습니다.");
      return;
    }
    const std::string value(reinterpret_cast<const char*>(stored->CredentialBlob),
                            stored->CredentialBlobSize);
    SecureZeroMemory(stored->CredentialBlob, stored->CredentialBlobSize);
    CredFree(stored);
    result->Success(flutter::EncodableValue(value));
  } else if (call.method_name() == "write") {
    const auto* value = CredentialText(*map, "value");
    if (!value || value->empty() || value->size() > 2560) {
      result->Error("discord_vault_value", "저장할 인증 정보의 크기가 올바르지 않습니다.");
      return;
    }
    CREDENTIALW credential{};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = const_cast<wchar_t*>(target.c_str());
    credential.CredentialBlobSize = static_cast<DWORD>(value->size());
    credential.CredentialBlob = reinterpret_cast<LPBYTE>(const_cast<char*>(value->data()));
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    if (!CredWriteW(&credential, 0)) {
      result->Error("discord_vault_write", "Windows에 Discord 인증 정보를 저장하지 못했습니다.");
      return;
    }
    result->Success();
  } else {
    if (!CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0) &&
        GetLastError() != ERROR_NOT_FOUND) {
      result->Error("discord_vault_delete", "Windows에 저장된 Discord 인증 정보를 지우지 못했습니다.");
      return;
    }
    result->Success();
  }
}
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

FlutterWindow::~FlutterWindow() { ReleaseDiscordSendMutex(); }

void FlutterWindow::ReleaseDiscordSendMutex() {
  if (discord_send_mutex_) {
    ReleaseMutex(discord_send_mutex_);
    CloseHandle(discord_send_mutex_);
    discord_send_mutex_ = nullptr;
  }
  discord_send_scope_.clear();
  discord_send_claim_.clear();
}

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
  discord_credentials_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ieum/discord_vault",
      &flutter::StandardMethodCodec::GetInstance());
  discord_credentials_->SetMethodCallHandler(HandleDiscordCredential);
  discord_process_lock_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "ieum/discord_process_lock",
      &flutter::StandardMethodCodec::GetInstance());
  discord_process_lock_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() != "acquire" && call.method_name() != "release") {
      result->NotImplemented();
      return;
    }
    const auto* map = call.arguments()
        ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
    const auto* claim = map ? CredentialText(*map, "claim") : nullptr;
    if (!claim || !DiscordLockClaim(*claim)) {
      result->Error("discord_lock_scope", "Discord 전송 잠금의 요청을 확인하세요.");
      return;
    }
    if (call.method_name() == "release") {
      if (discord_send_claim_ == *claim) ReleaseDiscordSendMutex();
      result->Success();
      return;
    }
    const auto* account = CredentialText(*map, "accountId");
    const auto* scope = CredentialText(*map, "scope");
    if (!account || account->size() < 4 || account->size() > 23 ||
        account->substr(0, 3) != "gh-" ||
        !std::all_of(account->begin() + 3, account->end(),
                     [](char c) { return c >= '0' && c <= '9'; }) ||
        !scope || !DiscordLockScope(*scope)) {
      result->Error("discord_lock_scope", "Discord 전송 잠금의 범위를 확인하세요.");
      return;
    }
    const std::string target = "Local\\Ieum.Discord.Send." + *account + "." + *scope;
    if (discord_send_mutex_) {
      // A Windows mutex is recursive on the platform thread; explicitly refuse
      // a second Dart service instead of granting it a recursive acquisition.
      result->Success(flutter::EncodableValue(
          discord_send_scope_ == target && discord_send_claim_ == *claim));
      return;
    }
    const std::wstring wide_target(target.begin(), target.end());
    HANDLE mutex = CreateMutexW(nullptr, FALSE, wide_target.c_str());
    if (!mutex) {
      result->Error("discord_lock_acquire", "Discord 전송 잠금을 만들지 못했습니다.");
      return;
    }
    const DWORD wait = WaitForSingleObject(mutex, 0);
    if (wait == WAIT_TIMEOUT) {
      CloseHandle(mutex);
      result->Success(flutter::EncodableValue(false));
      return;
    }
    if (wait != WAIT_OBJECT_0 && wait != WAIT_ABANDONED) {
      CloseHandle(mutex);
      result->Error("discord_lock_acquire", "Discord 전송 잠금을 획득하지 못했습니다.");
      return;
    }
    discord_send_mutex_ = mutex;
    discord_send_scope_ = target;
    discord_send_claim_ = *claim;
    result->Success(flutter::EncodableValue(true));
  });
  github_http_ = std::make_unique<GitHubHttp>(
      flutter_controller_->engine()->messenger(), GetHandle());
  discord_http_ = std::make_unique<GitHubHttp>(
      flutter_controller_->engine()->messenger(), GetHandle(),
      GitHubHttp::Service::discordWebhook);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Dart configures the custom title bar through window_manager before showing
  // the window, avoiding a flash of the native Windows caption.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  discord_http_ = nullptr;
  discord_process_lock_ = nullptr;
  ReleaseDiscordSendMutex();
  github_http_ = nullptr;
  discord_credentials_ = nullptr;
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
  if (message == GitHubHttp::kCompletionMessage) {
    if (github_http_) github_http_->Complete();
    if (discord_http_) discord_http_->Complete();
    return 0;
  }
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
