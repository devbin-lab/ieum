import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:file_selector/file_selector.dart';

import 'models.dart';
import 'store.dart';
import 'task_editor.dart';
import 'task_handoff.dart';
import 'task_handoff_dialog.dart';
import 'window_frame.dart';
import 'popup_ui.dart';
import 'github_sync.dart';
import 'github_panel.dart';
import 'project_service.dart';
import 'team_panel.dart';
import 'app_release.dart';
import 'account_menu.dart';
import 'settings_shell.dart';
import 'draft_guard.dart';
import 'horizontal_viewport.dart';
import 'update_ui.dart';
import 'roles_panel.dart';
import 'project_catalog.dart';
import 'notification_inbox.dart';
import 'project_schedule_view.dart';
import 'task_comments_panel.dart';
import 'project_connections_view.dart';

const purple = Color(0xff7963d5),
    ink = Color(0xff302b3c),
    muted = Color(0xff6e687b),
    border = Color(0xffe1e3e6),
    canvas = Color(0xfffafbfa);
const iconRailSurface = Color(0xffe6e8e7);
const boardStatuses = {'todo': '확인중', 'doing': '진행중', 'done': '완료'};
const iconRailSelected = Color(0xffcfd4d2), iconRailActive = Color(0xff302b3c);
const iconRailMuted = Color(0xff505753);
const _customStatusColors = [
  Color(0xff58798a),
  Color(0xff8a6e9d),
  Color(0xff9a713d),
  Color(0xff4e8078),
];
const _customStatusSurfaces = [
  Color(0xffedf3f5),
  Color(0xfff3eff7),
  Color(0xfff8f1e8),
  Color(0xffedf5f3),
];
int _stagePaletteIndex(String id) =>
    id.codeUnits.fold<int>(0, (sum, value) => sum + value) %
    _customStatusColors.length;
Color statusColor(String id) =>
    {
      'todo': const Color(0xff6e687b),
      'doing': purple,
      'review': const Color(0xff8c652d),
      'rework': const Color(0xffa0445a),
      'done': const Color(0xff417458),
    }[id] ??
    _customStatusColors[_stagePaletteIndex(id)];
Color stageSurfaceColor(String id) =>
    {
      'todo': const Color(0xfff1f3f5),
      'doing': const Color(0xfff2efff),
      'review': const Color(0xfffff5e8),
      'rework': const Color(0xfffff0f2),
      'done': const Color(0xffedf6ef),
    }[id] ??
    _customStatusSurfaces[_stagePaletteIndex(id)];
Color priorityColor(String id) => id == 'high'
    ? const Color(0xff9a622b)
    : id == 'low'
    ? const Color(0xff50735a)
    : muted;
Widget badge(String text, {Color color = muted}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .09),
    borderRadius: BorderRadius.circular(5),
  ),
  child: Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(color: color, fontSize: 10),
  ),
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

