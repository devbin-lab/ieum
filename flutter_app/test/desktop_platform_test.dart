import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/desktop_platform.dart';

void main() {
  test('Linux opens device login with a separated URL argument', () {
    final linux = browserCommand(
      'https://github.com/login/device',
      operatingSystem: 'linux',
    );
    expect(linux.$1, 'xdg-open');
    expect(linux.$2, ['https://github.com/login/device']);
    final windows = browserCommand(
      'https://github.com/login/device',
      operatingSystem: 'windows',
    );
    expect(windows.$1, 'rundll32.exe');
    expect(windows.$2, [
      'url.dll,FileProtocolHandler',
      'https://github.com/login/device',
    ]);
    expect(
      () => browserCommand('file:///tmp/test', operatingSystem: 'linux'),
      throwsFormatException,
    );
    expect(
      credentialStorageDescription(operatingSystem: 'linux'),
      contains('키링'),
    );
  });
}
