#include "github_http.h"

#include <winhttp.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <chrono>
#include <cwctype>
#include <map>
#include <mutex>
#include <regex>
#include <string>
#include <thread>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;

struct Handle {
  HINTERNET value;
  explicit Handle(HINTERNET v) : value(v) {}
  ~Handle() { if (value) WinHttpCloseHandle(value); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
};

std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      value.data(), static_cast<int>(value.size()), nullptr, 0);
  if (!size) return {};
  std::wstring result(size, 0);
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), size);
  return result;
}

std::string Utf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (!size) return {};
  std::string result(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      result.data(), size, nullptr, nullptr);
  return result;
}

const Value* Field(const Map& map, const char* key) {
  const auto it = map.find(Value(key));
  return it == map.end() ? nullptr : &it->second;
}

std::string Text(const Map& map, const char* key) {
  const auto* value = Field(map, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : std::string();
}

struct RequestData {
  std::wstring host, path, method, headers;
  std::vector<uint8_t> body;
  size_t limit = 0;
  bool file_transfer = false;
};
struct Reply {
  DWORD error = 0;
  DWORD status = 0;
  Map headers;
  std::vector<uint8_t> body;
};

// The native bridge cannot forward tokens to arbitrary hosts or redirects.
bool Parse(const Value* argument, RequestData& data, GitHubHttp::Service service) {
  const auto* map = argument ? std::get_if<Map>(argument) : nullptr;
  if (!map) return false;
  const auto url_text = Text(*map, "url");
  if (url_text.size() > 16384 || url_text.find_first_of("\r\n\0", 0, 3) != std::string::npos)
    return false;
  auto url = Wide(url_text);
  URL_COMPONENTS parts{};
  parts.dwStructSize = sizeof(parts);
  parts.dwHostNameLength = parts.dwUrlPathLength = parts.dwExtraInfoLength =
      parts.dwUserNameLength = parts.dwPasswordLength = static_cast<DWORD>(-1);
  if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0, &parts) ||
      parts.nScheme != INTERNET_SCHEME_HTTPS || parts.nPort != 443 ||
      parts.dwUserNameLength || parts.dwPasswordLength) return false;
  data.host.assign(parts.lpszHostName, parts.dwHostNameLength);
  std::transform(data.host.begin(), data.host.end(), data.host.begin(),
      [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
  const std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
  const bool oauth = data.host == L"github.com" &&
      (path == L"/login/device/code" || path == L"/login/oauth/access_token");
  const bool discord = service == GitHubHttp::Service::discordWebhook;
  if (discord) {
    if (data.host != L"discord.com" && data.host != L"discordapp.com") return false;
    const std::wregex webhook(L"^/api/(v10/)?webhooks/([0-9]{17,20})/[A-Za-z0-9_-]{16,256}$");
    std::wsmatch match;
    if (!std::regex_match(path, match, webhook)) return false;
    try {
      if (!std::stoull(match[2].str())) return false;
    } catch (...) { return false; }
  } else if (!oauth && data.host != L"api.github.com") return false;
  data.path = path;
  if (parts.dwExtraInfoLength) data.path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
  if (data.path.find(L'#') != std::wstring::npos) return false;
  data.method = Wide(Text(*map, "method"));
  if (discord && data.method != L"GET" && data.method != L"POST") return false;
  if (!discord && data.method != L"GET" && data.method != L"POST" && data.method != L"PUT" &&
      data.method != L"PATCH" && data.method != L"DELETE" && data.method != L"HEAD") return false;
  if (oauth && data.method != L"POST") return false;
  if (discord) {
    const std::wstring extra = parts.dwExtraInfoLength
        ? std::wstring(parts.lpszExtraInfo, parts.dwExtraInfoLength) : L"";
    if ((data.method == L"GET" && !extra.empty()) ||
        (data.method == L"POST" && extra != L"?wait=true")) return false;
  }
  const bool blob_download = !discord && data.method == L"GET" &&
      path.find(L"/git/blobs/") != std::wstring::npos;
  const bool blob_upload = !discord && data.method == L"POST" &&
      path.size() >= 10 && path.substr(path.size() - 10) == L"/git/blobs";
  data.file_transfer = blob_download || blob_upload;
  const auto* size_value = Field(*map, "maxBytes");
  const auto* size = size_value ? std::get_if<int32_t>(size_value) : nullptr;
  if (!size || *size < 1 || *size > (oauth || discord ? 65536 : (blob_download ? 50 : 32) * 1024 * 1024)) return false;
  data.limit = static_cast<size_t>(*size);
  const auto* body_value = Field(*map, "body");
  const auto* body = body_value ? std::get_if<std::vector<uint8_t>>(body_value) : nullptr;
  if (!body || body->size() > (oauth || discord ? 65536 : (blob_upload ? 70 : 16) * 1024 * 1024) ||
      (discord && data.method == L"GET" && !body->empty())) return false;
  data.body = *body;
  const auto* headers_value = Field(*map, "headers");
  const auto* headers = headers_value ? std::get_if<Map>(headers_value) : nullptr;
  if (!headers || headers->size() > 12) return false;
  for (const auto& entry : *headers) {
    const auto* key = std::get_if<std::string>(&entry.first);
    const auto* value = std::get_if<std::string>(&entry.second);
    if (!key || !value || value->size() > 16384 ||
        value->find_first_of("\r\n\0", 0, 3) != std::string::npos) return false;
    // Host, cookies, proxy credentials and arbitrary native headers are blocked.
    if (discord) {
      if (*key != "Accept" && *key != "Content-Type" && *key != "User-Agent") return false;
    } else if (*key != "Authorization" && *key != "Accept" && *key != "Content-Type" &&
               *key != "User-Agent" && *key != "X-GitHub-Api-Version") return false;
    if (oauth && *key == "Authorization") return false;
    data.headers += Wide(*key + ": " + *value + "\r\n");
  }
  return true;
}

struct Session {
  Handle handle;
  DWORD error = 0;
  Session() : handle(WinHttpOpen(L"IEUM-Desktop", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
      WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0)) {
    if (!handle.value || !WinHttpSetTimeouts(handle.value, 10000, 15000, 30000, 30000)) {
      error = GetLastError();
      return;
    }
    // Require modern TLS, with Windows trust verification fully enabled.
    DWORD protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3;
    if (!WinHttpSetOption(handle.value, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols))) {
      protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2;
      if (!WinHttpSetOption(handle.value, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols, sizeof(protocols))) {
        error = GetLastError();
      }
    }
  }
};

