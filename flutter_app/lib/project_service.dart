import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'github_sync.dart';
import 'models.dart';
import 'member_policy.dart';
import 'github_oauth.dart';

const _uncheckedWorkflowSheet = Object();

/// Authentication belongs to GitHub. IEUM stores a nickname, never a password.
class GitHubSession {
  GitHubSession({GitHubApi? api, GitHubOAuth? oauth})
    : oauth = oauth ?? GitHubOAuth() {
    _rawApi = api ?? HttpGitHubApi(credential);
    this.api = _SessionApi(this);
  }
  late final GitHubApi api;
  late final GitHubApi _rawApi;
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
  final connectionNotice = ValueNotifier<String>('');
  bool get offline => connectionNotice.value.isNotEmpty;
  final List<String> requestWarnings = [];
  Future<void>? _revalidating;
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
        if (user != null) 'identity': user!.json,
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
        final verifier = _rawApi is HttpGitHubApi
            ? HttpGitHubApi(() async => next.access)
            : _rawApi;
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
    Person? cached;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      if (data['schema'] != 1 || data['clientId'] != githubOAuthClientId) {
        throw const FormatException();
      }
      expected = data['userId'] as String;
      if (data['identity'] is Map) {
        cached = Person.fromJson(Map<String, dynamic>.from(data['identity']));
        if (cached.id != expected) throw const FormatException();
      }
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
      connectionNotice.value = '';
      _token = _oauthTokens!.access;
      await _saveOAuth(generation);
      return true;
    } on GitHubFailure catch (e) {
      if (generation == _authGeneration) {
        if (e.status == 401) {
          await logout();
        } else if (cached != null && transient(e)) {
          user = cached;
          _token = _oauthTokens!.access;
          connectionNotice.value =
              '오프라인 · 이 컴퓨터에 저장된 프로젝트를 열었습니다. 연결되면 계정을 다시 확인하고 동기화합니다.';
          return true;
        } else {
          signOut(); // Keep the vault on a temporary network failure.
        }
      }
      rethrow;
    }
  }

  static bool transient(Object error) =>
      error is GitHubFailure &&
      (error.status == 0 ||
          error.status == 403 && error.retryAfter != null ||
          error.status == 408 ||
          error.status == 429 ||
          error.status >= 500);

  Future<void> _revalidate() async {
    if (!offline) return;
    if (_revalidating != null) return _revalidating!;
    final generation = _authGeneration;
    final expected = user?.id;
    final operation = () async {
      try {
        final data = await _rawApi.call('GET', '/user');
        if (generation != _authGeneration) {
          throw const GitHubFailure('로그인이 변경되었습니다.', 401);
        }
        if ('gh-${data['id']}' != expected) {
          throw const GitHubFailure('GitHub 계정이 변경되었습니다. 다시 로그인하세요.', 401);
        }
        connectionNotice.value = '';
        await _saveOAuth(generation);
      } on GitHubFailure catch (e) {
        if (e.status == 401 && generation == _authGeneration) await logout();
        rethrow;
      } finally {
        _revalidating = null;
      }
    }();
    _revalidating = operation;
    return operation;
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
    if (_rawApi is HttpGitHubApi) _rawApi.close();
    _authGeneration++;
    _oauthTokens = null;
    _remember = false;
    _oauthUserId = null;
    _refreshing = null;
    _token = '';
    _allowGitCredential = false;
    user = null;
    connectionNotice.value = '';
    _revalidating = null;
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

  Future<Map<String, dynamic>> repository(GitHubConfig config) async {
    config.validate();
    if (user == null) throw StateError('GitHub에 먼저 로그인하세요.');
    final repo = await api.call('GET', '/repos/${config.slug}');
    if (repo['permissions']?['push'] != true) {
      throw const GitHubFailure(
        '저장소 초대와 쓰기 권한이 필요합니다. 관리자에게 GitHub 협업자 초대를 요청하세요.',
      );
    }
    return Map<String, dynamic>.from(repo);
  }

  Future<GitHubConfig> resolveRepository(GitHubConfig config) async {
    final repo = await repository(config);
    final resolved = GitHubConfig.fromJson({
      ...config.toJson(),
      'repository': repo['full_name'] ?? config.slug,
      'base': repo['default_branch'] ?? config.base,
    });
    resolved.validate();
    return resolved;
  }

  Future<void> access(GitHubConfig config) async {
    await repository(config);
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
    bool initialize = false,
    required String message,
  }) async {
    await api.call(
      'PUT',
      '/repos/${config.slug}/contents/$path',
      body: {
        'message': message,
        if (!initialize) 'branch': branch ?? config.base,
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
      throw const GitHubFailure('이음 프로젝트가 없는 저장소입니다. 관리자가 먼저 프로젝트를 생성하세요.');
    }
    return ProjectManifest.fromJson(file['data']).partWorkflowView;
  }

  /// Re-read and re-authorize each SHA retry; never overwrite a concurrent edit.
  Future<ProjectManifest> changeManifest(
    GitHubConfig config,
    String message,
    Future<ProjectManifest> Function(ProjectManifest, Person) change, {
    String? expectedProjectId,
    Object? expectedWorkflowSheet = _uncheckedWorkflowSheet,
  }) async {
    if (user == null) throw const GitHubFailure('로그인이 필요합니다.');
    final accountId = user!.id;
    final authGeneration = _authGeneration;
    for (var attempt = 0; attempt < 3; attempt++) {
      final file = await readJson(config, '.ieum/project.json');
      if (file == null) throw const GitHubFailure('프로젝트를 찾지 못했습니다.');
      final original = ProjectManifest.fromJson(file['data']);
      if (!identical(expectedWorkflowSheet, _uncheckedWorkflowSheet)) {
        final expected = expectedWorkflowSheet as WorkflowSheet?;
        final actual = expected == null
            ? original.workflowSheet
            : original.partWorkflowView.workflowSheet;
        if (jsonEncode(actual?.json) != jsonEncode(expected?.json)) {
          throw const GitHubFailure('자동화 흐름이 다른 곳에서 변경되었습니다. 최신 내용을 확인하세요.');
        }
      }
      final current = original.partWorkflowView;
      if (expectedProjectId != null && current.id != expectedProjectId) {
        throw const GitHubFailure('저장소의 프로젝트가 변경되었습니다. 다시 연결하세요.');
      }
      final actor = current.people.where((p) => p.id == accountId).firstOrNull;
      if (user?.id != accountId || actor == null || !actor.active) {
        throw const GitHubFailure('승인된 참여자만 변경할 수 있습니다.');
      }
      final next = (await change(current, actor)).partWorkflowView;
      if (user?.id != accountId || _authGeneration != authGeneration) {
        throw const GitHubFailure('처리 중 로그인 계정이 변경되었습니다. 다시 확인하세요.');
      }
      if (jsonEncode(original.json) == jsonEncode(next.json)) return current;
      try {
        await writeJson(
          config,
          '.ieum/project.json',
          next.json,
          sha: file['sha'],
          message: message,
        );
        return next;
      } on GitHubFailure catch (error) {
        if (error.status != 409 || attempt == 2) rethrow;
      }
    }
    throw const GitHubFailure('다른 변경이 진행 중입니다. 다시 저장하세요.');
  }

  Future<ProjectManifest> saveShortcuts(
    GitHubConfig config,
    List<ProjectShortcut> shortcuts, {
    required String expectedProjectId,
    required List<ProjectShortcut>? expectedShortcuts,
  }) {
    final validated = readProjectShortcuts(
      shortcuts.map((entry) => entry.json).toList(),
    )!;
    return changeManifest(config, 'Update IEUM project shortcuts', (
      current,
      actor,
    ) async {
      if (jsonEncode(current.shortcuts?.map((entry) => entry.json).toList()) !=
          jsonEncode(expectedShortcuts?.map((entry) => entry.json).toList())) {
        throw const GitHubFailure(
          '바로가기가 다른 곳에서 변경되었습니다. 최신 내용을 확인한 뒤 다시 저장해 주세요.',
        );
      }
      return ProjectManifest.fromJson({
        ...current.json,
        'shortcuts': validated.map((entry) => entry.json).toList(),
      });
    }, expectedProjectId: expectedProjectId);
  }

  Future<ProjectManifest> setAttachmentLimit(
    GitHubConfig config,
    int limitMb, {
    required String expectedProjectId,
    required int expectedLimitMb,
  }) => changeManifest(config, 'Update IEUM attachment size limit', (
    current,
    actor,
  ) async {
    if (actor.id != current.ownerId || !actor.active) {
      throw const GitHubFailure('첨부 파일 한도는 관리자만 변경할 수 있습니다.');
    }
    if (current.attachmentLimitMb != expectedLimitMb) {
      throw const GitHubFailure('파일 한도가 변경되었습니다. 최신 설정을 확인하세요.');
    }
    return ProjectManifest.fromJson({
      ...current.json,
      'attachmentLimitMb': limitMb,
    });
  }, expectedProjectId: expectedProjectId);

  Future<ProjectManifest> rename(
    GitHubConfig config,
    String nickname, {
    String? expectedProjectId,
  }) {
    final value = nickname.trim();
    if (value.isEmpty || value.length > 40) {
      throw StateError('이름은 1~40자로 입력하세요.');
    }
    return changeManifest(
      config,
      'Update IEUM display name',
      (current, actor) async => ProjectManifest.fromJson({
        ...current.json,
        'members': [
          for (final person in current.people)
            {...person.json, if (person.id == actor.id) 'name': value},
        ],
      }),
      expectedProjectId: expectedProjectId,
    );
  }

  Future<ProjectManifest> savePermissionPart(
    GitHubConfig config,
    ProjectRole part, {
    String? expectedProjectId,
    ProjectRole? expectedPart,
  }) => changeManifest(config, 'Update IEUM project part', (
    original,
    actor,
  ) async {
    final current = original.partWorkflowView;
    final validated = ProjectRole.fromJson({
      ...part.json,
      'permissions':
          part.permissions
              .where(managementPermissionLabels.containsKey)
              .toList()
            ..sort(),
    });
    final previous = current.roles.where((r) => r.id == part.id).firstOrNull;
    if (expectedPart != null &&
        (previous == null ||
            previous.id != expectedPart.id ||
            jsonEncode(previous.json) != jsonEncode(expectedPart.json))) {
      throw const GitHubFailure('파트가 원격에서 변경되었습니다. 최신 값을 확인한 뒤 다시 저장하세요.');
    }
    if (!actor.has('role.manage')) {
      throw const GitHubFailure('역할 관리 권한이 필요합니다.');
    }
    if (validated.permissions
        .difference(previous?.permissions ?? {})
        .any((permission) => !actor.has(permission))) {
      throw const GitHubFailure('보유하지 않은 관리 권한을 새로 부여할 수 없습니다.');
    }
    if (validated.name == roleLabels['owner'] &&
        previous?.name != validated.name) {
      throw const GitHubFailure('관리자와 구분되는 파트 이름을 입력하세요.');
    }
    final roles = [...current.roles.where((r) => r.id != part.id), validated];
    final next = ProjectManifest.fromJson({
      ...current.json,
      'roles': roles.map((r) => r.json).toList(),
      'parts': roles.map((r) => r.name).toList(),
      'members': [
        for (final p in current.people)
          {
            ...p.json,
            'parts': [
              for (final name in p.parts)
                if (name == previous?.name) validated.name else name,
            ],
          },
      ],
    });
    return next;
  }, expectedProjectId: expectedProjectId);

  Future<ProjectManifest> deletePermissionPart(
    GitHubConfig config,
    String partId, {
    String? expectedProjectId,
    ProjectRole? expectedPart,
  }) => changeManifest(config, 'Delete IEUM project part', (
    original,
    actor,
  ) async {
    final current = original.partWorkflowView;
    final part = current.roles.where((r) => r.id == partId).firstOrNull;
    if (part == null ||
        expectedPart != null &&
            jsonEncode(part.json) != jsonEncode(expectedPart.json)) {
      throw const GitHubFailure('파트가 변경되었거나 삭제되었습니다. 목록을 새로고침하세요.');
    }
    if (!actor.has('role.manage')) {
      throw const GitHubFailure('역할 관리 권한이 필요합니다.');
    }
    final publisher = GitHubPublisher(api);
    final partBlockers = await publisher.partBlockers(config, current, partId);
    if (partBlockers.isNotEmpty) {
      throw GitHubFailure(
        '이 파트가 처리 중인 작업을 먼저 회수하거나 전달하세요: ${partBlockers.take(5).join(', ')}',
      );
    }
    final roles = current.roles.where((r) => r.id != partId).toList();
    final next = ProjectManifest.fromJson({
      ...current.json,
      'roles': roles.map((r) => r.json).toList(),
      'parts': roles.map((r) => r.name).toList(),
      if (current.workflowSheet != null)
        'workflowSheet': {
          ...current.workflowSheet!.json,
          'routes': [
            for (final route in current.workflowSheet!.routes)
              if (route.source != 'part:$partId' &&
                  route.destination != 'part:$partId')
                route.json,
          ],
        },
      'members': [
        for (final p in current.people)
          {...p.json, 'parts': p.parts.where((n) => n != part.name).toList()},
      ],
    });
    return next;
  }, expectedProjectId: expectedProjectId);

  Future<ProjectManifest> saveRole(
    GitHubConfig config,
    ProjectRole role, {
    String? expectedProjectId,
    ProjectRole? expectedRole,
  }) => changeManifest(config, 'Update IEUM project role', (
    current,
    actor,
  ) async {
    final validated = ProjectRole.fromJson(role.json);
    if (current.unifiedParts) {
      throw const GitHubFailure('통합된 파트는 권한 화면에서 수정하세요.');
    }
    if (expectedRole != null) {
      final latest = current.roles
          .where((r) => r.id == expectedRole.id)
          .firstOrNull;
      if (latest == null ||
          latest.name != expectedRole.name ||
          latest.permissions.length != expectedRole.permissions.length ||
          !latest.permissions.containsAll(expectedRole.permissions)) {
        throw const GitHubFailure('역할이 원격에서 변경되었습니다. 초안을 유지하고 최신 값을 다시 확인하세요.');
      }
    }
    if (!actor.has('role.manage') ||
        !actor.permissions.containsAll(validated.permissions)) {
      throw const GitHubFailure('역할 관리 권한이 필요하며 본인 권한을 초과해 부여할 수 없습니다.');
    }
    final previous = current.roles.where((r) => r.id == role.id).firstOrNull;
    if (validated.name == roleLabels['owner'] &&
        previous?.name != validated.name) {
      throw const GitHubFailure('시스템 권한과 구분되는 역할 이름을 입력하세요.');
    }
    if (previous != null &&
        !actor.permissions.containsAll(previous.permissions)) {
      throw const GitHubFailure('본인보다 권한이 높은 역할은 변경할 수 없습니다.');
    }
    if (previous != null &&
        !validated.permissions.containsAll(previous.permissions)) {
      for (final member in current.people.where((p) => p.role == role.id)) {
        final blockers = await GitHubPublisher(api)
            .memberBlockers(config, current, member.id);
        if (blockers.isNotEmpty) {
          throw GitHubFailure(
            '${member.name}의 작업과 PR을 먼저 인수인계하세요: ${blockers.take(5).join(', ')}',
          );
        }
      }
    }
    return ProjectManifest.fromJson({
      ...current.json,
      'roles': [
        ...current.roles.where((r) => r.id != role.id).map((r) => r.json),
        validated.json,
      ],
    });
  }, expectedProjectId: expectedProjectId);

  Future<ProjectManifest> saveParts(
    GitHubConfig config,
    List<String> parts, {
    String? expectedProjectId,
    List<String>? expectedParts,
  }) => changeManifest(config, 'Update IEUM project parts', (
    current,
    actor,
  ) async {
    if (current.unifiedParts) {
      throw const GitHubFailure('통합된 파트는 권한 화면에서 수정하세요.');
    }
    if (!actor.has('member.manage')) {
      throw const GitHubFailure('프로젝트 관리 권한이 필요합니다.');
    }
    if (expectedParts != null &&
        jsonEncode(expectedParts) != jsonEncode(current.parts)) {
      throw const GitHubFailure('파트가 원격에서 변경되었습니다. 새로고침 후 다시 변경하세요.');
    }
    if (!validProjectParts(parts)) {
      throw const GitHubFailure(
        '파트 이름은 중복 없이 1~40자로 입력하세요. 최대 50개까지 등록할 수 있습니다.',
      );
    }
    return ProjectManifest.fromJson({...current.json, 'parts': parts});
  }, expectedProjectId: expectedProjectId);

  Future<ProjectManifest> saveWorkflowStages(
    GitHubConfig config,
    List<WorkflowStage> stages, {
    String? expectedProjectId,
    List<WorkflowStage>? expectedStages,
    bool reorderOnly = false,
  }) => changeManifest(config, 'Update IEUM project workflow stages', (
    current,
    actor,
  ) async {
    _requireWorkflowManager(current, actor);
    _checkWorkflowStageSnapshot(
      current,
      expectedStages,
      reorderOnly: reorderOnly,
    );
    final validated = _validatedWorkflowStages(stages);
    if (reorderOnly &&
        (validated.length != current.workflowStages.length ||
            current.workflowStages.any(
              (stage) => !validated.any(
                (item) => jsonEncode(item.json) == jsonEncode(stage.json),
              ),
            ))) {
      throw const GitHubFailure('작업 단계 구성이 변경되었습니다. 최신 목록을 다시 확인하세요.');
    }
    await _guardRemovedWorkflowStages(config, current, validated);
    return ProjectManifest.fromJson({
      ...current.json,
      'workflowStages': validated.map((stage) => stage.json).toList(),
      if (current.workflowSheet != null)
        'workflowSheet': _sheetWithoutRemovedStages(
          current.workflowSheet!,
          validated.map((stage) => stage.id).toSet(),
        ).json,
    });
  }, expectedProjectId: expectedProjectId);

  void _requireWorkflowManager(ProjectManifest project, Person actor) {
    if (actor.id != project.ownerId || actor.role != 'owner') {
      throw const GitHubFailure('프로젝트 관리자만 워크플로를 변경할 수 있습니다.');
    }
  }

  void _checkWorkflowStageSnapshot(
    ProjectManifest current,
    List<WorkflowStage>? expected, {
    bool reorderOnly = false,
  }) {
    if (expected == null) return;
    if (current.workflowStages.length != expected.length ||
        current.workflowStages.asMap().entries.any((entry) {
          final before = reorderOnly
              ? expected.where((s) => s.id == entry.value.id).firstOrNull
              : expected[entry.key];
          return before == null ||
              jsonEncode(before.json) != jsonEncode(entry.value.json);
        })) {
      throw const GitHubFailure('작업 단계가 다른 곳에서 변경되었습니다. 최신 목록을 다시 확인하세요.');
    }
  }

  List<WorkflowStage> _validatedWorkflowStages(List<WorkflowStage> stages) {
    final validated = stages
        .map((s) => WorkflowStage.fromJson(s.json))
        .toList();
    if (validated.length > maxWorkflowStages ||
        validated.map((s) => s.id).toSet().length != validated.length ||
        validated.map((s) => s.name.toLowerCase()).toSet().length !=
            validated.length) {
      throw const GitHubFailure('작업 단계 ID와 이름은 중복될 수 없습니다.');
    }
    final initial = validated.where((s) => s.initial).toList();
    if (initial.length > 1 ||
        initial.any((s) => s.isCompleted || s.locksContent)) {
      throw const GitHubFailure('등록 단계는 완료되거나 잠긴 단계가 아닌 하나의 단계로 지정하세요.');
    }
    return validated;
  }

  Future<void> _guardRemovedWorkflowStages(
    GitHubConfig config,
    ProjectManifest current,
    List<WorkflowStage> stages,
  ) async {
    final remaining = stages.map((s) => s.id).toSet();
    final removed = current.workflowStages
        .where((s) => !remaining.contains(s.id))
        .map((s) => s.id)
        .toSet();
    final completionChanges = current.workflowStages
        .where(
          (before) => stages.any(
            (after) =>
                after.id == before.id &&
                after.isCompleted != before.isCompleted,
          ),
        )
        .map((s) => s.id)
        .toSet();
    final protected = {...removed, ...completionChanges};
    if (protected.isEmpty) return;
    final blockers = await GitHubPublisher(api)
        .workflowStageBlockers(config, current, protected);
    if (blockers.isNotEmpty) {
      throw GitHubFailure(
        '삭제하거나 완료 분류를 바꿀 단계의 작업을 먼저 이동하고 대기 변경을 처리하세요: ${blockers.take(5).join(', ')}',
      );
    }
  }

  WorkflowSheet _sheetWithoutRemovedStages(
    WorkflowSheet sheet,
    Set<String> stages,
  ) {
    final nodes = sheet.nodes.where((n) => stages.contains(n.stageId)).toList();
    final ids = nodes.map((n) => n.id).toSet();
    return WorkflowSheet.fromJson({
      ...sheet.json,
      'nodes': nodes.map((n) => n.json).toList(),
      'routes': sheet.routes
          .where((r) => ids.contains(r.from) && ids.contains(r.to))
          .map((r) => r.json)
          .toList(),
    });
  }

  Future<ProjectManifest> saveWorkflowSheet(
    GitHubConfig config,
    WorkflowSheet sheet, {
    String? expectedProjectId,
    Object? expectedSheet = _uncheckedWorkflowSheet,
  }) => changeManifest(
    config,
    'Update IEUM project workflow sheet',
    (current, actor) async {
      _requireWorkflowManager(current, actor);
      final validated = _validatedWorkflowSheet(current, sheet);
      return ProjectManifest.fromJson({
        ...current.json,
        'workflowSheet': validated.json,
      });
    },
    expectedProjectId: expectedProjectId,
    expectedWorkflowSheet: expectedSheet,
  );

  /// Publish statuses and transitions together against the same manifest SHA.
  Future<ProjectManifest> saveWorkflowDefinition(
    GitHubConfig config,
    List<WorkflowStage> stages,
    WorkflowSheet sheet, {
    required String expectedProjectId,
    required List<WorkflowStage> expectedStages,
    required WorkflowSheet? expectedSheet,
  }) => changeManifest(
    config,
    'Publish IEUM project workflow',
    (current, actor) async {
      _requireWorkflowManager(current, actor);
      _checkWorkflowStageSnapshot(current, expectedStages);
      final validatedStages = _validatedWorkflowStages(stages);
      final draft = ProjectManifest.fromJson({
        ...current.json,
        'workflowStages': validatedStages.map((s) => s.json).toList(),
        'workflowSheet': sheet.json,
      });
      final validatedSheet = _validatedWorkflowSheet(draft, sheet);
      await _guardRemovedWorkflowStages(config, current, validatedStages);
      return ProjectManifest.fromJson({
        ...draft.json,
        'workflowSheet': validatedSheet.json,
      });
    },
    expectedProjectId: expectedProjectId,
    expectedWorkflowSheet: expectedSheet,
  );

  WorkflowSheet _validatedWorkflowSheet(
    ProjectManifest project,
    WorkflowSheet sheet,
  ) {
    final validated = WorkflowSheet.fromJson(sheet.json);
    final stages = project.workflowStages.map((s) => s.id).toSet();
    final parts = project.roles.map((p) => 'part:${p.id}').toSet();
    bool groupExists(String group) =>
        group.isEmpty || group == 'role:owner' || parts.contains(group);
    if (validated.nodes.any((n) => !stages.contains(n.stageId))) {
      throw const GitHubFailure('삭제된 작업 단계는 워크플로에 사용할 수 없습니다.');
    }
    final unique = <String>{};
    for (final route in validated.routes) {
      final from = validated.stageFor(route.from);
      final to = validated.stageFor(route.to);
      if (from == null || to == null) {
        throw const GitHubFailure('전환의 출발 단계와 도착 단계를 확인하세요.');
      }
      if (!groupExists(route.source) || !groupExists(route.destination)) {
        throw const GitHubFailure('삭제된 파트를 사용한 전달 조건은 저장할 수 없습니다.');
      }
      final required = route.requiredFields.toList()..sort();
      if (!unique.add(
        jsonEncode([
          from,
          to,
          route.effectiveOperation,
          route.name,
          route.source,
          route.destination,
          route.person,
          route.assignment,
          route.requiresComment,
          required,
          route.trigger,
          route.purpose,
          route.requiredPurpose,
        ]),
      )) {
        throw const GitHubFailure('같은 작업 단계의 전환 조건이 중복되어 있습니다.');
      }
      if (const {'target', 'select'}.contains(route.assignment) &&
          route.person.isNotEmpty) {
        final target = project.people
            .where((p) => p.id == route.person && p.active)
            .firstOrNull;
        final part = project.roles
            .where((p) => 'part:${p.id}' == route.destination)
            .firstOrNull;
        if (target == null ||
            route.destination == 'role:owner' && target.id != project.ownerId ||
            part != null && !target.parts.contains(part.name)) {
          throw const GitHubFailure('받는 작업자는 활성 참여자이며 받는 파트에 소속되어야 합니다.');
        }
      }
    }
    return validated;
  }

  Future<ProjectManifest> applyDefaultWorkflow(
    GitHubConfig config, {
    required String expectedProjectId,
    required List<WorkflowStage> expectedStages,
    required WorkflowAutomation expectedAutomation,
  }) async => throw const GitHubFailure('자동화 시트 기능이 제거되어 프로젝트에 적용할 수 없습니다.');

  Future<ProjectManifest> saveWorkflowAutomation(
    GitHubConfig config,
    WorkflowAutomation automation, {
    required String expectedProjectId,
    required WorkflowAutomation expectedAutomation,
  }) async => throw const GitHubFailure('자동화 시트 기능이 제거되어 프로젝트에 적용할 수 없습니다.');
  Future<ProjectManifest> deleteRole(
    GitHubConfig config,
    String roleId, {
    String? replacementRoleId,
    String? expectedProjectId,
    ProjectRole? expectedRole,
    List<Person>? expectedMembers,
  }) => changeManifest(config, 'Delete IEUM project role', (
    current,
    actor,
  ) async {
    if (current.unifiedParts) {
      throw const GitHubFailure('통합된 파트는 권한 화면에서 삭제하세요.');
    }
    final role = current.roles.where((r) => r.id == roleId).firstOrNull;
    if (!actor.has('role.manage') ||
        role == null ||
        !actor.permissions.containsAll(role.permissions)) {
      throw const GitHubFailure('삭제할 역할과 역할 관리 권한을 확인하세요.');
    }
    final members = current.people.where((p) => p.role == roleId).toList();
    if (expectedRole != null &&
        (role.name != expectedRole.name ||
            role.permissions.length != expectedRole.permissions.length ||
            !role.permissions.containsAll(expectedRole.permissions))) {
      throw const GitHubFailure('역할이 변경되었습니다. 최신 값을 확인한 뒤 삭제하세요.');
    }
    if (expectedMembers != null &&
        (members.length != expectedMembers.length ||
            members.any(
              (p) => !expectedMembers.any(
                (before) => jsonEncode(before.json) == jsonEncode(p.json),
              ),
            ))) {
      throw const GitHubFailure('역할에 배정된 참여자가 변경되었습니다. 최신 영향을 다시 확인하세요.');
    }

    if (members.isNotEmpty) {
      final replacement = Person(
        '',
        '',
        '',
        replacementRoleId ?? '',
        0,
      ).resolved(current.roles);
      if (replacementRoleId == roleId ||
          !replacement.active ||
          replacement.role == 'owner' ||
          !actor.has('member.manage') ||
          !actor.permissions.containsAll(replacement.permissions) ||
          (replacement.role == 'manager' && actor.role != 'owner')) {
        throw const GitHubFailure('사용 중인 역할입니다. 참여자 관리 권한과 이동할 다른 역할을 확인하세요.');
      }
      if (!replacement.permissions.containsAll(role.permissions)) {
        for (final member in members.where((p) => p.active)) {
          final blockers = await GitHubPublisher(api)
              .memberBlockers(config, current, member.id);
          if (blockers.isNotEmpty) {
            throw GitHubFailure(
              '${member.name}의 작업과 PR을 먼저 인수인계하세요: ${blockers.take(5).join(', ')}',
            );
          }
        }
      }
    }
    // Role reassignment and deletion share one revision: no dangling member roles.
    return ProjectManifest.fromJson({
      ...current.json,
      'roles': [
        for (final r in current.roles.where((r) => r.id != roleId)) r.json,
      ],
      'members': [
        for (final person in current.people)
          if (person.role == roleId)
            Person(
              person.id,
              person.name,
              person.initials,
              replacementRoleId!,
              person.color,
              login: person.login,
              parts: person.parts,
              enabled: person.enabled,
            ).json
          else
            person.json,
      ],
    });
  }, expectedProjectId: expectedProjectId);

  Future<ProjectManifest> createProject(
    GitHubConfig config,
    String name,
    String nickname,
  ) async {
    final repo = await repository(config);
    if (repo['permissions']?['admin'] != true) {
      throw const GitHubFailure('프로젝트 최초 생성은 저장소 관리자에게 허용됩니다.');
    }
    var initialize = false;
    try {
      await api.call(
        'GET',
        '/repos/${config.slug}/git/ref/heads/${config.base}',
      );
    } on GitHubFailure catch (e) {
      if (e.status != 404 && e.status != 409) rethrow;
      final branches = await api.call(
        'GET',
        '/repos/${config.slug}/branches',
        query: {'per_page': '1'},
      ) as List;
      if (branches.isNotEmpty) {
        throw GitHubFailure(
          '통합 브랜치 ${config.base}가 없습니다. 저장소를 다시 연결해 기본 브랜치를 확인하세요.',
        );
      }
      if (repo['default_branch'] != null &&
          repo['default_branch'] != config.base) {
        throw const GitHubFailure('저장소를 다시 연결해 기본 브랜치를 확인하세요.');
      }
      initialize = true;
    }
    final existing = await readJson(config, '.ieum/project.json');
    if (existing != null) {
      final current = ProjectManifest.fromJson(existing['data'])
          .partWorkflowView;
      if (current.ownerId == user!.id && current.name == name.trim()) {
        return current;
      }
      throw const GitHubFailure('이미 프로젝트가 있습니다. 프로젝트 참여를 선택하세요.');
    }
    final owner = named(nickname, role: 'owner', parts: const []);
    final project = ProjectManifest.fromJson({
      'schemaVersion': 1,
      'projectId': 'project-${const Uuid().v4()}',
      'name': name.trim(),
      'ownerId': owner.id,
      'members': [owner.json],
    }).partWorkflowView;
    try {
      await writeJson(
        config,
        '.ieum/project.json',
        project.json,
        initialize: initialize,
        message: 'Create IEUM project',
      );
    } on GitHubFailure catch (e) {
      if (!transient(e) && e.status != 409 && e.status != 422) rethrow;
      final recovered = await readJson(config, '.ieum/project.json');
      if (recovered == null) rethrow;
      final current = ProjectManifest.fromJson(recovered['data'])
          .partWorkflowView;
      if (current.ownerId != user!.id || current.name != name.trim()) rethrow;
      return current;
    }
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
    requestWarnings.clear();
    final result = <Map<String, dynamic>>[];
    final seen = <int>{};
    for (var page = 1; ; page++) {
      final prs = await api.call(
        'GET',
        '/repos/${config.slug}/pulls',
        query: {
          'state': 'open',
          'base': config.base,
          'per_page': '100',
          'page': '$page',
        },
      ) as List;
      var fresh = false;
      for (final raw in prs) {
        final number = raw is Map ? raw['number'] : null;
        if (number is! int || !seen.add(number)) continue;
        fresh = true;
        try {
          final pr = Map<String, dynamic>.from(raw);
          if (!(pr['head']['ref'] as String).startsWith('ieum/members/') ||
              (pr['head']['repo']?['full_name'] as String?)?.toLowerCase() !=
                  config.slug) {
            continue;
          }
          final files = await api.call(
            'GET',
            '/repos/${config.slug}/pulls/$number/files',
            query: {'per_page': '100'},
          ) as List;
          if (files.length != 1 ||
              !(files.single['filename'] as String).startsWith(
                '.ieum/requests/',
              )) {
            throw const FormatException('가입 요청 외의 파일이 포함되어 있습니다.');
          }
          final file = await readJson(
            config,
            files.single['filename'],
            ref: pr['head']['sha'],
          );
          if (file == null) throw const FormatException('가입 요청 파일이 없습니다.');
          final data = file['data'] as Map;
          final member = Person.fromJson(
            Map<String, dynamic>.from(data['member']),
          );
          if (data['schemaVersion'] != 1 ||
              data['projectId'] is! String ||
              member.id != 'gh-${pr['user']['id']}' ||
              member.role != 'pending' ||
              files.single['filename'] != '.ieum/requests/${member.id}.json') {
            throw const FormatException('요청자 또는 가입 요청 형식이 올바르지 않습니다.');
          }
          result.add({
            'member': {...member.json, 'login': pr['user']['login']},
            'projectId': data['projectId'],
            'number': number,
            'sha': pr['head']['sha'],
          });
        } catch (error) {
          if (error is GitHubFailure && error.status == 401) rethrow;
          requestWarnings.add(
            '가입 요청 #$number 확인 실패: ${error is GitHubFailure ? error.message : '$error'.replaceFirst('Bad state: ', '').replaceFirst('FormatException: ', '')}',
          );
        }
      }
      if (prs.length < 100 || !fresh) break;
    }
    return result;
  }

  Future<ProjectManifest> assign(
    GitHubConfig config,
    Person member, {
    Map<String, dynamic>? request,
    String? expectedProjectId,
    Person? expectedMember,
    bool unifyParts = false,
  }) async {
    final next = await changeManifest(config, 'Update IEUM member role', (
      current,
      executor,
    ) async {
      var expected = expectedMember;
      if (unifyParts && !current.unifiedParts) {
        final old = current.people.where((p) => p.id == member.id).firstOrNull;
        if (expected != null &&
            (old == null ||
                jsonEncode(old.json) != jsonEncode(expected.json))) {
          throw const GitHubFailure('참여자 정보가 원격에서 변경되었습니다. 최신 값을 확인하세요.');
        }
        current = current.unifiedView;
        if (expected != null) {
          expected = current.people.firstWhere((p) => p.id == member.id);
        }
      }
      final target = current.people.where((p) => p.id == member.id);
      if (member.parts.any((part) => !current.parts.contains(part))) {
        throw const GitHubFailure('등록된 파트만 참여자에게 배정할 수 있습니다.');
      }
      final ownerTarget = member.id == current.ownerId;
      if (ownerTarget) {
        if (request != null ||
            target.isEmpty ||
            jsonEncode({...member.json, 'parts': target.single.parts}) !=
                jsonEncode(target.single.json)) {
          throw const GitHubFailure('소유자는 관리자 권한과 활성 상태를 유지하며 파트만 변경할 수 있습니다.');
        }
      } else if (member.role != 'unassigned') {
        throw const GitHubFailure('일반 참여자는 파트로 배정합니다. 관리자 변경은 권한 이전을 사용하세요.');
      }
      if (expected != null &&
          (target.isEmpty ||
              jsonEncode(target.single.json) != jsonEncode(expected.json))) {
        throw const GitHubFailure(
          '참여자 정보가 원격에서 변경되었습니다. 초안을 유지하고 최신 값을 다시 확인하세요.',
        );
      }
      if (target.isNotEmpty &&
          !canAssignMember(executor, target.single, current.ownerId)) {
        throw const GitHubFailure('이 참여자의 역할을 변경할 권한이 없습니다.');
      }
      if (!executor.has('member.manage')) {
        throw const GitHubFailure('참여자 관리 권한이 필요합니다.');
      }
      final nextMember = member.resolved(
        current.roles,
        unifiedParts: true,
        workflowParticipant: true,
      );
      if (executor.id != current.ownerId &&
          nextMember.permissions
              .where(managementPermissionLabels.containsKey)
              .toSet()
              .difference(target.firstOrNull?.permissions ?? {})
              .any((permission) => !executor.has(permission))) {
        throw const GitHubFailure('보유하지 않은 관리 권한의 파트를 새로 배정할 수 없습니다.');
      }
      final wasEnabled = target.isEmpty ? true : target.single.enabled;
      if (member.enabled != wasEnabled &&
          (target.isEmpty ||
              !canManageMemberStatus(
                executor,
                target.single,
                current.ownerId,
              ))) {
        throw const GitHubFailure(
          '활성화·비활성화는 참여자 상태 관리 권한이 있는 관리자만 변경할 수 있습니다.',
        );
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
      if (target.any(
        (p) =>
            p.active &&
            (!member.enabled || !member.parts.toSet().containsAll(p.parts)),
      )) {
        final blockers = await GitHubPublisher(api).memberBlockers(
          config,
          current,
          member.id,
          remainingParts: member.parts,
          removingMember: !member.enabled,
        );
        if (blockers.isNotEmpty) {
          throw GitHubFailure(
            '진행 중인 작업과 PR을 먼저 인수인계하세요: ${blockers.take(5).join(', ')}',
          );
        }
      }
      final next = ProjectManifest.fromJson({
        ...current.json,
        'members': [
          ...current.people.where((p) => p.id != member.id).map((p) => p.json),
          {...member.json, if (target.isNotEmpty) 'name': target.single.name},
        ],
      });
      return next;
    }, expectedProjectId: expectedProjectId);
    // The request PR is a registration envelope, not task data. Close it after approval.
    if (request != null) {
      try {
        await api.call(
          'PATCH',
          '/repos/${config.slug}/pulls/${request['number']}',
          body: {'state': 'closed'},
        );
      } catch (e) {
        requestWarnings.add(
          '가입 승인은 저장됐지만 요청 PR #${request['number']} 닫기에 실패했습니다: $e',
        );
      }
    }
    return next;
  }

  Future<ProjectManifest> setMemberEnabled(
    GitHubConfig config,
    String memberId,
    bool enabled, {
    String? expectedProjectId,
    Person? expectedMember,
  }) => changeManifest(
    config,
    enabled ? 'Activate IEUM member' : 'Deactivate IEUM member',
    (current, actor) async {
      final target = current.people.where((p) => p.id == memberId).firstOrNull;
      if (target == null ||
          !canManageMemberStatus(actor, target, current.ownerId)) {
        throw const GitHubFailure(
          '참여자 상태 관리 권한이 있는 관리자만 변경할 수 있습니다. 관리자의 상태는 변경할 수 없습니다.',
        );
      }
      if (expectedMember != null &&
          jsonEncode(target.json) != jsonEncode(expectedMember.json)) {
        throw const GitHubFailure('참여자 상태가 원격에서 변경되었습니다. 최신 값을 다시 확인하세요.');
      }
      if (target.enabled == enabled) return current;
      if (enabled && target.role == 'disabled') {
        throw const GitHubFailure('이전 역할 정보가 없습니다. 역할 변경에서 활성 역할을 직접 선택하세요.');
      }
      if (!enabled) {
        final blockers = await GitHubPublisher(api)
            .memberBlockers(config, current, memberId);
        if (blockers.isNotEmpty) {
          throw GitHubFailure(
            '남은 업무와 PR을 먼저 인수인계하세요: ${blockers.take(5).join(', ')}',
          );
        }
      }
      return ProjectManifest.fromJson({
        ...current.json,
        'members': [
          for (final person in current.people)
            if (person.id == memberId)
              {...person.json, 'role': person.role, 'enabled': enabled}
            else
              person.json,
        ],
      });
    },
    expectedProjectId: expectedProjectId,
  );

  Future<void> rejectRequest(
    GitHubConfig config,
    Map<String, dynamic> request, {
    required String expectedProjectId,
  }) async {
    final current = await loadProject(config);
    final actor = current.people.where((p) => p.id == user?.id).firstOrNull;
    if (current.id != expectedProjectId ||
        request['projectId'] != current.id ||
        actor?.has('member.manage') != true) {
      throw const GitHubFailure('이 프로젝트의 참여 요청 관리 권한이 필요합니다.');
    }
    final latest = await requests(config);
    if (!latest.any(
      (r) =>
          r['number'] == request['number'] &&
          r['sha'] == request['sha'] &&
          jsonEncode(r['member']) == jsonEncode(request['member']),
    )) {
      throw const GitHubFailure('요청이 변경되거나 이미 처리되었습니다. 새로고침하세요.');
    }
    if (current.people.any(
      (p) => p.id == request['member']['id'] && p.role != 'pending',
    )) {
      throw const GitHubFailure('이미 승인된 참여자는 가입 요청을 거절할 수 없습니다.');
    }
    await api.call(
      'PATCH',
      '/repos/${config.slug}/pulls/${request['number']}',
      body: {'state': 'closed'},
    );
  }

  Future<ProjectManifest> transferOwnership(
    GitHubConfig config,
    String targetId, {
    String? expectedProjectId,
    Person? expectedTarget,
  }) => changeManifest(config, 'Transfer IEUM project ownership', (
    current,
    actor,
  ) async {
    final target = current.people.where((p) => p.id == targetId).firstOrNull;
    if (actor.id != current.ownerId ||
        targetId == current.ownerId ||
        target == null ||
        !target.active ||
        !target.canWork) {
      throw const GitHubFailure('현재 관리자가 승인된 작업 가능 참여자에게 관리자 권한을 이전할 수 있습니다.');
    }
    if (expectedTarget != null &&
        jsonEncode(target.json) != jsonEncode(expectedTarget.json)) {
      throw const GitHubFailure('이전 대상이 원격에서 변경되었습니다. 최신 값을 다시 확인하세요.');
    }
    return ProjectManifest.fromJson({
      ...current.json,
      'ownerId': targetId,
      'members': [
        for (final person in current.people)
          {
            ...person.json,
            'role': person.id == targetId
                ? 'owner'
                : person.id == current.ownerId
                ? current.unifiedParts
                      ? 'unassigned'
                      : 'manager'
                : person.role,
          },
      ],
    });
  }, expectedProjectId: expectedProjectId);

  Future<void> invite(
    GitHubConfig config,
    String login, {
    String? expectedProjectId,
  }) async {
    if (user == null ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]{0,38}$').hasMatch(login)) {
      throw StateError('초대할 GitHub 계정 이름을 입력하세요.');
    }
    final project = await loadProject(config);
    if (expectedProjectId != null && project.id != expectedProjectId) {
      throw const GitHubFailure('프로젝트가 변경되었습니다. 다시 연결하세요.');
    }
    if (project.ownerId != user!.id) {
      throw const GitHubFailure('저장소 초대는 프로젝트 관리자에게 허용됩니다.');
    }
    await api.call(
      'PUT',
      '/repos/${config.slug}/collaborators/$login',
      body: {'permission': 'push'},
    );
  }
}

/// After an offline restore, verify the token's account before any repository access.
class _SessionApi implements GitHubApi {
  const _SessionApi(this.session);
  final GitHubSession session;
  @override
  Future<dynamic> call(
    String method,
    String path, {
    Map<String, String>? query,
    Map<String, dynamic>? body,
  }) async {
    if (path != '/user') await session._revalidate();
    return session._rawApi.call(method, path, query: query, body: body);
  }
}
