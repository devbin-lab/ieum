import 'workspace_ui.dart';
import 'app_localizations.dart';

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
import 'profile_service.dart';
import 'project_picker.dart';
import 'store.dart';
import 'settings_shell.dart';
import 'desktop_platform.dart';
import 'update_ui.dart';
import 'startup_surface.dart';

import 'package:flutter_svg/flutter_svg.dart';

class ProjectGate extends StatefulWidget {
  const ProjectGate({
    super.key,
    required this.preferences,
    this.session,
    this.openBrowser,
    this.onOpenInitialSettings,
  });
  final File preferences;
  final GitHubSession? session;
  final Future<void> Function(String)? openBrowser;
  final VoidCallback? onOpenInitialSettings;
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
  bool rememberLogin = true, advancedLogin = false, advancedStorage = false;
  DeviceGrant? grant;
  String error = '';
  SavedProject? get recent =>
      session.user == null ? null : catalog.lastFor(session.user!.id);
  TaskStore? store;
  GitHubSync? sync;
  String? initialTaskId;

  @override
  void initState() {
    super.initState();
    catalog = ProjectCatalog(widget.preferences);
    folder.text =
        '${widget.preferences.absolute.parent.path}${Platform.pathSeparator}projects';
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
    nickname.text = catalog.nameFor(user.id) ?? user.name;
    if (mounted) {
      setState(() {});
      UpdateScope.of(context)?.notifier?.credentialsChanged();
    }
    await restoreProject();
  });

  void authenticated() {
    nickname.text = catalog.nameFor(session.user!.id) ?? session.user!.name;
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
      folder.text = File(recent!.path).parent.path;
      await openSaved(recent!);
    }
  }

  Future<void> openGitHub(String url) async {
    if (widget.openBrowser != null) {
      await widget.openBrowser!(url);
      return;
    }
    try {
      await openDesktopUrl(url);
    } catch (_) {
      if (mounted) {
        setState(
          () => error = tr('브라우저에서 {v0} 을 직접 열어주세요.', args: {'v0': url}),
        );
      }
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

  Future<String> renameAll(String name) async {
    nickname.text = name;
    return renameParticipatingProjects(
      catalog,
      session,
      name,
      onProject: (entry, project) {
        if (store?.project?.id == project.id &&
            sync?.config.slug == entry.config.slug) {
          store!.updateProject(project);
        }
      },
    );
  }

  Future<void> openStore(
    TaskStore next,
    GitHubConfig config, {
    bool cached = false,
    String? focusTaskId,
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
          session.connectionNotice.value = tr(
            '오프라인 · 저장된 프로젝트를 열었습니다. 연결되면 자동으로 동기화합니다.',
          );
        }
      }
      if (cached) {
        next.setMeta('github.config', jsonEncode(config.toJson()));
        next.setMeta('github.login', session.user!.login);
      }
      if (!mounted) throw StateError(tr('프로젝트 열기가 취소되었습니다.'));
      if (!cached &&
          catalog
              .pendingNames(session.user!.id)
              .contains('${config.slug}|${next.project!.id}')) {
        try {
          final renamed = await session.rename(
            config,
            catalog.nameFor(session.user!.id)!,
            expectedProjectId: next.project!.id,
          );
          next.updateProject(renamed);
          catalog.setName(
            session.user!.id,
            catalog.nameFor(session.user!.id)!,
            catalog
                .pendingNames(session.user!.id)
                .where((id) => id != '${config.slug}|${renamed.id}')
                .toList(),
          );
        } catch (e) {
          error = tr('이름 변경 전송 대기: {v0}', args: {'v0': e});
        }
      }
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
        initialTaskId = focusTaskId;
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
      throw StateError(tr('DB를 저장할 로컬 폴더의 전체 경로를 지정하세요.'));
    }
    final directory = Directory(folder.text.trim());
    await directory.create(recursive: true);
    if (creating &&
        (projectName.text.trim().isEmpty ||
            projectName.text.trim().length > 80)) {
      throw StateError(tr('프로젝트 이름은 1~80자로 입력하세요.'));
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

  Future<void> openSaved(
    SavedProject entry, {
    bool settingsView = false,
    String? focusTaskId,
  }) async {
    if (store?.filename == entry.path) {
      sync?.resume();
      if (mounted) {
        setState(() {
          initialTaskId = focusTaskId;
          showingSetup = false;
        });
      }
      return;
    }
    if (!File(entry.path).existsSync()) {
      throw StateError(tr('DB 파일이 없습니다. 프로젝트 참여에서 기존 DB 저장 폴더를 선택하세요.'));
    }
    final previousSync = sync;
    await previousSync?.quiesce();
    TaskStore? next;
    try {
      next = TaskStore(entry.path);
      if (!next.isProject ||
          next.profileId != session.user!.id ||
          next.project!.id != entry.projectId) {
        throw StateError(tr('이 계정과 프로젝트에 등록된 DB가 아닙니다. 내 계정으로 참여하세요.'));
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
            throw GitHubFailure(tr('이 DB와 연결된 프로젝트 저장소가 아닙니다.'));
          }
          next.updateProject(project);
        } catch (error) {
          if (error is GitHubFailure && error.status == 401) {
            await session.logout();
            rethrow;
          }
          if (!GitHubSession.transient(error)) rethrow;
          cached = true;
          session.connectionNotice.value = tr(
            '오프라인 · 저장된 프로젝트를 열었습니다. 연결되면 자동으로 동기화합니다.',
          );
        }
      }
      final opened = next;
      if (settingsView) {
        final view = <String, dynamic>{};
        try {
          view.addAll(
            jsonDecode(opened.meta('ui.workspace')) as Map<String, dynamic>,
          );
        } catch (_) {
          /* A new project has no saved view yet. */
        }
        view['page'] = 2;
        view['settings'] = SettingsSection.projectGeneral.name;
        opened.setMeta('ui.workspace', jsonEncode(view));
      }
      next = null; // openStore owns cleanup from here, including failure.
      await openStore(opened, config, cached: cached, focusTaskId: focusTaskId);
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
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const IeumBrand(size: 52),
              SizedBox(height: 24),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(height: 18),
              Text(
                tr('내 작업 공간을 준비하고 있어요'),
                style: TextStyle(color: WorkspaceUi.colors(context).muted),
              ),
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
          onRename: renameAll,
          initialTaskId: initialTaskId,
          onOpenProjectTask: (entry, taskId) =>
              run(() => openSaved(entry, focusTaskId: taskId)),
          onSignOut: signOut,
          sessionNotice: [
            session.connectionNotice.value,
            catalog.warning,
            error,
          ].where((s) => s.isNotEmpty).join(' · '),
          projectSwitcherBuilder: (onSettings) => ProjectPicker(
            projects: catalog.forAccount(session.user!.id),
            activePath: store!.filename,
            busy: busy,
            onSelected: (entry) =>
                run(() => openSaved(entry, settingsView: true)),
            onCreate: () => showSetup(true),
            onJoin: () => showSetup(false),
          ),
          notificationProjects: catalog.forAccount(session.user!.id),
        ),
      );
    }
    final signedIn = session.user != null;
    return StartupSurface(
      title: isEnglish
          ? 'Your team’s next step\nstarts here.'
          : '팀의 다음 단계,\n여기서 시작하세요.',
      description: isEnglish
          ? 'Open your project and bring your work together.\nEvery task, schedule, and handoff in one place.'
          : '프로젝트를 열고 팀의 일을 이어가세요.\n작업과 일정, 전달 기록이 한곳에 모입니다.',
      footer: widget.onOpenInitialSettings == null
          ? null
          : Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                key: const Key('open-initial-settings'),
                onPressed: busy ? null : widget.onOpenInitialSettings,
                icon: const Icon(Icons.tune, size: 16),
                label: Text(isEnglish ? 'Initial preferences' : '초기 설정'),
              ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            signedIn ? tr('프로젝트 시작하기') : tr('이음에 로그인'),
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              height: 1.3,
              letterSpacing: -.5,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            signedIn
                ? tr('@{v0} · GitHub 인증 완료', args: {'v0': session.user!.login})
                : (isEnglish
                      ? 'Continue with GitHub to get started.'
                      : 'GitHub 계정으로 로그인하고 프로젝트를 시작하세요.'),
            style: TextStyle(
              color: WorkspaceUi.colors(context).muted,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 24),
          if (!signedIn) ...[
            Text(
              tr(
                'GitHub에서 이음의 저장소 접근을 승인하면 로그인됩니다.\n작업 등록·PR·동기화를 위해 저장소 권한을 요청합니다.',
              ),
              style: TextStyle(
                fontSize: 12,
                color: WorkspaceUi.colors(context).muted,
                height: 1.7,
              ),
            ),
            const SizedBox(height: 12),
            Material(
              color: Colors.transparent,
              child: CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  tr('이 컴퓨터에서 로그인 유지'),
                  style: TextStyle(fontSize: 12),
                ),
                subtitle: Text(
                  credentialStorageDescription(),
                  style: TextStyle(
                    fontSize: 11,
                    color: WorkspaceUi.colors(context).muted,
                  ),
                ),
                value: rememberLogin,
                onChanged: busy
                    ? null
                    : (value) => setState(() => rememberLogin = value ?? false),
              ),
            ),
            const SizedBox(height: 12),
            if (grant != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: WorkspaceUi.colors(context).accent
                      .withValues(alpha: .06),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: WorkspaceUi.colors(context).line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('GitHub 인증 코드'),
                      style: TextStyle(
                        fontSize: 12,
                        color: WorkspaceUi.colors(context).muted,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      grant!.userCode,
                      key: const Key('oauth-code'),
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 3,
                        color: WorkspaceUi.colors(context).accent,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      tr(
                        '브라우저에 위 코드를 입력하고 이음의 접근을 승인하세요.\n인증 코드가 만료되면 다시 로그인할 수 있습니다.',
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        color: WorkspaceUi.colors(context).muted,
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
                          child: Text(tr('코드 복사')),
                        ),
                        OutlinedButton(
                          onPressed: () => openGitHub(githubDeviceUrl),
                          child: Text(tr('GitHub 인증 페이지 열기')),
                        ),
                        TextButton(
                          key: const Key('oauth-cancel'),
                          onPressed: session.signOut,
                          child: Text(tr('로그인 취소')),
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
              icon: SvgPicture.asset(
                'assets/shortcut-services/github.svg',
                width: 18,
                height: 18,
                colorFilter: ColorFilter.mode(
                  WorkspaceUi.colors(context).onAccent,
                  BlendMode.srcIn,
                ),
              ),
              onPressed: busy ? null : oauthLogin,
              label: Text(
                busy
                    ? (grant == null ? tr('로그인 확인 중…') : tr('GitHub 승인 대기 중…'))
                    : tr('GitHub로 로그인'),
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
                  child: Text(tr('GitHub 계정 만들기')),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() => advancedLogin = !advancedLogin),
                  child: Text(advancedLogin ? tr('고급 연결 닫기') : tr('고급 연결')),
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
                decoration: InputDecoration(
                  labelText: tr('세션 토큰 (선택)'),
                  hintText: tr('비워 두면 컴퓨터에 저장된 Git 인증 사용'),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                tr(
                  '토큰은 앱 메모리에만 보관합니다. 이음 비밀번호는 만들지 않습니다.\nGitHub 계정이 없다면 GitHub에서 계정을 만든 뒤 저장소 초대를 받으세요.',
                ),
                style: TextStyle(
                  fontSize: 11,
                  color: WorkspaceUi.colors(context).muted,
                  height: 1.7,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('github-advanced-login'),
                onPressed: busy ? null : signIn,
                child: Text(busy ? tr('계정 확인 중…') : tr('GitHub 연결 / 로그인')),
              ),
            ],
          ] else ...[
            if (recent != null) ...[
              OutlinedButton(
                key: const Key('reopen-project'),
                onPressed: busy ? null : reopen,
                child: Text(
                  store != null ? tr('현재 프로젝트로 돌아가기') : tr('최근 프로젝트 열기'),
                ),
              ),
              const SizedBox(height: 20),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: Text(tr('프로젝트 생성')),
                  selected: creating,
                  onSelected: busy
                      ? null
                      : (_) => setState(() => creating = true),
                ),
                ChoiceChip(
                  label: Text(tr('프로젝트 참여')),
                  selected: !creating,
                  onSelected: busy
                      ? null
                      : (_) => setState(() => creating = false),
                ),
              ],
            ),
            const SizedBox(height: 24),
            if (creating) ...[
              TextField(
                key: const Key('project-name'),
                enabled: !busy,
                controller: projectName,
                decoration: InputDecoration(labelText: tr('프로젝트 이름')),
              ),
              const SizedBox(height: 16),
            ],
            TextField(
              key: const Key('project-repository'),
              enabled: !busy,
              controller: repo,
              decoration: InputDecoration(
                labelText: tr('GitHub 저장소'),
                hintText: tr('소유자/저장소 또는 HTTPS 주소'),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('project-nickname'),
              enabled: !busy,
              controller: nickname,
              maxLength: 40,
              decoration: InputDecoration(
                labelText: tr('이름 / 닉네임'),
                counterText: '',
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: WorkspaceUi.colors(context).subtle,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('이 컴퓨터에 안전하게 저장'),
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    tr(
                      '작업은 자동 저장되고 GitHub와 동기화됩니다.\n인터넷이 끊겨도 저장된 프로젝트에서 작업할 수 있습니다.',
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      color: WorkspaceUi.colors(context).muted,
                      height: 1.6,
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('project-storage-options'),
                    onPressed: busy
                        ? null
                        : () => setState(
                            () => advancedStorage = !advancedStorage,
                          ),
                    icon: Icon(
                      advancedStorage ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                    ),
                    label: Text(
                      advancedStorage ? tr('저장 위치 닫기') : tr('저장 위치 변경'),
                    ),
                  ),
                  if (advancedStorage) ...[
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('project-folder'),
                      enabled: !busy,
                      controller: folder,
                      decoration: InputDecoration(labelText: tr('로컬 저장 폴더')),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () async {
                              final value = await getDirectoryPath(
                                confirmButtonText: tr('저장 위치 선택'),
                              );
                              if (value != null && mounted) {
                                setState(() => folder.text = value);
                              }
                            },
                      icon: const Icon(Icons.folder_open_outlined, size: 16),
                      label: Text(tr('폴더 선택')),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              creating
                  ? tr('프로젝트를 만들고 팀의 작업을 시작합니다. 파트는 프로젝트 설정에서 추가할 수 있습니다.')
                  : tr(
                      '먼저 GitHub 저장소 초대를 수락해 주세요. 참여 요청을 관리자가 승인하면 작업을 시작할 수 있습니다.',
                    ),
              style: TextStyle(
                fontSize: 11,
                color: WorkspaceUi.colors(context).muted,
                height: 1.7,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton(
                  key: const Key('project-submit'),
                  onPressed: busy ? null : submit,
                  child: Text(
                    busy
                        ? tr('프로젝트 준비 중…')
                        : creating
                        ? tr('프로젝트 생성')
                        : tr('참여 요청'),
                  ),
                ),
                TextButton(
                  onPressed: busy ? null : signOut,
                  child: Text(tr('로그아웃')),
                ),
              ],
            ),
          ],
          if (error.isNotEmpty || catalog.warning.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(
                [error, catalog.warning].where((s) => s.isNotEmpty).join('\n'),
                style: const TextStyle(color: Color(0xffbd6b7a), fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