Reply Send(const RequestData& data, const Session& session) {
  Reply reply;
  if (session.error) { reply.error = session.error; return reply; }
  auto failure = [&]() { reply.error = GetLastError(); return reply; };
  Handle connection(WinHttpConnect(session.handle.value, data.host.c_str(), 443, 0));
  if (!connection.value) return failure();
  Handle request(WinHttpOpenRequest(connection.value, data.method.c_str(), data.path.c_str(),
      nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE));
  if (!request.value) return failure();
  const int transfer_timeout = data.file_transfer ? 180000 : 30000;
  if (!WinHttpSetTimeouts(request.value, 10000, 15000, transfer_timeout, transfer_timeout)) return failure();
  DWORD redirect = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
  if (!WinHttpSetOption(request.value, WINHTTP_OPTION_REDIRECT_POLICY, &redirect, sizeof(redirect))) return failure();
  DWORD disable = WINHTTP_DISABLE_COOKIES;
  if (!WinHttpSetOption(request.value, WINHTTP_OPTION_DISABLE_FEATURE, &disable, sizeof(disable))) return failure();
  if (!WinHttpSendRequest(request.value, data.headers.c_str(), static_cast<DWORD>(data.headers.size()),
      data.body.empty() ? WINHTTP_NO_REQUEST_DATA : const_cast<uint8_t*>(data.body.data()),
      static_cast<DWORD>(data.body.size()), static_cast<DWORD>(data.body.size()), 0) ||
      !WinHttpReceiveResponse(request.value, nullptr)) return failure();
  DWORD length = sizeof(reply.status);
  if (!WinHttpQueryHeaders(request.value, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
      WINHTTP_HEADER_NAME_BY_INDEX, &reply.status, &length, WINHTTP_NO_HEADER_INDEX)) return failure();
  for (const auto* name : {L"retry-after", L"x-ratelimit-remaining", L"x-ratelimit-reset"}) {
    wchar_t buffer[256]{};
    DWORD bytes = sizeof(buffer);
    if (WinHttpQueryHeaders(request.value, WINHTTP_QUERY_CUSTOM, name, buffer, &bytes, WINHTTP_NO_HEADER_INDEX)) {
      const std::wstring value(buffer);
      reply.headers[Value(Utf8(name))] = Value(Utf8(value));
    }
  }
  const auto deadline = std::chrono::steady_clock::now() +
      std::chrono::seconds(data.file_transfer ? 300 : 60);
  while (true) {
    if (std::chrono::steady_clock::now() > deadline) { reply.error = ERROR_WINHTTP_TIMEOUT; return reply; }
    uint8_t buffer[8192];
    DWORD read = 0;
    if (!WinHttpReadData(request.value, buffer, sizeof(buffer), &read)) return failure();
    if (!read) break;
    if (reply.body.size() + read > data.limit) { reply.error = ERROR_WINHTTP_INVALID_SERVER_RESPONSE; return reply; }
    reply.body.insert(reply.body.end(), buffer, buffer + read);
  }
  return reply;
}
}  // namespace

