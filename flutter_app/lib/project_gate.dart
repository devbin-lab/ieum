import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'github_sync.dart';
import 'github_oauth.dart';
import 'project_service.dart';
import 'project_catalog.dart';
import 'project_picker.dart';
import 'store.dart';
import 'update_ui.dart';

class ProjectGate extends StatefulWidget {
  const ProjectGate({
    super.key,
    required this.preferences,
    this.session,
    this.openBrowser,
  });
  final File preferences;
  final GitHubSession? session;
  final Future<void> Function(String)? openBrowser;
  @override
  State<ProjectGate> createState() => _ProjectGateState();
}

class _ProjectGateState extends State<ProjectGate> {
  late final GitHubSession session = widget.session ?? GitHubSession();
  final token = TextEditingController();
  final repo = TextEditingController();
  final nickname = TextEditingController();
  final projectName = TextEditingController();
  final folder = TextEditingController();
  bool busy = false, creating = true, booting = true, showingSetup = false;
  late final ProjectCatalog catalog;
  bool rememberLogin = true, advancedLogin = false;
  DeviceGrant? grant;
  String error = '';
  SavedProject? get recent =>
      session.user == null ? null : catalog.lastFor(session.user!.id);
  TaskStore? store;
  GitHubSync? sync;

  @override
  void initState() {
    super.initState();
    catalog = ProjectCatalog(widget.preferences);
    session.connectionNotice.addListener(connectionChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) restoreLogin();
    });
  }

  void connectionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    session.connectionNotice.removeListener(connectionChanged);
    final previousSync = sync;
    final previousStore = store;
    unawaited(() async {
      await previousSync?.quiesce();
      previousSync?.dispose();
      previousStore?.dispose();
      session.signOut();
    }());
    for (final field in [token, repo, nickname, projectName, folder]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is GitHubFailure
              ? e.message
              : '$e'.replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> signIn() => run(() async {
    await session.logout();
    final user = await session.signIn(token: token.text);
    token.clear();
    nickname.text = user.name;
    if (mounted) {
      setState(() {});
      UpdateScope.of(context)?.notifier?.credentialsChanged();
    }
    await restoreProject();
  });

  void authenticated() {
    nickname.text = session.user!.name;
    if (mounted) {
      setState(() {});
      UpdateScope.of(context)?.notifier?.credentialsChanged();
    }
  }

  Future<void> restoreLogin() async {
    await run(() async {
      if (session.user != null || await session.restoreOAuth()) {
        if (!mounted) return;
        authenticated();
        await restoreProject();
      }
    });
    if (mounted) setState(() => booting = false);
  }

  Future<void> restoreProject() async {
    final identity = session.user;
    if (identity == null) return;
    final legacy = catalog.legacy;
    if (legacy != null &&
        legacy['path'] is String &&
        File(legacy['path']).existsSync()) {
      TaskStore? previous;
      try {
        previous = TaskStore(legacy['path']);
        if (previous.isProject && previous.profileId == identity.id) {
          catalog.remember(
            identity.id,
            SavedProject(
              path: previous.filename,
              name: previous.project!.name,
              projectId: previous.project!.id,
              config: GitHubConfig(
                repository: legacy['repository'],
                base: legacy['base'] ?? 'main',
                branch: legacy['branch'] ?? '',
                enabled: true,
              ),
            ),
            migrateLegacy: true,
          );
        }
      } finally {
        previous?.dispose();
      }
    }
    if (recent != null) {
      repo.text = recent!.config.slug;
      await openSaved(recent!);
    }
  }

  Future<void> openGitHub(String url) async {
    if (widget.openBrowser != null) {
      await widget.openBrowser!(url);
      return;
    }
    try {
      await Process.start('rundll32.exe', ['url.dll,FileProtocolHandler', url]);
    } catch (_) {
      if (mounted) setState(() => error = '브라우저에서 $url 을 직접 열어주세요.');
    }
  }

  Future<void> oauthLogin() => run(() async {
    try {
      await session.signInOAuth(
        remember: rememberLogin,
        onCode: (value) {
          if (!mounted) {
            session.signOut();
            return;
          }
          setState(() => grant = value);
          openGitHub(githubDeviceUrl);
        },
      );
      if (mounted) {
        authenticated();
        await restoreProject();
      }
    } finally {
      if (mounted) setState(() => grant = null);
    }
  });

  Future<void> openStore(
    TaskStore next,
    GitHubConfig config, {
    bool cached = false,
  }) async {
    final previousSync = sync;
    final previousStore = store;
    await previousSync?.quiesce();
    final service = GitHubSync(next, publisher: GitHubPublisher(session.api));
    try {
      if (!cached) {
        try {
          await service.connect(config);
        } catch (error) {
          if (!GitHubSession.transient(error)) rethrow;
          cached = true;
          session.connectionNotice.value =
              '오프라인 · 저장된 프로젝트를 열었습니다. 연결되면 자동으로 동기화합니다.';
        }
      }
      if (cached) {
        next.setMeta('github.config', jsonEncode(config.toJson()));
        next.setMeta('github.login', session.user!.login);
      }
      if (!mounted) throw StateError('프로젝트 열기가 취소되었습니다.');
      catalog.remember(
        session.user!.id,
        SavedProject(
          path: next.filename,
          name: next.project!.name,
          projectId: next.project!.id,
          config: config,
        ),
      );
      setState(() {
        store = next;
        sync = service;
        showingSetup = false;
      });
      previousSync?.dispose();
      previousStore?.dispose();
      if (cached && config.enabled) service.start();
    } catch (_) {
      await service.quiesce();
      service.dispose();
      next.dispose();
      if (mounted && !showingSetup) previousSync?.resume();
      rethrow;
    }
  }

  Future<void> submit() => run(() async {
    final identity = session.named(nickname.text);
    var config = GitHubConfig(repository: repo.text.trim(), enabled: true);
    config.validate();
    if (folder.text.trim().isEmpty ||
        !Directory(folder.text.trim()).isAbsolute) {
      throw StateError('DB를 저장할 로컬 폴더의 전체 경로를 지정하세요.');
    }
    final directory = Directory(folder.text.trim());
    await directory.create(recursive: true);
    if (creating &&
        (projectName.text.trim().isEmpty ||
            projectName.text.trim().length > 80)) {
      throw StateError('프로젝트 이름은 1~80자로 입력하세요.');
    }
    config = await session.resolveRepository(config);
    final project = creating
        ? await session.createProject(config, projectName.text, nickname.text)
        : await session.loadProject(config);
    final branch = session.branchFor(identity);
    final pr = await session.register(config, project, nickname.text);
    final path =
        '${directory.path}${Platform.pathSeparator}ieum-${project.id}-${identity.id}.sqlite';
    final next = TaskStore(path, project: project, identity: identity);
    next.setMeta('membership.pr', pr ?? '');
    await openStore(
      next,
      GitHubConfig.fromJson({...config.toJson(), 'branch': branch}),
    );
  });

  Future<void> reopen() => run(() async {
    if (recent != null) await openSaved(recent!);
  });

  Future<void> openSaved(SavedProject entry) async {
    if (store?.filename == entry.path) {
      sync?.resume();
      if (mounted) setState(() => showingSetup = false);
      return;
    }
    if (!File(entry.path).existsSync()) {
      throw StateError('DB 파일이 없습니다. 프로젝트 참여에서 기존 DB 저장 폴더를 선택하세요.');
    }
    final previousSync = sync;
    await previousSync?.quiesce();
    TaskStore? next;
    try {
      next = TaskStore(entry.path);
      if (!next.isProject ||
          next.profileId != session.user!.id ||
          next.project!.id != entry.projectId) {
        throw StateError('이 계정과 프로젝트에 등록된 DB가 아닙니다. 내 계정으로 참여하세요.');
      }
      final raw = next.meta('github.config');
      final config = raw.isEmpty
          ? entry.config
          : GitHubConfig.fromJson(jsonDecode(raw));
      var cached = session.offline;
      if (!cached) {
        try {
          final project = await session.loadProject(config);
          if (project.id != next.project!.id ||
              project.founderId != next.project!.founderId) {
            throw const GitHubFailure('이 DB와 연결된 프로젝트 저장소가 아닙니다.');
          }
          next.updateProject(project);
        } catch (error) {
          if (error is GitHubFailure && error.status == 401) {
            await session.logout();
            rethrow;
          }
          if (!GitHubSession.transient(error)) rethrow;
          cached = true;
          session.connectionNotice.value =
              '오프라인 · 저장된 프로젝트를 열었습니다. 연결되면 자동으로 동기화합니다.';
        }
      }
      final opened = next;
      next = null; // openStore owns cleanup from here, including failure.
      await openStore(opened, config, cached: cached);
    } catch (_) {
      next?.dispose();
      if (mounted && !showingSetup) previousSync?.resume();
      rethrow;
    }
  }

  void showSetup(bool create) => run(() async {
    await sync?.quiesce();
    if (mounted) {
      setState(() {
        creating = create;
        showingSetup = true;
        projectName.clear();
        repo.clear();
        folder.clear();
      });
    }
  });

  void signOut() => run(() async {
    await sync?.quiesce();
    sync?.dispose();
    sync = null;
    store?.dispose();
    store = null;
    showingSetup = false;
    token.clear();
    await session.logout();
  });

  @override
  Widget build(BuildContext context) {
    if (booting) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.all_inclusive, size: 44, color: purple),
              SizedBox(height: 24),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(height: 18),
              Text('내 작업 공간을 준비하고 있어요', style: TextStyle(color: muted)),
            ],
          ),
        ),
      );
    }
    if (store != null && session.user != null && !showingSetup) {
      return AbsorbPointer(
        absorbing: busy,
        child: Workspace(
          key: ObjectKey(store),
          store: store!,
          sync: sync,
          session: session,
          onSignOut: signOut,
          sessionNotice: [
            session.connectionNotice.value,
            catalog.warning,
            error,
          ].where((s) => s.isNotEmpty).join(' · '),
          projectSwitcher: ProjectPicker(
            projects: catalog.forAccount(session.user!.id),
            activePath: store!.filename,
            busy: busy,
            onSelected: (entry) => run(() => openSaved(entry)),
            onCreate: () => showSetup(true),
            onJoin: () => showSetup(false),
          ),
        ),
      );
    }
    final signedIn = session.user != null;
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(36),
          child: SizedBox(
            width: 680,
            child: Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: border),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.all_inclusive, size: 44, color: purple),
                  const SizedBox(height: 16),
                  Text(
                    signedIn ? '프로젝트 시작하기' : '이음에 로그인',
                    style: const TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    signedIn
                        ? '@${session.user!.login} · GitHub 인증 완료'
                        : 'GitHub 계정으로 인증한 뒤 프로젝트를 만들거나 참여하세요.',
                    style: const TextStyle(color: muted, fontSize: 12),
                  ),
                  const SizedBox(height: 24),
                  if (!signedIn) ...[
                    const Text(
                      'GitHub에서 이음의 저장소 접근을 승인하면 로그인됩니다.\n작업 등록·PR·동기화를 위해 저장소 권한을 요청합니다.',
                      style: TextStyle(fontSize: 12, color: muted, height: 1.7),
                    ),
                    const SizedBox(height: 12),
                    Material(
                      color: Colors.transparent,
                      child: CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text(
                          '이 컴퓨터에서 로그인 유지',
                          style: TextStyle(fontSize: 12),
                        ),
                        subtitle: const Text(
                          'Windows 자격 증명 관리자에 안전하게 보관합니다.',
                          style: TextStyle(fontSize: 11, color: muted),
                        ),
                        value: rememberLogin,
                        onChanged: busy
                            ? null
                            : (value) => setState(
                                () => rememberLogin = value ?? false,
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (grant != null) ...[
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: purple.withValues(alpha: .06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'GitHub 인증 코드',
                              style: TextStyle(fontSize: 12, color: muted),
                            ),
                            const SizedBox(height: 8),
                            SelectableText(
                              grant!.userCode,
                              key: const Key('oauth-code'),
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 3,
                                color: purple,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '브라우저에 위 코드를 입력하고 이음의 접근을 승인하세요.\n인증 코드가 만료되면 다시 로그인할 수 있습니다.',
                              style: TextStyle(
                                fontSize: 12,
                                color: muted,
                                height: 1.7,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              children: [
                                OutlinedButton(
                                  onPressed: () async {
                                    await Clipboard.setData(
                                      ClipboardData(text: grant!.userCode),
                                    );
                                  },
                                  child: const Text('코드 복사'),
                                ),
                                OutlinedButton(
                                  onPressed: () => openGitHub(githubDeviceUrl),
                                  child: const Text('GitHub 인증 페이지 열기'),
                                ),
                                TextButton(
                                  key: const Key('oauth-cancel'),
                                  onPressed: session.signOut,
                                  child: const Text('로그인 취소'),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    FilledButton.icon(
                      key: const Key('github-login'),
                      icon: const Icon(Icons.login, size: 18),
                      onPressed: busy ? null : oauthLogin,
                      label: Text(
                        busy
                            ? (grant == null ? '로그인 확인 중…' : 'GitHub 승인 대기 중…')
                            : 'GitHub로 로그인',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => openGitHub('https://github.com/signup'),
                          child: const Text('GitHub 계정 만들기'),
                        ),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(
                                  () => advancedLogin = !advancedLogin,
                                ),
                          child: Text(advancedLogin ? '고급 연결 닫기' : '고급 연결'),
                        ),
                      ],
                    ),
                    if (advancedLogin) ...[
                      const SizedBox(height: 12),
                      TextField(
                        key: const Key('login-token'),
                        enabled: !busy,
                        controller: token,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: '세션 토큰 (선택)',
                          hintText: '비워 두면 컴퓨터에 저장된 Git 인증 사용',
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        '토큰은 앱 메모리에만 보관합니다. 이음 비밀번호는 만들지 않습니다.\nGitHub 계정이 없다면 GitHub에서 계정을 만든 뒤 저장소 초대를 받으세요.',
                        style: TextStyle(
                          fontSize: 11,
                          color: muted,
                          height: 1.7,
                        ),
                      ),
                      const SizedBox(height: 24),
                      FilledButton(
                        key: const Key('github-advanced-login'),
                        onPressed: busy ? null : signIn,
                        child: Text(busy ? '계정 확인 중…' : 'GitHub 연결 / 로그인'),
                      ),
                    ],
                  ] else ...[
                    if (recent != null) ...[
                      OutlinedButton(
                        key: const Key('reopen-project'),
                        onPressed: busy ? null : reopen,
                        child: Text(
                          store != null ? '현재 프로젝트로 돌아가기' : '최근 프로젝트 열기',
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],
                    SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(value: true, label: Text('프로젝트 생성')),
                        ButtonSegment(value: false, label: Text('프로젝트 참여')),
                      ],
                      selected: {creating},
                      onSelectionChanged: busy
                          ? null
                          : (value) => setState(() => creating = value.single),
                    ),
                    const SizedBox(height: 24),
                    if (creating) ...[
                      TextField(
                        key: const Key('project-name'),
                        enabled: !busy,
                        controller: projectName,
                        decoration: const InputDecoration(labelText: '프로젝트 이름'),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      key: const Key('project-repository'),
                      enabled: !busy,
                      controller: repo,
                      decoration: const InputDecoration(
                        labelText: 'GitHub 저장소',
                        hintText: '소유자/저장소 또는 HTTPS 주소',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      key: const Key('project-nickname'),
                      enabled: !busy,
                      controller: nickname,
                      maxLength: 40,
                      decoration: const InputDecoration(
                        labelText: '이름 / 닉네임',
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            key: const Key('project-folder'),
                            enabled: !busy,
                            controller: folder,
                            decoration: const InputDecoration(
                              labelText: '개인 DB 저장 폴더',
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton(
                          onPressed: busy
                              ? null
                              : () async {
                                  final value = await getDirectoryPath(
                                    confirmButtonText: 'DB 저장 위치 선택',
                                  );
                                  if (value != null && mounted) {
                                    setState(() => folder.text = value);
                                  }
                                },
                          child: const Text('폴더 선택'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      creating ? '새 프로젝트와 빈 DB를 만듭니다. 개설자는 관리자 권한을 갖습니다.' : '닉네임과 GitHub 계정 ID로 개인 브랜치를 만듭니다. 가입 요청 후 개설자가 역할을 부여하면 작업할 수 있습니다.',
                      style: const TextStyle(
                        fontSize: 11,
                        color: muted,
                        height: 1.7,
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        FilledButton(
                          key: const Key('project-submit'),
                          onPressed: busy ? null : submit,
                          child: Text(
                            busy
                                ? '프로젝트 준비 중…'
                                : creating
                                ? '프로젝트 생성'
                                : '참여 요청',
                          ),
                        ),
                        const SizedBox(width: 12),
                        TextButton(
                          onPressed: busy ? null : signOut,
                          child: const Text('로그아웃'),
                        ),
                      ],
                    ),
                  ],
                  if (error.isNotEmpty || catalog.warning.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Text(
                        [
                          error,
                          catalog.warning,
                        ].where((s) => s.isNotEmpty).join('\n'),
                        style: const TextStyle(
                          color: Color(0xffbd6b7a),
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
