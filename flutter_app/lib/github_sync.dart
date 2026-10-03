import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'store.dart';
import 'models.dart';

part 'github_auto_merge.dart';
part 'sync_payload.dart';

class GitHubConfig {
  const GitHubConfig({
    this.repository = '',
    this.base = 'main',
    this.branch = '',
    this.enabled = false,
    this.separatePr = true,
    this.autoMerge = true,
  });
  final String repository, base, branch;
  final bool enabled, separatePr, autoMerge;

  String get slug => repository
      .trim()
      .replaceFirst(RegExp(r'^https://github\.com/', caseSensitive: false), '')
      .replaceFirst(RegExp(r'/$'), '')
      .replaceFirst(RegExp(r'\.git$', caseSensitive: false), '')
      .toLowerCase();

  void validate() {
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(slug)) {
      throw StateError('저장소를 소유자/저장소 또는 GitHub HTTPS 주소로 입력하세요.');
    }
    for (final ref in [base, if (branch.isNotEmpty) branch]) {
      if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_./-]*$').hasMatch(ref) ||
          ref.contains('..') ||
          ref.contains('//') ||
          ref.endsWith('/') ||
          ref.endsWith('.') ||
          ref.endsWith('.lock')) {
        throw StateError('브랜치 이름을 확인하세요.');
      }
    }
    if (branch.isNotEmpty && branch == base) {
      throw StateError('개인 브랜치는 통합 브랜치와 달라야 합니다.');
    }
  }

  Map<String, dynamic> toJson() => {
    'repository': slug,
    'base': base,
    'branch': branch,
    'enabled': enabled,
    'separatePr': separatePr,
    'autoMerge': autoMerge,
  };
  factory GitHubConfig.fromJson(Map<String, dynamic> json) => GitHubConfig(
    repository: json['repository'] as String? ?? '',
    base: json['base'] as String? ?? 'main',
    branch: json['branch'] as String? ?? '',
    enabled: json['enabled'] == true,
    separatePr: json['separatePr'] != false,
    autoMerge: json['autoMerge'] != false,
  );
}

class GitHubFailure implements Exception {
  const GitHubFailure(this.message, [this.status = 0, this.retryAfter]);
  final String message;
  final int status;
  final Duration? retryAfter;
  @override
  String toString() => message;
}

abstract interface class GitHubApi {
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  });
}

class HttpGitHubApi implements GitHubApi {
  HttpGitHubApi(this.token, {HttpClient Function()? createClient})
    : _createClient = createClient ?? HttpClient.new;
  final Future<String> Function() token;
  final HttpClient Function() _createClient;
  HttpClient? _client;

  // Keep TLS connections alive across the sequential commit/PR requests.
  // Credentials are still retrieved and set separately for every request.
  void close() {
    _client?.close();
    _client = null;
  }

  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final credential = await token();
    if (credential.isEmpty) throw const GitHubFailure('GitHub 인증이 필요합니다.');
    final client = _client ??= _createClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 15);
    try {
      final uri = Uri.https('api.github.com', path, query);
      final request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      request.headers.set('Authorization', 'Bearer $credential');
      request.headers.set('Accept', 'application/vnd.github+json');
      request.headers.set('User-Agent', 'IEUM-Desktop');
      request.headers.set('X-GitHub-Api-Version', '2022-11-28');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      final raw = await utf8.decoder
          .bind(response)
          .join()
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        var serverMessage = '';
        try {
          serverMessage = '${jsonDecode(raw)['message']}'.toLowerCase();
        } catch (_) {}
        final limited =
            response.statusCode == 429 ||
            response.headers.value('retry-after') != null ||
            response.headers.value('x-ratelimit-remaining') == '0' ||
            serverMessage.contains('rate limit') ||
            serverMessage.contains('abuse detection');
        final explanation = switch (response.statusCode) {
          401 => 'GitHub 인증이 만료되었거나 토큰이 올바르지 않습니다.',
          403 => '저장소 쓰기·PR 권한 또는 GitHub 요청 한도를 확인하세요.',
          404 => '저장소·브랜치가 없거나 접근 권한이 없습니다.',
          409 => '브랜치 변경이 충돌했습니다. 통합 상태를 확인 후 재시도하세요.',
          422 => 'GitHub가 변경을 거부했습니다. 브랜치·PR 상태를 확인하세요.',
          _ => 'GitHub 요청에 실패했습니다. HTTP ${response.statusCode}',
        };
        throw GitHubFailure(
          explanation,
          response.statusCode,
          githubRetryDelay(
            response.statusCode,
            response.headers.value('retry-after'),
            response.headers.value('x-ratelimit-remaining'),
            response.headers.value('x-ratelimit-reset'),
            rateLimited: limited,
          ),
        );
      }
      return raw.isEmpty ? null : jsonDecode(raw);
    } on SocketException {
      throw const GitHubFailure('네트워크에 연결할 수 없습니다. 작업은 로컬에 보관됩니다.');
    } on TimeoutException {
      throw const GitHubFailure('GitHub 응답 시간이 초과되었습니다. 재시도할 수 있습니다.');
    }
  }
}

class SyncReceipt {
  const SyncReceipt(
    this.prUrl,
    this.commitSha,
    this.branch, {
    this.integrated = false,
    this.request,
  });
  final bool integrated;
  final String prUrl, commitSha, branch;
  final Map<String, dynamic>? request;
}

class GitHubPublisher {
  GitHubPublisher(this.api);
  final GitHubApi api;
  final Map<String, Map<String, dynamic>> _blobCache = {};
  final Map<String, String> _badBlobs = {};
  final Map<String, Map<String, dynamic>> _snapshots = {};

  Future<String> head(GitHubConfig config) async {
    final ref = await api.call(
      'GET',
      '/repos/${config.slug}/git/ref/heads/${config.base}',
    );
    return ref['object']['sha'] as String;
  }

