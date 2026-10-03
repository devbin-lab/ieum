import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import 'models.dart';
import 'store.dart';
import 'task_editor.dart';
import 'window_frame.dart';
import 'popup_ui.dart';
import 'github_sync.dart';
import 'github_panel.dart';
import 'project_service.dart';
import 'team_panel.dart';
import 'app_release.dart';
import 'account_menu.dart';
import 'settings_shell.dart';
import 'horizontal_viewport.dart';
import 'update_ui.dart';
import 'roles_panel.dart';

const purple = Color(0xff7963d5),
    ink = Color(0xff302b3c),
    muted = Color(0xff9990a5),
    border = Color(0xffe9e5ef),
    canvas = Color(0xfffaf9fc);
Color statusColor(String id) => {
  'todo': const Color(0xff9895a2),
  'doing': purple,
  'review': const Color(0xffbd9655),
  'rework': const Color(0xffc47c89),
  'done': const Color(0xff65987d),
}[id]!;
Color priorityColor(String id) => id == 'high'
    ? const Color(0xffbe8951)
    : id == 'low'
    ? const Color(0xff7b9b84)
    : muted;
Widget badge(String text, {Color color = muted}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .09),
    borderRadius: BorderRadius.circular(5),
  ),
  child: Text(text, style: TextStyle(color: color, fontSize: 10)),
);
Widget avatar(Person p, {double size = 28}) {
  return CircleAvatar(
    radius: size / 2,
    backgroundColor: Color(p.color).withValues(alpha: .10),
    child: Text(
      p.initials,
      style: TextStyle(
        color: Color(p.color),
        fontSize: 11,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

Widget heading(String title, String subtitle) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(
      title,
      style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 8),
    Text(subtitle, style: const TextStyle(fontSize: 11, color: muted)),
  ],
);
String shortId(String id) => id.startsWith('TASK-')
    ? 'IE-${id.substring(id.length - 6).toUpperCase()}'
    : id;
String shortDate(String date) => date.isEmpty
    ? '미정'
    : '${int.parse(date.substring(5, 7))}.${date.substring(8, 10)}';

class IeumApp extends StatelessWidget {
  final TaskStore store;
  final GitHubSync? sync;
  final Widget? home;
  final VoidCallback? onSignOut;
  final GitHubSession? session;
  const IeumApp({
    super.key,
    required this.store,
    this.sync,
    this.home,
    this.onSignOut,
    this.session,
  });
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '이음',
    debugShowCheckedModeBanner: false,
    builder: (context, child) => DesktopFrame(child: child!),
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Malgun Gothic',
      colorScheme: ColorScheme.fromSeed(
        seedColor: purple,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: canvas,
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 24,
        shadowColor: ink.withValues(alpha: .20),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: border),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: ink,
          borderRadius: BorderRadius.circular(6),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        textStyle: const TextStyle(fontSize: 11, color: Colors.white),
        waitDuration: const Duration(milliseconds: 450),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: purple,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 13, color: ink),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        isDense: true,
        contentPadding: const EdgeInsets.all(13),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: border),
        ),
        labelStyle: const TextStyle(fontSize: 12, color: muted),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: purple,
          padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 17),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: muted,
          side: const BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    ),
    home:
        home ??
        Workspace(
          store: store,
          sync: sync,
          onSignOut: onSignOut,
          session: session,
        ),
  );
}

class Workspace extends StatefulWidget {
  final TaskStore store;
  final GitHubSync? sync;
  final VoidCallback? onSignOut;
  final GitHubSession? session;
  final Widget? projectSwitcher;
  final String? sessionNotice;
  final Future<String> Function(String)? onRename;
  const Workspace({
    super.key,
    required this.store,
    this.sync,
    this.onSignOut,
    this.session,
    this.projectSwitcher,
    this.sessionNotice,
    this.onRename,
  });
  @override
  State<Workspace> createState() => _WorkspaceState();
}

enum TaskView { list, kanban }

class _WorkspaceState extends State<Workspace> {
  int page = 0;
  SettingsSection settingsSection = SettingsSection.general;
  TaskView taskView = TaskView.list;
  String search = '', part = '', scope = 'all';
  bool fileBusy = false;
  TaskStore get s => widget.store;
  @override
  void initState() {
    super.initState();
    try {
      final saved = jsonDecode(s.meta('ui.workspace')) as Map;
      final savedPage = saved['page'];
      if (savedPage is int && savedPage >= 0 && savedPage < 3) page = savedPage;
      settingsSection = page == 1
          ? SettingsSection.changes
          : SettingsSection.values
                    .where((v) => v.name == saved['settings'])
                    .firstOrNull ??
                SettingsSection.general;
      taskView = saved['view'] == 'kanban' ? TaskView.kanban : TaskView.list;
    } catch (_) {
      // New projects start with the task list.
    }
  }

