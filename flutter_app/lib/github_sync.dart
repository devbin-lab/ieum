import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'store.dart';
import 'models.dart';

part 'github_auto_merge.dart';

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
      .replaceFirst(RegExp(r'^https://github\.com/'), '')
      .replaceFirst(RegExp(r'\.git$'), '')
      .replaceFirst(RegExp(r'/$'), '');

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
  const GitHubFailure(this.message, [this.status = 0]);
  final String message;
  final int status;
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
  HttpGitHubApi(this.token);
  final Future<String> Function() token;

  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    final credential = await token();
    if (credential.isEmpty) throw const GitHubFailure('GitHub 인증이 필요합니다.');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
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
      final data = raw.isEmpty ? null : jsonDecode(raw);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final explanation = switch (response.statusCode) {
          401 => 'GitHub 인증이 만료되었거나 토큰이 올바르지 않습니다.',
          403 => '저장소 쓰기·PR 권한 또는 GitHub 요청 한도를 확인하세요.',
          404 => '저장소·브랜치가 없거나 접근 권한이 없습니다.',
          409 => '브랜치 변경이 충돌했습니다. 통합 상태를 확인 후 재시도하세요.',
          422 => 'GitHub가 변경을 거부했습니다. 브랜치·PR 상태를 확인하세요.',
          _ => 'GitHub 요청에 실패했습니다. HTTP ${response.statusCode}',
        };
        throw GitHubFailure(explanation, response.statusCode);
      }
      return data;
    } on SocketException {
      throw const GitHubFailure('네트워크에 연결할 수 없습니다. 작업은 로컬에 보관됩니다.');
    } on TimeoutException {
      throw const GitHubFailure('GitHub 응답 시간이 초과되었습니다. 재시도할 수 있습니다.');
    } finally {
      client.close(force: true);
    }
  }
}

class SyncReceipt {
  const SyncReceipt(this.prUrl, this.commitSha, this.branch);
  final String prUrl, commitSha, branch;
}