  Future<ProjectManifest> project(GitHubConfig config, {String? ref}) async {
    final file = await api.call(
      'GET',
      '/repos/${config.slug}/contents/.ieum/project.json',
      query: {'ref': ref ?? config.base},
    );
    if (file['encoding'] != 'base64') {
      throw const GitHubFailure('프로젝트 설정 인코딩이 올바르지 않습니다.');
    }
    final raw = jsonDecode(
      utf8.decode(
        base64Decode((file['content'] as String).replaceAll(RegExp(r'\s'), '')),
      ),
    );
    return ProjectManifest.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<Person> projectActor(
    GitHubConfig config,
    ProjectManifest manifest, {
    Map<String, dynamic>? checkedIdentity,
  }) async {
    final identity = checkedIdentity ?? await api.call('GET', '/user');
    final people = manifest.people.where((p) => p.id == 'gh-${identity['id']}');
    if (people.isNotEmpty && !people.first.enabled) {
      throw const GitHubFailure(
        '비활성화된 참여자는 작업을 업로드하거나 통합할 수 없습니다. 관리자에게 활성화를 요청하세요.',
        403,
      );
    }
    if (people.isEmpty || !people.first.active) {
      throw const GitHubFailure('가입 승인을 받거나 현재 역할을 확인하세요.');
    }
    return people.first;
  }

  Future<String> check(GitHubConfig config, {bool readBase = true}) async {
    return (await _checkAccess(config, readBase: readBase)).login;
  }

  Future<({String login, Map<String, dynamic> identity, String? baseSha})>
  _checkAccess(GitHubConfig config, {required bool readBase}) async {
    config.validate();
    final checked = await Future.wait([
      api.call('GET', '/user'),
      api.call('GET', '/repos/${config.slug}'),
      if (readBase)
        api.call('GET', '/repos/${config.slug}/git/ref/heads/${config.base}'),
    ]);
    final user = checked[0];
    final repository = checked[1];
    if (repository['permissions']?['push'] != true) {
      throw const GitHubFailure('이 저장소에 개인 브랜치를 올릴 수 있는 쓰기 권한이 필요합니다.');
    }
    return (
      login: user['login'] as String,
      identity: Map<String, dynamic>.from(user),
      baseSha: readBase ? checked[2]['object']['sha'] as String : null,
    );
  }

  Future<SyncReceipt> publish(
    GitHubConfig config,
    Map<String, dynamic> job,
  ) async {
    final access = await _checkAccess(config, readBase: true);
    final login = access.login;
    final proposal = job['proposal'] as Map;
    final sameAccount = proposal['authorId'] == 'gh-${access.identity['id']}';
    if (job['githubLogin'] != null &&
        job['githubLogin'] != login &&
        !sameAccount) {
      throw const GitHubFailure('이 작업을 등록한 GitHub 계정으로 다시 연결하세요.');
    }
    if (proposal['projectId'] != 'ieum-demo') {
      final manifest = await project(config, ref: access.baseSha);
      final actor = await projectActor(
        config,
        manifest,
        checkedIdentity: access.identity,
      );
      if (manifest.id != proposal['projectId'] ||
          actor.id != proposal['authorId']) {
        throw const GitHubFailure('프로젝트 또는 로그인한 작업 작성자가 다릅니다.');
      }
      final change = (proposal['changes'] as List).single as Map;
      final task = WorkTask.fromJson(Map<String, dynamic>.from(change['task']));
      final base = change['base'] == null
          ? null
          : WorkTask.fromJson(Map<String, dynamic>.from(change['base']));
      try {
        validateTaskMutation(
          actor: actor,
          next: task,
          current: base,
          allowCollapsedTransitions: true,
        );
      } on StateError catch (e) {
        throw GitHubFailure(e.message.toString());
      }
      for (final (id, reviewer) in [
        (task.assigneeId, false),
        (task.reviewerId, true),
      ]) {
        if (!manifest.people.any(
          (p) => p.id == id && (reviewer ? p.canReview : p.canWork),
        )) {
          throw const GitHubFailure('작업 담당자의 현재 참여 권한을 확인하세요.');
        }
      }
    }
    final root = '/repos/${config.slug}';
    final taskId = job['taskId'] as String;
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(taskId)) {
      throw const GitHubFailure('작업 ID 형식을 확인하세요.');
    }
    final branch = config.separatePr
        ? 'ieum/tasks/$login/$taskId'
        : config.branch.isEmpty
        ? 'ieum/$login'
        : config.branch;
    if (branch == config.base) {
      throw const GitHubFailure('통합 브랜치에는 직접 커밋하지 않습니다.');
    }
    // Head ownership is part of the PR filter; unrelated PRs are never modified.
    final query = {
      'state': 'open',
      'head': '${config.slug.split('/').first}:$branch',
      'base': config.base,
    };
    List prs;
    final baseSha = access.baseSha!;
    var createdBranch = false;
    try {
      final branchRef = await api.call('GET', '$root/git/ref/heads/$branch');
      // Advance/merge main into an existing personal branch without force push.
      // Conflicts stop here, leaving the saved task and queue intact.
      if (branchRef['object']['sha'] != baseSha) {
        await api.call(
          'POST',
          '$root/merges',
          body: {
            'base': branch,
            'head': baseSha,
            'commit_message': 'Sync ${config.base} before IEUM task submission',
          },
        );
      }
    } on GitHubFailure catch (e) {
      if (e.status != 404) rethrow;
      try {
        await api.call(
          'POST',
          '$root/git/refs',
          body: {'ref': 'refs/heads/$branch', 'sha': baseSha},
        );
        createdBranch = true;
      } on GitHubFailure catch (e) {
        if (e.status != 422) rethrow;
        try {
          await api.call('GET', '$root/git/ref/heads/$branch');
        } on GitHubFailure {
          throw GitHubFailure(
            '작업 브랜치 생성이 거부되었습니다. 같은 이름의 브랜치·저장소 규칙을 확인하세요. ($branch)',
            422,
          );
        }
      }
    }
    final path = '$root/contents/.ieum/changes/$login/$taskId.json';
    // Keep payload deterministic: retry after an uncertain network response
    // must reuse the same file, commit and PR instead of creating duplicates.
    final payload = {
      ...Map<String, dynamic>.from(job['proposal'] as Map),
      'githubLogin': login,
    };
    final content = '${const JsonEncoder.withIndent('  ').convert(payload)}\n';
    _validateTaskProposal(payload);
    if (utf8.encode(content).length > _maxTaskJsonBytes) {
      throw const GitHubFailure('작업 JSON은 1MB 이하만 지원합니다.');
    }
    String? fileSha;
    bool unchanged = false;
    try {
      final file = await api.call('GET', path, query: {'ref': branch});
      fileSha = file['sha'] as String;
      if (file['encoding'] == 'base64') {
        unchanged =
            utf8.decode(
              base64Decode(
                (file['content'] as String).replaceAll(RegExp(r'\s'), ''),
              ),
            ) ==
            content;
      }
    } on GitHubFailure catch (e) {
      if (e.status != 404) rethrow;
    }
    String commitSha;
    if (!unchanged) {
      final result = await api.call(
        'PUT',
        path,
        body: {
          'message': 'Register IEUM task $taskId',
          'content': base64Encode(utf8.encode(content)),
          'branch': branch,
          'sha': ?fileSha,
        },
      );
      commitSha = result['commit']['sha'] as String;
    } else {
      final ref = await api.call('GET', '$root/git/ref/heads/$branch');
      commitSha = ref['object']['sha'] as String;
    }
    // A newly created branch has no earlier PR. A peer creating one in the
    // meantime is handled by the existing 422 recovery path below.
    prs = createdBranch
        ? []
        : await api.call('GET', '$root/pulls', query: query) as List;
    if (prs.isNotEmpty) {
      return SyncReceipt(
        prs.first['html_url'] as String,
        commitSha,
        branch,
        request: Map<String, dynamic>.from(prs.first),
      );
    }
    // A POST response can be lost after another app already integrated the PR.
    // Check the authoritative file before attempting another no-diff PR.
    if (unchanged) {
      try {
        final mainFile = await api.call(
          'GET',
          path,
          query: {'ref': config.base},
        );
        if (mainFile['encoding'] == 'base64' &&
            utf8.decode(
                  base64Decode(
                    (mainFile['content'] as String).replaceAll(
                      RegExp(r'\s'),
                      '',
                    ),
                  ),
                ) ==
                content) {
          return SyncReceipt(
            job['prUrl'] as String? ?? '',
            commitSha,
            branch,
            integrated: true,
          );
        }
      } on GitHubFailure catch (e) {
        if (e.status != 404) rethrow;
      }
    }
    try {
      final pr = await api.call(
        'POST',
        '$root/pulls',
        body: {
          'head': branch,
          'base': config.base,
          'title': config.separatePr
              ? '이음 작업 등록 · ${job['title']}'
              : '이음 · $login 작업 등록',
          'body': '등록한 작업의 JSON 변경안입니다. 이음 앱에서 작성자·역할·최신 작업 기준을 확인한 뒤 자동 통합합니다. 수동 통합 모드에서는 변경을 확인하고 승인해 주세요.\n\nSQLite DB와 인증 정보는 포함하지 않습니다.',
        },
      );
      return SyncReceipt(
        pr['html_url'] as String,
        commitSha,
        branch,
        request: Map<String, dynamic>.from(pr),
      );
    } on GitHubFailure catch (e) {
      if (e.status != 422) rethrow;
      prs = await api.call('GET', '$root/pulls', query: query) as List;
      if (prs.isEmpty) rethrow;
      return SyncReceipt(
        prs.first['html_url'] as String,
        commitSha,
        branch,
        request: Map<String, dynamic>.from(prs.first),
      );
    }
  }