  void rememberView(VoidCallback change) => setState(() {
    change();
    s.setMeta(
      'ui.workspace',
      jsonEncode({
        'page': page,
        'view': taskView.name,
        'settings': settingsSection.name,
      }),
    );
  });
  static const titles = ['일정 · 작업', '내 변경내역', '프로젝트 설정'];
  static const subtitles = [
    '작업과 일정을 목록 또는 칸반으로 확인하세요.',
    '개인 작업을 팀의 통합본으로 연결하세요.',
    '팀의 다음 단계를 준비하세요.',
  ];
  void message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(text),
          behavior: SnackBarBehavior.floating,
          width: 520,
          backgroundColor: ink,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
  }

  void action(VoidCallback work) {
    try {
      work();
    } catch (e) {
      message(e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  void edit([WorkTask? task]) => showDialog<void>(
    context: context,
    builder: (_) => TaskEditor(store: s, task: task),
  );
  Future<void> move(WorkTask task, String target) async {
    if (task.status == target) return;
    if (!s.canMove(task, target)) {
      message('담당 역할과 작업 흐름에 맞는 열로 옮겨 주세요.');
      return;
    }
    String reason = '';
    if (target == 'rework') {
      final value = await showDialog<String>(
        context: context,
        builder: (_) => const ReworkDialog(),
      );
      if (value == null || !mounted) return;
      reason = value;
    }
    action(() {
      s.transition(
        task.id,
        target,
        reason: reason,
        expectedVersion: task.version,
      );
      message('${statuses[target]} 상태로 옮겼습니다.');
    });
  }

  void details(WorkTask task) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '작업 상세 닫기',
      barrierColor: Colors.black.withValues(alpha: .18),
      pageBuilder: (ctx, a, b) => Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: 470,
          child: Material(
            color: Colors.white,
            child: SafeArea(
              child: AnimatedBuilder(
                animation: s,
                builder: (_, _) => detailBody(ctx, s.find(task.id)),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> export() async {
    setState(() => fileBusy = true);
    try {
      final target = await getSaveLocation(
        suggestedName: 'ieum-flutter-changes.json',
        acceptedTypeGroups: [
          const XTypeGroup(label: 'JSON 변경안', extensions: ['json']),
        ],
      );
      if (target == null) return;
      await File(target.path).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(s.exportChanges())}\n',
      );
      message('개인 변경안을 JSON 파일로 내보냈습니다.');
    } catch (e) {
      message('내보내기 실패: $e');
    } finally {
      if (mounted) setState(() => fileBusy = false);
    }
  }

  Future<void> import() async {
    setState(() => fileBusy = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(label: '통합본 JSON', extensions: ['json']),
        ],
      );
      if (file == null) return;
      if (await File(file.path).length() > 10 * 1024 * 1024) {
        throw StateError('통합본은 10MB 이하만 지원합니다.');
      }
      final result = s.importSnapshot(jsonDecode(await file.readAsString()));
      if (result.applied) {
        message('통합본을 반영했습니다. 개인 변경은 보존했습니다.');
      } else if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => IeumDialog(
            title: const Text('통합 전 확인이 필요해요'),
            width: 580,
            icon: Icons.merge_outlined,
            content: SizedBox(
              width: 530,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '데이터는 변경하지 않았습니다. 양쪽 변경을 확인해 주세요.',
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                    const SizedBox(height: 15),
                    ...result.conflicts.map(
                      (c) => Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(15),
                        color: const Color(0xfffaf0f3),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${c['title']} · ${c['field']}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 7),
                            SelectableText(
                              '내 변경: ${c['local']}\n통합본: ${c['remote']}',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('닫기'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      message('통합본 가져오기 실패: $e');
    } finally {
      if (mounted) setState(() => fileBusy = false);
    }
  }

  void notifications() {
    s.markNotificationsRead();
    showDialog<void>(
      context: context,
      builder: (ctx) => IeumDialog(
        title: Text(s.isProject ? '내 알림' : '알림 미리보기'),
        icon: Icons.notifications_none_rounded,
        content: SizedBox(
          width: 470,
          height: 440,
          child: AnimatedBuilder(
            animation: s,
            builder: (_, _) => ListView(
              children: [
                Text(
                  s.isProject
                      ? '나에게 도착한 작업과 검토 요청입니다.'
                      : 'Discord 연결 전의 로컬 이벤트입니다. 외부로 전송하지 않습니다.',
                  style: const TextStyle(fontSize: 12, color: muted),
                ),
                const SizedBox(height: 20),
                if (s.notifications.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Text('아직 도착한 알림이 없습니다.'),
                  ),
                ...s.notifications.map(
                  (n) => Container(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: const BoxDecoration(
                      border: Border(bottom: BorderSide(color: border)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        badge(s.isProject ? '받은 알림' : '미리보기'),
                        const SizedBox(height: 10),
                        Text(
                          n['title'],
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${n['eventType'] == 'task.created'
                              ? '새 작업 등록'
                              : n['eventType'] == 'task.assigned'
                              ? '작업 배정'
                              : statuses[n['status']]!} → ${s.member(n['recipientId']).name}',
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                        if ((n['reason'] as String? ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              n['reason'] as String,
                              style: const TextStyle(
                                fontSize: 11,
                                color: muted,
                              ),
                            ),
                          ),
                        if (s.isProject)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () {
                                Navigator.pop(ctx);
                                details(s.find(n['taskId'] as String));
                              },
                              child: const Text('작업 보기'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: s,
    builder: (_, _) {
      final all = s.tasks;
      final filtered = all
          .where(
            (t) =>
                (part.isEmpty || t.part == part) &&
                (search.isEmpty ||
                    ('${t.title} ${t.id} ${t.description}')
                        .toLowerCase()
                        .contains(search.toLowerCase())) &&
                (scope == 'all' ||
                    scope == 'mine' &&
                        t.currentId == s.profileId &&
                        t.status != 'done' ||
                    scope == 'review' &&
                        t.status == 'review' &&
                        t.reviewerId == s.profileId),
          )
          .toList();
      return Scaffold(
        body: Row(
          children: [
            sidebar(),
            Expanded(
              child: Column(
                children: [
                  if (widget.sessionNotice?.isNotEmpty == true)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 34,
                        vertical: 10,
                      ),
                      color: const Color(0xfffff6e8),
                      child: Text(
                        widget.sessionNotice!,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xff896b37),
                        ),
                      ),
                    ),
                  Expanded(
                    child: page == 0
                        ? LayoutBuilder(
                            builder: (ctx, constraints) => SingleChildScrollView(
                              child: Padding(
                                padding: EdgeInsets.fromLTRB(
                                  constraints.maxWidth < 700 ? 16 : 34,
                                  constraints.maxWidth < 700 ? 24 : 34,
                                  constraints.maxWidth < 700 ? 16 : 34,
                                  30,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Text(
                                                'TEAM WORKSPACE',
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  letterSpacing: 2,
                                                  color: muted,
                                                ),
                                              ),
                                              const SizedBox(height: 10),
                                              Text(
                                                page == 0 ? titles[0] : '설정',
                                                style: const TextStyle(
                                                  fontSize: 27,
                                                  fontWeight: FontWeight.w700,
                                                  letterSpacing: -1,
                                                ),
                                              ),
                                              const SizedBox(height: 9),
                                              Text(
                                                page == 0 ? subtitles[0] : '프로젝트 설정과 개인 변경내역을 관리하세요.',
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: muted,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        if (page == 0)
                                          FilledButton.icon(
                                            key: const Key('new-task'),
                                            onPressed: s.canCreate
                                                ? () => edit()
                                                : null,
                                            icon: const Icon(
                                              Icons.add,
                                              size: 18,
                                            ),
                                            label: const Text(
                                              '작업 등록',
                                              style: TextStyle(fontSize: 12),
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 30),
                                    if (s.isProject &&
                                        s.actor.role == 'pending')
                                      info(
                                        '가입 승인 대기 중입니다. 관리자가 역할을 부여하면 자동 동기화 후 작업을 진행할 수 있습니다.',
                                      ),
                                    if (s.isProject &&
                                        s.actor.role != 'pending' &&
                                        !s.actor.active)
                                      info(
                                        '비활성화된 참여자입니다. 작업 수정·진행·업로드가 차단됩니다. 관리자에게 활성화를 요청하세요.',
                                      ),
                                    if (page == 0) ...[
                                      stats(all),
                                      const SizedBox(height: 27),
                                      toolbar(),
                                      const SizedBox(height: 17),
                                      Row(
                                        children: [
                                          const Icon(
                                            Icons.circle_outlined,
                                            size: 12,
                                            color: muted,
                                          ),
                                          const SizedBox(width: 5),
                                          Expanded(
                                            child: Text(
                                              s.isProject
                                                  ? '할 일 → 진행 중 → 검토 → 완료'
                                                  : '예시 데이터로 흐름을 테스트해 보세요.',
                                              style: const TextStyle(
                                                fontSize: 10,
                                                color: muted,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            '${filtered.length}개 작업 · 자동 저장',
                                            style: const TextStyle(
                                              fontSize: 10,
                                              color: muted,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 15),
                                      if (taskView == TaskView.kanban)
                                        board(
                                          filtered,
                                          constraints.maxWidth -
                                              (constraints.maxWidth < 700
                                                  ? 32
                                                  : 68),
                                        )
                                      else
                                        schedule(filtered),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          )
                        : SettingsShell(
                            selected: settingsSection,
                            onSelected: selectSettings,
                            contentBuilder: settingsContent,
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
  void selectSettings(SettingsSection section) => rememberView(() {
    settingsSection = section;
    page = section == SettingsSection.changes ? 1 : 2;
  });

  Widget sidebar() => Container(
    key: const Key('workspace-sidebar'),
    width: 64,
    decoration: const BoxDecoration(
      color: Color(0xfff1f3f2),
      border: Border(right: BorderSide(color: Color(0xffe1e4e3))),
    ),
    padding: const EdgeInsets.fromLTRB(9, 12, 9, 12),
    child: Column(
      children: [
        widget.projectSwitcher ??
            Tooltip(
              message: s.project?.name ?? '졸업작품 팀',
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  Icons.folder_outlined,
                  size: 21,
                  color: Color(0xff505753),
                ),
              ),
            ),
        const SizedBox(height: 8),
        railButton(
          'nav-0',
          '일정 · 작업',
          Icons.calendar_month_outlined,
          () => rememberView(() => page = 0),
          selected: page == 0,
        ),
        const SizedBox(height: 8),
        IconButton(
          key: const Key('sidebar-notifications'),
          tooltip: s.isProject ? '내 알림' : '알림 미리보기',
          onPressed: notifications,
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          padding: EdgeInsets.zero,
          icon: Badge(
            isLabelVisible: s.unreadNotificationCount > 0,
            smallSize: 5,
            backgroundColor: purple,
            child: const Icon(
              Icons.notifications_none_outlined,
              size: 21,
              color: Color(0xff505753),
            ),
          ),
        ),
        const Spacer(),
        AccountMenu(
          name: s.actor.name,
          role: s.isProject ? s.actor.roleLabel : '테스트 사용자',
          avatar: avatar(s.actor),
          onSettings: () => selectSettings(SettingsSection.general),
          onSignOut: widget.onSignOut,
          profileControl: s.isProject
              ? null
              : IeumSelect(
                  key: const Key('profile'),
                  value: s.profileId,
                  values: {for (final m in s.people) m.id: m.name},
                  colors: {for (final m in s.people) m.id: Color(m.color)},
                  onChanged: s.setProfile,
                ),
        ),
      ],
    ),
  );

  Widget railButton(
    String key,
    String label,
    IconData icon,
    VoidCallback action, {
    bool selected = false,
  }) => IconButton(
    key: Key(key),
    tooltip: label,
    onPressed: action,
    constraints: const BoxConstraints.tightFor(width: 44, height: 44),
    padding: EdgeInsets.zero,
    style: IconButton.styleFrom(
      backgroundColor: selected ? const Color(0xffe1e6e3) : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    icon: Icon(icon, size: 21, color: selected ? ink : const Color(0xff505753)),
  );
  Widget stats(List<WorkTask> tasks) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 760 ? 4 : 2;
      final width = (constraints.maxWidth - (columns - 1) * 15) / columns;
      return Wrap(
        spacing: 15,
        runSpacing: 15,
        children: List.generate(
          4,
          (i) => SizedBox(
            width: width,
            child: Container(
              height: 106,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: border),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          ['전체 작업', '진행 중', '검토 대기', '완료'][i],
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                        const SizedBox(height: 9),
                        RichText(
                          text: TextSpan(
                            style: const TextStyle(
                              color: ink,
                              fontFamily: 'Malgun Gothic',
                            ),
                            children: [
                              TextSpan(
                                text:
                                    '${i == 0 ? tasks.length : tasks.where((t) => t.status == ['', 'doing', 'review', 'done'][i]).length}',
                                style: const TextStyle(
                                  fontSize: 25,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const TextSpan(
                                text: '  건',
                                style: TextStyle(fontSize: 10, color: muted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (width >= 150)
                    Icon(
                      [
                        Icons.folder_copy_outlined,
                        Icons.play_arrow_outlined,
                        Icons.verified_user_outlined,
                        Icons.check_circle_outline,
                      ][i],
                      size: 22,
                      color: i == 2
                          ? statusColor('review')
                          : i == 3
                          ? statusColor('done')
                          : purple.withValues(alpha: .6),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
  Widget toolbar() => Wrap(
    alignment: WrapAlignment.spaceBetween,
    runSpacing: 12,
    spacing: 20,
    children: [
      Wrap(
        spacing: 5,
        runSpacing: 6,
        children: [
          for (final entry in {
            'all': '전체 작업',
            'mine': '내 할 일',
            'review': '내 검토 요청',
          }.entries)
            Padding(
              padding: const EdgeInsets.only(right: 5),
              child: TextButton(
                key: Key('scope-${entry.key}'),
                style: TextButton.styleFrom(
                  backgroundColor: scope == entry.key
                      ? const Color(0xffeee8fb)
                      : Colors.transparent,
                  foregroundColor: scope == entry.key ? purple : muted,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                onPressed: () => setState(() => scope = entry.key),
                child: Text(entry.value, style: const TextStyle(fontSize: 11)),
              ),
            ),
        ],
      ),
      SegmentedButton<TaskView>(
        key: const Key('task-view-selector'),
        showSelectedIcon: false,
        style: SegmentedButton.styleFrom(
          foregroundColor: muted,
          selectedForegroundColor: purple,
          backgroundColor: Colors.white,
          selectedBackgroundColor: const Color(0xffeee8fb),
          side: const BorderSide(color: border),
          textStyle: const TextStyle(fontSize: 11),
          iconSize: 16,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
        segments: const [
          ButtonSegment(
            value: TaskView.list,
            label: Text('목록', key: Key('view-list')),
            icon: Icon(Icons.view_list_outlined),
            tooltip: '담당자와 날짜를 목록으로 보기',
          ),
          ButtonSegment(
            value: TaskView.kanban,
            label: Text('칸반보드', key: Key('view-kanban')),
            icon: Icon(Icons.view_kanban_outlined),
            tooltip: '작업 상태를 칸반보드로 보기',
          ),
        ],
        selected: {taskView},
        onSelectionChanged: (value) =>
            rememberView(() => taskView = value.single),
      ),
      Wrap(
        spacing: 9,
        runSpacing: 10,
        children: [
          SizedBox(
            width: 190,
            child: TextField(
              key: const Key('search'),
              style: const TextStyle(fontSize: 11),
              onChanged: (value) => setState(() => search = value),
              decoration: const InputDecoration(
                hintText: '작업 검색',
                prefixIcon: Icon(Icons.search, size: 17),
                contentPadding: EdgeInsets.all(10),
              ),
            ),
          ),
          SizedBox(
            width: 140,
            child: IeumSelect(
              key: ValueKey('filter-$part'),
              value: part,
              values: {
                '': '모든 파트',
                for (final r in s.partRules) r.part: r.part,
              },
              onChanged: (value) => setState(() => part = value),
            ),
          ),
        ],
      ),
    ],
  );
  Widget board(List<WorkTask> tasks, double available) => HorizontalViewport(
    key: const Key('task-kanban'),
    child: SizedBox(
      width: max(available, 980),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: statuses.entries.map((stage) {
          final list = tasks.where((t) => t.status == stage.key).toList();
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: stage.key == 'done' ? 0 : 13),
              child: DragTarget<WorkTask>(
                onWillAcceptWithDetails: (d) => s.canMove(d.data, stage.key),
                onAcceptWithDetails: (d) => move(d.data, stage.key),
                builder: (ctx, candidates, rejected) => Container(
                  key: Key('column-${stage.key}'),
                  constraints: const BoxConstraints(minHeight: 425),
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: candidates.isNotEmpty
                        ? const Color(0xffeae3f8)
                        : const Color(0xfff0eff4),
                    border: Border.all(
                      color: candidates.isNotEmpty ? purple : border,
                    ),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.circle,
                            size: 6,
                            color: statusColor(stage.key),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            stage.value,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          badge('${list.length}'),
                          const Spacer(),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '새 작업 등록',
                            onPressed: () => edit(),
                            icon: const Icon(Icons.add, size: 16, color: muted),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...list.map(
                        (t) => Padding(
                          padding: const EdgeInsets.only(bottom: 11),
                          child: Draggable<WorkTask>(
                            data: t,
                            feedback: Material(
                              color: Colors.transparent,
                              child: SizedBox(width: 200, child: taskCard(t)),
                            ),
                            childWhenDragging: Opacity(
                              opacity: .35,
                              child: taskCard(t),
                            ),
                            child: taskCard(t),
                          ),
                        ),
                      ),
                      if (list.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 35),
                          child: Center(
                            child: Text(
                              '아직 작업이 없어요',
                              style: TextStyle(fontSize: 11, color: muted),
                            ),
                          ),
                        ),
                      TextButton.icon(
                        onPressed: () => edit(),
                        icon: const Icon(Icons.add, size: 14),
                        label: const Text(
                          '작업 추가',
                          style: TextStyle(fontSize: 10),
                        ),
                        style: TextButton.styleFrom(foregroundColor: muted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    ),
  );
  Widget taskCard(WorkTask t) => Material(
    key: Key('card-${t.id}'),
    color: Colors.white,
    borderRadius: BorderRadius.circular(9),
    child: InkWell(
      borderRadius: BorderRadius.circular(9),
      onTap: () => details(t),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                badge(t.part),
                const Spacer(),
                badge(
                  '${t.priority == 'high' ? '↑ ' : ''}${priorities[t.priority]}',
                  color: priorityColor(t.priority),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              shortId(t.id),
              style: const TextStyle(fontSize: 9, color: muted),
            ),
            const SizedBox(height: 7),
            SizedBox(
              height: 44,
              child: Text(
                t.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  height: 1.7,
                ),
              ),
            ),
            if (t.status == 'rework')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '재작업 요청이 있어요',
                  style: TextStyle(fontSize: 9, color: statusColor('rework')),
                ),
              ),
            const SizedBox(height: 15),
            Row(
              children: [
                const Icon(
                  Icons.calendar_month_outlined,
                  size: 13,
                  color: muted,
                ),
                const SizedBox(width: 5),
                Text(
                  shortDate(t.dueDate),
                  style: const TextStyle(fontSize: 10, color: muted),
                ),
                const Spacer(),
                Tooltip(
                  message: s.member(t.currentId).name,
                  child: avatar(s.member(t.currentId), size: 25),
                ),
              ],
            ),
            if (t.status == 'review') ...[
              const Divider(height: 24, color: border),
              Row(
                children: [
                  Icon(
                    Icons.arrow_forward,
                    size: 12,
                    color: statusColor('review'),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${s.member(t.reviewerId).name} 검토 대기',
                      style: TextStyle(
                        fontSize: 9,
                        color: statusColor('review'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
  );
  Widget schedule(List<WorkTask> tasks) => Container(
    key: const Key('task-list'),
    width: double.infinity,
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: border),
      borderRadius: BorderRadius.circular(10),
    ),
    child: HorizontalViewport(
      child: DataTable(
        showCheckboxColumn: false,
        columnSpacing: 24,
        headingRowHeight: 49,
        dataRowMinHeight: 70,
        dataRowMaxHeight: 70,
        headingTextStyle: const TextStyle(fontSize: 10, color: muted),
        dataTextStyle: const TextStyle(fontSize: 11, color: ink),
        columns: [
          '작업내용',
          '상태',
          '담당자',
          '현재 처리자',
          '우선순위',
          '작업 지정일',
          '마감일',
          '완료일',
        ].map((label) => DataColumn(label: Text(label))).toList(),
        rows: tasks
            .map(
              (t) => DataRow(
                onSelectChanged: (_) => details(t),
                cells: [
                  DataCell(
                    SizedBox(
                      width: 215,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${t.part} · ${shortId(t.id)}',
                            style: const TextStyle(fontSize: 9, color: muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                  DataCell(
                    badge(statuses[t.status]!, color: statusColor(t.status)),
                  ),
                  DataCell(Text(s.member(t.assigneeId).name)),
                  DataCell(Text(s.member(t.currentId).name)),
                  DataCell(
                    badge(
                      priorities[t.priority]!,
                      color: priorityColor(t.priority),
                    ),
                  ),
                  DataCell(Text(t.assignedDate)),
                  DataCell(Text(t.dueDate.isEmpty ? '—' : t.dueDate)),
                  DataCell(
                    Text(t.completedDate.isEmpty ? '—' : t.completedDate),
                  ),
                ],
              ),
            )
            .toList(),
      ),
    ),
  );
  Widget changesPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        padding: const EdgeInsets.all(23),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Wrap(
          spacing: 25,
          runSpacing: 15,
          children: ['개인 SQLite', '변경안 JSON', '개인 브랜치 · PR', 'main 통합본']
              .asMap()
              .entries
              .map(
                (e) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    badge('${e.key + 1}', color: purple),
                    const SizedBox(width: 10),
                    Text(
                      e.value,
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                    if (e.key < 3) ...[
                      const SizedBox(width: 18),
                      const Icon(Icons.arrow_forward, size: 15, color: muted),
                    ],
                  ],
                ),
              )
              .toList(),
        ),
      ),
      const SizedBox(height: 27),
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        runSpacing: 15,
        spacing: 20,
        children: [
          heading(
            '통합 전 변경 ${s.changes.length}건',
            '기준 통합본: ${s.baseRevision} · 전송 상태는 GitHub 동기화에서 확인하세요.',
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: fileBusy ? null : import,
                icon: const Icon(Icons.upload_outlined, size: 16),
                label: const Text('통합본 가져오기', style: TextStyle(fontSize: 11)),
              ),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: fileBusy || s.changes.isEmpty ? null : export,
                icon: const Icon(Icons.download_outlined, size: 16),
                label: const Text('변경안 내보내기', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ],
      ),
      const SizedBox(height: 20),
      if (s.changes.isEmpty)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(60),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Column(
            children: [
              Icon(Icons.merge_outlined, size: 32, color: purple),
              SizedBox(height: 18),
              Text('아직 개인 변경이 없어요', style: TextStyle(fontSize: 15)),
              SizedBox(height: 10),
              Text(
                '작업 등록이나 상태 변경을 하면 여기에 표시됩니다.',
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ],
          ),
        ),
      ...s.changes.map(
        (c) => Container(
          margin: const EdgeInsets.only(bottom: 15),
          padding: const EdgeInsets.all(23),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              badge(c['kind'] == 'create' ? '신규 작업' : '수정 작업', color: purple),
              const SizedBox(height: 10),
              Text(
                c['title'],
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              ...(c['fields'] as List).map(
                (f) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 100,
                        child: Text(
                          f['label'],
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${f['before'] ?? '—'}',
                          style: const TextStyle(fontSize: 11, color: muted),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 13),
                        child: Icon(
                          Icons.arrow_forward,
                          size: 14,
                          color: muted,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          '${f['after']}',
                          style: const TextStyle(fontSize: 11, color: purple),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      info(
        '자동 동기화 중 충돌한 작업은 개인 변경을 보존하고, 나머지 작업은 계속 가져옵니다. 설정의 GitHub 동기화에서 충돌 내용을 확인할 수 있습니다.',
      ),
    ],
  );
  Widget info(String text) => Container(
    margin: const EdgeInsets.only(top: 24),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xfff1edf8),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 18, color: purple),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 11, color: muted, height: 1.8),
          ),
        ),
      ],
    ),
  );
  Widget settingsContent(SettingsSection section) => switch (section) {
    SettingsSection.general => generalSettings(),
    SettingsSection.roles =>
      s.isProject && widget.session != null && widget.sync != null
          ? RolesPanel(store: s, sync: widget.sync!, session: widget.session!)
          : settingsGroup('역할', [
              ('프로젝트 필요', '프로젝트를 연결하면 역할을 관리할 수 있습니다.', ''),
            ]),
    SettingsSection.team =>
      s.isProject && widget.session != null && widget.sync != null
          ? TeamPanel(store: s, sync: widget.sync!, session: widget.session!)
          : info('프로젝트에 로그인하면 참여자와 역할, 가입 요청을 관리할 수 있습니다.'),
    SettingsSection.assignments => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '파트를 선택하면 기본 작업자와 검토자가 자동으로 배정됩니다.',
          style: TextStyle(fontSize: 12, color: muted),
        ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: HorizontalViewport(
            child: DataTable(
              columnSpacing: 35,
              headingTextStyle: const TextStyle(fontSize: 11, color: muted),
              dataTextStyle: const TextStyle(fontSize: 12, color: ink),
              columns: [
                '담당 파트',
                '기본 작업자',
                '검토자',
                '후속 파트 (설계)',
              ].map((v) => DataColumn(label: Text(v))).toList(),
              rows: s.partRules
                  .map(
                    (r) => DataRow(
                      cells: [
                        DataCell(Text(r.part)),
                        DataCell(Text(s.member(r.assigneeId).name)),
                        DataCell(Text(s.member(r.reviewerId).name)),
                        DataCell(Text(r.nextPart.isEmpty ? '—' : r.nextPart)),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
      ],
    ),
    SettingsSection.github =>
      widget.sync != null
          ? GitHubPanel(sync: widget.sync!)
          : info('프로젝트 저장소에 연결하면 동기화 상태와 전송 대기열을 확인할 수 있습니다.'),
    SettingsSection.changes => changesPanel(),
    SettingsSection.notifications => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsGroup('작업 알림', [
          (
            '앱 알림함',
            '작업 배정, 검토 요청, 재작업 결과를 확인합니다.',
            '${s.unreadNotificationCount}개 읽지 않음',
          ),
          ('Discord', '현재 작업 알림은 이음의 앱 알림함으로 전달됩니다.', '미연결'),
        ]),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: notifications,
          icon: const Icon(Icons.notifications_none_rounded, size: 18),
          label: const Text('앱 알림함 열기'),
        ),
      ],
    ),
  };

  bool nameBusy = false;
  String nameNotice = '';
  Future<void> renameAccount() async {
    final controller = TextEditingController(text: s.actor.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => IeumDialog(
        title: const Text('이름 변경'),
        icon: Icons.edit_outlined,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const Key('account-display-name'),
              controller: controller,
              maxLength: 40,
              decoration: const InputDecoration(labelText: '이름 / 닉네임'),
            ),
            const SizedBox(height: 12),
            const Text(
              '이 컴퓨터에 연결된 모든 참여 프로젝트에 커밋으로 반영합니다. GitHub 아이디와 기존 브랜치는 유지됩니다.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(ctx, controller.text.trim());
              }
            },
            child: const Text('변경'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (name == null || !mounted) return;
    setState(() {
      nameBusy = true;
      nameNotice = '';
    });
    try {
      final result = widget.onRename != null
          ? await widget.onRename!(name)
          : await renameCurrent(name);
      if (mounted) setState(() => nameNotice = result);
    } catch (e) {
      if (mounted) setState(() => nameNotice = '$e');
    } finally {
      if (mounted) setState(() => nameBusy = false);
    }
  }

  Future<String> renameCurrent(String name) async {
    s.updateProject(
      await widget.session!.rename(
        widget.sync!.config,
        name,
        expectedProjectId: s.project!.id,
      ),
    );
    return '이름을 변경했습니다.';
  }

  Widget generalSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      settingsGroup('프로젝트', [
        ('프로젝트 이름', '현재 열려 있는 작업 공간입니다.', s.project?.name ?? '예시 작업 공간'),
        (
          '데이터 저장 위치',
          '이 컴퓨터의 작업과 전송 대기열을 보관합니다.',
          s.filename == ':memory:' ? '테스트용 메모리 DB' : s.filename,
        ),
        (
          'GitHub 저장소',
          '팀의 작업과 통합본을 공유합니다.',
          widget.sync?.config.repository.isNotEmpty == true
              ? widget.sync!.config.slug
              : '연결되지 않음',
        ),
      ]),
      const SizedBox(height: 32),
      settingsGroup('계정', [
        ('이름', '참여 중인 프로젝트에서 사용하는 표시 이름입니다.', s.actor.name),
        (
          '상태',
          '비활성화된 참여자는 작업을 수정하거나 업로드할 수 없습니다.',
          s.actor.active ? '활성화' : '비활성화',
        ),
        (
          '역할',
          '프로젝트에서 지정된 역할과 권한입니다.',
          s.isProject ? s.actor.roleLabel : '테스트 사용자',
        ),
      ]),
      if (s.isProject && widget.session != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('change-account-name'),
            onPressed: nameBusy ? null : renameAccount,
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: Text(nameBusy ? '이름 반영 중…' : '모든 프로젝트의 이름 변경'),
          ),
        ),
      if (nameNotice.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SelectableText(
            nameNotice,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      const SizedBox(height: 32),
      settingsGroup('앱 정보', [('이음 버전', '새 버전을 확인하고 다운로드합니다.', appVersion)]),
      const Align(alignment: Alignment.centerLeft, child: UpdateButton()),
    ],
  );

  Widget settingsGroup(String title, List<(String, String, String)> rows) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xff303632),
            ),
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: const Color(0xffe5e8e6)),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const Divider(height: 1, color: Color(0xffeceeec)),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: settingRow(rows[i]),
                  ),
                ],
              ],
            ),
          ),
        ],
      );
  Widget settingRow((String, String, String) row) => LayoutBuilder(
    builder: (context, constraints) {
      final label = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            row.$1,
            style: const TextStyle(
              fontSize: 12,
              height: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            row.$2,
            style: const TextStyle(
              fontSize: 11,
              color: Color(0xff7d8380),
              height: 1.5,
            ),
          ),
        ],
      );
      final value = SelectableText(
        row.$3,
        textAlign: TextAlign.left,
        style: const TextStyle(
          fontSize: 12,
          color: Color(0xff666e68),
          height: 1.5,
        ),
      );
      return constraints.maxWidth < 560
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [label, const SizedBox(height: 12), value],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 220, child: label),
                const SizedBox(width: 24),
                Expanded(child: value),
              ],
            );
    },
  );
  Widget detailBody(BuildContext ctx, WorkTask t) {
    final canEdit = s.canEdit(t);
    final lockReason = t.status == 'review' || !s.canEditContent(t)
        ? s.editLockReason(t)
        : '';
    final history = s.activity.where((a) => a['taskId'] == t.id);
    return ListView(
      padding: const EdgeInsets.all(31),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t.id,
                style: const TextStyle(fontSize: 10, color: muted),
              ),
            ),
            IconButton(
              tooltip: '작업 상세 닫기',
              onPressed: () => Navigator.pop(ctx),
              icon: const Icon(Icons.close, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Align(
          alignment: Alignment.centerLeft,
          child: badge(statuses[t.status]!, color: statusColor(t.status)),
        ),
        const SizedBox(height: 18),
        Text(
          t.title,
          style: const TextStyle(
            fontSize: 23,
            fontWeight: FontWeight.w600,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 26),
        ...{
          '담당 파트': t.part,
          '작업 담당자': s.member(t.assigneeId).name,
          '검토 담당자': s.member(t.reviewerId).name,
          '현재 처리자': s.member(t.currentId).name,
          '우선순위': priorities[t.priority]!,
          '작업 지정일': t.assignedDate,
          '마감일': t.dueDate.isEmpty ? '미정' : t.dueDate,
          '완료일': t.completedDate.isEmpty ? '—' : t.completedDate,
        }.entries.map(
          (e) => Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(
              children: [
                SizedBox(
                  width: 115,
                  child: Text(
                    e.key,
                    style: const TextStyle(fontSize: 11, color: muted),
                  ),
                ),
                Expanded(
                  child: Text(e.value, style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 13),
        const Text(
          '작업 설명',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Text(
          t.description.isEmpty ? '작성된 설명이 없습니다.' : t.description,
          style: const TextStyle(fontSize: 12, color: muted, height: 1.9),
        ),
        if (t.reworkReason.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 20),
            padding: const EdgeInsets.all(16),
            color: const Color(0xfffaf0f3),
            child: Text(
              '재작업 요청 사유\n${t.reworkReason}',
              style: TextStyle(
                fontSize: 11,
                height: 1.9,
                color: statusColor('rework'),
              ),
            ),
          ),
        const Divider(height: 43, color: border),
        if (lockReason.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.lock_outline, size: 16, color: muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    lockReason,
                    style: const TextStyle(
                      fontSize: 11,
                      color: muted,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (canEdit)
              OutlinedButton(
                onPressed: () => edit(t),
                child: Text(s.canEditContent(t) ? '작업 수정' : '배정 · 일정 변경'),
              ),
            if (s.canMove(t, 'doing'))
              FilledButton.icon(
                onPressed: () => move(t, 'doing'),
                icon: const Icon(Icons.play_arrow_outlined, size: 17),
                label: const Text('작업 시작'),
              ),
            if (s.canMove(t, 'review'))
              FilledButton.icon(
                onPressed: () => move(t, 'review'),
                icon: const Icon(Icons.send_outlined, size: 16),
                label: const Text('검토 요청'),
              ),
            if (s.canMove(t, 'done'))
              FilledButton.icon(
                onPressed: () => move(t, 'done'),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('완료 승인'),
              ),
            if (s.canMove(t, 'rework'))
              OutlinedButton.icon(
                onPressed: () => move(t, 'rework'),
                icon: const Icon(Icons.replay, size: 16),
                label: const Text('재작업 요청'),
              ),
          ],
        ),
        if (t.status == 'review' && !s.canMove(t, 'done'))
          const Padding(
            padding: EdgeInsets.only(top: 15),
            child: Text(
              '검토자의 확인을 기다리고 있습니다.',
              style: TextStyle(fontSize: 11, color: muted),
            ),
          ),
        const SizedBox(height: 30),
        const Text(
          '활동 기록',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 13),
        ...history.map(
          (a) => Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Text(
              '${s.member(a['actorId']).name} · ${a['message']}',
              style: const TextStyle(fontSize: 11, color: muted),
            ),
          ),
        ),
      ],
    );
  }
}