struct GitHubHttp::State {
  std::mutex mutex;
  HWND window;
  bool alive = true;
  Service service = Service::github;
  uint64_t next = 0;
  std::map<uint64_t, std::unique_ptr<Result>> pending;  // UI thread only.
  std::map<uint64_t, Reply> completed;  // Protected by mutex.
  std::shared_ptr<Session> session;  // Shared connection pool; request cookies are disabled.
};

GitHubHttp::GitHubHttp(flutter::BinaryMessenger* messenger, HWND window, Service service)
    : state_(std::make_shared<State>()) {
  state_->window = window;
  state_->service = service;
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, service == Service::discordWebhook ? "ieum/discord_http" : "ieum/github_http",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    Request(call, std::move(result));
  });
}

GitHubHttp::~GitHubHttp() {
  channel_->SetMethodCallHandler(nullptr);
  std::lock_guard<std::mutex> lock(state_->mutex);
  state_->alive = false;
  state_->completed.clear();
  state_->pending.clear();
}

void GitHubHttp::Request(const flutter::MethodCall<Value>& call, std::unique_ptr<Result> result) {
  if (call.method_name() != "request") { result->NotImplemented(); return; }
  RequestData data;
  if (!Parse(call.arguments(), data, state_->service)) {
    result->Error("invalid_request", "Request is outside the allowed provider endpoints");
    return;
  }
  if (state_->pending.size() >= 8) { result->Error("network_busy", "Too many requests"); return; }
  const auto id = ++state_->next;
  state_->pending[id] = std::move(result);
  const auto state = state_;
  try {
    std::thread([state, id, data = std::move(data)] {
      Reply reply;
      try {
        std::shared_ptr<Session> session;
        {
          std::lock_guard<std::mutex> lock(state->mutex);
          if (!state->alive) return;
          if (!state->session) state->session = std::make_shared<Session>();
          session = state->session;
        }
        reply = Send(data, *session);
      } catch (...) { reply.error = ERROR_NOT_ENOUGH_MEMORY; }
      std::lock_guard<std::mutex> lock(state->mutex);
      if (!state->alive) return;
      state->completed[id] = std::move(reply);
      PostMessage(state->window, kCompletionMessage, 0, 0);
    }).detach();
  } catch (...) {
    auto failed = std::move(state_->pending[id]);
    state_->pending.erase(id);
    failed->Error("network_busy", "Could not start request");
  }
}

void GitHubHttp::Complete() {
  std::map<uint64_t, Reply> completed;
  {
    std::lock_guard<std::mutex> lock(state_->mutex);
    completed.swap(state_->completed);
  }
  for (auto& entry : completed) {
    auto it = state_->pending.find(entry.first);
    if (it == state_->pending.end()) continue;
    auto result = std::move(it->second);
    state_->pending.erase(it);
    auto& reply = entry.second;
    if (reply.error) {
      result->Error("winhttp_" + std::to_string(reply.error), "Provider transport failed");
    } else {
      result->Success(Value(Map{{Value("status"), Value(static_cast<int32_t>(reply.status))},
          {Value("headers"), Value(std::move(reply.headers))}, {Value("body"), Value(std::move(reply.body))}}));
    }
  }
}