  Future<List<Map<String, dynamic>>> _taskFiles(
    String root,
    String revision, {
    bool Function()? cancelled,
  }) async {
    if (cancelled?.call() == true) throw const _SyncInterrupted();
    final commit = await api.call('GET', '$root/git/commits/$revision');
    final rootTree = await api.call(
      'GET',
      '$root/git/trees/${commit['tree']['sha']}',
    );
    if (rootTree['truncated'] == true) {
      throw const GitHubFailure('저장소 최상위 파일 목록을 모두 확인하지 못했습니다.');
    }
    final entries = rootTree['tree'] as List;
    // Older fixtures and compatible Git providers return flattened trees.
    if (entries.any(
      (e) => (e['path'] as String).startsWith('.ieum/changes/'),
    )) {
      return entries
          .where(
            (e) =>
                e['type'] == 'blob' &&
                (e['path'] as String).startsWith('.ieum/changes/') &&
                (e['path'] as String).endsWith('.json'),
          )
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    final ieum = entries.where(
      (e) => e['path'] == '.ieum' && e['type'] == 'tree',
    );
    if (ieum.isEmpty) return [];
    final settings = await api.call(
      'GET',
      '$root/git/trees/${ieum.single['sha']}',
    );
    if (settings['truncated'] == true) {
      throw const GitHubFailure('프로젝트 폴더 목록을 모두 확인하지 못했습니다.');
    }
    final changes = (settings['tree'] as List).where(
      (e) => e['path'] == 'changes' && e['type'] == 'tree',
    );
    if (changes.isEmpty) return [];
    final result = <Map<String, dynamic>>[];
    Future<void> visit(String sha, String prefix, int depth) async {
      if (cancelled?.call() == true) throw const _SyncInterrupted();
      if (depth > 5) throw const GitHubFailure('작업 폴더의 구조가 너무 깊습니다.');
      final tree = await api.call('GET', '$root/git/trees/$sha');
      if (tree['truncated'] == true) {
        throw const GitHubFailure('작업 폴더 목록을 모두 확인하지 못했습니다.');
      }
      for (final entry in tree['tree'] as List) {
        final path = '$prefix/${entry['path']}';
        if (entry['type'] == 'tree') {
          await visit(entry['sha'] as String, path, depth + 1);
        } else if (entry['type'] == 'blob' && path.endsWith('.json')) {
          result.add({...Map<String, dynamic>.from(entry), 'path': path});
        }
      }
    }

    await visit(changes.single['sha'] as String, '.ieum/changes', 0);
    return result;
  }

  Future<Map<String, dynamic>?> pull(
    GitHubConfig config,
    String previous, {
    String? revision,
    bool Function()? cancelled,
  }) async {
    config.validate();
    final root = '/repos/${config.slug}';
    revision ??= await head(config);
    if (revision == previous) return null;
    final key = '${config.slug}:$revision';
    if (_snapshots.containsKey(key)) return _snapshots[key];
    final files = await _taskFiles(root, revision, cancelled: cancelled);
    final proposals = <Map<String, dynamic>>[];
    final quarantined = <Map<String, dynamic>>[];
    for (final file in files) {
      if (cancelled?.call() == true) throw const _SyncInterrupted();
      final sha = file['sha'] as String;
      final path = file['path'] as String;
      String? error = _badBlobs['$sha:$path'];
      var proposal = _blobCache['$sha:$path'];
      if (error == null && proposal == null) {
        if ((file['size'] as int? ?? 0) > _maxTaskJsonBytes) {
          error = '작업 JSON은 1MB 이하만 지원합니다.';
        } else {
          // Transport errors must not be mistaken for corrupt data: retry this
          // revision instead of committing an incomplete authoritative snapshot.
          final blob = await api.call('GET', '$root/git/blobs/$sha');
          try {
            proposal = _decodeTaskProposal(blob, path: path);
          } catch (e) {
            error = e is GitHubFailure
                ? e.message
                : '작업 JSON의 형식·버전·항목을 확인하세요.';
          }
        }
      }
      if (error != null) {
        _badBlobs['$sha:$path'] = error;
        quarantined.add({
          'path': path,
          'taskId': _quarantineTaskId(path),
          'error': error,
        });
      } else if (proposal != null) {
        _blobCache['$sha:$path'] = proposal;
        proposals.add(proposal);
      }
    }
    if (_blobCache.length > 20000) _blobCache.clear();
    if (_badBlobs.length > 20000) _badBlobs.clear();
    if (_snapshots.length >= 4) _snapshots.remove(_snapshots.keys.first);
    return _snapshots[key] = {
      'revision': revision,
      'proposals': proposals,
      'quarantined': quarantined,
    };
  }

  Future<List<String>> memberBlockers(
    GitHubConfig config,
    ProjectManifest project,
    String memberId,
  ) async {
    final snapshot = (await pull(config, ''))!;
    final remote = _RemoteTasks(snapshot, project.id);
    if (remote.blocked.isNotEmpty) {
      throw const GitHubFailure('손상된 작업을 복구한 뒤 참여자 권한을 변경하세요.');
    }
    return [
      for (final task in remote.tasks.values)
        if (task.status != 'done' &&
            (task.assigneeId == memberId || task.reviewerId == memberId))
          task.title,
      for (final pr in await openRequests(config))
        if ('gh-${pr['user']?['id']}' == memberId &&
            (pr['head']['ref'] as String).startsWith('ieum/tasks/'))
          '통합 대기 PR #${pr['number']}',
    ];
  }

  Future<List<Map<String, dynamic>>> openRequests(GitHubConfig config) async {
    final all = <Map<String, dynamic>>[];
    final seen = <dynamic>{};
    for (var page = 1; ; page++) {
      final prs = await api.call(
        'GET',
        '/repos/${config.slug}/pulls',
        query: {
          'state': 'open',
          'base': config.base,
          'per_page': '100',
          'page': '$page',
          'sort': 'created',
          'direction': 'asc',
        },
      ) as List;
      var added = 0;
      for (final raw in prs) {
        final pr = Map<String, dynamic>.from(raw);
        if (!seen.add(pr['number'])) continue;
        added++;
        final branch = pr['head']['ref'] as String;
        if (branch.startsWith('ieum/members/') &&
            branch.split('/').length == 3) {
          continue;
        }
        if (branch.startsWith('ieum/') ||
            config.branch.isNotEmpty &&
                branch.startsWith('${config.branch}/')) {
          all.add(pr);
        }
      }
      if (prs.length < 100 || added == 0) break;
    }
    return all;
  }

  Future<Map<String, dynamic>> requestState(
    GitHubConfig config,
    String url,
  ) async {
    final prefix = 'https://github.com/${config.slug}/pull/';
    if (!url.toLowerCase().startsWith(prefix.toLowerCase()) ||
        !RegExp(r'^\d+$').hasMatch(url.substring(prefix.length))) {
      throw const GitHubFailure('이 프로젝트의 PR 주소가 아닙니다.');
    }
    return Map<String, dynamic>.from(
      await api.call(
        'GET',
        '/repos/${config.slug}/pulls/${url.substring(prefix.length)}',
      ),
    );
  }

  Future<Map<String, dynamic>> review(GitHubConfig config, String url) async {
    final uri = Uri.tryParse(url);
    final prefix = 'https://github.com/${config.slug}/pull/';
    if (uri == null ||
        !url.toLowerCase().startsWith(prefix.toLowerCase()) ||
        !RegExp(r'^\d+$').hasMatch(url.substring(prefix.length))) {
      throw const GitHubFailure('이 프로젝트의 PR 주소가 아닙니다.');
    }
    final root = '/repos/${config.slug}/pulls/${url.substring(prefix.length)}';
    final pr = await api.call('GET', root);
    if (pr['state'] != 'open' ||
        pr['base']['ref'] != config.base ||
        (pr['head']['repo']?['full_name'] as String?)?.toLowerCase() !=
            config.slug.toLowerCase() ||
        (pr['changed_files'] as int) > 100) {
      throw const GitHubFailure('승인할 수 있는 이 프로젝트의 열린 PR이 아닙니다.');
    }
    final files = await api.call(
      'GET',
      '$root/files',
      query: {'per_page': '100'},
    ) as List;
    if (files.length != pr['changed_files'] ||
        files.isEmpty ||
        files.any(
          (f) =>
              !(f['filename'] as String).startsWith('.ieum/changes/') ||
              !(f['filename'] as String).endsWith('.json') ||
              f['status'] == 'removed' ||
              f['patch'] is! String,
        )) {
      throw const GitHubFailure(
        '작업 JSON 이외의 변경이 포함되어 있습니다. GitHub에서 직접 검토하세요.',
      );
    }
    return {
      'url': url,
      'number': pr['number'],
      'title': pr['title'],
      'sha': pr['head']['sha'],
      'files': files,
      'request': pr,
    };
  }

  Future<void> approve(
    GitHubConfig config,
    Map<String, dynamic> reviewed, {
    bool demo = false,
  }) async {
    ProjectManifest? manifest;
    try {
      manifest = await project(config);
    } on GitHubFailure catch (e) {
      if (e.status != 404 || !demo) rethrow;
    }
    if (manifest != null) {
      await integrateTask(
        config,
        reviewed['url'] as String,
        projectId: manifest.id,
        founderId: manifest.founderId,
        expectedHead: reviewed['sha'] as String,
      );
      return;
    }
    // The bundled offline demo has no project manifest. Keep its preview flow;
    // real project callers require their manifest before reaching this method.
    final result = await api.call(
      'PUT',
      '/repos/${config.slug}/pulls/${reviewed['number']}/merge',
      body: {'sha': reviewed['sha'], 'merge_method': 'merge'},
    );
    if (result['merged'] != true) {
      throw const GitHubFailure('PR을 통합하지 못했습니다. 충돌·승인 조건을 확인하세요.');
    }
  }
}

class GitHubSync extends ChangeNotifier {
  GitHubSync(this.store, {GitHubPublisher? publisher}) {
    if (publisher == null) {
      _ownedApi = HttpGitHubApi(_credential);
    }
    this.publisher = publisher ?? GitHubPublisher(_ownedApi!);
    store.addListener(_onStoreChange);
  }
  final TaskStore store;
  late final GitHubPublisher publisher;
  HttpGitHubApi? _ownedApi;
  bool busy = false, pulling = false, _disposed = false;
  bool _paused = false, _cycling = false;
  DateTime? _retryUntil;
  final Map<String, ({String key, DateTime at})> _integrationAttempts = {};
  static const pollInterval = Duration(seconds: 10);
  DateTime? get retryAt => _retryUntil;
  bool get _waiting => _retryUntil?.isAfter(DateTime.now()) == true;

