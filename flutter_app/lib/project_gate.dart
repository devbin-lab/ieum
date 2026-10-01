import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'app.dart';
import 'github_sync.dart';
import 'project_service.dart';
import 'store.dart';
import 'update_ui.dart';

class ProjectGate extends StatefulWidget {
  const ProjectGate({super.key, required this.preferences, this.session});
  final File preferences;
  final GitHubSession? session;
  @override
  State<ProjectGate> createState() => _ProjectGateState();
}

class _ProjectGateState extends State<ProjectGate> {
  late final GitHubSession session = widget.session ?? GitHubSession();
  final token = TextEditingController();
  final repo = TextEditingController(text: 'devbin-lab/ieum-test-fresh');
  final nickname = TextEditingController();
  final projectName = TextEditingController();
  final folder = TextEditingController();
  bool busy = false, creating = true;
  String error = '';
  Map<String, dynamic>? recent;
  TaskStore? store;
  GitHubSync? sync;

  @override
  void initState() {
    super.initState();
    try {
      if (widget.preferences.existsSync()) {
        recent = Map<String, dynamic>.from(
          jsonDecode(widget.preferences.readAsStringSync()),
        );
      }
    } catch (_) {
      recent = null;
    }
    if (recent != null) {
      repo.text = recent!['repository'] as String? ?? repo.text;
    }
  }

  @override
  void dispose() {
    sync?.dispose();
    store?.dispose();
    session.signOut();
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
    final user = await session.signIn(token: token.text);
    token.clear();
    nickname.text = user.name;
    if (mounted) {
      setState(() {});
      UpdateScope.of(context)?.notifier?.check();
    }
  });

  Future<void> openStore(TaskStore next, GitHubConfig config) async {
    final service = GitHubSync(next, publisher: GitHubPublisher(session.api));
    try {
      await service.connect(config);
      if (!mounted) {
        service.dispose();
        next.dispose();
        return;
      }
      final value = {
        'path': next.filename,
        'repository': config.slug,
        'base': config.base,
        'branch': config.branch,
      };
      widget.preferences.parent.createSync(recursive: true);
      widget.preferences.writeAsStringSync(jsonEncode(value));
      setState(() {
        store = next;
        sync = service;
        recent = value;
      });
    } catch (_) {
      service.dispose();
      next.dispose();
      rethrow;
    }
  }

  Future<void> submit() => run(() async {
    final identity = session.named(nickname.text);
    final config = GitHubConfig(repository: repo.text.trim(), enabled: true);
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
      GitHubConfig(repository: config.slug, branch: branch, enabled: true),
    );
  });

  Future<void> reopen() => run(() async {
    if (recent == null) return;
    final path = recent!['path'] as String;
    if (!File(path).existsSync()) {
      throw StateError('DB 파일이 없습니다. 프로젝트 참여에서 저장 폴더를 다시 선택하세요.');
    }
    final next = TaskStore(path);
    if (!next.isProject || next.profileId != session.user!.id) {
      next.dispose();
      throw StateError('다른 GitHub 사용자의 DB입니다. 내 계정으로 참여하세요.');
    }
    final config = GitHubConfig(
      repository: recent!['repository'],
      base: recent!['base'] ?? 'main',
      branch: recent!['branch'] ?? '',
      enabled: true,
    );
    try {
      final project = await session.loadProject(config);
      next.updateProject(project);
    } catch (_) {
      next.dispose();
      rethrow;
    }
    await openStore(next, config);
  });

  void signOut() {
    sync?.dispose();
    sync = null;
    store?.dispose();
    store = null;
    session.signOut();
    token.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (store != null) {
      return Workspace(
        store: store!,
        sync: sync,
        session: session,
        onSignOut: signOut,
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
                      style: TextStyle(fontSize: 11, color: muted, height: 1.7),
                    ),
                    const SizedBox(height: 24),
                    TextButton(
                      onPressed: busy
                          ? null
                          : () async {
                              try {
                                await Process.start('rundll32.exe', [
                                  'url.dll,FileProtocolHandler',
                                  'https://github.com/signup',
                                ]);
                              } catch (_) {
                                if (mounted) {
                                  setState(
                                    () => error = '브라우저에서 https://github.com/signup 을 열어 계정을 생성하세요.',
                                  );
                                }
                              }
                            },
                      child: const Text('GitHub 계정 만들기'),
                    ),
                    FilledButton(
                      key: const Key('github-login'),
                      onPressed: busy ? null : signIn,
                      child: Text(busy ? '계정 확인 중…' : 'GitHub 연결 / 로그인'),
                    ),
                  ] else ...[
                    if (recent != null) ...[
                      OutlinedButton(
                        key: const Key('reopen-project'),
                        onPressed: busy ? null : reopen,
                        child: const Text('최근 프로젝트 열기'),
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
                  if (error.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Text(
                        error,
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