String taskChangeValue(String key, dynamic value) {
  if (value == null) return '—';
  if (key == 'pinned') return value == 'true' ? '고정' : '해제';
  return '$value';
}

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
          textStyle: const TextStyle(
            fontFamily: 'Malgun Gothic',
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
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
          textStyle: const TextStyle(
            fontFamily: 'Malgun Gothic',
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
          minimumSize: const Size(40, 40),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          textStyle: const TextStyle(fontFamily: 'Malgun Gothic', fontSize: 13),
          minimumSize: const Size(40, 40),
          side: const BorderSide(color: border),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
  final Widget Function(VoidCallback)? projectSwitcherBuilder;
  final List<SavedProject> notificationProjects;
  final String? sessionNotice;
  final Future<String> Function(String)? onRename;
  const Workspace({
    super.key,
    required this.store,
    this.sync,
    this.onSignOut,
    this.session,
    this.projectSwitcher,
    this.projectSwitcherBuilder,
    this.notificationProjects = const [],
    this.sessionNotice,
    this.onRename,
  });
  @override
  State<Workspace> createState() => _WorkspaceState();
}

enum TaskView { list, kanban }

typedef _WorkspaceView = ({
  int page,
  SettingsSection settings,
  TaskView taskView,
  String notificationProject,
  String? selectedNotificationKey,
  bool unreadOnly,
  bool mentionsOnly,
});

class _WorkspaceState extends State<Workspace>
    with SingleTickerProviderStateMixin {
  int page = 6;
  SettingsSection settingsSection = SettingsSection.general;
  TaskView taskView = TaskView.list;
  String search = '', part = '', scope = 'all', relatedMember = '';
  String statusFilter = '', deadlineFilter = '', taskSort = 'updated';
  int taskPage = 0;
  final taskSearch = TextEditingController();
  String notificationProject = 'all';
  String? selectedNotificationKey;
  bool unreadNotificationsOnly = false, myMentionsOnly = false;
  List<Map<String, dynamic>> notificationHistory = const [];
  bool fileBusy = false;
  bool handoffOpen = false;
  bool projectViewOpen = false;
  late final AnimationController _projectViewAnimation;
  SidebarTitlebarController? titlebarSidebar;
  late final VoidCallback titlebarToggle = toggleProjectView;
  final List<_WorkspaceView> _viewHistory = [];
  int _viewHistoryIndex = 0;
  _WorkspaceView get _currentView => (
    page: page,
    settings: settingsSection,
    taskView: taskView,
    notificationProject: notificationProject,
    selectedNotificationKey: selectedNotificationKey,
    unreadOnly: unreadNotificationsOnly,
    mentionsOnly: myMentionsOnly,
  );
  TaskStore get s => widget.store;
  @override
  void initState() {
    super.initState();
    projectViewOpen =
        s.meta('ui.projectView') != 'closed' &&
        (widget.projectSwitcherBuilder != null ||
            widget.projectSwitcher != null);
    var migrateSavedView = false;
    try {
      final saved = jsonDecode(s.meta('ui.workspace')) as Map;
      final savedPage = saved['page'];
      migrateSavedView = saved['projectTabsVersion'] != 1;
      if (savedPage is int && savedPage >= 0 && savedPage <= 6) {
        // The old home combined schedule and task management. Preserve that
        // content under Tasks once, then respect future Schedule selections.
        page = migrateSavedView && (savedPage == 0 || savedPage == 3)
            ? 6
            : savedPage;
      }
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
    if (migrateSavedView) _saveView();
    _projectViewAnimation = AnimationController.unbounded(
      vsync: this,
      value: projectViewOpen && hasProjectSidebar ? 1 : 0,
    );
    _viewHistory.add(_currentView);
    if (page == 4) refreshNotificationHistory();
  }

  bool projectViewInitialized = false;
  bool get hasProjectSidebar => page == 0 || page == 5 || page == 6;
  bool get isTaskPage => page == 6;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    titlebarSidebar = SidebarTitlebarScope.maybeOf(context);
    if (!projectViewInitialized) {
      projectViewInitialized = true;
      if (s.meta('ui.projectView').isEmpty &&
          hasProjectSidebar &&
          MediaQuery.sizeOf(context).width < 1000) {
        projectViewOpen = false;
        _projectViewAnimation.value = 0;
        _viewHistory[_viewHistoryIndex] = _currentView;
      }
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _configureTitlebar();
    });
  }

  @override
  void dispose() {
    taskSearch.dispose();
    _projectViewAnimation.dispose();
    final controller = titlebarSidebar;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      controller?.clear(titlebarToggle);
    });
    super.dispose();
  }

  void rememberView(VoidCallback change) {
    setState(() {
      final previous = _currentView;
      change();
      final next = _currentView;
      if (next != previous) {
        _viewHistory.removeRange(_viewHistoryIndex + 1, _viewHistory.length);
        _viewHistory.add(next);
        _viewHistoryIndex++;
      }
      _saveView();
    });
    _syncProjectView();
    _configureTitlebar();
  }

  void _syncProjectView({bool animate = false}) {
    if (!hasProjectSidebar) {
      _projectViewAnimation.value = 0;
      return;
    }
    final target = projectViewOpen ? 1.0 : 0.0;
    if (!animate ||
        (!_projectViewAnimation.isAnimating &&
            (_projectViewAnimation.value - target).abs() < .005)) {
      _projectViewAnimation.value = target;
      return;
    }
    _projectViewAnimation.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 420, damping: 30),
        _projectViewAnimation.value,
        target,
        0,
        tolerance: const Tolerance(distance: .001, velocity: .01),
      ),
    );
  }

  void _saveView() => s.setMeta(
    'ui.workspace',
    jsonEncode({
      'page': page,
      'view': taskView.name,
      'settings': settingsSection.name,
      'projectTabsVersion': 1,
    }),
  );

  void _configureTitlebar() => titlebarSidebar?.configure(
    titlebarToggle,
    projectViewOpen,
    back: _viewHistoryIndex > 0 ? goBack : null,
    forward: _viewHistoryIndex < _viewHistory.length - 1 ? goForward : null,
    showSidebar: hasProjectSidebar,
  );

  void goBack() => _travelHistory(-1);
  void goForward() => _travelHistory(1);

  void _travelHistory(int step) {
    final nextIndex = _viewHistoryIndex + step;
    if (nextIndex < 0 || nextIndex >= _viewHistory.length) return;
    setState(() {
      _viewHistoryIndex = nextIndex;
      final view = _viewHistory[nextIndex];
      page = view.page;
      settingsSection = view.settings;
      taskView = view.taskView;
      notificationProject = view.notificationProject;
      selectedNotificationKey = view.selectedNotificationKey;
      unreadNotificationsOnly = view.unreadOnly;
      myMentionsOnly = view.mentionsOnly;
      _saveView();
    });
    _syncProjectView();
    _configureTitlebar();
    if (page == 4) refreshNotificationHistory();
  }

  static const titles = ['작업', '내 변경내역', '프로젝트 설정'];
  static const subtitles = [
    '프로젝트 작업을 목록 또는 칸반보드로 확인하고 관리하세요.',
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
          width: min(520, MediaQuery.sizeOf(context).width - 32),
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

  void edit([WorkTask? task, DateTime? date]) {
    if (task == null && s.isProject && s.partRules.isEmpty) {
      if (s.actor.has('role.manage')) {
        selectSettings(SettingsSection.roles);
        message('첫 작업을 등록하기 전에 팀에서 사용할 파트를 추가하세요.');
      } else {
        message('프로젝트 관리자에게 작업을 등록할 파트 추가를 요청하세요.');
      }
      return;
    }
    showDialog<void>(
      context: context,
      builder: (_) => TaskEditor(store: s, task: task, initialDate: date),
    );
  }

  Future<void> move(WorkTask task, String target) async {
    if (handoffOpen || task.status == target) return;
    try {
      final choices = s
          .availableHandoffs(task)
          .where((plan) => plan.destinationId == target)
          .toList();
      if (choices.isEmpty) throw StateError('현재 작업을 이 단계로 전달할 수 없습니다.');
      await chooseHandoff(choices);
    } catch (e) {
      if (mounted) message(e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  String boardCategory(WorkTask task) => workflowBoardCategory(task, s.project);
  String boardKey(WorkTask task) =>
      boardCategory(task) == 'inProgress' ? 'doing' : boardCategory(task);
  String purposeLabel(WorkTask task) =>
      workflowPurposeLabels[workflowTaskPurpose(task, s.project)] ?? '작성';
  List<TaskHandoffPlan> taskActions(WorkTask task) => [
    ...s.availableHandoffs(task),
    ...s.availableTransfers(task),
  ];
  bool wasTransferred(WorkTask task) {
    if (task.workflowSender.isNotEmpty) return true;
    if (task.workflowRoute.isEmpty ||
        const {
          'manual-start',
          'manual-finish',
          'default-start',
          'default-finish',
        }.contains(task.workflowRoute)) {
      return false;
    }
    final route = s.project?.workflowSheet?.routes
        .where((r) => r.id == task.workflowRoute)
        .firstOrNull;
    return route?.assignment != 'keep';
  }

  String destinationCategory(String id) {
    final stage = s.project?.stage(id);
    if (id == 'review' && (stage == null || stage.category.isEmpty) ||
        id == 'rework') {
      return 'inProgress';
    }
    return stage?.resolvedCategory ??
        (id == 'todo'
            ? 'todo'
            : id == 'done'
            ? 'done'
            : 'inProgress');
  }

  Future<void> moveToCategory(WorkTask task, String category) async {
    if (handoffOpen) return;
    try {
      final choices = s
          .availableHandoffs(task)
          .where((plan) => destinationCategory(plan.destinationId) == category)
          .toList();
      if (choices.isEmpty) throw StateError('이 작업을 해당 열로 전달할 수 없습니다.');
      await chooseHandoff(choices);
    } catch (e) {
      if (mounted) message(e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  Future<void> chooseHandoff(List<TaskHandoffPlan> choices) async {
    var plan = choices.first;
    if (choices.length > 1) {
      final selected = await showDialog<TaskHandoffPlan>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('전달 경로 선택'),
          children: [
            for (final choice in choices)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, choice),
                child: Text('${choice.buttonLabel} · ${choice.recipientLabel}'),
              ),
          ],
        ),
      );
      if (!mounted || selected == null) return;
      plan = selected;
    }
    await confirmHandoff(plan);
  }

  Future<void> confirmHandoff(TaskHandoffPlan plan) async {
    if (handoffOpen) return;
    setState(() => handoffOpen = true);
    try {
      final result = await showTaskHandoffDialog(context, plan: plan, store: s);
      if (!mounted || result == null) return;
      action(() {
        s.confirmHandoff(result.plan, reason: result.reason);
        message(
          result.plan.maintainsStatus
              ? '${result.plan.recipientLabel}에게 전달했습니다. ${result.plan.routeLabel}.'
              : '${result.plan.destinationName}으로 변경했습니다.',
        );
      });
    } finally {
      if (mounted) setState(() => handoffOpen = false);
    }
  }

  Widget handoffButton(
    TaskHandoffPlan plan, {
    bool compact = false,
    bool interactive = true,
    String? surface,
  }) {
    final key = interactive
        ? Key(
            'task-handoff-${surface == null ? (compact ? '' : 'detail-') : '$surface-'}${plan.taskId}-${plan.action}-${plan.destinationId}${plan.routeId.isEmpty ? '' : '-${plan.routeId}'}',
          )
        : null;
    final actionLabel = plan.buttonLabel;
    final matching = taskActions(s.find(plan.taskId))
        .where(
          (other) =>
              other.destinationId == plan.destinationId &&
              other.action == plan.action,
        )
        .length;
    final label = matching > 1 && !directWorkflowRouteIds.contains(plan.routeId)
        ? '$actionLabel · ${plan.recipientLabel}'
        : actionLabel;
    final onPressed = interactive && !handoffOpen
        ? () => confirmHandoff(plan)
        : null;
    final icon = Icon(
      plan.action == 'reject'
          ? Icons.reply_rounded
          : plan.action == 'approve'
          ? Icons.check_rounded
          : Icons.arrow_forward_rounded,
      size: compact ? 14 : 16,
    );
    final text = Text(
      label,
      softWrap: !compact,
      maxLines: compact ? 1 : null,
      overflow: compact ? TextOverflow.ellipsis : null,
    );
    return Tooltip(
      message: '${plan.routeLabel}\n다음 담당자: ${plan.recipientLabel}',
      child: compact || plan.action == 'reject'
          ? OutlinedButton.icon(
              key: key,
              onPressed: onPressed,
              icon: icon,
              label: text,
              style: compact
                  ? OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 7,
                      ),
                      textStyle: const TextStyle(fontSize: 11),
                    )
                  : null,
            )
          : FilledButton.icon(
              key: key,
              onPressed: onPressed,
              icon: icon,
              label: text,
            ),
    );
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
    if (!s.canImportManually) {
      message('읽기 전용 · 수동 가져오기 권한이 없습니다.');
      return;
    }
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
      if (!mounted) return;
      final trusted = await showDialog<bool>(
        context: context,
        builder: (ctx) => IeumDialog(
          title: const Text('신뢰할 수 있는 통합본인가요?'),
          content: const Text(
            '수동 JSON은 GitHub에서 검증된 통합본과 다릅니다. 출처를 확인한 파일만 가져오세요. 현재 프로젝트의 업무 데이터가 변경되며 충돌은 자동 덮어쓰지 않습니다.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('출처 확인 · 가져오기'),
            ),
          ],
        ),
      );
      if (trusted != true || !mounted) return;
      final result = s.importManualSnapshot(
        jsonDecode(await file.readAsString()),
        trusted: true,
      );

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
    rememberView(() {
      page = 4;
    });
    refreshNotificationHistory();
  }

  void refreshNotificationHistory() {
    final projects = notificationProjectList();
    final result = <Map<String, dynamic>>[];
    if (projects.isEmpty) {
      for (final notification in s.notifications) {
        final taskDetails = notificationTaskDetails(s, notification);
        result.add({
          ...notification,
          ...taskDetails,
          'projectPath': s.filename,
          'projectName': s.project?.name ?? '현재 프로젝트',
          'projectSlug': '로컬',
          'searchableText':
              '${notification['title'] ?? ''} ${notification['reason'] ?? ''} ${taskDetails['taskDescription'] ?? ''} ${taskDetails['taskReworkReason'] ?? ''}',
        });
      }
    }
    for (final project in projects) {
      TaskStore? snapshot;
      try {
        final source = project.path == s.filename
            ? s
            : File(project.path).existsSync()
            ? snapshot = TaskStore(project.path)
            : null;
        if (source == null ||
            !source.isProject ||
            source.profileId != s.profileId) {
          continue;
        }
        for (final notification in source.notifications) {
          final taskDetails = notificationTaskDetails(source, notification);
          result.add({
            ...notification,
            ...taskDetails,
            'projectPath': project.path,
            'projectName': project.name,
            'projectSlug': project.config.slug,
            'searchableText':
                '${notification['title'] ?? ''} ${notification['reason'] ?? ''} ${taskDetails['taskDescription'] ?? ''} ${taskDetails['taskReworkReason'] ?? ''}',
          });
        }
      } catch (_) {
        // A damaged or unavailable project DB does not hide other inboxes.
      } finally {
        snapshot?.dispose();
      }
    }
    result.sort((a, b) {
      final left = DateTime.tryParse('${a['createdAt']}') ?? DateTime(1970);
      final right = DateTime.tryParse('${b['createdAt']}') ?? DateTime(1970);
      return right.compareTo(left);
    });
    if (mounted) setState(() => notificationHistory = result);
  }

  Map<String, dynamic> notificationTaskDetails(
    TaskStore source,
    Map<String, dynamic> notification,
  ) {
    final taskId = notification['taskId'];
    if (taskId is! String) return const {};
    try {
      final task = source.find(taskId);
      return {
        'taskTitle': task.title,
        'taskDescription': task.description,
        'taskStatus': source.workflowStatusName(task.status),
        'taskPart': task.part,
        'taskPriority': priorities[task.priority] ?? task.priority,
        'taskAssigneeName': source.member(task.assigneeId).name,
        'taskReviewerName': source.member(task.reviewerId).name,
        'taskAssignedDate': task.assignedDate,
        'taskDueDate': task.dueDate,
        'taskCompletedDate': task.completedDate,
        'taskReworkReason': task.reworkReason,
      };
    } catch (_) {
      // Older notifications remain readable after the task is removed.
      return const {};
    }
  }

  bool isMyMention(Map<String, dynamic> notification) {
    final mentions = notification['mentions'];
    if (notification['isMention'] == true ||
        '${notification['eventType']}'.toLowerCase().contains('mention') ||
        mentions is List && mentions.contains(s.profileId)) {
      return true;
    }
    final text = '${notification['searchableText'] ?? ''}'.toLowerCase();
    final login = s.actor.login.trim();
    final name = s.actor.name.trim();
    return login.isNotEmpty && text.contains('@${login.toLowerCase()}') ||
        name.isNotEmpty && text.contains('@${name.toLowerCase()}');
  }

  void markNotificationRead(Map<String, dynamic> notification) {
    final path = notification['projectPath'] as String? ?? s.filename;
    final id = notification['id'] as String?;
    if (id == null) return;
    if (path == s.filename) {
      s.markNotificationRead(id);
    } else {
      TaskStore? snapshot;
      try {
        snapshot = TaskStore(path);
        snapshot.markNotificationRead(id);
      } catch (_) {
        message('알림을 읽음 처리하지 못했습니다. 프로젝트 DB를 확인하세요.');
      } finally {
        snapshot?.dispose();
      }
    }
    refreshNotificationHistory();
  }

  void markVisibleNotificationsRead(List<Map<String, dynamic>> visible) {
    for (final notification in visible.where((n) => n['read'] != true)) {
      final path = notification['projectPath'] as String? ?? s.filename;
      final id = notification['id'] as String?;
      if (id == null) continue;
      if (path == s.filename) {
        s.markNotificationRead(id);
      } else {
        TaskStore? snapshot;
        try {
          snapshot = TaskStore(path);
          snapshot.markNotificationRead(id);
        } catch (_) {
          // Leave inaccessible inboxes unchanged.
        } finally {
          snapshot?.dispose();
        }
      }
    }
    refreshNotificationHistory();
  }

  Widget notificationsPage() {
    final projectValues = <String, String>{'all': '모든 프로젝트'};
    for (final project in notificationProjectList()) {
      projectValues[project.path] = project.name;
    }
    return NotificationInbox(
      notifications: [
        for (final notification in notificationHistory)
          {...notification, 'isMyMention': isMyMention(notification)},
      ],
      projects: projectValues,
      selectedProject: notificationProject,
      selectedNotificationKey: selectedNotificationKey,
      unreadOnly: unreadNotificationsOnly,
      mentionsOnly: myMentionsOnly,
      onSelect: (notification) => rememberView(() {
        selectedNotificationKey =
            '${notification['projectPath']}:${notification['id']}';
      }),
      onCloseDetail: () => rememberView(() => selectedNotificationKey = null),
      onProjectChanged: (value) => rememberView(() {
        notificationProject = value;
        selectedNotificationKey = null;
      }),
      onUnreadChanged: (value) => rememberView(() {
        unreadNotificationsOnly = value;
        selectedNotificationKey = null;
      }),
      onMentionsChanged: (value) => rememberView(() {
        myMentionsOnly = value;
        selectedNotificationKey = null;
      }),
      onResetFilters: () => rememberView(() {
        notificationProject = 'all';
        unreadNotificationsOnly = false;
        myMentionsOnly = false;
        selectedNotificationKey = null;
      }),
      onRefresh: refreshNotificationHistory,
      onRead: markNotificationRead,
      onReadVisible: markVisibleNotificationsRead,
    );
  }

  List<SavedProject> notificationProjectList() {
    final projects = [...widget.notificationProjects];
    if (s.isProject && !projects.any((p) => p.path == s.filename)) {
      try {
        final raw = s.meta('github.config');
        if (raw.isNotEmpty) {
          projects.add(
            SavedProject(
              path: s.filename,
              name: s.project!.name,
              projectId: s.project!.id,
              config: GitHubConfig.fromJson(
                Map<String, dynamic>.from(jsonDecode(raw)),
              ),
            ),
          );
        }
      } catch (_) {
        // A project with an unreadable GitHub config can still show its active inbox.
      }
    }
    return projects;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: s,
    builder: (_, _) {
      final tasks = s.tasks;
      final all = tasks.where((t) => !t.isArchived).toList();
      final filtered = tasks
          .where(
            (t) =>
                (t.isArchived == (scope == 'archived')) &&
                (statusFilter.isEmpty ||
                    (statusFilter.startsWith('category:')
                        ? boardCategory(t) == statusFilter.substring(9)
                        : t.status == statusFilter)) &&
                matchesDeadline(t) &&
                (relatedMember.isEmpty ||
                    t.assigneeId == relatedMember ||
                    t.reviewerId == relatedMember) &&
                (part.isEmpty || t.part == part) &&
                (search.isEmpty ||
                    ('${t.title} ${t.id} ${t.description}')
                        .toLowerCase()
                        .contains(search.toLowerCase())) &&
                (scope == 'all' ||
                    scope == 'archived' ||
                    scope == 'mine' &&
                        s.isAssignedToMe(t) &&
                        !s.isCompleted(t) ||
                    scope == 'review' &&
                        wasTransferred(t) &&
                        s.isAssignedToMe(t) &&
                        !s.isCompleted(t)),
          )
          .toList();
      filtered.sort(compareTasks);
      final pageCount = max(1, (filtered.length / 50).ceil());
      final visiblePage = taskPage.clamp(0, pageCount - 1);
      final content = Column(
        children: [
          if (widget.sessionNotice?.isNotEmpty == true)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 10),
              color: const Color(0xfffff6e8),
              child: Text(
                widget.sessionNotice!,
                style: const TextStyle(fontSize: 11, color: Color(0xff896b37)),
              ),
            ),
          Expanded(
            child: page == 0
                ? ProjectScheduleView(
                    key: Key('schedule-page'),
                    store: s,
                    onOpenTask: details,
                    onEditTask: edit,
                    onCreateTask: (date) => edit(null, date),
                  )
                : page == 5
                ? ProjectConnectionsView(
                    key: const Key('connections-page'),
                    store: s,
                    sync: widget.sync,
                    onOpenSettings: () =>
                        selectSettings(SettingsSection.github),
                    onOpenWorkflow: () =>
                        selectSettings(SettingsSection.projectGeneral),
                    onOpenMembers: () => selectSettings(SettingsSection.team),
                  )
                : page == 4
                ? notificationsPage()
                : isTaskPage
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
                                      Text(
                                        s.project?.name ?? '예시 작업 공간',
                                        key: const Key(
                                          'workspace-project-name',
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: muted,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Text(
                                        isTaskPage ? titles[0] : '설정',
                                        style: const TextStyle(
                                          fontSize: 27,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: -1,
                                        ),
                                      ),
                                      const SizedBox(height: 9),
                                      Text(
                                        isTaskPage
                                            ? subtitles[0]
                                            : '프로젝트 설정과 개인 변경내역을 관리하세요.',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: muted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (isTaskPage)
                                  FilledButton.icon(
                                    key: const Key('new-task'),
                                    onPressed: s.canCreate
                                        ? () => edit()
                                        : null,
                                    icon: const Icon(Icons.add, size: 18),
                                    label: const Text(
                                      '작업 등록',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 30),
                            if (s.isProject && s.actor.role == 'pending')
                              info(
                                '가입 승인 대기 중입니다. 관리자가 역할을 부여하면 자동 동기화 후 작업을 진행할 수 있습니다.',
                              ),
                            if (s.isProject &&
                                s.actor.role != 'pending' &&
                                !s.actor.active)
                              info(
                                '비활성화된 참여자입니다. 작업 수정·진행·업로드가 차단됩니다. 관리자에게 활성화를 요청하세요.',
                              ),
                            if (isTaskPage) ...[
                              const Text(
                                '프로젝트 전체 현황',
                                key: Key('project-stats-scope'),
                              ),
                              const SizedBox(height: 8),
                              stats(all),
                              if (relatedMember.isNotEmpty)
                                InputChip(
                                  label: Text(
                                    '${s.member(relatedMember).name} · 관련 업무',
                                  ),
                                  onDeleted: () =>
                                      setState(() => relatedMember = ''),
                                ),
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
                                          ? '확인중 → 진행중 → 완료 · 전달 시 상태 유지'
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
                              if (filtered.isEmpty && taskView == TaskView.list)
                                emptyTasks()
                              else if (taskView == TaskView.kanban)
                                board(
                                  filtered,
                                  constraints.maxWidth -
                                      (constraints.maxWidth < 700 ? 32 : 68),
                                )
                              else ...[
                                schedule(
                                  filtered
                                      .skip(visiblePage * 50)
                                      .take(50)
                                      .toList(),
                                ),
                                if (pageCount > 1)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 18),
                                    child: Wrap(
                                      spacing: 12,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Text(
                                          '${visiblePage * 50 + 1}–${min((visiblePage + 1) * 50, filtered.length)} / ${filtered.length}',
                                          style: const TextStyle(
                                            color: muted,
                                            fontSize: 12,
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: '이전 페이지',
                                          onPressed: visiblePage > 0
                                              ? () => setState(
                                                  () => taskPage =
                                                      visiblePage - 1,
                                                )
                                              : null,
                                          icon: const Icon(Icons.chevron_left),
                                        ),
                                        Text('${visiblePage + 1} / $pageCount'),
                                        IconButton(
                                          tooltip: '다음 페이지',
                                          onPressed: visiblePage + 1 < pageCount
                                              ? () => setState(
                                                  () => taskPage =
                                                      visiblePage + 1,
                                                )
                                              : null,
                                          icon: const Icon(Icons.chevron_right),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ],
                          ],
                        ),
                      ),
                    ),
                  )
                : SettingsShell(
                    personal: settingsSection == SettingsSection.general,
                    projectName: s.project?.name ?? '예시 작업 공간',
                    projectSelector:
                        widget.projectSwitcherBuilder?.call(
                          () => selectSettings(SettingsSection.projectGeneral),
                        ) ??
                        widget.projectSwitcher,
                    selected: settingsSection,
                    onSelected: selectSettings,
                    contentBuilder: settingsContent,
                    contentOnly: true,
                    workflowStages:
                        s.project?.workflowStages ?? defaultWorkflowStages,
                    workflowProjectId: s.project?.id,
                    workflowRoles:
                        s.project?.partWorkflowView.roles ?? const [],
                    workflowPeople:
                        s.project?.partWorkflowView.people ?? const [],
                    workflowParts:
                        s.project?.partWorkflowView.parts ?? const [],
                  ),
          ),
        ],
      );
      return Scaffold(
        backgroundColor: iconRailSurface,
        body: LayoutBuilder(
          builder: (context, bounds) {
            final docked = bounds.maxWidth >= 1000;
            return Row(
              children: [
                sidebar(),
                Expanded(
                  child: Material(
                    color: canvas,
                    elevation: 4,
                    shadowColor: const Color(0x40000000),
                    surfaceTintColor: Colors.transparent,
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(16),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Row(
                      children: [
                        if (page == 1 || page == 2)
                          SettingsShell(
                            key: const Key('settings-sidebar-view'),
                            personal:
                                settingsSection == SettingsSection.general,
                            projectName: s.project?.name ?? '예시 작업 공간',
                            projectSelector:
                                widget.projectSwitcherBuilder?.call(
                                  () => selectSettings(
                                    SettingsSection.projectGeneral,
                                  ),
                                ) ??
                                widget.projectSwitcher,
                            selected: settingsSection,
                            onSelected: selectSettings,
                            contentBuilder: settingsContent,
                            navigationOnly: true,
                          )
                        else if (docked && hasProjectSidebar)
                          dockedProjectView(),
                        Expanded(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              content,
                              if (!docked && hasProjectSidebar)
                                overlayProjectView(bounds.maxWidth - 56),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      );
    },
  );
  void selectSettings(SettingsSection section) => rememberView(() {
    settingsSection = section;
    page = section == SettingsSection.changes ? 1 : 2;
  });

  void toggleProjectView() {
    if (!hasProjectSidebar) return;
    setState(() {
      projectViewOpen = !projectViewOpen;
      s.setMeta('ui.projectView', projectViewOpen ? 'open' : 'closed');
    });
    _syncProjectView(animate: true);
    _configureTitlebar();
  }

  Widget contextSidebar() => projectView();

  Widget dockedProjectView() => AnimatedBuilder(
    animation: _projectViewAnimation,
    child: contextSidebar(),
    builder: (context, sidebar) {
      final progress = _projectViewAnimation.value.clamp(0.0, 1.04).toDouble();
      if (!projectViewOpen && progress < .005) {
        return const SizedBox.shrink();
      }
      final slide = progress.clamp(0.0, 1.0).toDouble();
      return ClipRect(
        child: SizedBox(
          width: 210 * progress,
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 210,
            maxWidth: 210,
            child: Transform.translate(
              offset: Offset(-24 * (1 - slide), 0),
              child: sidebar,
            ),
          ),
        ),
      );
    },
  );

  Widget overlayProjectView(double availableWidth) => AnimatedBuilder(
    animation: _projectViewAnimation,
    child: contextSidebar(),
    builder: (context, sidebar) {
      final progress = _projectViewAnimation.value.clamp(0.0, 1.0).toDouble();
      if (!projectViewOpen && progress < .005) {
        return const SizedBox.shrink();
      }
      final width = min(210.0, availableWidth);
      return Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            key: const Key('project-view-barrier'),
            onTap: toggleProjectView,
            child: ColoredBox(
              color: Colors.black.withValues(alpha: .12 * progress),
            ),
          ),
          Positioned(
            left: (progress - 1) * width,
            top: 0,
            bottom: 0,
            width: width,
            child: sidebar!,
          ),
        ],
      );
    },
  );

  Widget projectView() {
    final picker =
        widget.projectSwitcherBuilder?.call(
          () => selectSettings(SettingsSection.projectGeneral),
        ) ??
        widget.projectSwitcher;
    return Container(
      key: const Key('project-view-sidebar'),
      width: 210,
      decoration: const BoxDecoration(
        color: Color(0xfff8f9f8),
        border: Border(right: BorderSide(color: Color(0xffe1e4e3))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 18, 8, 18),
            child: Text(
              '프로젝트',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  picker ?? Text(s.project?.name ?? '예시 작업 공간'),
                  const SizedBox(height: 14),
                  const Divider(height: 1, color: Color(0xffe1e4e3)),
                  const SizedBox(height: 10),
                  projectViewTab(
                    key: 'project-view-tab-tasks',
                    title: '작업',
                    icon: Icons.view_kanban_outlined,
                    targetPage: 6,
                  ),
                  const SizedBox(height: 4),
                  projectViewTab(
                    key: 'project-view-tab-schedule',
                    title: '일정',
                    icon: Icons.calendar_month_outlined,
                    targetPage: 0,
                  ),
                  const SizedBox(height: 4),
                  projectViewTab(
                    key: 'project-view-tab-connections',
                    title: '연결',
                    icon: Icons.link,
                    targetPage: 5,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget sidebar() => Container(
    key: const Key('workspace-sidebar'),
    width: 56,
    decoration: const BoxDecoration(color: iconRailSurface),
    padding: const EdgeInsets.fromLTRB(6, 12, 6, 12),
    child: Column(
      children: [
        railButton(
          'project-home',
          '${s.project?.name ?? '현재 프로젝트'} 홈',
          Icons.home_outlined,
          () => rememberView(() => page = 6),
          selected: isTaskPage,
        ),
        const SizedBox(height: 8),
        IconButton(
          key: const Key('sidebar-notifications'),
          tooltip: s.isProject ? '내 알림' : '알림 미리보기',
          onPressed: notifications,
          style: IconButton.styleFrom(
            backgroundColor: page == 4 ? iconRailSelected : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          constraints: const BoxConstraints.tightFor(width: 44, height: 44),
          padding: EdgeInsets.zero,
          icon: Badge(
            isLabelVisible: s.unreadNotificationCount > 0,
            smallSize: 5,
            backgroundColor: purple,
            child: const Icon(
              Icons.notifications_none_outlined,
              size: 21,
              color: iconRailMuted,
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Spacer(),
        AccountMenu(
          name: s.actor.name,
          role: s.isProject ? s.actor.roleLabel : '테스트 사용자',
          avatar: avatar(s.actor),
          onSettings: () => selectSettings(SettingsSection.general),
          onProjectSettings: () =>
              selectSettings(SettingsSection.projectGeneral),
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
      backgroundColor: selected ? iconRailSelected : Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    icon: Icon(
      icon,
      size: 21,
      color: selected ? iconRailActive : iconRailMuted,
    ),
  );

  Widget projectViewTab({
    required String key,
    required String title,
    required IconData icon,
    required int targetPage,
  }) => SizedBox(
    height: 40,
    child: TextButton.icon(
      key: Key(key),
      onPressed: () => rememberView(() => page = targetPage),
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft,
        foregroundColor: page == targetPage ? ink : muted,
        backgroundColor: page == targetPage
            ? const Color(0xffe9edeb)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
      ),
      icon: Icon(icon, size: 17),
      label: Text(title),
    ),
  );

  Widget stats(List<WorkTask> tasks) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 760 ? 4 : 2;
      final width = (constraints.maxWidth - (columns - 1) * 15) / columns;
      final labels = ['전체 작업', '확인중', '진행중', '완료'];
      final counts = [
        tasks.length,
        tasks.where((task) => boardCategory(task) == 'todo').length,
        tasks.where((task) => boardCategory(task) == 'inProgress').length,
        tasks.where(s.isCompleted).length,
      ];
      return Wrap(
        spacing: 15,
        runSpacing: 15,
        children: List.generate(
          4,
          (i) => SizedBox(
            width: width,
            child: Container(
              constraints: BoxConstraints(minHeight: columns == 4 ? 106 : 82),
              padding: EdgeInsets.all(columns == 4 ? 20 : 12),
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
                          labels[i],
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
                                text: '${counts[i]}',
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
                        Icons.play_arrow_outlined,
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
  bool matchesDeadline(WorkTask task) {
    if (deadlineFilter.isEmpty) return true;
    if (deadlineFilter == 'none') return task.dueDate.isEmpty;
    if (task.dueDate.isEmpty || s.isCompleted(task)) return false;
    final today = localDate();
    return deadlineFilter == 'overdue'
        ? task.dueDate.compareTo(today) < 0
        : task.dueDate == today;
  }

  int compareTasks(WorkTask a, WorkTask b) {
    final pinned = compareTaskPins(a, b);
    if (pinned != 0) return pinned;
    final order = switch (taskSort) {
      'due' => (a.dueDate.isEmpty ? '9999' : a.dueDate).compareTo(
        b.dueDate.isEmpty ? '9999' : b.dueDate,
      ),
      'priority' =>
        const {'high': 0, 'normal': 1, 'low': 2}[a.priority]!.compareTo(
          const {'high': 0, 'normal': 1, 'low': 2}[b.priority]!,
        ),
      'title' => a.title.compareTo(b.title),
      _ => (b.data['updatedAt'] as String).compareTo(
        a.data['updatedAt'] as String,
      ),
    };
    return order == 0 ? a.id.compareTo(b.id) : order;
  }

  void clearTaskFilters() => setState(() {
    search = part = statusFilter = deadlineFilter = relatedMember = '';
    taskSearch.clear();
    taskPage = 0;
  });

  Widget emptyTasks() => Container(
    key: Key(taskView == TaskView.list ? 'task-list' : 'task-kanban'),
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 56),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: border),
    ),
    child: Column(
      children: [
        Icon(
          scope == 'archived'
              ? Icons.inventory_2_outlined
              : Icons.task_alt_rounded,
          size: 30,
          color: muted,
        ),
        const SizedBox(height: 14),
        Text(
          scope == 'archived' ? '보관한 작업이 없습니다' : '표시할 작업이 없습니다',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          search.isNotEmpty ||
                  part.isNotEmpty ||
                  statusFilter.isNotEmpty ||
                  deadlineFilter.isNotEmpty
              ? '검색어나 필터를 바꾸어 보세요.'
              : scope == 'archived'
              ? '작업 상세에서 보관한 항목을 여기서 확인하고 복원할 수 있습니다.'
              : scope != 'all'
              ? '배정받은 작업이 생기면 여기에 표시됩니다.'
              : '첫 작업을 등록하고 팀의 흐름을 시작하세요.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: muted, fontSize: 12),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (search.isNotEmpty ||
                part.isNotEmpty ||
                statusFilter.isNotEmpty ||
                deadlineFilter.isNotEmpty ||
                relatedMember.isNotEmpty)
              OutlinedButton(
                onPressed: clearTaskFilters,
                child: const Text('필터 초기화'),
              ),
            if (s.canCreate && scope == 'all')
              FilledButton.icon(
                onPressed: () => edit(),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('작업 등록'),
              ),
          ],
        ),
      ],
    ),
  );

  Widget taskFilter(
    String key,
    String value,
    Map<String, String> values,
    ValueChanged<String> onChanged,
  ) => SizedBox(
    width: 140,
    child: IeumSelect(
      key: ValueKey('$key-$value'),
      value: values.containsKey(value) ? value : '',
      values: values,
      onChanged: (value) => setState(() {
        taskPage = 0;
        onChanged(value);
      }),
    ),
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
            'review': '전달받은 작업',
            'archived': '보관함',
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
                onPressed: () => setState(() {
                  scope = entry.key;
                  taskPage = 0;
                }),
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
          textStyle: const TextStyle(fontFamily: 'Malgun Gothic', fontSize: 12),
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
              controller: taskSearch,
              style: const TextStyle(fontSize: 11),
              onChanged: (value) => setState(() {
                search = value;
                taskPage = 0;
              }),
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
              onChanged: (value) => setState(() {
                part = value;
                taskPage = 0;
              }),
            ),
          ),
          taskFilter('status-filter', statusFilter, {
            '': '모든 상태',
            'category:todo': '확인중',
            'category:inProgress': '진행중',
            'category:done': '완료',
          }, (value) => statusFilter = value),
          taskFilter('deadline-filter', deadlineFilter, {
            '': '모든 마감일',
            'overdue': '마감 지남',
            'today': '오늘 마감',
            'none': '마감 미정',
          }, (value) => deadlineFilter = value),
          taskFilter('task-sort', taskSort, {
            'updated': '최근 수정순',
            'due': '마감일순',
            'priority': '우선순위순',
            'title': '이름순',
          }, (value) => taskSort = value),
          if (search.isNotEmpty ||
              part.isNotEmpty ||
              statusFilter.isNotEmpty ||
              deadlineFilter.isNotEmpty ||
              relatedMember.isNotEmpty)
            IconButton(
              tooltip: '필터 초기화',
              onPressed: clearTaskFilters,
              icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
            ),
        ],
      ),
    ],
  );
  Widget board(List<WorkTask> tasks, double available) => HorizontalViewport(
    key: const Key('task-kanban'),
    child: SizedBox(
      width: max(available, 760.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: boardStatuses.entries.map((stage) {
          final category = stage.key == 'doing' ? 'inProgress' : stage.key;
          final list = tasks
              .where((t) => boardCategory(t) == category)
              .toList();
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: stage.key == 'done' ? 0 : 13),
              child: DragTarget<WorkTask>(
                onWillAcceptWithDetails: (d) =>
                    !handoffOpen &&
                    s
                        .availableHandoffs(d.data)
                        .any(
                          (plan) =>
                              destinationCategory(plan.destinationId) ==
                              category,
                        ),
                onAcceptWithDetails: (d) => moveToCategory(d.data, category),
                builder: (ctx, candidates, rejected) => Container(
                  key: Key('column-${stage.key}'),
                  constraints: const BoxConstraints(minHeight: 425),
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: candidates.isNotEmpty
                        ? const Color(0xffeae3f8)
                        : stageSurfaceColor(stage.key),
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
                          Expanded(
                            child: Tooltip(
                              message: stage.value,
                              child: Text(
                                stage.value,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          badge('${list.length}'),
                          if (s.canCreate &&
                              stage.key == 'todo' &&
                              scope != 'archived')
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: '새 작업 등록',
                              onPressed: () => edit(),
                              icon: const Icon(
                                Icons.add,
                                size: 16,
                                color: muted,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ...list
                          .take(50)
                          .map(
                            (t) => Padding(
                              padding: const EdgeInsets.only(bottom: 11),
                              child: Draggable<WorkTask>(
                                data: t,
                                feedback: Material(
                                  color: Colors.transparent,
                                  child: SizedBox(
                                    width: 200,
                                    child: taskCard(t, interactive: false),
                                  ),
                                ),
                                childWhenDragging: Opacity(
                                  opacity: .35,
                                  child: taskCard(t, interactive: false),
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
                      if (list.length > 50)
                        TextButton(
                          onPressed: () => setState(() {
                            statusFilter = 'category:$category';
                            taskPage = 0;
                            taskView = TaskView.list;
                          }),
                          child: Text('전체 ${list.length}개 목록에서 보기'),
                        ),
                      if (s.canCreate &&
                          stage.key == 'todo' &&
                          scope != 'archived')
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
  void toggleTaskPin(WorkTask task) => action(() {
    s.setTaskPinned(task.id, !task.isPinned, expectedVersion: task.version);
    if (!task.isPinned) setState(() => taskPage = 0);
  });

  Widget taskPinButton(WorkTask task, String surface) => IconButton(
    key: Key('task-pin-$surface-${task.id}'),
    tooltip: task.isPinned ? '상단 고정 해제' : '상단에 고정',
    onPressed: s.canPin(task) ? () => toggleTaskPin(task) : null,
    constraints: const BoxConstraints.tightFor(width: 28, height: 28),
    padding: EdgeInsets.zero,
    icon: Icon(
      task.isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
      size: 16,
      color: task.isPinned ? purple : muted,
    ),
  );

  Widget taskCard(WorkTask t, {bool interactive = true}) {
    final handoffs = taskActions(t);
    final openStage = s.isOpenTaskStage(t);
    return Material(
      key: interactive ? Key('card-${t.id}') : null,
      color: Colors.white,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: interactive ? () => details(t) : null,
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
                  Flexible(
                    child: Tooltip(
                      message: workflowCurrentPartLabel(t, s.project),
                      child: badge(workflowCurrentPartLabel(t, s.project)),
                    ),
                  ),
                  taskPinButton(t, 'card'),
                  const SizedBox(width: 4),
                  if (t.isLocked) ...[
                    Tooltip(
                      message: '${s.member(t.lockedBy).name}님만 수정 가능',
                      child: const Icon(
                        Icons.lock_outline_rounded,
                        size: 14,
                        color: muted,
                      ),
                    ),
                    const SizedBox(width: 5),
                  ],
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
                    '기존 코멘트를 확인하세요',
                    style: TextStyle(fontSize: 9, color: statusColor('rework')),
                  ),
                ),
              const SizedBox(height: 15),
              Text(
                '담당 · ${s.currentActorLabel(t)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 10, color: muted),
              ),
              const SizedBox(height: 5),
              Text(
                '목적 · ${purposeLabel(t)}',
                key: interactive ? Key('task-purpose-${t.id}') : null,
                style: const TextStyle(fontSize: 10, color: muted),
              ),
              const SizedBox(height: 12),
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
                    message: openStage ? '모든 작업자' : s.currentActorLabel(t),
                    child:
                        !t.isLocked &&
                            (openStage ||
                                s.project?.workflowSheet != null &&
                                    t.workflowPerson.isEmpty)
                        ? const Icon(
                            Icons.groups_outlined,
                            size: 22,
                            color: muted,
                          )
                        : avatar(
                            s.member(
                              t.isLocked
                                  ? t.lockedBy
                                  : s.project?.workflowSheet != null &&
                                        t.workflowPerson.isNotEmpty
                                  ? t.workflowPerson
                                  : s.currentActorId(t),
                            ),
                            size: 25,
                          ),
                  ),
                ],
              ),
              if (s.isWaitingForReview(t)) ...[
                const Divider(height: 24, color: border),
                Row(
                  children: [
                    Icon(
                      Icons.arrow_forward,
                      size: 12,
                      color: statusColor(t.status),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        s.project?.workflowSheet != null
                            ? '${s.currentActorLabel(t)} · 검토 요청'
                            : openStage
                            ? '모든 작업자 검토 대기'
                            : '${s.member(t.reviewerId).name} 검토 대기',
                        style: TextStyle(
                          fontSize: 9,
                          color: statusColor(t.status),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (handoffs.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final plan in handoffs)
                      handoffButton(
                        plan,
                        compact: true,
                        interactive: interactive,
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget schedule(List<WorkTask> tasks) => LayoutBuilder(
    builder: (context, constraints) => constraints.maxWidth < 700
        ? compactSchedule(tasks)
        : scheduleTable(tasks),
  );

  Widget compactSchedule(List<WorkTask> tasks) => Material(
    key: const Key('task-list'),
    color: Colors.white,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: const BorderSide(color: border),
    ),
    child: Column(
      children: [
        for (var i = 0; i < tasks.length; i++) ...[
          if (i > 0) const Divider(height: 1, color: border),
          InkWell(
            key: Key('compact-task-${tasks[i].id}'),
            onTap: () => details(tasks[i]),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tasks[i].title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      taskPinButton(tasks[i], 'compact'),
                      const SizedBox(width: 12),
                      badge(
                        boardStatuses[boardKey(tasks[i])]!,
                        color: statusColor(boardKey(tasks[i])),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 12,
                    runSpacing: 6,
                    children: [
                      Text(
                        '${workflowCurrentPartLabel(tasks[i], s.project)} · ${s.currentActorLabel(tasks[i])}',
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                      Text(
                        '목적 · ${purposeLabel(tasks[i])}',
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                      Text(
                        '마감 ${tasks[i].dueDate.isEmpty ? '미정' : tasks[i].dueDate}',
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                      Text(
                        priorities[tasks[i].priority]!,
                        style: TextStyle(
                          fontSize: 12,
                          color: priorityColor(tasks[i].priority),
                        ),
                      ),
                    ],
                  ),
                  if (taskActions(tasks[i]).isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final plan in taskActions(tasks[i]))
                          handoffButton(plan, compact: true, surface: 'list'),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ],
    ),
  );

  Widget scheduleTable(List<WorkTask> tasks) => Container(
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
        columnSpacing: 20,
        headingRowHeight: 49,
        dataRowMinHeight: 70,
        dataRowMaxHeight: 110,
        headingTextStyle: const TextStyle(fontSize: 12, color: muted),
        dataTextStyle: const TextStyle(fontSize: 12, color: ink),
        dividerThickness: .5,
        columns: [
          '작업내용',
          '상태',
          '등록 담당자',
          '현재 처리자',
          '우선순위',
          '작업 지정일',
          '마감일',
          '완료일',
          '작업 처리',
        ].map((label) => DataColumn(label: Text(label))).toList(),
        rows: tasks
            .map(
              (t) => DataRow(
                onSelectChanged: (_) => details(t),
                cells: [
                  DataCell(
                    SizedBox(
                      width: 215,
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '${t.part} · ${shortId(t.id)}',
                                  style: const TextStyle(
                                    fontSize: 9,
                                    color: muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          taskPinButton(t, 'list'),
                        ],
                      ),
                    ),
                  ),
                  DataCell(
                    badge(
                      boardStatuses[boardKey(t)]!,
                      color: statusColor(boardKey(t)),
                    ),
                  ),
                  DataCell(Text(s.member(t.assigneeId).name)),
                  DataCell(
                    SizedBox(
                      width: 120,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            s.isOpenTaskStage(t)
                                ? '모든 작업자'
                                : s.currentActorLabel(t),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${workflowCurrentPartLabel(t, s.project)} · ${purposeLabel(t)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10, color: muted),
                          ),
                        ],
                      ),
                    ),
                  ),
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
                  DataCell(tableTaskActions(t)),
                ],
              ),
            )
            .toList(),
      ),
    ),
  );
  Widget tableTaskActions(WorkTask task) {
    final plans = taskActions(task);
    if (plans.isEmpty) return const SizedBox(width: 228);
    return SizedBox(
      width: 228,
      child: Row(
        children: [
          Expanded(
            child: handoffButton(plans.first, compact: true, surface: 'list'),
          ),
          if (plans.length > 1) ...[
            const SizedBox(width: 6),
            PopupMenuButton<TaskHandoffPlan>(
              key: Key('task-actions-more-${task.id}'),
              tooltip: '다른 작업 처리',
              enabled: !handoffOpen,
              icon: const Icon(Icons.more_horiz_rounded, size: 20),
              onSelected: confirmHandoff,
              itemBuilder: (_) => [
                for (final plan in plans.skip(1))
                  PopupMenuItem(
                    value: plan,
                    child: Text(
                      '${plan.buttonLabel} · ${plan.recipientLabel}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget changesPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      heading(
        '통합 전 변경 ${s.changes.length}건',
        '작업에서 저장한 변경 내용입니다. 전송 진행 상황은 GitHub 동기화에서 확인하세요.',
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
                          taskChangeValue(f['key'], f['before']),
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
                          taskChangeValue(f['key'], f['after']),
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
      const SizedBox(height: 20),
      ExpansionTile(
        key: const Key('manual-transfer'),
        tilePadding: EdgeInsets.zero,
        title: const Text('수동 가져오기 · 내보내기', style: TextStyle(fontSize: 13)),
        subtitle: const Text(
          '자동 동기화를 사용할 수 없을 때',
          style: TextStyle(fontSize: 12, color: muted),
        ),
        childrenPadding: const EdgeInsets.only(bottom: 16),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Wrap(
              spacing: 10,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: fileBusy || !s.canImportManually ? null : import,
                  icon: const Icon(Icons.upload_outlined, size: 16),
                  label: const Text('통합본 가져오기'),
                ),
                OutlinedButton.icon(
                  onPressed: fileBusy || s.changes.isEmpty ? null : export,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: const Text('변경안 내보내기'),
                ),
              ],
            ),
          ),
          if (!s.canImportManually) info('읽기 전용 · 수동 가져오기는 작업 변경 권한이 필요합니다.'),
        ],
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
    SettingsSection.projectGeneral => projectGeneralSettings(),
    SettingsSection.roles || SettingsSection.assignments =>
      s.isProject && widget.session != null && widget.sync != null
          ? RolesPanel(
              store: s,
              sync: widget.sync!,
              session: widget.session!,
              onMember: (id) {
                relatedMember = id;
                selectSettings(SettingsSection.team);
              },
            )
          : settingsGroup('파트', [
              ('프로젝트 필요', '프로젝트를 연결하면 파트를 관리할 수 있습니다.', ''),
            ]),
    SettingsSection.team =>
      s.isProject && widget.session != null && widget.sync != null
          ? TeamPanel(
              store: s,
              sync: widget.sync!,
              session: widget.session!,
              initialMember: relatedMember,
              onOpenTasks: (id) => rememberView(() {
                relatedMember = id;
                page = 0;
                scope = 'all';
                search = '';
                part = '';
              }),
            )
          : info('프로젝트에 로그인하면 참여자와 파트, 가입 요청을 관리할 수 있습니다.'),
    SettingsSection.workflow => info(
      '확인중 → 진행중 → 완료. 작업은 직접 전달하고 필요할 때 잠글 수 있습니다.',
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
            '작업 배정, 검토 요청, 검토 결과를 확인합니다.',
            '${s.unreadNotificationCount}개 읽지 않음',
          ),
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
    final original = s.actor.name;
    var busy = false, saved = false;
    var error = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          Future<void> save() async {
            if (busy) return;
            final name = controller.text.trim();
            if (name.isEmpty) {
              update(() => error = '이름을 입력하세요.');
              return;
            }
            update(() {
              busy = true;
              error = '';
            });
            try {
              final result = widget.onRename != null
                  ? await widget.onRename!(name)
                  : await renameCurrent(name);
              if (!ctx.mounted || !mounted) return;
              setState(() => nameNotice = result);
              update(() {
                saved = true;
                busy = false;
              });
              await WidgetsBinding.instance.endOfFrame;
              if (ctx.mounted) Navigator.pop(ctx);
            } catch (e) {
              if (ctx.mounted) {
                update(() {
                  busy = false;
                  error = '이름 저장 실패 · 초안은 유지됩니다. $e';
                });
              }
            }
          }

          return DraftGuard(
            dirty: !saved && controller.text.trim() != original,
            busy: busy,
            onSave: save,
            child: IeumDialog(
              title: const Text('이름 변경'),
              icon: Icons.edit_outlined,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    key: const Key('account-display-name'),
                    controller: controller,
                    enabled: !busy,
                    maxLength: 40,
                    onChanged: (_) => update(() {}),
                    decoration: const InputDecoration(labelText: '이름 / 닉네임'),
                  ),
                  const Text(
                    '이 컴퓨터에 연결된 참여 프로젝트에 커밋으로 반영합니다. GitHub 아이디와 기존 브랜치는 유지됩니다. 프로젝트별 실패 결과는 별도로 표시합니다.',
                  ),
                  if (controller.text.trim() != original)
                    const Text('저장하지 않은 변경사항'),
                  if (error.isNotEmpty)
                    Text(error, style: const TextStyle(color: Colors.red)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.maybePop(ctx),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: busy || controller.text.trim() == original
                      ? null
                      : save,
                  child: Text(busy ? '반영 중…' : '변경'),
                ),
              ],
            ),
          );
        },
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
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

  Widget projectGeneralSettings() => Column(
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
      settingsGroup('현재 참여 상태', [
        ('역할', '이 프로젝트에서 부여받은 권한입니다.', s.actor.roleLabel),
        ('상태', '비활성화된 참여자는 작업·업로드가 제한됩니다.', s.actor.active ? '활성화' : '비활성화'),
      ]),
    ],
  );

  Widget generalSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      settingsGroup(
        '계정',
        [
          ('이름', '참여 중인 모든 프로젝트에서 사용하는 표시 이름입니다.', s.actor.name),
          ('GitHub 계정', '표시 이름과 별개의 로그인 식별자입니다.', s.actor.login),
        ],
        actions: {
          if (s.isProject && widget.session != null)
            '이름': OutlinedButton.icon(
              key: const Key('change-account-name'),
              onPressed: nameBusy ? null : renameAccount,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: Text(nameBusy ? '이름 반영 중…' : '이름 변경'),
            ),
        },
      ),
      if (nameNotice.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SelectableText(
            nameNotice,
            style: const TextStyle(fontSize: 12),
          ),
        ),
      const SizedBox(height: 28),
      settingsGroup(
        '앱 정보',
        [('이음 버전', '새 버전을 확인하고 다운로드합니다.', appVersion)],
        actions: {'이음 버전': const UpdateButton()},
      ),
    ],
  );

  Widget settingsGroup(
    String title,
    List<(String, String, String)> rows, {
    Map<String, Widget> actions = const {},
  }) => Column(
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
                child: settingRow(rows[i], action: actions[rows[i].$1]),
              ),
            ],
          ],
        ),
      ),
    ],
  );
  Widget settingRow((String, String, String) row, {Widget? action}) =>
      LayoutBuilder(
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
          final valueText = SelectableText(
            row.$3,
            textAlign: TextAlign.left,
            style: const TextStyle(
              fontSize: 12,
              color: Color(0xff666e68),
              height: 1.5,
            ),
          );
          final value = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              valueText,
              if (action != null) ...[const SizedBox(height: 10), action],
            ],
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
  Future<void> confirmTaskDeletion(BuildContext ctx, WorkTask task) async {
    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('작업을 삭제할까요?'),
        content: Text(
          '“${task.title}”\n\n목록·칸반·일정에서 삭제됩니다. GitHub 동기화 후 팀에도 반영됩니다. 앱에서 복원할 수 없습니다.',
        ),
        actions: [
          TextButton(
            key: const Key('task-delete-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('취소'),
          ),
          FilledButton(
            key: const Key('task-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xffc44848),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('삭제'),
          ),
        ],
      ),
    );
    if (confirmed != true || !ctx.mounted) return;
    action(() {
      s.deleteTask(task.id, expectedVersion: task.version);
      Navigator.pop(ctx);
      message('작업을 삭제했습니다.');
    });
  }

  Widget detailBody(BuildContext ctx, WorkTask t) {
    if (t.isDeleted) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('삭제된 작업입니다.'),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('닫기'),
            ),
          ],
        ),
      );
    }
    final canEdit = s.canEdit(t);
    final lockReason = !s.canEditContent(t) ? s.editLockReason(t) : '';
    final history = s.activityFor(t.id);
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
          child: badge(
            boardStatuses[boardKey(t)]!,
            color: statusColor(boardKey(t)),
          ),
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
          '작업 파트': t.part,
          '잠금': t.isLocked ? '${s.member(t.lockedBy).name}만 수정 가능' : '잠금 없음',
          '등록 담당자': s.member(t.assigneeId).name,
          if (s.project?.workflowSheet == null)
            '검토 담당자': s.member(t.reviewerId).name,
          '현재 처리자': s.isOpenTaskStage(t) ? '모든 작업자' : s.currentActorLabel(t),
          '현재 파트': workflowCurrentPartLabel(t, s.project),
          '처리 목적': purposeLabel(t),
          if (t.workflowSender.isNotEmpty)
            '직전 전달자': s.member(t.workflowSender).name,
          if (!const {'todo', 'doing', 'done'}.contains(t.status))
            '세부 상태': s.workflowStatusName(t.status),
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
              '최근 전달 코멘트\n${t.reworkReason}',
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
            if (t.isArchived)
              const Chip(
                label: Text('보관된 작업'),
                avatar: Icon(Icons.inventory_2_outlined, size: 16),
              ),
            if (s.canPin(t))
              OutlinedButton.icon(
                key: Key('task-pin-detail-${t.id}'),
                onPressed: () => toggleTaskPin(t),
                icon: Icon(
                  t.isPinned ? Icons.push_pin_rounded : Icons.push_pin_outlined,
                  size: 16,
                ),
                label: Text(t.isPinned ? '상단 고정 해제' : '상단에 고정'),
              ),
            if (s.canSetTaskLock(t))
              OutlinedButton.icon(
                key: Key('task-lock-${t.id}'),
                onPressed: () => action(() {
                  s.setTaskLocked(
                    t.id,
                    !t.isLocked,
                    expectedVersion: t.version,
                  );
                }),
                icon: Icon(
                  t.isLocked
                      ? Icons.lock_open_rounded
                      : Icons.lock_outline_rounded,
                  size: 16,
                ),
                label: Text(t.isLocked ? '잠금 해제' : '내 작업으로 잠금'),
              ),
            if (canEdit)
              OutlinedButton(
                onPressed: () => edit(t),
                child: Text(s.canEditContent(t) ? '작업 수정' : '배정 · 일정 변경'),
              ),
            if (s.manualWorkflow && s.availableHandoffs(t).isNotEmpty)
              SizedBox(
                width: 210,
                child: IeumSelect(
                  key: Key('task-manual-stage-${t.id}'),
                  value: t.status,
                  values: {
                    t.status: s.workflowStatusName(t.status),
                    for (final plan in s.availableHandoffs(t))
                      plan.destinationId: plan.destinationName,
                  },
                  label: '작업 단계',
                  icon: Icons.view_kanban_outlined,
                  onChanged: (target) => move(t, target),
                ),
              )
            else if (!s.manualWorkflow)
              for (final plan in s.availableHandoffs(t)) handoffButton(plan),
            for (final plan in s.availableTransfers(t)) handoffButton(plan),
            if (s.canDelete(t))
              OutlinedButton.icon(
                key: Key('task-delete-${t.id}'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xffc44848),
                ),
                onPressed: () => confirmTaskDeletion(ctx, t),
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('삭제'),
              ),
            if (s.canArchive(t))
              OutlinedButton.icon(
                key: Key('task-archive-${t.id}'),
                onPressed: () => action(() {
                  s.setArchived(
                    t.id,
                    !t.isArchived,
                    expectedVersion: t.version,
                  );
                  Navigator.pop(ctx);
                  message(
                    t.isArchived
                        ? '작업을 복원했습니다.'
                        : '작업을 보관함으로 옮겼습니다. 보관함에서 복원할 수 있습니다.',
                  );
                }),
                icon: Icon(
                  t.isArchived
                      ? Icons.unarchive_outlined
                      : Icons.inventory_2_outlined,
                  size: 16,
                ),
                label: Text(t.isArchived ? '복원' : '보관'),
              ),
          ],
        ),
        const SizedBox(height: 30),
        TaskCommentsPanel(key: ValueKey('comments-${t.id}'), store: s, task: t),
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
