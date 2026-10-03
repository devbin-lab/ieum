import 'dart:io';

/// Arguments stay separate from the command so URLs are never shell code.
(String, List<String>) browserCommand(String url, {String? operatingSystem}) {
  final uri = Uri.parse(url);
  if (uri.scheme != 'https' || uri.userInfo.isNotEmpty) {
    throw const FormatException('HTTPS 주소만 브라우저로 열 수 있습니다.');
  }
  return switch (operatingSystem ?? Platform.operatingSystem) {
    'windows' => ('rundll32.exe', ['url.dll,FileProtocolHandler', url]),
    'linux' => ('xdg-open', [url]),
    'macos' => ('open', [url]),
    _ => throw UnsupportedError('지원하지 않는 데스크톱 운영체제입니다.'),
  };
}

Future<void> openDesktopUrl(String url) async {
  final (executable, arguments) = browserCommand(url);
  await Process.start(executable, arguments);
}

String credentialStorageDescription({String? operatingSystem}) =>
    (operatingSystem ?? Platform.operatingSystem) == 'linux'
    ? 'Linux 키링에 안전하게 보관합니다. 키링이 없으면 로그인 유지를 꺼주세요.'
    : 'Windows 자격 증명 관리자에 안전하게 보관합니다.';