  Future<void> quiesce() async {
    _paused = true;
    _timer?.cancel();
    _timer = null;
    while (!_disposed && (busy || pulling || _cycling)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  void resume() {
    if (_disposed) return;
    _paused = false;
    start();
  }

  void _recordFailure(Object error) {
    if (error is GitHubFailure && error.retryAfter != null) {
      _retryUntil = DateTime.now().add(error.retryAfter!);
    }
  }

  void _backfill() {
    if (_disposed || !config.enabled) return;
    final queued = {for (final job in jobs) job['taskId']: job};
    for (final change in store.changes) {
      final id = change['taskId'] as String;
      final job = queued[id];
      if (job == null) {
        store.queueGitHub(store.find(id));
      } else {
        final submitted = WorkTask.fromJson(
          Map<String, dynamic>.from(
            (job['proposal']['changes'] as List).single['task'],
          ),
        );
        final local = store.find(id);
        if (!submitted.same(local) && job['state'] != 'sending') {
          store.queueGitHub(local);
        }
      }
    }
  }

  Timer? _timer;
  String pullMessage = '';
  String autoMergeMessage = '';
  final Map<String, String> autoMergeErrors = {};
  bool get autoMergeEnabled => store.isProject && config.autoMerge;
  List<Map<String, dynamic>> openRequests = [];
  String login = '', _sessionToken = '';

  GitHubConfig get config {
    final raw = store.meta('github.config');
    return raw.isEmpty
        ? const GitHubConfig()
        : GitHubConfig.fromJson(Map<String, dynamic>.from(jsonDecode(raw)));
  }

  List<Map<String, dynamic>> get jobs => _readJobs('github_queue');

  List<Map<String, dynamic>> _readJobs(String table) {
    final result = <Map<String, dynamic>>[];
    for (final row in store.db.select(
      'SELECT id,body FROM $table ORDER BY rowid DESC',
    )) {
      try {
        final job = Map<String, dynamic>.from(
          jsonDecode(row['body'] as String),
        );
        final proposal = Map<String, dynamic>.from(job['proposal']);
        _validateTaskProposal(proposal);
        final task = WorkTask.fromJson(
          Map<String, dynamic>.from(
            (proposal['changes'] as List).single['task'],
          ),
        );
        if (job['taskId'] != task.id ||
            (table == 'github_queue' && row['id'] != task.id) ||
            (table == 'github_sent' && row['id'] != job['revision']) ||
            job['revision'] is! String ||
            (job['revision'] as String).isEmpty ||
            job['repository'] is! String ||
            job['title'] is! String ||
            (job['attempts'] != null &&
                (job['attempts'] is! int || job['attempts'] < 0)) ||
            [
              'error',
              'retryAt',
              'prUrl',
              'commitSha',
              'branch',
              'githubLogin',
              'createdAt',
            ].any((key) => job[key] != null && job[key] is! String) ||
            ![
              'pending',
              'sending',
              'sent',
              'merged',
              'failed',
            ].contains(job['state'])) {
          throw const FormatException('전송 기록의 항목이 올바르지 않습니다.');
        }
        job['repository'] = (job['repository'] as String).toLowerCase();
        result.add(job);
      } catch (error) {
        store.transaction(() {
          store.db.execute('INSERT INTO sync_recovery VALUES (?,?)', [
            const Uuid().v4(),
            jsonEncode({
              'table': table,
              'recordId': row['id'],
              'raw': row['body'],
              'error': '$error',
              'createdAt': DateTime.now().toUtc().toIso8601String(),
            }),
          ]);
          store.db.execute('DELETE FROM $table WHERE id=?', [row['id']]);
          store.setMeta(
            'github.recoveryNotice',
            '손상된 전송 기록을 복구 기록에 보관했습니다. 저장된 작업을 기준으로 전송을 다시 준비합니다.',
          );
        });
      }
    }
    return result;
  }

  Future<String> _credential() async {
    if (_sessionToken.isNotEmpty) return _sessionToken;
    Process process;
    try {
      process = await Process.start(
        'git',
        ['credential', 'fill'],
        environment: {'GIT_TERMINAL_PROMPT': '0', 'GCM_INTERACTIVE': 'false'},
      );
    } on ProcessException {
      throw const GitHubFailure('Git 인증을 사용할 수 없습니다. 세션 토큰을 입력하세요.');
    }
    process.stdin.write('protocol=https\nhost=github.com\n\n');
    await process.stdin.close();
    final output = utf8.decoder.bind(process.stdout).join();
    final errors = process.stderr.drain<void>();
    try {
      final code = await process.exitCode.timeout(const Duration(seconds: 15));
      final response = await output;
      await errors;
      if (code == 0) {
        for (final line in const LineSplitter().convert(response)) {
          if (line.startsWith('password=')) {
            _sessionToken = line.substring(9);
            return _sessionToken;
          }
        }
      }
    } on TimeoutException {
      process.kill();
      await errors;
    }
    throw const GitHubFailure('GitHub 인증이 필요합니다. 저장된 Git 인증 또는 세션 토큰을 준비하세요.');
  }

  Future<void> connect(GitHubConfig value, {String token = ''}) async {
    value.validate();
    if (busy || pulling) throw StateError('진행 중인 동기화가 끝난 뒤 설정을 바꿔 주세요.');
    final previousToken = _sessionToken;
    busy = true;
    _notify();
    try {
      _sessionToken = token.trim();
      final identity = await publisher.check(value);
      if (_disposed) return;
      if (store.isProject) {
        final manifest = await publisher.project(value);
        if (_disposed) return;
        if (manifest.id != store.project!.id ||
            manifest.founderId != store.project!.founderId) {
          throw const GitHubFailure('이 DB와 연결된 프로젝트 저장소가 아닙니다.');
        }
        final user = await publisher.api.call('GET', '/user');
        if (_disposed) return;
        if ('gh-${user['id']}' != store.profileId) {
          throw const GitHubFailure('이 DB를 등록한 GitHub 계정으로 로그인하세요.');
        }
        if (_disposed) return;
        store.updateProject(manifest);
      }
      store.setMeta('github.config', jsonEncode(value.toJson()));
      store.setMeta('github.login', identity);
      login = identity;
      store.setMeta('github.pullRevision', '');
    } catch (_) {
      _sessionToken = previousToken;
      rethrow;
    } finally {
      busy = false;
      _notify();
    }
    if (!_disposed && value.enabled) start();
  }

  void start() {
    if (_disposed || _paused) return;
    _backfill();
    _timer ??= Timer.periodic(
      pollInterval,
      (_) => unawaited(cycle(retryFailed: true, background: true)),
    );
    unawaited(cycle(retryFailed: true));
  }

  Future<void> cycle({
    bool retryFailed = false,
    bool background = false,
  }) async {
    if (_disposed ||
        _paused ||
        _cycling ||
        busy ||
        pulling ||
        _waiting ||
        !config.enabled) {
      return;
    }
    _cycling = true;
    try {
      _backfill();
      // One main-head read and one paginated PR listing while nothing changed.
      // Download manifests/JSON and validate merges only when there is new work.
      await pullLatest();
      if (_disposed || _paused || _waiting) return;
      await drain(retryFailed: retryFailed, respectRetrySchedule: background);
      if (!_disposed && !_paused && !_waiting) {
        await integratePending(
          requests: openRequests,
          skipUnchanged: background,
        );
      }
    } finally {
      _cycling = false;
    }
  }

  void setAutoMerge(bool enabled) {
    if (busy || pulling || _disposed) return;
    store.setMeta(
      'github.config',
      jsonEncode({...config.toJson(), 'autoMerge': enabled}),
    );
    _notify();
    if (enabled) unawaited(cycle());
  }

  Future<void> integratePending({
    List<Map<String, dynamic>>? requests,
    bool skipUnchanged = false,
  }) async {
    if (_disposed ||
        _paused ||
        busy ||
        pulling ||
        _waiting ||
        !config.enabled ||
        !autoMergeEnabled) {
      return;
    }
    busy = true;
    _notify();
    final settings = config;
    final projectId = store.project!.id, founderId = store.project!.founderId;
    final executor = store.actor;
    var merged = 0, attempted = 0;
    try {
      requests ??= await publisher.openRequests(settings);
      if (_disposed || _paused || !config.enabled) return;
      openRequests = requests;
      autoMergeErrors.removeWhere(
        (url, _) => !requests!.any((pr) => pr['html_url'] == url),
      );
      _integrationAttempts.removeWhere(
        (url, _) => !requests!.any((pr) => pr['html_url'] == url),
      );
      if (!executor.canMutate) return;
      for (final pr in requests) {
        if (_disposed ||
            _paused ||
            !config.enabled ||
            !autoMergeEnabled ||
            _waiting) {
          break;
        }
        if (!(pr['head']['ref'] as String).startsWith('ieum/tasks/')) continue;
        if (!executor.has('task.integrate') &&
            pr['user']?['id'].toString() !=
                executor.id.replaceFirst('gh-', '')) {
          continue;
        }
        final url = pr['html_url'] as String;
        final key = '${pr['head']['sha']}:${store.meta('github.pullRevision')}';
        final attempt = _integrationAttempts[url];
        if (skipUnchanged &&
            attempt?.key == key &&
            DateTime.now().difference(attempt!.at) <
                const Duration(minutes: 1)) {
          continue;
        }
        _integrationAttempts[url] = (key: key, at: DateTime.now());
        attempted++;
        try {
          await publisher.integrateTask(
            settings,
            url,
            projectId: projectId,
            founderId: founderId,
          );
          if (_disposed) return;
          autoMergeErrors.remove(url);
          openRequests = openRequests
              .where((p) => p['html_url'] != url)
              .toList();
          merged++;
        } catch (e) {
          _recordFailure(e);
          autoMergeErrors[url] = e is GitHubFailure
              ? e.message
              : '작업 JSON을 검증하지 못했습니다. 자동 통합을 보류했습니다.';
        }
      }
      autoMergeMessage = autoMergeErrors.isNotEmpty
          ? '자동 통합 보류 ${autoMergeErrors.length}건 · 이유를 확인하세요.'
          : merged > 0
          ? '작업 PR $merged건을 자동 통합했습니다.'
          : '작업 PR을 검사한 뒤 자동 통합합니다.';
    } catch (e) {
      _recordFailure(e);
      autoMergeMessage = e is GitHubFailure
          ? e.message
          : '자동 통합을 확인하지 못했습니다. 다음 동기화 때 재시도합니다.';
    } finally {
      busy = false;
      _notify();
    }
    if (attempted > 0 && !_disposed && !_paused) await pullLatest();
  }

  void disable() {
    final value = config;
    store.setMeta(
      'github.config',
      jsonEncode({...value.toJson(), 'enabled': false}),
    );
    _notify();
  }

  void _onStoreChange() {
    if (!_disposed && !_paused && config.enabled && !pulling) {
      unawaited(drain());
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> drain({
    bool retryFailed = false,
    bool respectRetrySchedule = false,
  }) async {
    if (busy ||
        pulling ||
        _disposed ||
        _paused ||
        _waiting ||
        !config.enabled) {
      return;
    }
    busy = true;
    _notify();
    final settings = config;
    var submitted = false;
    final submittedRequests = <String, Map<String, dynamic>>{};
    try {
      final pending = jobs
          .where(
            (job) =>
                job['state'] == 'pending' ||
                job['state'] == 'sending' ||
                retryFailed &&
                    job['state'] == 'failed' &&
                    (!respectRetrySchedule ||
                        DateTime.tryParse(job['retryAt'] as String? ?? '')
                                ?.isAfter(DateTime.now()) !=
                            true),
          )
          .toList()
          .reversed;
      for (final job in pending) {
        if (_disposed || _paused || _waiting || !config.enabled) break;
        if ((job['repository'] as String?)?.toLowerCase() != settings.slug) {
          _put({
            ...job,
            'state': 'failed',
            'error': '등록 당시 저장소와 현재 설정이 다릅니다. 원래 저장소를 다시 연결하세요.',
          });
          continue;
        }
        _put({...job, 'state': 'sending', 'error': ''});
        try {
          final original = job['configuration'] == null
              ? settings
              : GitHubConfig.fromJson(
                  Map<String, dynamic>.from(job['configuration'] as Map),
                );
          final receipt = await publisher.publish(original, job);
          submitted = true;
          if (receipt.request != null) {
            submittedRequests[receipt.prUrl] = receipt.request!;
          }
          _put({
            ...job,
            'state': receipt.integrated ? 'merged' : 'sent',
            'attempts': 0,
            'retryAt': '',
            'error': '',
            'prUrl': receipt.prUrl,
            'commitSha': receipt.commitSha,
            'branch': receipt.branch,
          });
        } catch (e) {
          // Never expose credentials or subprocess output in persisted errors.
          final message = e is GitHubFailure
              ? e.message
              : '전송하지 못했습니다. 연결 설정을 확인하고 재시도하세요.';
          _recordFailure(e);
          final attempts = ((job['attempts'] as int? ?? 0) + 1).clamp(1, 10);
          final delay = e is GitHubFailure && e.retryAfter != null
              ? e.retryAfter!
              : Duration(seconds: (5 * (1 << (attempts - 1))).clamp(5, 300));
          _put({
            ...job,
            'state': 'failed',
            'error': message,
            'attempts': attempts,
            'retryAt': DateTime.now().add(delay).toUtc().toIso8601String(),
          });
        }
      }
    } finally {
      busy = false;
      _notify();
    }
    if (submitted &&
        !_disposed &&
        !_paused &&
        autoMergeEnabled &&
        config.enabled) {
      // The publication response already identifies the PRs we just sent.
      // Full team PR discovery remains on the periodic receive cycle.
      await integratePending(
        requests: submittedRequests.isEmpty
            ? null
            : submittedRequests.values.toList(),
      );
      await pullLatest();
    }
    if (!_disposed &&
        !_paused &&
        !_waiting &&
        config.enabled &&
        jobs.any((job) => job['state'] == 'pending')) {
      unawaited(drain());
    }
  }

  void _put(Map<String, dynamic> job) {
    if (_disposed) return;
    if (job['state'] == 'sent' || job['state'] == 'merged') {
      store.db.execute(
        'INSERT INTO github_sent VALUES (?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body',
        [job['revision'], jsonEncode(job)],
      );
      if (job['state'] == 'merged') {
        final version =
            (job['proposal']['changes'] as List).single['task']['version'];
        // A confirmed latest receipt subsumes older submissions by this author.
        // Keep newer in-flight submissions for acknowledgement after a lost reply.
        store.db.execute(
          '''DELETE FROM github_sent WHERE id != ? AND json_valid(body)
          AND lower(json_extract(body, '\$.repository')) = ?
          AND json_extract(body, '\$.taskId') = ?
          AND json_extract(body, '\$.githubLogin') = ?
          AND json_extract(body, '\$.proposal.changes[0].task.version') <= ?''',
          [
            job['revision'],
            job['repository'],
            job['taskId'],
            job['githubLogin'],
            version,
          ],
        );
      }
    }
    final rows = store.db.select('SELECT body FROM github_queue WHERE id=?', [
      job['taskId'],
    ]);
    if (rows.isEmpty ||
        jsonDecode(rows.first['body'] as String)['revision'] !=
            job['revision']) {
      return;
    }
    store.transaction(() {
      store.db.execute('UPDATE github_queue SET body=? WHERE id=?', [
        jsonEncode(job),
        job['taskId'],
      ]);
    });
    _notify();
  }

  Future<void> _reconcileRequests(
    GitHubConfig settings,
    Map<String, WorkTask> remoteTasks,
  ) async {
    final urls = openRequests.map((pr) => pr['html_url']).toSet();
    for (final job in jobs) {
      if (_disposed || _paused) return;
      if (job['repository'] != settings.slug || job['state'] == 'merged') {
        continue;
      }
      final submitted = WorkTask.fromJson(
        Map<String, dynamic>.from(
          (job['proposal']['changes'] as List).single['task'],
        ),
      );
      final remote = remoteTasks[job['taskId']];
      if (remote != null && remote.same(submitted)) {
        _put({
          ...job,
          'state': 'merged',
          'error': '',
          'retryAt': '',
          'attempts': 0,
        });
        continue;
      }
      final url = job['prUrl'] as String? ?? '';
      if (url.isEmpty || urls.contains(url) || job['state'] != 'sent') continue;
      final pr = await publisher.requestState(settings, url);
      if (_disposed || _paused) return;
      if (pr['merged'] == true || pr['merged_at'] != null) {
        _put({...job, 'state': 'merged', 'error': ''});
      } else if (pr['state'] == 'closed') {
        // The change still exists locally. A fresh PR can be created without
        // duplicating the commit, rather than leaving a permanent sent state.
        _put({
          ...job,
          'state': 'pending',
          'prUrl': '',
          'error': '',
          'attempts': 0,
          'retryAt': '',
        });
      }
    }
  }

  Future<void> pullLatest() async {
    if (_disposed ||
        _paused ||
        busy ||
        pulling ||
        _waiting ||
        !config.enabled) {
      return;
    }
    pulling = true;
    _notify();
    final settings = config;
    final previousRevision = store.meta('github.pullRevision');
    final previousConflicts = store.meta('github.pullConflicts');
    try {
      final revision = await publisher.head(settings);
      if (_disposed || _paused || !config.enabled) return;
      final data = await publisher.pull(
        settings,
        previousConflicts.isEmpty ? previousRevision : '',
        revision: revision,
        cancelled: () => _disposed || _paused,
      );
      if (_disposed || _paused) return;
      final requests = await publisher.openRequests(settings);
      if (_disposed || _paused || !config.enabled) return;
      openRequests = requests;
      if (store.isProject &&
          (revision != previousRevision || previousRevision.isEmpty)) {
        final manifest = await publisher.project(settings, ref: revision);
        if (_disposed || _paused || !config.enabled) return;
        store.updateProject(manifest);
      }
      if (data == null) {
        await _reconcileRequests(settings, store.baseline);
        return;
      }
      final remote = _RemoteTasks(data, store.meta('projectId'));
      store.setMeta(
        'github.quarantined',
        jsonEncode(data['quarantined'] ?? []),
      );
      if (remote.uncertain) {
        pullMessage =
            '작업 ID를 확인할 수 없는 손상 파일이 있습니다. 해당 파일을 복구해 주세요. ${remote.warnings.join(' / ')}';
        return;
      }
      await _reconcileRequests(settings, remote.tasks);
      if (_disposed || _paused || !config.enabled) return;
      final incoming = Map<String, WorkTask>.from(store.baseline);
      final acknowledged = Map<String, WorkTask>.from(store.baseline);
      final receipts = [
        ..._readJobs('github_sent'),
        ...jobs,
      ].where((job) => job['repository'] == settings.slug).toList();
      final receiptTasks = <String, List<WorkTask>>{};
      for (final receipt in receipts) {
        final key = '${receipt['taskId']}:${receipt['githubLogin']}';
        (receiptTasks[key] ??= []).add(
          WorkTask.fromJson(
            Map<String, dynamic>.from(
              (receipt['proposal']['changes'] as List).single['task'],
            ),
          ),
        );
      }
      for (final proposal in data['proposals'] as List) {
        if (proposal['projectId'] != store.meta('projectId')) continue;
        final task = WorkTask.fromJson(
          Map<String, dynamic>.from(
            (proposal['changes'] as List).single['task'],
          ),
        );
        if (remote.blocked.contains(task.id)) continue;
        final base = acknowledged[task.id];
        if ((base == null || base.version <= task.version) &&
            (receiptTasks['${task.id}:${proposal['githubLogin']}'] ?? []).any(
              (own) => own.version == task.version && own.same(task),
            )) {
          acknowledged[task.id] = task;
        }
      }
      // A merged receipt can have been superseded in its author file already.
      // Its exact submission is still the base against which newer local edits
      // were made; only a confirmed merged PR may advance that acknowledgment.
      for (final job in receipts.where((j) => j['state'] == 'merged')) {
        final own = WorkTask.fromJson(
          Map<String, dynamic>.from(
            (job['proposal']['changes'] as List).single['task'],
          ),
        );
        final latest = remote.tasks[own.id], base = acknowledged[own.id];
        if (latest != null &&
            latest.version >= own.version &&
            (base == null || own.version > base.version)) {
          acknowledged[own.id] = own;
        }
      }
      for (final task in remote.tasks.values) {
        final base = incoming[task.id];
        if (base == null || base.version <= task.version) {
          incoming[task.id] = task;
        }
      }
      final result = store.importSnapshot(
        {
          'schemaVersion': 1,
          'projectId': store.meta('projectId'),
          'revision': revision,
          'tasks': incoming.values.map((t) => t.data).toList(),
        },
        acknowledgedBases: acknowledged,
        allowPartial: true,
      );
      final conflicts = result.conflicts.map((c) => c['taskId']).toSet();
      store.setMeta('github.pullRevision', revision);
      store.setMeta(
        'github.pullConflicts',
        result.conflicts.isEmpty ? '' : jsonEncode(result.conflicts),
      );
      final messages = <String>[
        '최신 작업을 동기화했습니다.',
        if (result.conflicts.isNotEmpty)
          '충돌 ${result.conflicts.length}건의 개인 변경을 보존했습니다. 다른 작업은 동기화됩니다.',
        if (remote.warnings.isNotEmpty)
          '문제 파일 ${remote.warnings.length}건을 격리했습니다. 정상 작업은 계속 동기화됩니다. ${remote.warnings.join(' / ')}',
      ];
      pullMessage = messages.join(' ');
      if (autoMergeEnabled) {
        for (final job in jobs) {
          if (conflicts.contains(job['taskId']) ||
              remote.blocked.contains(job['taskId'])) {
            continue;
          }
          final local = store.tasks.where((t) => t.id == job['taskId']);
          final current = remote.tasks[job['taskId']];
          if (local.isEmpty || current == null || local.single.same(current)) {
            continue;
          }
          final submitted = (job['proposal']['changes'] as List).single as Map;
          final oldBase = submitted['base'];
          if (oldBase == null ||
              oldBase['version'] != current.version ||
              !WorkTask.fromJson(Map<String, dynamic>.from(oldBase))
                  .same(current)) {
            store.queueGitHub(local.single);
          }
        }
      }
    } catch (e) {
      _recordFailure(e);
      if (e is _SyncInterrupted) return;
      pullMessage = e is GitHubFailure
          ? e.message
          : '통합본을 가져오지 못했습니다. 개인 데이터는 보존했습니다.';
    } finally {
      pulling = false;
      _notify();
      if (!_disposed &&
          !_paused &&
          !_waiting &&
          !_cycling &&
          config.enabled &&
          jobs.any((job) => job['state'] == 'pending')) {
        unawaited(drain());
      }
    }
  }

  Future<void> acceptRemote(
    String taskId, {
    required int expectedVersion,
  }) async {
    if (_disposed || _paused || busy || pulling || _waiting) {
      throw StateError('진행 중인 동기화가 끝난 뒤 다시 선택하세요.');
    }
    if (store.find(taskId).version != expectedVersion) {
      throw StateError('작업이 변경되었습니다. 내용을 다시 확인하세요.');
    }
    final settings = config;
    final projectId = store.meta('projectId');
    final profileId = store.profileId;
    busy = true;
    _notify();
    try {
      var snapshot = (await publisher.pull(settings, ''))!;
      var remote = _RemoteTasks(snapshot, projectId);
      if (remote.uncertain ||
          remote.blocked.contains(taskId) ||
          !remote.tasks.containsKey(taskId)) {
        throw const GitHubFailure('정상적인 최신 작업을 확인하지 못했습니다. 통합 파일을 먼저 확인하세요.');
      }
      final requests = await publisher.openRequests(settings);
      for (final pr in requests) {
        final branch = pr['head']['ref'] as String;
        if ('gh-${pr['user']?['id']}' != profileId ||
            !branch.startsWith('ieum/tasks/') ||
            !branch.endsWith('/$taskId')) {
          continue;
        }
        await publisher.api.call(
          'PATCH',
          '/repos/${settings.slug}/pulls/${pr['number']}',
          body: {'state': 'closed'},
        );
      }
      final protection = await publisher.api.call(
        'GET',
        '/repos/${settings.slug}/branches/${Uri.encodeComponent(settings.base)}',
      );
      if (protection['protected'] != false) {
        throw const GitHubFailure(
          '보호 브랜치의 승인 조건 때문에 충돌 해결을 완료하지 못했습니다. 개인 변경은 보존했습니다.',
        );
      }
      // Closing a PR alone does not fence an integrator that already read its
      // open state. A same-tree commit advances main atomically, invalidating
      // every integration prepared against the earlier parent without changing
      // task data. A competing accepted merge is observed before trying again.
      var fenced = false;
      for (var attempt = 0; attempt < 3 && !fenced; attempt++) {
        final revision = await publisher.head(settings);
        final commit = await publisher.api.call(
          'GET',
          '/repos/${settings.slug}/git/commits/$revision',
        );
        final fence = await publisher.api.call(
          'POST',
          '/repos/${settings.slug}/git/commits',
          body: {
            'message': 'Resolve IEUM task $taskId against current main',
            'tree': commit['tree']['sha'],
            'parents': [revision],
          },
        );
        try {
          await publisher.api.call(
            'PATCH',
            '/repos/${settings.slug}/git/refs/heads/${settings.base}',
            body: {'sha': fence['sha'], 'force': false},
          );
          fenced = true;
        } on GitHubFailure catch (e) {
          if (e.status != 409 && e.status != 422) rethrow;
        }
      }
      if (!fenced) {
        throw const GitHubFailure(
          '다른 작업이 통합 중입니다. 잠시 후 다시 선택하세요. 개인 변경은 보존했습니다.',
        );
      }
      // Include any competing integration that won before the fence.
      snapshot = (await publisher.pull(settings, ''))!;
      remote = _RemoteTasks(snapshot, projectId);
      if (_disposed) return;
      if (remote.uncertain ||
          remote.blocked.contains(taskId) ||
          !remote.tasks.containsKey(taskId)) {
        throw const GitHubFailure('최신 작업을 다시 확인하지 못했습니다. 개인 변경은 보존했습니다.');
      }
      store.acceptRemoteTask(
        remote.tasks[taskId]!,
        expectedVersion: expectedVersion,
      );
      pullMessage = '개인 변경을 복구 기록에 보관하고 최신 통합본을 적용했습니다.';
    } catch (e) {
      _recordFailure(e);
      rethrow;
    } finally {
      busy = false;
      _notify();
    }
    await pullLatest();
  }

  Future<void> approve(Map<String, dynamic> review) async {
    if (_disposed || _paused || busy || pulling) {
      throw StateError('진행 중인 동기화가 끝난 뒤 승인하세요.');
    }
    busy = true;
    _notify();
    try {
      if (store.isProject) {
        final manifest = await publisher.project(config);
        if (_disposed) return;
        store.updateProject(manifest);
        final actor = await publisher.projectActor(config, manifest);
        if (_disposed) return;
        if (!actor.has('task.integrate')) {
          throw const GitHubFailure('다른 참여자의 PR 통합 권한이 필요합니다.');
        }
      }
      await publisher.approve(config, review, demo: !store.isProject);
    } finally {
      busy = false;
      _notify();
    }
    await pullLatest();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    store.removeListener(_onStoreChange);
    _ownedApi?.close();
    _sessionToken = '';
    super.dispose();
  }
}
