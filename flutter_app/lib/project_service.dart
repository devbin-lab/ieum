import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'github_sync.dart';
import 'models.dart';
import 'github_oauth.dart';

/// Authentication belongs to GitHub. IEUM stores a nickname, never a password.
class GitHubSession {
  GitHubSession({GitHubApi? api, GitHubOAuth? oauth})
    : oauth = oauth ?? GitHubOAuth() {
    this.api = api ?? HttpGitHubApi(credential);
  }
  late final GitHubApi api;
  final GitHubOAuth oauth;
  OAuthTokens? _oauthTokens;
  bool _remember = false;
  String? _oauthUserId;
  int _authGeneration = 0;
  Future<String>? _refreshing;
  Future<void> _vaultQueue = Future<void>.value();
  String _token = '';
  bool _allowGitCredential = false;
  Person? user;
  String get sessionToken => _token;

  Future<String> credential() async {
    if (_oauthTokens != null) return oauthCredential();
    if (_token.isNotEmpty) return _token;
    if (!_allowGitCredential) {
      throw const GitHubFailure('GitHub에 다시 로그인하세요.', 401);
    }
    Process process;
    try {
      process = await Process.start(
        'git',
        ['credential', 'fill'],
        environment: {'GIT_TERMINAL_PROMPT': '0', 'GCM_INTERACTIVE': 'false'},
      );
    } on ProcessException {
      throw const GitHubFailure('저장된 Git 인증을 찾을 수 없습니다. 세션 토큰을 입력하세요.');
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
            _token = line.substring(9);
            return _token;
          }
        }
      }
    } catch (_) {
      process.kill();
      await errors;
    }
    throw const GitHubFailure('GitHub 로그인이 필요합니다. 저장된 Git 인증 또는 세션 토큰을 사용하세요.');
  }

  Future<void> _vault(Future<void> Function() operation) {
    final next = _vaultQueue.then((_) => operation());
    _vaultQueue = next.catchError((Object _) {});
    return next;
  }

  Future<void> _saveOAuth(int generation) => _vault(() async {
    if (generation != _authGeneration ||
        !_remember ||
        _oauthTokens == null ||
        (user?.id ?? _oauthUserId) == null) {
      return;
    }
    await oauth.vault.write(
      jsonEncode({
        'schema': 1,
        'clientId': githubOAuthClientId,
        'userId': user?.id ?? _oauthUserId,
        'tokens': _oauthTokens!.toJson(),
      }),
    );
  });

  Future<String> oauthCredential() {
    final current = _oauthTokens;
    if (current == null) return Future.value(_token);
    if (current.expiresAt == null ||
        oauth
            .now()
            .add(const Duration(minutes: 2))
            .isBefore(current.expiresAt!)) {
      return Future.value(current.access);
    }
    if (_refreshing != null) return _refreshing!;
    final generation = _authGeneration;
    final expectedId = user?.id ?? _oauthUserId;
    final future = () async {
      try {
        final next = await oauth.refresh(current);
        if (generation != _authGeneration) {
          throw const GitHubFailure('로그인이 변경되었습니다.', 401);
        }
        // Revalidate the identity with the new token before publishing it to callers.
        final verifier = api is HttpGitHubApi
            ? HttpGitHubApi(() async => next.access)
            : api;
        final identity = await verifier.call('GET', '/user');
        if (expectedId != null && 'gh-${identity['id']}' != expectedId) {
          throw const GitHubFailure('GitHub 계정이 변경되었습니다. 다시 로그인하세요.', 401);
        }
        if (generation != _authGeneration) {
          throw const GitHubFailure('로그인이 변경되었습니다.', 401);
        }
        _oauthTokens = next;
        _token = next.access;
        await _saveOAuth(generation);
        return next.access;
      } on GitHubFailure catch (e) {
        if (e.status == 401 && generation == _authGeneration) await logout();
        rethrow;
      } finally {
        if (generation == _authGeneration) _refreshing = null;
      }
    }();
    _refreshing = future;
    return future;
  }

  Future<Person> _identity() async {
    final data = await api.call('GET', '/user');
    if (data['id'] is! int || data['id'] <= 0) {
      throw const GitHubFailure('GitHub 계정 ID를 확인하지 못했습니다.');
    }
    return Person.fromJson({
      'id': 'gh-${data['id']}',
      'login': data['login'],
      'name': data['login'],
      'role': 'pending',
      'parts': <String>[],
    });
  }

  Future<Person> signInOAuth({
    required bool remember,
    required void Function(DeviceGrant) onCode,
  }) async {
    await logout();
    final generation = _authGeneration;
    final grant = await oauth.start();
    if (generation != _authGeneration) {
      throw const GitHubFailure('로그인을 취소했습니다.');
    }
    onCode(grant);
    final tokens = await oauth.poll(grant, () => generation != _authGeneration);
    if (generation != _authGeneration) {
      throw const GitHubFailure('로그인을 취소했습니다.');
    }
    _oauthTokens = tokens;
    _token = tokens.access;
    try {
      final identity = await _identity();
      if (generation != _authGeneration) {
        throw const GitHubFailure('로그인을 취소했습니다.');
      }
      user = identity;
      _oauthUserId = identity.id;
      _remember = remember;
      await _saveOAuth(generation);
      return identity;
    } catch (_) {
      if (generation == _authGeneration) await logout();
      rethrow;
    }
  }

  Future<bool> restoreOAuth() async {
    final generation = _authGeneration;
    final raw = await oauth.vault.read();
    if (raw == null || generation != _authGeneration) return false;
    String expected;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['schema'] != 1 || data['clientId'] != githubOAuthClientId) {
        throw const FormatException();
      }
      expected = data['userId'] as String;
      _oauthUserId = expected;
      _oauthTokens = OAuthTokens.fromStored(
        Map<String, dynamic>.from(data['tokens']),
      );
      if (_oauthTokens!.access.isEmpty ||
          !_oauthTokens!.scope.split(RegExp(r'[ ,]+')).contains('repo')) {
        throw const FormatException();
      }
      _remember = true;
    } catch (_) {
      await logout();
      throw const GitHubFailure('저장된 로그인을 확인하지 못했습니다. GitHub에 다시 로그인하세요.');
    }
    try {
      final identity = await _identity();
      if (generation != _authGeneration) return false;
      if (identity.id != expected) {
        throw const GitHubFailure('GitHub 계정이 변경되었습니다. 다시 로그인하세요.', 401);
      }
      user = identity;
      _token = _oauthTokens!.access;
      await _saveOAuth(generation);
      return true;
    } on GitHubFailure catch (e) {
      if (generation == _authGeneration) {
        if (e.status == 401) {
          await logout();
        } else {
          signOut(); // Keep the vault on a temporary network failure.
        }
      }
      rethrow;
    }
  }

  Future<void> logout() async {
    signOut();
    await _vault(() => oauth.vault.delete());
  }

  Future<Person> signIn({String token = ''}) async {
    signOut();
    _token = token.trim();
    _allowGitCredential = _token.isEmpty;
    try {
      final data = await api.call('GET', '/user');
      if (data['id'] is! int || data['id'] <= 0) {
        throw const GitHubFailure('GitHub 계정 ID를 확인하지 못했습니다.');
      }
      user = Person.fromJson({
        'id': 'gh-${data['id']}',
        'login': data['login'],
        'name': data['login'],
        'role': 'pending',
        'parts': <String>[],
      });
      return user!;
    } catch (_) {
      signOut();
      rethrow;
    }
  }

  void signOut() {
    _authGeneration++;
    _oauthTokens = null;
    _remember = false;
    _oauthUserId = null;
    _refreshing = null;
    _token = '';
    _allowGitCredential = false;
    user = null;
  }

  Person named(
    String nickname, {
    String role = 'pending',
    List<String> parts = const [],
  }) {
    if (user == null) throw StateError('GitHub에 먼저 로그인하세요.');
    return Person.fromJson({
      ...user!.json,
      'name': nickname.trim(),
      'role': role,
      'parts': parts,
    });
  }

  Future<void> access(GitHubConfig config) async {
    config.validate();
    if (user == null) throw StateError('GitHub에 먼저 로그인하세요.');
    final repo = await api.call('GET', '/repos/${config.slug}');
    if (repo['permissions']?['push'] != true) {
      throw const GitHubFailure(
        '저장소 초대와 쓰기 권한이 필요합니다. 개설자에게 GitHub 협업자 초대를 요청하세요.',
      );
    }
    await api.call('GET', '/repos/${config.slug}/git/ref/heads/${config.base}');
  }

  Future<Map<String, dynamic>?> readJson(
    GitHubConfig config,
    String path, {
    String? ref,
  }) async {
    try {
      final file = await api.call(
        'GET',
        '/repos/${config.slug}/contents/$path',
        query: {'ref': ref ?? config.base},
      );
      if (file['encoding'] != 'base64') {
        throw const GitHubFailure('프로젝트 파일 인코딩을 확인하세요.');
      }
      final content = utf8.decode(
        base64Decode((file['content'] as String).replaceAll(RegExp(r'\s'), '')),
      );
      return {
        'sha': file['sha'],
        'data': Map<String, dynamic>.from(jsonDecode(content)),
      };
    } on GitHubFailure catch (e) {
      if (e.status == 404) return null;
      rethrow;
    }
  }

  Future<void> writeJson(
    GitHubConfig config,
    String path,
    Map<String, dynamic> data, {
    String? sha,
    String? branch,
    required String message,
  }) async {
    await api.call(
      'PUT',
      '/repos/${config.slug}/contents/$path',
      body: {
        'message': message,
        'branch': branch ?? config.base,
        'sha': ?sha,
        'content': base64Encode(
          utf8.encode('${const JsonEncoder.withIndent('  ').convert(data)}\n'),
        ),
      },
    );
  }

  Future<ProjectManifest> loadProject(GitHubConfig config) async {
    final file = await readJson(config, '.ieum/project.json');
    if (file == null) {
      throw const GitHubFailure('이음 프로젝트가 없는 저장소입니다. 개설자가 먼저 프로젝트를 생성하세요.');
    }
    return ProjectManifest.fromJson(file['data']);
  }

  Future<ProjectManifest> createProject(
    GitHubConfig config,
    String name,
    String nickname,
  ) async {
    await access(config);
    final repo = await api.call('GET', '/repos/${config.slug}');
    if (repo['permissions']?['admin'] != true) {
      throw const GitHubFailure('프로젝트 최초 생성은 저장소 관리자에게 허용됩니다.');
    }
    if (await readJson(config, '.ieum/project.json') != null) {
      throw const GitHubFailure('이미 프로젝트가 있습니다. 프로젝트 참여를 선택하세요.');
    }
    final owner = named(
      nickname,
      role: 'owner',
      parts: rules.map((r) => r.part).toList(),
    );
    final project = ProjectManifest.fromJson({
      'schemaVersion': 1,
      'projectId': 'project-${const Uuid().v4()}',
      'name': name.trim(),
      'ownerId': owner.id,
      'members': [owner.json],
    });
    await writeJson(
      config,
      '.ieum/project.json',
      project.json,
      message: 'Create IEUM project',
    );
    return project;
  }

  String branchFor(Person member) {
    var label = member.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    if (label.isEmpty) {
      label =
          'u${utf8.encode(member.name).map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
    }
    if (label.length > 40) {
      label = label.substring(0, 40).replaceAll(RegExp(r'-+$'), '');
    }
    return 'ieum/members/$label-${member.id}';
  }

  Future<void> ensureBranch(GitHubConfig config, String branch) async {
    final root = '/repos/${config.slug}';
    try {
      await api.call('GET', '$root/git/ref/heads/$branch');
    } on GitHubFailure catch (e) {
      if (e.status != 404) rethrow;
      final base = await api.call('GET', '$root/git/ref/heads/${config.base}');
      try {
        await api.call(
          'POST',
          '$root/git/refs',
          body: {'ref': 'refs/heads/$branch', 'sha': base['object']['sha']},
        );
      } on GitHubFailure catch (e) {
        if (e.status != 422) rethrow;
        await api.call('GET', '$root/git/ref/heads/$branch');
      }
    }
  }

  Future<String?> register(
    GitHubConfig config,
    ProjectManifest project,
    String nickname,
  ) async {
    await access(config);
    final self = named(nickname);
    final branch = branchFor(self);
    await ensureBranch(config, branch);
    if (project.people.any((p) => p.id == self.id && p.active)) return null;
    final path = '.ieum/requests/${self.id}.json';
    final existing = await readJson(config, path, ref: branch);
    await writeJson(
      config,
      path,
      {'schemaVersion': 1, 'projectId': project.id, 'member': self.json},
      sha: existing?['sha'],
      branch: branch,
      message: 'Request IEUM membership',
    );
    final root = '/repos/${config.slug}/pulls';
    final query = {
      'state': 'open',
      'head': '${config.slug.split('/').first}:$branch',
      'base': config.base,
    };
    final prs = await api.call('GET', root, query: query) as List;
    if (prs.isNotEmpty) return prs.first['html_url'] as String;
    try {
      final pr = await api.call(
        'POST',
        root,
        body: {
          'head': branch,
          'base': config.base,
          'title': '이음 가입 요청 · ${self.name}',
          'body':
              'GitHub @${self.login}의 가입 요청입니다. 이음 참여자 관리에서 역할과 파트를 지정해 승인하세요.',
        },
      );
      return pr['html_url'] as String;
    } on GitHubFailure catch (e) {
      if (e.status != 422) rethrow;
      final retried = await api.call('GET', root, query: query) as List;
      if (retried.isEmpty) rethrow;
      return retried.first['html_url'] as String;
    }
  }

  Future<List<Map<String, dynamic>>> requests(GitHubConfig config) async {
    final prs = await api.call(
      'GET',
      '/repos/${config.slug}/pulls',
      query: {'state': 'open', 'base': config.base, 'per_page': '100'},
    ) as List;
    final result = <Map<String, dynamic>>[];
    for (final pr in prs) {
      if (!(pr['head']['ref'] as String).startsWith('ieum/members/') ||
          pr['head']['repo']?['full_name'] != config.slug) {
        continue;
      }
      final files = await api.call(
        'GET',
        '/repos/${config.slug}/pulls/${pr['number']}/files',
        query: {'per_page': '100'},
      ) as List;
      if (files.length != 1 ||
          !(files.single['filename'] as String).startsWith('.ieum/requests/')) {
        continue;
      }
      final file = await readJson(
        config,
        files.single['filename'],
        ref: pr['head']['sha'],
      );
      if (file == null) continue;
      final data = file['data'] as Map;
      final member = Person.fromJson(Map<String, dynamic>.from(data['member']));
      // Names cannot impersonate an account. Only the PR author's numeric ID registers.
      if (member.id != 'gh-${pr['user']['id']}' ||
          member.login != pr['user']['login'] ||
          member.role != 'pending' ||
          files.single['filename'] != '.ieum/requests/${member.id}.json') {
        continue;
      }
      result.add({
        'member': member.json,
        'projectId': data['projectId'],
        'number': pr['number'],
        'sha': pr['head']['sha'],
      });
    }
    return result;
  }

  Future<ProjectManifest> assign(
    GitHubConfig config,
    Person member, {
    Map<String, dynamic>? request,
  }) async {
    if (user == null) throw StateError('로그인이 필요합니다.');
    final file = await readJson(config, '.ieum/project.json');
    if (file == null) throw const GitHubFailure('프로젝트를 찾지 못했습니다.');
    final current = ProjectManifest.fromJson(file['data']);
    if (current.ownerId != user!.id ||
        member.id == current.ownerId ||
        !['manager', 'worker', 'viewer', 'disabled'].contains(member.role)) {
      throw const GitHubFailure('역할 변경은 개설자만 할 수 있으며 개설자 역할은 변경할 수 없습니다.');
    }
    if (request != null) {
      if (request['projectId'] != current.id) {
        throw const GitHubFailure('다른 프로젝트의 가입 요청입니다.');
      }
      final latest = await requests(config);
      if (!latest.any(
        (r) =>
            r['number'] == request['number'] &&
            r['sha'] == request['sha'] &&
            jsonEncode(r['member']) == jsonEncode(request['member']),
      )) {
        throw const GitHubFailure('가입 요청이 변경되었습니다. 목록을 새로고침하세요.');
      }
      if (request['member']['id'] != member.id ||
          request['member']['name'] != member.name ||
          request['member']['login'] != member.login) {
        throw const GitHubFailure('가입 요청자 정보가 다릅니다.');
      }
    } else if (!current.people.any(
      (p) => p.id == member.id && p.login == member.login,
    )) {
      throw const GitHubFailure('승인된 참여자를 선택하세요.');
    }
    final next = ProjectManifest.fromJson({
      ...current.json,
      'members': [
        ...current.people.where((p) => p.id != member.id).map((p) => p.json),
        member.json,
      ],
    });
    await writeJson(
      config,
      '.ieum/project.json',
      next.json,
      sha: file['sha'],
      message: 'Update IEUM member role',
    );
    // The request PR is a registration envelope, not task data. Close it after approval.
    if (request != null) {
      await api.call(
        'PATCH',
        '/repos/${config.slug}/pulls/${request['number']}',
        body: {'state': 'closed'},
      );
    }
    return next;
  }

  Future<void> invite(GitHubConfig config, String login) async {
    if (user == null ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,38}$').hasMatch(login)) {
      throw StateError('초대할 GitHub 계정 이름을 입력하세요.');
    }
    final project = await loadProject(config);
    if (project.ownerId != user!.id) {
      throw const GitHubFailure('저장소 초대는 프로젝트 개설자에게 허용됩니다.');
    }
    await api.call(
      'PUT',
      '/repos/${config.slug}/collaborators/$login',
      body: {'permission': 'push'},
    );
  }
}
