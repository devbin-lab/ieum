import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

class ReleaseVersion implements Comparable<ReleaseVersion> {
  ReleaseVersion(this.value) {
    final match = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:\+(\d+))?$')
        .firstMatch(value);
    if (match == null) throw const FormatException('업데이트 버전이 올바르지 않습니다.');
    parts = List.generate(4, (i) => int.parse(match.group(i + 1) ?? '0'));
    if (parts.any((p) => p > 2147483647)) {
      throw const FormatException('업데이트 버전이 너무 큽니다.');
    }
  }
  final String value;
  late final List<int> parts;
  @override
  int compareTo(ReleaseVersion other) {
    for (var i = 0; i < 4; i++) {
      final result = parts[i].compareTo(other.parts[i]);
      if (result != 0) return result;
    }
    return 0;
  }
}

class UpdateRelease {
  UpdateRelease.fromJson(Map<String, dynamic> release) {
    if (release['draft'] == true || release['prerelease'] == true) {
      throw const FormatException('정식 배포 버전만 설치할 수 있습니다.');
    }
    version = ReleaseVersion(
      (release['tag_name'] as String).replaceFirst(RegExp(r'^v'), ''),
    );
    final assets = (release['assets'] as List)
        .where((a) => a['name'] == 'Ieum-Windows-x64.exe')
        .toList();
    if (assets.length != 1) {
      throw const FormatException('Windows EXE 배포 파일을 찾지 못했습니다.');
    }
    final asset = assets.single;
    assetId = asset['id'] as int;
    size = asset['size'] as int;
    final digest = asset['digest'] as String? ?? '';
    if (assetId <= 0 ||
        size <= 0 ||
        size > 300 * 1024 * 1024 ||
        !RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)) {
      throw const FormatException('배포 파일 크기 또는 SHA-256 정보가 올바르지 않습니다.');
    }
    hash = digest.substring(7).toLowerCase();
  }
  late final ReleaseVersion version;
  late final int assetId, size;
  late final String hash;
}

abstract interface class UpdateSource {
  Future<UpdateRelease?> latest();
  Future<void> download(
    UpdateRelease release,
    File target,
    void Function(int) progress,
  );
}

class GitHubUpdateSource implements UpdateSource {
  GitHubUpdateSource(this.repository, {this.credential});
  final String repository;
  final FutureOr<String> Function()? credential;
  static bool trusted(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (uri.host == 'api.github.com' ||
          uri.host == 'github.com' ||
          uri.host == 'release-assets.githubusercontent.com' ||
          uri.host == 'objects.githubusercontent.com');

  Future<HttpClientResponse> _get(
    HttpClient client,
    Uri uri,
    String accept,
  ) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      if (!trusted(uri)) throw const FormatException('허용되지 않은 업데이트 주소입니다.');
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set('User-Agent', 'IEUM-Desktop-Updater');
      request.headers.set('Accept', accept);
      if (uri.host == 'api.github.com') {
        request.headers.set('X-GitHub-Api-Version', '2022-11-28');
        final token = await credential?.call() ?? '';
        if (token.isNotEmpty) {
          request.headers.set('Authorization', 'Bearer $token');
        }
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value('location');
        await response.drain<void>();
        if (location == null) throw const FormatException('업데이트 이동 주소가 없습니다.');
        uri = uri.resolve(location);
        continue;
      }
      return response;
    }
    throw const FormatException('업데이트 주소 이동이 너무 많습니다.');
  }

  @override
  Future<UpdateRelease?> latest() async {
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      throw const FormatException('업데이트 저장소 설정이 올바르지 않습니다.');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final response = await _get(
        client,
        Uri.https('api.github.com', '/repos/$repository/releases/latest'),
        'application/vnd.github+json',
      );
      if (response.statusCode == 404) {
        await response.drain<void>();
        return null;
      }
      if (response.statusCode != 200) {
        throw HttpException('업데이트 확인 실패 · HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        bytes.addAll(chunk);
        if (bytes.length > 1024 * 1024) {
          throw const FormatException('업데이트 정보가 너무 큽니다.');
        }
      }
      return UpdateRelease.fromJson(
        Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes))),
      );
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<void> download(
    UpdateRelease release,
    File target,
    void Function(int) progress,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    IOSink? sink;
    try {
      final response = await _get(
        client,
        Uri.https(
          'api.github.com',
          '/repos/$repository/releases/assets/${release.assetId}',
        ),
        'application/octet-stream',
      );
      if (response.statusCode != 200) {
        throw HttpException('업데이트 다운로드 실패 · HTTP ${response.statusCode}');
      }
      sink = target.openWrite();
      var received = 0;
      await for (final chunk in response.timeout(const Duration(seconds: 30))) {
        received += chunk.length;
        if (received > release.size) {
          throw const FormatException('배포 파일이 지정된 크기를 초과했습니다.');
        }
        sink.add(chunk);
        progress(received);
      }
      await sink.flush();
      if (received != release.size) {
        throw const FormatException('업데이트 다운로드가 완전하지 않습니다.');
      }
    } finally {
      await sink?.close();
      client.close(force: true);
    }
  }
}

