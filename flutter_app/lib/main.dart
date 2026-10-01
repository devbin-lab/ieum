import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'store.dart';
import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final base =
        Platform.environment['IEUM_FLUTTER_DATA_DIR'] ??
        '${Platform.environment['APPDATA'] ?? (await getApplicationSupportDirectory()).path}${Platform.pathSeparator}Ieum-Flutter-Prototype';
    await Directory(base).create(recursive: true);
    final sample = jsonDecode(
      await rootBundle.loadString('assets/demo-snapshot.json'),
    );
    runApp(
      IeumApp(
        store: TaskStore(
          '$base${Platform.pathSeparator}ieum.sqlite',
          seed: sample['tasks'],
        ),
      ),
    );
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(body: Center(child: SelectableText('이음 실행 오류\n$e'))),
      ),
    );
  }
}