class GitHubPublisher {
  GitHubPublisher(this.api);
  final GitHubApi api;
  final Map<String, Map<String, dynamic>> _blobCache = {};

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
    ProjectManifest manifest,
  ) async {
    final identity = await api.call('GET', '/user');
    final people = manifest.people.where((p) => p.id == 'gh-${identity['id']}');
    if (people.isEmpty || !people.first.active) {
      throw const GitHubFailure('가입 승인을 받거나 현재 역할을 확인하세요.');
    }
    return people.first;
  }

  Future<String> check(GitHubConfig config) async {
    config.validate();
    final user = await api.call('GET', '/user');
    final repository = await api.call('GET', '/repos/${config.slug}');
    if (repository['permissions']?['push'] != true) {
      throw const GitHubFailure('이 저장소에 개인 브랜치를 올릴 수 있는 쓰기 권한이 필요합니다.');
    }
    await api.call('GET', '/repos/${config.slug}/git/ref/heads/${config.base}');
    return user['login'] as String;
  }

  Future<SyncReceipt> publish(
    GitHubConfig config,
    Map<String, dynamic> job,
  ) async {
    final login = await check(config);
    if (job['githubLogin'] != null && job['githubLogin'] != login) {
      throw const GitHubFailure('이 작업을 등록한 GitHub 계정으로 다시 연결하세요.');
    }
    final proposal = job['proposal'] as Map;
    if (proposal['projectId'] != 'ieum-demo') {
      final manifest = await project(config);
      final actor = await projectActor(config, manifest);
      if (manifest.id != proposal['projectId'] ||
          actor.id != proposal['authorId']) {
        throw const GitHubFailure('프로젝트 또는 로그인한 작업 작성자가 다릅니다.');
      }
      final change = (proposal['changes'] as List).single as Map;
      final task = WorkTask.fromJson(Map<String, dynamic>.from(change['task']));
      final base = change['base'];
      if (!actor.manages) {
        if (actor.role != 'worker' || base is! Map) {
          throw const GitHubFailure('작업 등록·전송 권한이 없습니다.');
        }
        final worker = base['assigneeId'] == actor.id;
        final reviewer = base['reviewerId'] == actor.id;
        final assignments = [
          'part',
          'assigneeId',
          'reviewerId',
          'assignedDate',
          'dueDate',
          'priority',
        ];
        if (assignments.any((f) => base[f] != task.data[f]) ||
            (!worker && !reviewer) ||
            ['done', 'rework'].contains(task.status) && !reviewer ||
            !['done', 'rework'].contains(task.status) && !worker) {
          throw const GitHubFailure('배정된 작업·검토 범위 밖의 변경입니다.');
        }
      }
      for (final id in [task.assigneeId, task.reviewerId]) {
        if (!manifest.people.any(
          (p) => p.id == id && p.active && p.role != 'viewer',
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
    var prs = await api.call('GET', '$root/pulls', query: query) as List;
    final baseRef = await api.call('GET', '$root/git/ref/heads/${config.base}');
    try {
      await api.call('GET', '$root/git/ref/heads/$branch');
      // Advance/merge main into an existing personal branch without force push.
      // Conflicts stop here, leaving the saved task and queue intact.
      await api.call(
        'POST',
        '$root/merges',
        body: {
          'base': branch,
          'head': baseRef['object']['sha'],
          'commit_message': 'Sync ${config.base} before IEUM task submission',
        },
      );
    } on GitHubFailure catch (e) {
      if (e.status != 404) rethrow;
      try {
        await api.call(
          'POST',
          '$root/git/refs',
          body: {'ref': 'refs/heads/$branch', 'sha': baseRef['object']['sha']},
        );
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
    prs = await api.call('GET', '$root/pulls', query: query) as List;
    if (prs.isNotEmpty) {
      return SyncReceipt(prs.first['html_url'] as String, commitSha, branch);
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
      return SyncReceipt(pr['html_url'] as String, commitSha, branch);
    } on GitHubFailure catch (e) {
      if (e.status != 422) rethrow;
      prs = await api.call('GET', '$root/pulls', query: query) as List;
      if (prs.isEmpty) rethrow;
      return SyncReceipt(prs.first['html_url'] as String, commitSha, branch);
    }
  }

  Future<Map<String, dynamic>?> pull(
    GitHubConfig config,
    String previous,
  ) async {
    config.validate();
    final root = '/repos/${config.slug}';
    final ref = await api.call('GET', '$root/git/ref/heads/${config.base}');
    final revision = ref['object']['sha'] as String;
    if (revision == previous) return null;
    final commit = await api.call('GET', '$root/git/commits/$revision');
    final tree = await api.call(
      'GET',
      '$root/git/trees/${commit['tree']['sha']}',
      query: {'recursive': '1'},
    );
    if (tree['truncated'] == true) {
      throw const GitHubFailure('저장소가 커서 통합 데이터를 모두 확인하지 못했습니다.');
    }
    final files = (tree['tree'] as List)
        .where(
          (entry) =>
              entry['type'] == 'blob' &&
              (entry['path'] as String).startsWith('.ieum/changes/') &&
              (entry['path'] as String).endsWith('.json'),
        )
        .toList();
    if (files.length > 1000) {
      throw const GitHubFailure('현재 자동 통합은 작업 파일 1000개까지 지원합니다.');
    }
    final proposals = <Map<String, dynamic>>[];
    for (final file in files) {
      final cached = _blobCache[file['sha']];
      if (cached != null) {
        proposals.add(cached);
        continue;
      }
      if ((file['size'] as int? ?? 0) > 1024 * 1024) {
        throw const GitHubFailure('작업 JSON은 1MB 이하만 지원합니다.');
      }
      final blob = await api.call('GET', '$root/git/blobs/${file['sha']}');
      if (blob['encoding'] != 'base64') {
        throw const GitHubFailure('작업 파일 형식을 확인하세요.');
      }
      final content = utf8.decode(
        base64Decode((blob['content'] as String).replaceAll(RegExp(r'\s'), '')),
      );
      final data = jsonDecode(content);
      if (data is! Map) throw const GitHubFailure('통합 작업 JSON이 올바르지 않습니다.');
      final proposal = Map<String, dynamic>.from(data);
      _blobCache[file['sha'] as String] = proposal;
      proposals.add(proposal);
    }
    return {'revision': revision, 'proposals': proposals};
  }

  Future<List<Map<String, dynamic>>> openRequests(GitHubConfig config) async {
    final prs = await api.call(
      'GET',
      '/repos/${config.slug}/pulls',
      query: {'state': 'open', 'base': config.base, 'per_page': '100'},
    ) as List;
    return prs
        .where(
          (pr) =>
              !((pr['head']['ref'] as String).startsWith('ieum/members/') &&
                  (pr['head']['ref'] as String).split('/').length == 3) &&
              ((pr['head']['ref'] as String).startsWith('ieum/') ||
                  config.branch.isNotEmpty &&
                      (pr['head']['ref'] as String).startsWith(
                        '${config.branch}/',
                      )),
        )
        .map((pr) => Map<String, dynamic>.from(pr))
        .toList();
  }

  Future<Map<String, dynamic>> review(GitHubConfig config, String url) async {
    final uri = Uri.tryParse(url);
    final prefix = 'https://github.com/${config.slug}/pull/';
    if (uri == null ||
        !url.startsWith(prefix) ||
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

  Future<void> approve(GitHubConfig config, Map<String, dynamic> review) async {
    final result = await api.call(
      'PUT',
      '/repos/${config.slug}/pulls/${review['number']}/merge',
      body: {'sha': review['sha'], 'merge_method': 'merge'},
    );
    if (result['merged'] != true) {
      throw const GitHubFailure('PR을 통합하지 못했습니다. 충돌·승인 조건을 확인하세요.');
    }
  }
}

class GitHubSync extends ChangeNotifier {
  GitHubSync(this.store, {GitHubPublisher? publisher}) {
    this.publisher = publisher ?? GitHubPublisher(HttpGitHubApi(_credential));
    store.addListener(_onStoreChange);
  }
  final TaskStore store;
  late final GitHubPublisher publisher;
  bool busy = false, pulling = false, _disposed = false;
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

  List<Map<String, dynamic>> get jobs => store.db
      .select('SELECT body FROM github_queue ORDER BY rowid DESC')
      .map(
        (row) => Map<String, dynamic>.from(jsonDecode(row['body'] as String)),
      )
      .toList();

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
            manifest.ownerId != store.project!.ownerId) {
          throw const GitHubFailure('이 DB와 연결된 프로젝트 저장소가 아닙니다.');
        }
        final user = await publisher.api.call('GET', '/user');
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
    if (_disposed) return;
    _timer ??= Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(cycle(retryFailed: true)),
    );
    unawaited(cycle());
  }

  Future<void> cycle({bool retryFailed = false}) async {
    await drain(retryFailed: retryFailed);
    if (!_disposed) await integratePending();
    if (!_disposed) await pullLatest();
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

  Future<void> integratePending() async {
    if (_disposed || busy || pulling || !config.enabled || !autoMergeEnabled) {
      return;
    }
    busy = true;
    _notify();
    final settings = config;
    try {
      final manifest = await publisher.project(settings);
      final executor = await publisher.projectActor(settings, manifest);
      if (!executor.active || executor.role == 'viewer') return;
      final requests = await publisher.openRequests(settings);
      if (_disposed || !config.enabled) return;
      autoMergeErrors.removeWhere(
        (url, _) => !requests.any((pr) => pr['html_url'] == url),
      );
      var merged = 0;
      for (final pr in requests.reversed) {
        if (_disposed || !config.enabled || !autoMergeEnabled) break;
        if (!(pr['head']['ref'] as String).startsWith('ieum/tasks/')) continue;
        if (!executor.manages &&
            pr['user']?['id'] != int.parse(executor.id.substring(3))) {
          continue;
        }
        final url = pr['html_url'] as String;
        try {
          await publisher.integrateTask(
            settings,
            url,
            projectId: store.project!.id,
            ownerId: store.project!.ownerId,
          );
          autoMergeErrors.remove(url);
          merged++;
        } catch (e) {
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
      autoMergeMessage = e is GitHubFailure
          ? e.message
          : '자동 통합을 확인하지 못했습니다. 다음 동기화 때 재시도합니다.';
    } finally {
      busy = false;
      _notify();
    }
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
    if (config.enabled && !pulling) unawaited(drain());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> drain({bool retryFailed = false}) async {
    if (busy || pulling || _disposed || !config.enabled) return;
    busy = true;
    _notify();
    final settings = config;
    var submitted = false;
    try {
      final pending = jobs
          .where(
            (job) =>
                job['state'] == 'pending' ||
                job['state'] == 'sending' ||
                retryFailed && job['state'] == 'failed',
          )
          .toList()
          .reversed;
      for (final job in pending) {
        if (_disposed || !config.enabled) break;
        if (job['repository'] != settings.slug) {
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
          _put({
            ...job,
            'state': 'sent',
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
          _put({...job, 'state': 'failed', 'error': message});
        }
      }
    } finally {
      busy = false;
      _notify();
    }
    if (submitted && !_disposed && autoMergeEnabled && config.enabled) {
      await integratePending();
      await pullLatest();
    }
    if (!_disposed &&
        config.enabled &&
        jobs.any((job) => job['state'] == 'pending')) {
      unawaited(drain());
    }
  }

  void _put(Map<String, dynamic> job) {
    if (_disposed) return;
    if (job['state'] == 'sent') {
      store.db.execute(
        'INSERT INTO github_sent VALUES (?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body',
        [job['revision'], jsonEncode(job)],
      );
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

  Future<void> pullLatest() async {
    if (_disposed || busy || pulling || !config.enabled) return;
    pulling = true;
    _notify();
    final settings = config;
    try {
      if (store.isProject) {
        final manifest = await publisher.project(settings);
        if (_disposed || !config.enabled) return;
        store.updateProject(manifest);
      }
      final data = await publisher.pull(
        settings,
        store.meta('github.pullRevision'),
      );
      final requests = await publisher.openRequests(settings);
      if (_disposed || !config.enabled) return;
      openRequests = requests;
      if (data == null) return;
      final incoming = Map<String, WorkTask>.from(store.baseline);
      final acknowledged = Map<String, WorkTask>.from(store.baseline);
      final sent = store.db
          .select('SELECT body FROM github_sent')
          .map(
            (row) =>
                Map<String, dynamic>.from(jsonDecode(row['body'] as String)),
          )
          .where((job) => job['repository'] == settings.slug)
          .toList();
      final remoteTasks = <String, WorkTask>{};
      for (final proposal in data['proposals'] as List) {
        if (proposal['projectId'] != store.meta('projectId')) continue;
        if (proposal['schemaVersion'] != 1 || proposal['changes'] is! List) {
          throw const GitHubFailure('프로젝트 변경안 형식이 올바르지 않습니다.');
        }
        for (final change in proposal['changes'] as List) {
          final task = WorkTask.fromJson(
            Map<String, dynamic>.from(change['task'] as Map),
          );
          // A team may approve our PR and then advance the same task before
          // our next poll. Treat our accepted proposal as a baseline first,
          // so the later update does not conflict with our already-approved edit.
          final base = acknowledged[task.id];
          if ((base == null || base.version <= task.version) &&
              sent.any((job) {
                if (job['taskId'] != task.id ||
                    job['githubLogin'] != proposal['githubLogin']) {
                  return false;
                }
                final own = WorkTask.fromJson(
                  Map<String, dynamic>.from(
                    (job['proposal']['changes'] as List).single['task'],
                  ),
                );
                return own.version == task.version && own.same(task);
              })) {
            acknowledged[task.id] = task;
          }
          final previous = remoteTasks[task.id];
          if (previous != null &&
              previous.version == task.version &&
              !previous.same(task)) {
            throw const GitHubFailure('동일 작업의 서로 다른 변경이 통합되어 있습니다. 확인이 필요합니다.');
          }
          if (previous == null || previous.version < task.version) {
            remoteTasks[task.id] = task;
          }
        }
      }
      for (final task in remoteTasks.values) {
        final base = incoming[task.id];
        if (base == null || base.version <= task.version) {
          incoming[task.id] = task;
        }
      }
      final result = store.importSnapshot({
        'schemaVersion': 1,
        'projectId': store.meta('projectId'),
        'revision': data['revision'],
        'tasks': incoming.values.map((t) => t.data).toList(),
      }, acknowledgedBases: acknowledged);
      if (!result.applied) {
        pullMessage =
            '통합 충돌 ${result.conflicts.length}건: 개인 변경을 보존했습니다. 아래 충돌 내용을 확인하세요.';
        store.setMeta('github.pullConflicts', jsonEncode(result.conflicts));
      } else {
        store.setMeta('github.pullRevision', data['revision'] as String);
        store.setMeta('github.pullConflicts', '');
        pullMessage = '승인된 통합본을 자동으로 가져왔습니다.';
        for (final job in jobs) {
          if (job['state'] != 'sent') continue;
          final remote = remoteTasks[job['taskId']];
          final submitted = (job['proposal']['changes'] as List).first['task'];
          if (remote != null &&
              remote.same(
                WorkTask.fromJson(Map<String, dynamic>.from(submitted)),
              )) {
            _put({...job, 'state': 'merged'});
          }
        }
        // Rebase newer local edits on the acknowledged submission. Their old
        // queued proposal may have been captured while the previous PR merged.
        if (autoMergeEnabled) {
          for (final job in jobs) {
            final local = store.tasks.where((t) => t.id == job['taskId']);
            final remote = remoteTasks[job['taskId']];
            if (local.isEmpty || remote == null || local.single.same(remote)) {
              continue;
            }
            final submitted =
                (job['proposal']['changes'] as List).single as Map;
            final oldBase = submitted['base'];
            if (oldBase == null ||
                oldBase['version'] != remote.version ||
                !WorkTask.fromJson(Map<String, dynamic>.from(oldBase))
                    .same(remote)) {
              store.queueGitHub(local.single);
            }
          }
        }
      }
    } catch (e) {
      pullMessage = e is GitHubFailure
          ? e.message
          : '통합본을 가져오지 못했습니다. 개인 데이터는 보존했습니다.';
    } finally {
      pulling = false;
      _notify();
      if (!_disposed &&
          config.enabled &&
          jobs.any((job) => job['state'] == 'pending')) {
        unawaited(drain());
      }
    }
  }

  Future<void> approve(Map<String, dynamic> review) async {
    if (busy || pulling) throw StateError('진행 중인 동기화가 끝난 뒤 승인하세요.');
    busy = true;
    _notify();
    try {
      if (store.isProject) {
        final manifest = await publisher.project(config);
        if (_disposed) return;
        store.updateProject(manifest);
        final actor = await publisher.projectActor(config, manifest);
        if (!actor.manages) {
          throw const GitHubFailure('통합 승인은 개설자 또는 PD / PM에게 허용됩니다.');
        }
      }
      await publisher.approve(config, review);
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
    _sessionToken = '';
    super.dispose();
  }
}
