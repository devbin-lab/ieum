import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ieum_flutter/startup_health.dart';

void main() {
  test('acknowledgement accepts Directory URI trailing separators but no escape', () {
    final root = Directory.systemTemp.absolute.path;
    final builds =
        '$root${Platform.pathSeparator}Ieum${Platform.pathSeparator}builds';
    final marker =
        '$builds${Platform.pathSeparator}20261001-190000${Platform.pathSeparator}.startup-example';
    expect(startupHealthFile(builds, marker), isNotNull);
    expect(
      startupHealthFile('$builds${Platform.pathSeparator}', marker),
      isNotNull,
    );
    expect(
      startupHealthFile(
        builds,
        '$builds-other${Platform.pathSeparator}.startup-escape',
      ),
      isNull,
    );
    expect(
      startupHealthFile(
        builds,
        '$builds${Platform.pathSeparator}..${Platform.pathSeparator}.startup-escape',
      ),
      isNull,
    );
    expect(
      startupHealthFile(
        builds,
        '$builds${Platform.pathSeparator}project.sqlite',
      ),
      isNull,
    );
  });
}
