#ifndef IEUM_GITHUB_HTTP_H_
#define IEUM_GITHUB_HTTP_H_

#include <windows.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>

// Completes channel calls on the platform thread; network I/O uses workers.
class GitHubHttp {
 public:
  // Shared WinHTTP mechanics, isolated channels and provider allowlists.
  enum class Service { github, discordWebhook };
  static constexpr UINT kCompletionMessage = WM_APP + 0x4E1;
  GitHubHttp(flutter::BinaryMessenger* messenger, HWND window,
             Service service = Service::github);
  ~GitHubHttp();
  void Complete();

 private:
  struct State;
  std::shared_ptr<State> state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  void Request(const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};
#endif
