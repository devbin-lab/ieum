#include "oauth_credentials.h"
#include <libsecret/secret.h>
#include <cstring>

namespace {
const SecretSchema* schema() {
  static const SecretSchema value = [] {
    SecretSchema result{};
    result.name = "com.devbin.ieum.OAuth";
    result.flags = SECRET_SCHEMA_NONE;
    result.attributes[0] = {"application", SECRET_SCHEMA_ATTRIBUTE_STRING};
    return result;
  }();
  return &value;
}

struct Request {
  FlMethodCall* call;
  GCancellable* cancellable;
  guint timeout;
};
Request* request_new(FlMethodCall* call) {
  auto* request = new Request{FL_METHOD_CALL(g_object_ref(call)),
                              g_cancellable_new(), 0};
  request->timeout = g_timeout_add_seconds(20, [](gpointer data) -> gboolean {
    auto* pending = static_cast<Request*>(data);
    pending->timeout = 0;
    g_cancellable_cancel(pending->cancellable);
    return G_SOURCE_REMOVE;
  }, request);
  return request;
}
void request_free(Request* request) {
  if (request->timeout != 0) g_source_remove(request->timeout);
  g_object_unref(request->call);
  g_object_unref(request->cancellable);
  delete request;
}
void vault_failure(FlMethodCall* call) {
  // A service error can include sensitive details; return a fixed message.
  fl_method_call_respond_error(call, "vault_unavailable",
      "Linux 키링에 접근할 수 없습니다. 키링을 잠금 해제하거나 로그인 유지를 꺼주세요.",
      nullptr, nullptr);
}
void read_finished(GObject*, GAsyncResult* result, gpointer data) {
  auto* request = static_cast<Request*>(data);
  g_autoptr(GError) error = nullptr;
  gchar* password = secret_password_lookup_finish(result, &error);
  if (error != nullptr) {
    vault_failure(request->call);
  } else {
    g_autoptr(FlValue) value = password ? fl_value_new_string(password) : nullptr;
    fl_method_call_respond_success(request->call, value, nullptr);
  }
  if (password) secret_password_free(password);
  request_free(request);
}
void write_finished(GObject*, GAsyncResult* result, gpointer data) {
  auto* request = static_cast<Request*>(data);
  g_autoptr(GError) error = nullptr;
  const gboolean stored = secret_password_store_finish(result, &error);
  if (error != nullptr || !stored) vault_failure(request->call);
  else fl_method_call_respond_success(request->call, nullptr, nullptr);
  request_free(request);
}
void delete_finished(GObject*, GAsyncResult* result, gpointer data) {
  auto* request = static_cast<Request*>(data);
  g_autoptr(GError) error = nullptr;
  secret_password_clear_finish(result, &error);
  if (error != nullptr) vault_failure(request->call);
  else fl_method_call_respond_success(request->call, nullptr, nullptr);
  request_free(request);
}
void method_call(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* name = fl_method_call_get_name(call);
  if (strcmp(name, "read") == 0) {
    auto* request = request_new(call);
    secret_password_lookup(schema(), request->cancellable, read_finished, request,
                           "application", "ieum-github", nullptr);
  } else if (strcmp(name, "write") == 0) {
    FlValue* args = fl_method_call_get_args(call);
    if (!args || fl_value_get_type(args) != FL_VALUE_TYPE_STRING ||
        strlen(fl_value_get_string(args)) == 0 ||
        strlen(fl_value_get_string(args)) > 16384) {
      fl_method_call_respond_error(call, "vault_value",
          "저장할 인증 정보가 올바르지 않습니다.", nullptr, nullptr);
      return;
    }
    auto* request = request_new(call);
    secret_password_store(schema(), SECRET_COLLECTION_DEFAULT, "IEUM GitHub login",
        fl_value_get_string(args), request->cancellable, write_finished, request,
        "application", "ieum-github", nullptr);
  } else if (strcmp(name, "delete") == 0) {
    auto* request = request_new(call);
    secret_password_clear(schema(), request->cancellable, delete_finished, request,
                          "application", "ieum-github", nullptr);
  } else {
    fl_method_call_respond_not_implemented(call, nullptr);
  }
}
}  // namespace

void ieum_register_oauth_credentials(FlEngine* engine) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(engine), "ieum/oauth_credentials",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call, nullptr, nullptr);
}
