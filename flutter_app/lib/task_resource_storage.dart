import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:file_selector/file_selector.dart';
import 'package:uuid/uuid.dart';

import 'task_resources_model.dart';

/// Pending files stay beside the project DB. Downloaded files form a bounded,
/// disposable cache; neither the DB nor task proposals contain file bytes.
class TaskResourceStorage {
  TaskResourceStorage(this.root);
  factory TaskResourceStorage.forDatabase(String filename) {
    if (filename == ':memory:') throw StateError('파일을 첨부하려면 저장된 프로젝트를 여세요.');
    return TaskResourceStorage(Directory('$filename.resources'));
  }
  final Directory root;
  static const cacheByteLimit = 200 * attachmentMegabyte;

  File _file(String area, TaskResource resource) => File(
    '${root.path}${Platform.pathSeparator}$area${Platform.pathSeparator}${resource.sha256}',
  );

  static String blobSha(List<int> bytes) {
    final result = _DigestResult();
    final sink = crypto.sha1.startChunkedConversion(result);
    sink.add(utf8.encode('blob ${bytes.length}\u0000'));
    sink.add(bytes);
    sink.close();
    return result.value.toString();
  }

  static bool matches(TaskResource resource, List<int> bytes) =>
      resource.size == bytes.length &&
      crypto.sha256.convert(bytes).toString() == resource.sha256 &&
      blobSha(bytes) == resource.blobSha;

  static Future<Uint8List> readBounded(
    Stream<List<int>> stream,
    int limit,
  ) async {
    final result = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (result.length + chunk.length > limit) {
        throw StateError('프로젝트의 첨부 파일 용량 한도를 초과했습니다.');
      }
      result.add(chunk);
    }
    return result.takeBytes();
  }

  Future<TaskResource> stage(
    XFile source, {
    required String authorId,
    required int limitMb,
  }) async {
    if (limitMb < 1 ||
        limitMb > maxAttachmentLimitMb ||
        await source.length() > limitMb * attachmentMegabyte) {
      throw StateError('프로젝트의 첨부 파일 용량 한도를 초과했습니다.');
    }
    final bytes = await readBounded(
      source.openRead(),
      limitMb * attachmentMegabyte,
    );
    final resource = TaskResource.fromJson(
      TaskResource(
        id: 'resource-${const Uuid().v4()}',
        name: source.name,
        authorId: authorId,
        createdAt: DateTime.now().toUtc().toIso8601String(),
        size: bytes.length,
        sha256: crypto.sha256.convert(bytes).toString(),
        blobSha: blobSha(bytes),
      ).json,
    );
    await _write(_file('pending', resource), bytes);
    return resource;
  }

  Future<Uint8List?> local(TaskResource resource) async {
    for (final area in ['pending', 'cache']) {
      final file = _file(area, resource);
      if (!await file.exists()) continue;
      final bytes = await readBounded(
        file.openRead(),
        maxAttachmentLimitMb * attachmentMegabyte,
      );
      if (!matches(resource, bytes)) throw StateError('첨부 파일 내용이 등록 당시와 다릅니다.');
      if (area == 'cache') await file.setLastModified(DateTime.now());
      return bytes;
    }
    return null;
  }

  Future<void> cache(TaskResource resource, Uint8List bytes) async {
    if (!matches(resource, bytes)) throw StateError('첨부 파일 내용을 확인하지 못했습니다.');
    await _write(_file('cache', resource), bytes);
    await trimCache();
  }

  Future<void> uploaded(TaskResource resource) async {
    final pending = _file('pending', resource);
    if (!await pending.exists()) return;
    final bytes = await local(resource);
    if (bytes == null) return;
    await cache(resource, bytes);
    await pending.delete();
  }

  void discardPending(TaskResource resource) {
    final pending = _file('pending', resource);
    if (pending.existsSync()) pending.deleteSync();
  }

  Future<void> trimCache() async {
    final directory = Directory('${root.path}${Platform.pathSeparator}cache');
    if (!await directory.exists()) return;
    final entries = <({File file, FileStat stat})>[];
    await for (final file in directory.list(followLinks: false)) {
      if (file is File &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(file.uri.pathSegments.last)) {
        entries.add((file: file, stat: await file.stat()));
      }
    }
    entries.sort((a, b) => a.stat.modified.compareTo(b.stat.modified));
    var size = entries.fold<int>(0, (sum, item) => sum + item.stat.size);
    for (final entry in entries) {
      if (size <= cacheByteLimit) break;
      await entry.file.delete();
      size -= entry.stat.size;
    }
  }

  Future<void> _write(File target, Uint8List bytes) async {
    await target.parent.create(recursive: true);
    if (await target.exists()) return;
    final temporary = File('${target.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

class _DigestResult implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