class AppUpdater extends ChangeNotifier {
  AppUpdater({
    required this.root,
    required this.currentVersion,
    required this.source,
    Future<void> Function(File)? launch,
  }) : launch = launch ?? _launch;
  final Directory root;
  final String currentVersion;
  final UpdateSource source;
  final Future<void> Function(File) launch;
  String message = '자동 업데이트', readyVersion = '';
  bool busy = false, ready = false, _disposed = false;
  bool _checkAgain = false;
  double progress = 0;
  Timer? _timer;
  File get pointer =>
      File('${root.path}${Platform.pathSeparator}pending-update.json');
  File packageFor(String version) => File(
    '${root.path}${Platform.pathSeparator}updates${Platform.pathSeparator}$version${Platform.pathSeparator}Ieum-Windows-x64.exe',
  );
  static Future<void> _launch(File file) async {
    await Process.start(file.path, [
      '--wait-for',
      '$pid',
    ], mode: ProcessStartMode.detached);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_disposed) return;
    _timer ??= Timer.periodic(
      const Duration(hours: 4),
      (_) => unawaited(check()),
    );
    unawaited(check());
  }

  Future<File?> pending() async {
    if (!await pointer.exists()) return null;
    try {
      final data = jsonDecode(await pointer.readAsString()) as Map;
      final version = ReleaseVersion(data['version'] as String);
      final hash = data['sha256'] as String;
      if (version.compareTo(ReleaseVersion(currentVersion)) <= 0 ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)) {
        return null;
      }
      final file = packageFor(version.value);
      if (!await file.exists() ||
          (await sha256.bind(file.openRead()).first).toString() != hash) {
        return null;
      }
      readyVersion = version.value;
      return file;
    } catch (_) {
      return null;
    }
  }

  Future<bool> restartPending() async {
    final file = await pending();
    if (file == null) return false;
    await launch(file);
    return true;
  }

  Future<void> check() async {
    if (busy || _disposed) return;
    busy = true;
    lastError = '';
    message = '업데이트 확인 중';
    _changed();
    try {
      final cached = await pending();
      if (_disposed) return;
      ready = cached != null;
      final release = await source.latest();
      if (_disposed) return;
      if (release == null) {
        message = ready ? '업데이트 후 재시작' : '배포 버전 없음 · 접근 권한 확인';
        return;
      }
      if (release.version.compareTo(ReleaseVersion(currentVersion)) <= 0 ||
          ready &&
              release.version.compareTo(ReleaseVersion(readyVersion)) <= 0) {
        message = ready ? '업데이트 후 재시작' : '최신 버전 $currentVersion';
        return;
      }
      final file = packageFor(release.version.value);
      await file.parent.create(recursive: true);
      final partial = File('${file.path}.part');
      message = '업데이트 다운로드 중';
      progress = 0;
      _changed();
      await source.download(release, partial, (bytes) {
        progress = bytes / release.size;
        _changed();
      });
      if (_disposed) return;
      if (await partial.length() != release.size ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              release.hash) {
        throw const FormatException('업데이트 검증에 실패했습니다. 현재 버전을 유지합니다.');
      }
      // The app and DB stay untouched. Only a fully verified package becomes ready.
      if (await file.exists()) await file.delete();
      await partial.rename(file.path);
      await root.create(recursive: true);
      final tempPointer = File('${pointer.path}.tmp');
      await tempPointer.writeAsString(
        jsonEncode({'version': release.version.value, 'sha256': release.hash}),
        flush: true,
      );
      if (await pointer.exists()) await pointer.delete();
      await tempPointer.rename(pointer.path);
      ready = true;
      readyVersion = release.version.value;
      message = '업데이트 후 재시작';
    } catch (e) {
      message = ready ? '업데이트 후 재시작' : '업데이트 재시도';
      lastError = '$e';
    } finally {
      busy = false;
      _changed();
      if (_checkAgain && !_disposed) {
        _checkAgain = false;
        unawaited(check());
      }
    }
  }

  void credentialsChanged() {
    if (_disposed) return;
    if (busy) {
      _checkAgain = true;
    } else {
      unawaited(check());
    }
  }

  String lastError = '';
  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
