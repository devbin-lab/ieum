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
import 'work_status_palette.dart' as work_palette;
import 'task_comments_panel.dart';
import 'task_detail_toolbar.dart';
import 'workspace_ui.dart';
import 'app_preferences.dart';
import 'app_theme.dart';
import 'appearance_settings.dart';
import 'markdown_content.dart';
import 'task_resources_panel.dart';
import 'project_resource_settings.dart';
import 'app_localizations.dart';

import 'package:flutter_localizations/flutter_localizations.dart';

import 'project_connections_view.dart';
import 'project_timeline_view.dart';
import 'project_shortcuts_view.dart';

const purple = Color(0xff7963d5),
    ink = Color(0xff302b3c),
    muted = Color(0xff6e687b),
    border = Color(0xffe1e3e6),
    canvas = Color(0xfffafbfa);
const iconRailSurface = Color(0xffe6e8e7);
const boardStatuses = {
  'todo': '확인중',
  'doing': '진행중',
  'review': '검토중',
  'done': '완료',
  'hold': '보류',
  'drop': '드랍',
};
const iconRailSelected = Color(0xffcfd4d2), iconRailActive = Color(0xff302b3c);
const iconRailMuted = Color(0xff505753);
Map<String, String> _localizedBoardLabels() => {
  for (final entry in boardStatuses.entries) entry.key: tr(entry.value),
};
Map<String, String> _localizedPriorities() => {
  for (final entry in priorities.entries) entry.key: tr(entry.value),
};
Color statusColor(String id) => work_palette.statusColor(id);
Color stageSurfaceColor(String id) => work_palette.stageSurfaceColor(id);
Color priorityColor(String id) => id == 'high'
    ? const Color(0xff9a622b)
    : id == 'low'
    ? const Color(0xff50735a)
    : muted;
Widget badge(String text, {Color? color}) => Builder(
  builder: (context) {
    final tint = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: tint, fontSize: 10),
      ),
    );
  },
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

Widget heading(String title, String subtitle) => Builder(
  builder: (context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Text(
        subtitle,
        style: TextStyle(
          fontSize: 11,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    ],
  ),
);
String shortId(String id) => id.startsWith('TASK-')
    ? 'IE-${id.substring(id.length - 6).toUpperCase()}'
    : id;
String shortDate(String date) => date.isEmpty
    ? tr('미정')
    : '${int.parse(date.substring(5, 7))}.${date.substring(8, 10)}';

String displayDateTime(String value) {
  final time = DateTime.tryParse(value)?.toLocal();
  if (time == null) return tr('기록 없음');
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year}.${two(time.month)}.${two(time.day)} '
      '${two(time.hour)}:${two(time.minute)}';
}

String displayDate(String value) =>
    value.isEmpty ? tr('미정') : value.replaceAll('-', '.');

String displayActivityMessage(String value) => value == '코멘트를 추가했습니다.'
    ? '댓글을 추가했습니다.'
    : value.replaceFirst(RegExp(r'^코멘트 · '), '댓글 · ');

String taskChangeValue(String key, dynamic value) {
  if (value == null) return '—';
  if (key == 'pinned') return value == 'true' ? tr('고정') : tr('해제');
  return '$value';
}

class IeumApp extends StatefulWidget {
  const IeumApp({
    super.key,
    required this.store,
    this.sync,
    this.home,
    this.onSignOut,
    this.session,
    this.preferences,
  });
  final TaskStore store;
  final GitHubSync? sync;
  final Widget? home;
  final VoidCallback? onSignOut;
  final GitHubSession? session;
  final AppPreferences? preferences;
  @override
  State<IeumApp> createState() => _IeumAppState();
}

class _IeumAppState extends State<IeumApp> {
  late AppPreferences preferences = widget.preferences ?? AppPreferences();
  @override
  void didUpdateWidget(covariant IeumApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferences != widget.preferences) {
      if (oldWidget.preferences == null) preferences.dispose();
      preferences = widget.preferences ?? AppPreferences();
    }
  }

  @override
  void dispose() {
    if (widget.preferences == null) preferences.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: preferences,
    builder: (context, _) {
      setAppLanguage(preferences.languageCode);
      return AppPreferencesScope(
        preferences: preferences,
        child: MaterialApp(
          title: '이음',
          debugShowCheckedModeBanner: false,
          locale: Locale(preferences.languageCode),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          themeMode: preferences.themeMode,
          themeAnimationDuration: const Duration(milliseconds: 140),
          theme: buildAppTheme(
            preferences.accentForBrightness(Brightness.light),
            Brightness.light,
            languageCode: preferences.languageCode,
          ),
          darkTheme: buildAppTheme(
            preferences.accentForBrightness(Brightness.dark),
            Brightness.dark,
            languageCode: preferences.languageCode,
          ),
          builder: (context, child) => DesktopFrame(child: child!),
          home:
              widget.home ??
              Workspace(
                store: widget.store,
                sync: widget.sync,
                onSignOut: widget.onSignOut,
                session: widget.session,
              ),
        ),
      );
    },
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
  final Future<void> Function(SavedProject, String)? onOpenProjectTask;
  final String? initialTaskId;
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
    this.onOpenProjectTask,
    this.initialTaskId,
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
  WorkspaceColors get colors => WorkspaceUi.colors(context);
  Color get purple => colors.accent;
  Color get ink => colors.ink;
  Color get muted => colors.muted;
  Color get border => colors.line;
  Color get canvas => colors.background;
  Color get surface => colors.surface;
  Color get iconRailSurface => colors.chrome;
  Color get iconRailSelected => colors.chromeHover;
  Color get iconRailActive => colors.ink;
  Color get iconRailMuted => colors.chromeInk;
  Map<String, String> get boardStatuses => _localizedBoardLabels();
  Map<String, String> get priorities => _localizedPriorities();
  final _standalonePreferences = AppPreferences();
  Color statusColor(String id) =>
      work_palette.statusColor(id, brightness: Theme.of(context).brightness);
  Color stageSurfaceColor(String id) => work_palette.stageSurfaceColor(
    id,
    brightness: Theme.of(context).brightness,
  );
  Color priorityColor(String id) => id == 'high'
      ? colors.warning
      : id == 'low'
      ? colors.success
      : muted;
  int page = 6;
  SettingsSection settingsSection = SettingsSection.general;
  TaskView taskView = TaskView.list;
  int lastWorkPage = 6;
  String? focusedTaskId;
  bool openingRecordTask = false;
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
      if (savedPage is int && savedPage >= 0 && savedPage <= 8) {
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
      lastWorkPage = const {0, 6}.contains(saved['lastWorkPage'])
          ? saved['lastWorkPage'] as int
          : page == 0
          ? 0
          : 6;
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
    if (widget.initialTaskId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openLocalTask(widget.initialTaskId!);
      });
    }
  }

  bool projectViewInitialized = false;
  bool get hasProjectSidebar =>
      page == 0 || page == 5 || page == 6 || page == 7 || page == 8;
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
    _standalonePreferences.dispose();
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
      if (page == 0 || page == 6) lastWorkPage = page;
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
      'lastWorkPage': lastWorkPage,
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
      if (page == 0 || page == 6) lastWorkPage = page;
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

  void message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(trEventMessage(text)),
          behavior: SnackBarBehavior.floating,
          width: min(520, MediaQuery.sizeOf(context).width - 32),
          backgroundColor: Theme.of(context).snackBarTheme.backgroundColor,
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
        message(tr('첫 작업을 등록하기 전에 팀에서 사용할 파트를 추가하세요.'));
      } else {
        message(tr('프로젝트 관리자에게 작업을 등록할 파트 추가를 요청하세요.'));
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
      if (choices.isEmpty) throw StateError(tr('현재 작업을 이 단계로 전달할 수 없습니다.'));
      await chooseHandoff(choices);
    } catch (e) {
      if (mounted) message(e.toString().replaceFirst('Bad state: ', ''));
    }
  }

  String boardCategory(WorkTask task) => workflowBoardCategory(task, s.project);
  String boardKey(WorkTask task) => work_palette.workStatusKey(task, s.project);
  String purposeLabel(WorkTask task) =>
      tr(workflowPurposeLabels[workflowTaskPurpose(task, s.project)] ?? '작업');
  String taskAssigneeId(WorkTask task) => s.manualWorkflow
      ? task.assigneeId
      : s.project?.workflowSheet == null || task.workflowTarget == 'legacy'
      ? task.currentId
      : task.workflowPerson;
  String taskAssigneeLabel(WorkTask task) {
    final personId = taskAssigneeId(task);
    if (personId.isNotEmpty) return s.member(personId).name;
    if (task.workflowTarget == 'role:owner') return tr('관리자');
    if (task.workflowTarget.startsWith('part:')) {
      return tr(
        '{value0} 전체',
        args: {'value0': workflowCurrentPartLabel(task, s.project)},
      );
    }
    return tr('모든 작업자');
  }

  String taskPartLabel(WorkTask task) =>
      s.manualWorkflow ? task.part : workflowCurrentPartLabel(task, s.project);
  List<TaskHandoffPlan> taskActions(WorkTask task) => [
    ...s.availableHandoffs(task),
    ...s.availableTransfers(task),
  ];
  List<TaskHandoffPlan> cardActions(WorkTask task) => taskActions(task)
      .where(
        (plan) => !const {
          'manual-review',
          'manual-hold',
          'manual-drop',
        }.contains(plan.routeId),
      )
      .toList();
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

  String destinationCategory(String id) => boardStatuses.containsKey(id)
      ? id
      : id == 'rework'
      ? 'todo'
      : s.project?.stage(id)?.isCompleted == true
      ? 'done'
      : 'doing';

  Future<void> moveToCategory(WorkTask task, String category) async {
    if (handoffOpen) return;
    try {
      final choices = s
          .availableHandoffs(task)
          .where((plan) => destinationCategory(plan.destinationId) == category)
          .toList();
      if (choices.isEmpty) throw StateError(tr('이 작업을 해당 열로 전달할 수 없습니다.'));
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
          title: Text(tr('전달 경로 선택')),
          children: [
            for (final choice in choices)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, choice),
                child: Text(
                  '${tr(choice.buttonLabel)} · ${choice.recipientLabel}',
                ),
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
              ? tr(
                  '{value0}에게 전달했습니다. {value1}.',
                  args: {
                    'value0': result.plan.recipientLabel,
                    'value1': result.plan.routeLabel,
                  },
                )
              : tr(
                  '{value0}으로 변경했습니다.',
                  args: {
                    'value0': trStageName(
                      result.plan.destinationId,
                      result.plan.destinationName,
                    ),
                  },
                ),
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
    bool secondary = false,
    String? surface,
  }) {
    final key = interactive
        ? Key(
            'task-handoff-${surface == null ? (compact ? '' : 'detail-') : '$surface-'}${plan.taskId}-${plan.action}-${plan.destinationId}${plan.routeId.isEmpty ? '' : '-${plan.routeId}'}',
          )
        : null;
    final actionLabel = compact
        ? switch (plan.routeId) {
            'manual-handoff' => tr('전달'),
            'manual-finish' => tr('완료'),
            'manual-start' => tr('시작'),
            'manual-resume' => tr('재개'),
            'manual-restore' => tr('복원'),
            _ => tr(plan.buttonLabel),
          }
        : tr(plan.buttonLabel);
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
      message: tr(
        '{value0}\n다음 담당자: {value1}',
        args: {'value0': plan.routeLabel, 'value1': plan.recipientLabel},
      ),
      child: compact
          ? TextButton.icon(
              key: key,
              onPressed: onPressed,
              icon: icon,
              label: text,
              style: TextButton.styleFrom(
                foregroundColor: muted,
                minimumSize: const Size(0, 30),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                textStyle: const TextStyle(
                  fontFamily: 'Malgun Gothic',
                  fontSize: 10,
                ),
              ),
            )
          : secondary || plan.action == 'reject'
          ? OutlinedButton.icon(
              key: key,
              onPressed: onPressed,
              icon: icon,
              label: text,
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
      barrierLabel: tr('작업 상세 닫기'),
      barrierColor: Colors.black.withValues(alpha: .18),
      pageBuilder: (ctx, a, b) => Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: 470,
          child: Material(
            color: surface,
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
          XTypeGroup(label: tr('JSON 변경안'), extensions: ['json']),
        ],
      );
      if (target == null) return;
      await File(target.path).writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(s.exportChanges())}\n',
      );
      message(tr('개인 변경안을 JSON 파일로 내보냈습니다.'));
    } catch (e) {
      message(tr('내보내기 실패: {value0}', args: {'value0': e}));
    } finally {
      if (mounted) setState(() => fileBusy = false);
    }
  }

  Future<void> import() async {
    if (!s.canImportManually) {
      message(tr('읽기 전용 · 수동 가져오기 권한이 없습니다.'));
      return;
    }
    setState(() => fileBusy = true);
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(label: tr('통합본 JSON'), extensions: ['json']),
        ],
      );
      if (file == null) return;
      if (await File(file.path).length() > 10 * 1024 * 1024) {
        throw StateError(tr('통합본은 10MB 이하만 지원합니다.'));
      }
      if (!mounted) return;
      final trusted = await showDialog<bool>(
        context: context,
        builder: (ctx) => IeumDialog(
          title: Text(tr('신뢰할 수 있는 통합본인가요?')),
          content: Text(
            tr(
              '수동 JSON은 GitHub에서 검증된 통합본과 다릅니다. 출처를 확인한 파일만 가져오세요. 현재 프로젝트의 업무 데이터가 변경되며 충돌은 자동 덮어쓰지 않습니다.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('취소')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('출처 확인 · 가져오기')),
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
        message(tr('통합본을 반영했습니다. 개인 변경은 보존했습니다.'));
      } else if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => IeumDialog(
            title: Text(tr('통합 전 확인이 필요해요')),
            width: 580,
            icon: Icons.merge_outlined,
            content: SizedBox(
              width: 530,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('데이터는 변경하지 않았습니다. 양쪽 변경을 확인해 주세요.'),
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                    const SizedBox(height: 15),
                    ...result.conflicts.map(
                      (c) => Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(15),
                        color: Theme.of(context).colorScheme.errorContainer,
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
                              tr(
                                '내 변경: {value0}\n통합본: {value1}',
                                args: {
                                  'value0': c['local'],
                                  'value1': c['remote'],
                                },
                              ),
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
                child: Text(tr('닫기')),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      message(tr('통합본 가져오기 실패: {value0}', args: {'value0': e}));
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

  Future<void> openRecordTask(Map<String, dynamic> record) async {
    if (openingRecordTask) return;
    final taskId = record['taskId'];
    if (taskId is! String || taskId.isEmpty) return;
    final path = record['projectPath'] as String? ?? s.filename;
    openingRecordTask = true;
    try {
      if (path == s.filename) {
        await openLocalTask(taskId);
        return;
      }
      final entry = notificationProjectList()
          .where((project) => project.path == path)
          .firstOrNull;
      if (entry == null || widget.onOpenProjectTask == null) {
        message(tr('이 작업의 프로젝트를 열 수 없습니다. 프로젝트 연결을 확인해 주세요.'));
        return;
      }
      await widget.onOpenProjectTask!(entry, taskId);
    } catch (error) {
      if (mounted) message(error.toString().replaceFirst('Bad state: ', ''));
    } finally {
      openingRecordTask = false;
    }
  }

  Future<void> openLocalTask(String taskId) async {
    if (!mounted) return;
    WorkTask task;
    try {
      task = s.find(taskId);
    } catch (_) {
      message(tr('이 작업을 찾을 수 없습니다. 최신 프로젝트 기록을 확인해 주세요.'));
      return;
    }
    if (task.isDeleted) {
      message(tr('삭제된 작업입니다. 변경 기록은 타임라인에서 확인할 수 있습니다.'));
      return;
    }
    rememberView(() {
      page = task.isArchived || task.isDropped ? 6 : lastWorkPage;
      focusedTaskId = task.id;
      scope = task.isArchived ? 'archived' : 'all';
      search = '';
      part = '';
      relatedMember = '';
      statusFilter = '';
      deadlineFilter = '';
      taskPage = 0;
      taskSearch.clear();
    });
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) {
      setState(() => focusedTaskId = null);
      details(s.find(task.id));
    }
  }

  List<Map<String, dynamic>> get currentProjectActivity {
    final records = <Map<String, dynamic>>[];
    collectProjectActivity(
      records,
      s,
      projectPath: s.filename,
      projectName: s.project?.name ?? tr('로컬 작업 공간'),
    );
    records.sort((a, b) {
      final left = DateTime.tryParse('${a['createdAt']}') ?? DateTime(1970);
      final right = DateTime.tryParse('${b['createdAt']}') ?? DateTime(1970);
      return right.compareTo(left);
    });
    return records.take(300).toList();
  }

  void refreshNotificationHistory() {
    final projects = notificationProjectList();
    final result = <Map<String, dynamic>>[];
    if (projects.isEmpty) {
      for (final notification in s.notifications) {
        if (notification['recipientId'] is String &&
            notification['recipientId'] != s.profileId) {
          continue;
        }
        final taskDetails = notificationTaskDetails(s, notification);
        result.add({
          ...notification,
          ...taskDetails,
          'projectPath': s.filename,
          'projectName': s.project?.name ?? tr('현재 프로젝트'),
          'projectSlug': tr('로컬'),
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
          if (notification['recipientId'] is String &&
              notification['recipientId'] != source.profileId) {
            continue;
          }
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
    if (mounted) {
      setState(() {
        notificationHistory = result;
      });
    }
  }

  void collectProjectActivity(
    List<Map<String, dynamic>> target,
    TaskStore source, {
    required String projectPath,
    required String projectName,
  }) {
    final tasks = {for (final task in source.storedTasks) task.id: task};
    String personName(String id) => id.isEmpty ? '작업자' : source.member(id).name;

    void add({
      required String id,
      required String kind,
      required String taskId,
      required String taskTitle,
      required String actorId,
      required String message,
      required String createdAt,
    }) {
      if (DateTime.tryParse(createdAt) == null || message.trim().isEmpty) {
        return;
      }
      target.add({
        'id': '$projectPath:$id',
        'kind': kind,
        'taskId': taskId,
        'taskTitle': taskTitle,
        'actorId': actorId,
        'actorName': personName(actorId),
        'message': message,
        'createdAt': createdAt,
        'projectPath': projectPath,
        'projectName': projectName,
      });
    }

    for (final task in tasks.values) {
      if (task.createdAt.isNotEmpty) {
        add(
          id: '${task.id}:created',
          kind: 'created',
          taskId: task.id,
          taskTitle: task.title,
          actorId: task.creatorId,
          message: '작업을 등록했습니다.',
          createdAt: task.createdAt,
        );
      }
      for (final transition in task.transitionHistory) {
        final from = source.workflowStatusName('${transition['from']}');
        final to = source.workflowStatusName('${transition['to']}');
        final recipientId = '${transition['recipientId'] ?? ''}';
        final comment = '${transition['comment'] ?? ''}'.trim();
        add(
          id: '${transition['id']}',
          kind: 'transition',
          taskId: task.id,
          taskTitle: task.title,
          actorId: '${transition['actorId'] ?? ''}',
          message:
              '단계 전달 · $from → $to'
              '${recipientId.isEmpty ? '' : ' · 담당 ${personName(recipientId)}'}'
              '${comment.isEmpty ? '' : ' · $comment'}',
          createdAt: '${transition['createdAt'] ?? ''}',
        );
      }
      for (final comment in task.comments) {
        add(
          id: '${comment['id']}',
          kind: 'comment',
          taskId: task.id,
          taskTitle: task.title,
          actorId: '${comment['authorId'] ?? ''}',
          message: '댓글 · ${comment['text']}',
          createdAt: '${comment['createdAt'] ?? ''}',
        );
      }
    }

    for (final record in source.activity) {
      final taskId = '${record['taskId'] ?? ''}';
      final task = tasks[taskId];
      if (task == null) continue;
      final actorId = '${record['actorId'] ?? ''}';
      final message = '${record['message'] ?? ''}';
      final version = record['taskVersion'];
      if (task.transitionHistory.any((event) => event['version'] == version) ||
          message.contains('새 작업을 등록했습니다.')) {
        continue;
      }
      final recordTime = DateTime.tryParse('${record['createdAt'] ?? ''}');
      final commentAlreadyShared =
          message == '코멘트를 추가했습니다.' &&
          task.comments.any((comment) {
            if (comment['authorId'] != actorId || recordTime == null) {
              return false;
            }
            final commentTime = DateTime.tryParse('${comment['createdAt']}');
            return commentTime != null &&
                commentTime.difference(recordTime).abs() <
                    const Duration(seconds: 5);
          });
      if (commentAlreadyShared) continue;
      add(
        id: '${record['id'] ?? '${task.id}:${record['taskVersion']}'}',
        kind: 'activity',
        taskId: task.id,
        taskTitle: task.title,
        actorId: actorId,
        message: displayActivityMessage(message),
        createdAt: '${record['createdAt'] ?? ''}',
      );
    }
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
        message(tr('알림을 읽음으로 표시하지 못했습니다. 다시 시도해 주세요.'));
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
    final projectValues = <String, String>{'all': tr('모든 프로젝트')};
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
      onOpenTask: openRecordTask,
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
      final project = s.project;
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
              color: stageSurfaceColor("review"),
              child: Text(
                widget.sessionNotice!,
                style: TextStyle(fontSize: 11, color: statusColor("review")),
              ),
            ),
          Expanded(
            child: page == 0
                ? ProjectScheduleView(
                    key: Key('schedule-page'),
                    store: s,
                    focusTaskId: focusedTaskId,
                    onOpenTask: details,
                    onEditTask: edit,
                    onCreateTask: (date) => edit(null, date),
                  )
                : page == 7
                ? ProjectTimelineView(
                    key: const Key('project-timeline-page'),
                    projectName: s.project?.name ?? tr('로컬 작업 공간'),
                    activityHistory: currentProjectActivity,
                    onRefresh: () => setState(() {}),
                    onOpenTask: openRecordTask,
                  )
                : page == 8
                ? ProjectShortcutsView(
                    key: const Key('project-shortcuts-page'),
                    store: s,
                    repository: widget.sync?.config.slug,
                    onSave:
                        project != null &&
                            widget.session != null &&
                            widget.sync != null
                        ? (shortcuts, expected) async {
                            final saved = await widget.session!.saveShortcuts(
                              widget.sync!.config,
                              shortcuts,
                              expectedProjectId: project.id,
                              expectedShortcuts: expected,
                            );
                            s.updateProject(saved);
                          }
                        : null,
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
                ? tasksWorkspace(all, filtered, pageCount, visiblePage)
                : SettingsShell(
                    personal: settingsSection.isPersonal,
                    projectName: s.project?.name ?? tr('로컬 작업 공간'),
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
                    key: Key('workspace-main-surface'),
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
                            personal: settingsSection.isPersonal,
                            projectName: s.project?.name ?? tr('로컬 작업 공간'),
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
      decoration: BoxDecoration(
        color: surface,
        border: Border(right: BorderSide(color: colors.line)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(20, 24, 12, 20),
            child: Text(
              tr('프로젝트'),
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  picker ?? Text(s.project?.name ?? tr('로컬 작업 공간')),
                  const SizedBox(height: 14),
                  Divider(height: 1, color: border),
                  const SizedBox(height: 10),
                  projectViewTab(
                    key: 'project-view-tab-tasks',
                    title: tr('작업'),
                    icon: Icons.view_kanban_outlined,
                    targetPage: 6,
                  ),
                  const SizedBox(height: 4),
                  projectViewTab(
                    key: 'project-view-tab-schedule',
                    title: tr('일정'),
                    icon: Icons.calendar_month_outlined,
                    targetPage: 0,
                  ),
                  const SizedBox(height: 4),
                  projectViewTab(
                    key: 'project-view-tab-timeline',
                    title: tr('타임라인'),
                    icon: Icons.history_rounded,
                    targetPage: 7,
                  ),
                  const SizedBox(height: 4),
                  projectViewTab(
                    key: 'project-view-tab-connections',
                    title: tr('연결'),
                    icon: Icons.link,
                    targetPage: 5,
                  ),
                  const SizedBox(height: 4),
                  projectViewTab(
                    key: 'project-view-tab-shortcuts',
                    title: tr('바로가기'),
                    icon: Icons.bookmarks_outlined,
                    targetPage: 8,
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
    decoration: BoxDecoration(color: iconRailSurface),
    padding: const EdgeInsets.fromLTRB(6, 12, 6, 12),
    child: Column(
      children: [
        railButton(
          'project-home',
          tr('{value0} 홈', args: {'value0': s.project?.name ?? '현재 프로젝트'}),
          Icons.home_outlined,
          () => rememberView(() => page = 6),
          selected: isTaskPage,
        ),
        const SizedBox(height: 8),
        IconButton(
          key: const Key('sidebar-notifications'),
          tooltip: s.isProject ? tr('내 알림') : tr('알림 미리보기'),
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
            child: Icon(
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
          role: s.isProject
              ? trRoleName(s.actor.role, s.actor.roleLabel)
              : tr('테스트 사용자'),
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
            ? colors.subtle
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        textStyle: const TextStyle(
          fontFamily: 'Malgun Gothic',
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      icon: Icon(icon, size: 17),
      label: Text(title),
    ),
  );

  Widget stats(List<WorkTask> tasks) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        Text(
          tr('프로젝트 현황'),
          key: Key('project-stats-scope'),
          style: WorkspaceUi.captionStyleOf(context),
        ),
        const SizedBox(width: 16),
        Text(
          tr('전체 {value0}', args: {'value0': tasks.length}),
          style: WorkspaceUi.captionStyleOf(context),
        ),
        for (final entry in boardStatuses.entries) ...[
          const SizedBox(width: 16),
          Icon(Icons.circle, size: 5, color: statusColor(entry.key)),
          const SizedBox(width: 5),
          Text(
            '${entry.value} ${tasks.where((task) => boardKey(task) == entry.key).length}',
            style: WorkspaceUi.captionStyleOf(context),
          ),
        ],
      ],
    ),
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
      color: surface,
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
          scope == 'archived' ? tr('보관한 작업이 없습니다') : tr('표시할 작업이 없습니다'),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          search.isNotEmpty ||
                  part.isNotEmpty ||
                  statusFilter.isNotEmpty ||
                  deadlineFilter.isNotEmpty
              ? tr('검색어나 필터를 바꾸어 보세요.')
              : scope == 'archived'
              ? tr('작업 상세에서 보관한 항목을 여기서 확인하고 복원할 수 있습니다.')
              : scope != 'all'
              ? tr('배정받은 작업이 생기면 여기에 표시됩니다.')
              : tr('새 작업을 등록해 팀과 함께 진행하세요.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: muted, fontSize: 12),
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
                child: Text(tr('필터 초기화')),
              ),
            if (s.canCreate && scope == 'all')
              FilledButton.icon(
                onPressed: () => edit(),
                icon: const Icon(Icons.add, size: 16),
                label: Text(tr('새 작업')),
              ),
          ],
        ),
      ],
    ),
  );

  Widget tasksWorkspace(
    List<WorkTask> all,
    List<WorkTask> filtered,
    int pageCount,
    int visiblePage,
  ) => LayoutBuilder(
    builder: (context, bounds) {
      final inset = bounds.maxWidth < 600 ? 16.0 : 24.0;
      return Column(
        children: [
          Container(
            key: const Key('task-workspace-header'),
            padding: EdgeInsets.fromLTRB(inset, 20, inset, 12),
            decoration: BoxDecoration(
              color: surface,
              border: Border(bottom: BorderSide(color: colors.line)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WorkspacePageHeader(
                  title: tr('작업'),
                  contextLabel: s.project?.name ?? tr('로컬 작업 공간'),
                  contextKey: const Key('workspace-project-name'),
                  actions: [
                    FilledButton.icon(
                      key: const Key('new-task'),
                      onPressed: s.canCreate ? () => edit() : null,
                      icon: const Icon(Icons.add_rounded, size: 17),
                      label: Text(tr('새 작업')),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                toolbar(),
                const SizedBox(height: 12),
                stats(all),
              ],
            ),
          ),
          if (s.isProject && s.actor.role == 'pending')
            info(tr('가입 승인 대기 중입니다. 관리자가 참여를 승인하면 작업을 진행할 수 있습니다.')),
          if (s.isProject && s.actor.role != 'pending' && !s.actor.active)
            info(tr('비활성화된 참여자입니다. 관리자에게 활성화를 요청하세요.')),
          Expanded(
            child: Padding(
              padding: EdgeInsets.fromLTRB(inset, 16, inset, 0),
              child: taskView == TaskView.kanban
                  ? board(filtered, bounds.maxWidth - inset * 2)
                  : SingleChildScrollView(
                      key: const Key('task-content-scroll'),
                      padding: const EdgeInsets.only(bottom: 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (relatedMember.isNotEmpty)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: InputChip(
                                label: Text(
                                  tr(
                                    '{value0} · 관련 업무',
                                    args: {
                                      'value0': s.member(relatedMember).name,
                                    },
                                  ),
                                ),
                                onDeleted: () =>
                                    setState(() => relatedMember = ''),
                              ),
                            ),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              tr(
                                '{value0}개 작업',
                                args: {'value0': filtered.length},
                              ),
                              style: WorkspaceUi.captionStyleOf(context),
                            ),
                          ),
                          if (filtered.isEmpty)
                            emptyTasks()
                          else
                            schedule(
                              filtered.skip(visiblePage * 50).take(50).toList(),
                            ),
                          if (pageCount > 1)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Wrap(
                                spacing: 12,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    '${visiblePage * 50 + 1}–${min((visiblePage + 1) * 50, filtered.length)} / ${filtered.length}',
                                    style: WorkspaceUi.captionStyleOf(context),
                                  ),
                                  IconButton(
                                    tooltip: tr('이전 페이지'),
                                    onPressed: visiblePage > 0
                                        ? () => setState(
                                            () => taskPage = visiblePage - 1,
                                          )
                                        : null,
                                    icon: const Icon(Icons.chevron_left),
                                  ),
                                  Text('${visiblePage + 1} / $pageCount'),
                                  IconButton(
                                    tooltip: tr('다음 페이지'),
                                    onPressed: visiblePage + 1 < pageCount
                                        ? () => setState(
                                            () => taskPage = visiblePage + 1,
                                          )
                                        : null,
                                    icon: const Icon(Icons.chevron_right),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
            ),
          ),
        ],
      );
    },
  );

  Widget taskFilter(
    String key,
    String value,
    Map<String, String> values,
    ValueChanged<String> onChanged,
  ) => SizedBox(
    width: 124,
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

  Widget toolbar() => LayoutBuilder(
    builder: (context, bounds) => Column(
      children: [
        Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final entry in {
                      'all': tr('전체 작업'),
                      'mine': tr('내 할 일'),
                      'review': tr('전달받은 작업'),
                      'archived': tr('보관함'),
                    }.entries)
                      WorkspaceTab(
                        key: Key('scope-${entry.key}'),
                        label: entry.value,
                        selected: scope == entry.key,
                        onPressed: () => setState(() {
                          scope = entry.key;
                          taskPage = 0;
                        }),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            SegmentedButton<TaskView>(
              key: const Key('task-view-selector'),
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                foregroundColor: muted,
                selectedForegroundColor: ink,
                backgroundColor: surface,
                selectedBackgroundColor: colors.subtle,
                side: BorderSide(color: colors.line),
                textStyle: const TextStyle(
                  fontFamily: 'Malgun Gothic',
                  fontSize: 11,
                ),
                iconSize: 15,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                minimumSize: const Size(0, 34),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
              segments: [
                ButtonSegment(
                  value: TaskView.list,
                  label: Text(tr('목록'), key: Key('view-list')),
                  icon: Icon(Icons.view_list_outlined),
                ),
                ButtonSegment(
                  value: TaskView.kanban,
                  label: Text(tr('보드'), key: Key('view-kanban')),
                  icon: Icon(Icons.view_kanban_outlined),
                ),
              ],
              selected: {taskView},
              onSelectionChanged: (value) =>
                  rememberView(() => taskView = value.single),
            ),
          ],
        ),
        Divider(height: 1, color: colors.line),
        const SizedBox(height: 12),
        Row(
          children: [
            SizedBox(
              width: min(200, max(112, bounds.maxWidth * .26)),
              height: 36,
              child: TextField(
                key: const Key('search'),
                controller: taskSearch,
                style: const TextStyle(fontSize: 12),
                onChanged: (value) => setState(() {
                  search = value;
                  taskPage = 0;
                }),
                decoration: InputDecoration(
                  hintText: tr('작업 검색'),
                  prefixIcon: Icon(Icons.search_rounded, size: 17),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 9,
                  ),
                  prefixIconConstraints: BoxConstraints(
                    minWidth: 34,
                    minHeight: 34,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    SizedBox(
                      width: 124,
                      child: IeumSelect(
                        key: ValueKey('filter-$part'),
                        value: part,
                        values: {
                          '': tr('모든 파트'),
                          for (final r in s.partRules) r.part: r.part,
                        },
                        onChanged: (value) => setState(() {
                          part = value;
                          taskPage = 0;
                        }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    taskFilter('status-filter', statusFilter, {
                      '': tr('모든 상태'),
                      ...boardStatuses,
                      if (statusFilter.startsWith('category:'))
                        statusFilter: tr('이전 상태 필터'),
                    }, (value) => statusFilter = value),
                    const SizedBox(width: 8),
                    taskFilter('deadline-filter', deadlineFilter, {
                      '': tr('모든 마감일'),
                      'overdue': tr('마감 지남'),
                      'today': tr('오늘 마감'),
                      'none': tr('마감 미정'),
                    }, (value) => deadlineFilter = value),
                    const SizedBox(width: 8),
                    taskFilter('task-sort', taskSort, {
                      'updated': tr('최근 수정순'),
                      'due': tr('마감일순'),
                      'priority': tr('우선순위순'),
                      'title': tr('이름순'),
                    }, (value) => taskSort = value),
                  ],
                ),
              ),
            ),
            if (search.isNotEmpty ||
                part.isNotEmpty ||
                statusFilter.isNotEmpty ||
                deadlineFilter.isNotEmpty ||
                relatedMember.isNotEmpty)
              IconButton(
                tooltip: tr('필터 초기화'),
                onPressed: clearTaskFilters,
                icon: const Icon(Icons.filter_alt_off_outlined, size: 17),
              ),
          ],
        ),
      ],
    ),
  );

  Widget board(List<WorkTask> tasks, double available) => LayoutBuilder(
    builder: (context, bounds) => HorizontalViewport(
      key: const Key('task-kanban'),
      child: SizedBox(
        width: max(available, 1480.0),
        height: max(120, bounds.maxHeight - 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final stage in boardStatuses.entries)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: stage.key == 'drop' ? 0 : 12),
                  child: DragTarget<WorkTask>(
                    onWillAcceptWithDetails: (d) =>
                        !handoffOpen &&
                        s
                            .availableHandoffs(d.data)
                            .any(
                              (plan) =>
                                  destinationCategory(plan.destinationId) ==
                                  stage.key,
                            ),
                    onAcceptWithDetails: (d) =>
                        moveToCategory(d.data, stage.key),
                    builder: (context, candidates, rejected) {
                      final list = tasks
                          .where((t) => boardKey(t) == stage.key)
                          .toList();
                      return Container(
                        key: Key('column-${stage.key}'),
                        padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                        decoration: BoxDecoration(
                          color: candidates.isNotEmpty
                              ? colors.accentSurface
                              : stageSurfaceColor(stage.key),
                          border: Border.all(
                            color: candidates.isNotEmpty ? purple : colors.line,
                          ),
                          borderRadius: BorderRadius.circular(
                            WorkspaceUi.radius,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              height: 36,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.circle,
                                    size: 6,
                                    color: statusColor(stage.key),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      stage.value,
                                      style: WorkspaceUi.sectionStyleOf(
                                        context,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    '${list.length}',
                                    style: WorkspaceUi.captionStyleOf(context),
                                  ),
                                  if (s.canCreate &&
                                      stage.key == 'todo' &&
                                      scope != 'archived')
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      tooltip: tr('새 작업 등록'),
                                      onPressed: () => edit(),
                                      icon: Icon(
                                        Icons.add_rounded,
                                        size: 17,
                                        color: muted,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 8),
                            Expanded(
                              child: list.isEmpty
                                  ? Center(
                                      child: Text(
                                        tr('작업 없음'),
                                        style: WorkspaceUi.captionStyleOf(
                                          context,
                                        ),
                                      ),
                                    )
                                  : ListView(
                                      key: Key('column-items-${stage.key}'),
                                      padding: const EdgeInsets.only(
                                        bottom: 12,
                                      ),
                                      children: [
                                        for (final task in list.take(50))
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              bottom: 10,
                                            ),
                                            child: Draggable<WorkTask>(
                                              data: task,
                                              feedback: Material(
                                                color: Colors.transparent,
                                                child: SizedBox(
                                                  width: 220,
                                                  child: taskCard(
                                                    task,
                                                    interactive: false,
                                                  ),
                                                ),
                                              ),
                                              childWhenDragging: Opacity(
                                                opacity: .35,
                                                child: taskCard(
                                                  task,
                                                  interactive: false,
                                                ),
                                              ),
                                              child: taskCard(task),
                                            ),
                                          ),
                                        if (list.length > 50)
                                          TextButton(
                                            onPressed: () => setState(() {
                                              statusFilter = stage.key;
                                              taskPage = 0;
                                              taskView = TaskView.list;
                                            }),
                                            child: Text(
                                              tr(
                                                '전체 {value0}개 목록에서 보기',
                                                args: {'value0': list.length},
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    ),
  );

  void toggleTaskPin(WorkTask task) => action(() {
    s.setTaskPinned(task.id, !task.isPinned, expectedVersion: task.version);
    if (!task.isPinned) setState(() => taskPage = 0);
  });

  Widget taskPinButton(WorkTask task, String surface) => IconButton(
    key: Key('task-pin-$surface-${task.id}'),
    tooltip: task.isPinned ? tr('상단 고정 해제') : tr('상단에 고정'),
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
    final handoffs = cardActions(t);
    return Material(
      key: interactive ? Key('card-${t.id}') : null,
      color: surface,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        borderRadius: BorderRadius.circular(9),
        onTap: interactive ? () => details(t) : null,
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
          decoration: BoxDecoration(
            border: Border.all(color: colors.line),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      shortId(t.id),
                      style: TextStyle(fontSize: 10, color: muted),
                    ),
                  ),
                  if (t.priority == 'high')
                    Tooltip(
                      message: tr('높은 우선순위'),
                      child: Icon(
                        Icons.keyboard_double_arrow_up_rounded,
                        size: 15,
                        color: Color(0xff9a622b),
                      ),
                    ),
                  if (t.isLocked)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Tooltip(
                        message: tr(
                          '{value0}님만 수정 가능',
                          args: {'value0': s.member(t.lockedBy).name},
                        ),
                        child: Icon(
                          Icons.lock_outline_rounded,
                          size: 14,
                          color: muted,
                        ),
                      ),
                    ),
                  taskPinButton(t, 'card'),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                t.title,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  badge(taskPartLabel(t)),
                  Text(
                    tr('{value0} 요청', args: {'value0': purposeLabel(t)}),
                    key: interactive ? Key('task-purpose-${t.id}') : null,
                    style: TextStyle(fontSize: 10, color: muted, height: 1.9),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                tr('담당 · {value0}', args: {'value0': taskAssigneeLabel(t)}),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: muted),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.calendar_today_outlined, size: 12, color: muted),
                  const SizedBox(width: 5),
                  Text(
                    shortDate(t.dueDate),
                    style: TextStyle(fontSize: 10, color: muted),
                  ),
                  const Spacer(),
                  Tooltip(
                    message: taskAssigneeLabel(t),
                    child: taskAssigneeId(t).isEmpty
                        ? Icon(Icons.groups_outlined, size: 20, color: muted)
                        : avatar(s.member(taskAssigneeId(t)), size: 23),
                  ),
                ],
              ),
              if (s.isWaitingForReview(t)) ...[
                const SizedBox(height: 10),
                Text(
                  tr(
                    '{value0} · 검토 요청',
                    args: {'value0': taskAssigneeLabel(t)},
                  ),
                  style: TextStyle(fontSize: 10, color: statusColor(t.status)),
                ),
              ],
              if (handoffs.isNotEmpty) ...[
                Divider(height: 18, color: colors.line),
                Wrap(
                  spacing: 4,
                  runSpacing: 4,
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
    color: surface,
    clipBehavior: Clip.antiAlias,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide(color: border),
    ),
    child: Column(
      children: [
        for (var i = 0; i < tasks.length; i++) ...[
          if (i > 0) Divider(height: 1, color: border),
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
                        '${taskPartLabel(tasks[i])} · ${taskAssigneeLabel(tasks[i])}',
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                      Text(
                        tr(
                          '{value0} 요청',
                          args: {'value0': purposeLabel(tasks[i])},
                        ),
                        style: TextStyle(fontSize: 12, color: muted),
                      ),
                      Text(
                        tr(
                          '마감 {value0}',
                          args: {
                            'value0': tasks[i].dueDate.isEmpty
                                ? '미정'
                                : tasks[i].dueDate,
                          },
                        ),
                        style: TextStyle(fontSize: 12, color: muted),
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
      color: surface,
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
        headingTextStyle: TextStyle(fontSize: 12, color: muted),
        dataTextStyle: TextStyle(fontSize: 12, color: ink),
        dividerThickness: .5,
        columns: [
          tr('작업'),
          tr('상태'),
          tr('담당자'),
          tr('우선순위'),
          tr('시작일'),
          tr('마감일'),
          tr('동작'),
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
                                  style: TextStyle(fontSize: 9, color: muted),
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
                  DataCell(
                    SizedBox(
                      width: 120,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            taskAssigneeLabel(t),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            tr(
                              '{value0} · {value1} 요청',
                              args: {
                                'value0': taskPartLabel(t),
                                'value1': purposeLabel(t),
                              },
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 10, color: muted),
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
                  DataCell(Text(displayDate(t.assignedDate))),
                  DataCell(Text(displayDate(t.dueDate))),
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
    if (plans.isEmpty) return const SizedBox(width: 140);
    return SizedBox(
      width: 140,
      child: Row(
        children: [
          Expanded(
            child: handoffButton(plans.first, compact: true, surface: 'list'),
          ),
          if (plans.length > 1) ...[
            const SizedBox(width: 6),
            PopupMenuButton<TaskHandoffPlan>(
              key: Key('task-actions-more-${task.id}'),
              tooltip: tr('다른 작업 처리'),
              enabled: !handoffOpen,
              icon: const Icon(Icons.more_horiz_rounded, size: 20),
              onSelected: confirmHandoff,
              itemBuilder: (_) => [
                for (final plan in plans.skip(1))
                  PopupMenuItem(
                    value: plan,
                    child: Text(
                      '${tr(plan.buttonLabel)} · ${plan.recipientLabel}',
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
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      WorkspaceSectionLabel(
        title: tr('전송 전 변경'),
        trailing: Text(
          tr('{value0}건', args: {'value0': s.changes.length}),
          style: WorkspaceUi.captionStyleOf(context),
        ),
      ),
      const SizedBox(height: 12),
      if (s.changes.isEmpty)
        WorkspacePanel(
          child: WorkspaceEmptyState(
            icon: Icons.check_circle_outline_rounded,
            title: tr('전송할 변경이 없습니다.'),
            message: tr('저장한 작업의 변경사항을 여기서 확인할 수 있습니다.'),
          ),
        )
      else
        WorkspacePanel(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < s.changes.length; i++) ...[
                if (i > 0) Divider(height: 1, color: colors.line),
                ExpansionTile(
                  shape: const Border(),
                  collapsedShape: const Border(),
                  tilePadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  leading: Icon(
                    s.changes[i]['kind'] == 'create'
                        ? Icons.add_circle_outline
                        : Icons.edit_outlined,
                    size: 18,
                    color: muted,
                  ),
                  title: Text(
                    s.changes[i]['title'],
                    style: WorkspaceUi.sectionStyleOf(context),
                  ),
                  subtitle: Text(
                    s.changes[i]['kind'] == 'create'
                        ? tr('신규 작업')
                        : tr('수정 작업'),
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                  children: [
                    for (final field in s.changes[i]['fields'] as List)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 6,
                          children: [
                            SizedBox(
                              width: 100,
                              child: Text(
                                field['label'],
                                style: WorkspaceUi.captionStyleOf(context),
                              ),
                            ),
                            Text(
                              taskChangeValue(field['key'], field['before']),
                              style: WorkspaceUi.captionStyleOf(context),
                            ),
                            Icon(
                              Icons.arrow_forward_rounded,
                              size: 14,
                              color: muted,
                            ),
                            Text(
                              taskChangeValue(field['key'], field['after']),
                              style: TextStyle(fontSize: 11, color: ink),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      const SizedBox(height: 20),
      ExpansionTile(
        key: const Key('manual-transfer'),
        tilePadding: EdgeInsets.zero,
        title: Text(tr('수동 가져오기 · 내보내기'), style: TextStyle(fontSize: 13)),
        subtitle: Text(
          tr('자동 동기화를 사용할 수 없을 때'),
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
                  label: Text(tr('통합본 가져오기')),
                ),
                OutlinedButton.icon(
                  onPressed: fileBusy || s.changes.isEmpty ? null : export,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: Text(tr('변경안 내보내기')),
                ),
              ],
            ),
          ),
          if (!s.canImportManually)
            info(tr('읽기 전용 · 수동 가져오기는 작업 변경 권한이 필요합니다.')),
        ],
      ),
    ],
  );
  Widget info(String text) => Container(
    margin: const EdgeInsets.only(top: 24),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: colors.accentSurface,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 18, color: purple),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontSize: 11, color: muted, height: 1.8),
          ),
        ),
      ],
    ),
  );
  Widget settingsContent(SettingsSection section) => switch (section) {
    SettingsSection.general => generalSettings(),
    SettingsSection.design => AppPreferencesScope(
      preferences:
          AppPreferencesScope.maybeOf(context) ?? _standalonePreferences,
      child: const AppearanceSettings(),
    ),
    SettingsSection.language => AppPreferencesScope(
      preferences:
          AppPreferencesScope.maybeOf(context) ?? _standalonePreferences,
      child: const LanguageSettings(),
    ),
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
          : settingsGroup(tr('파트'), [
              (tr('프로젝트 필요'), tr('프로젝트를 연결하면 파트를 관리할 수 있습니다.'), ''),
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
                page = 6;
                scope = 'all';
                search = '';
                part = '';
              }),
            )
          : info(tr('프로젝트에 로그인하면 참여자와 파트, 가입 요청을 관리할 수 있습니다.')),
    SettingsSection.workflow => info(
      tr('확인중 → 진행중 → 검토중 → 완료. 전달하면 확인중으로 이동하며, 보류와 드랍에서 복귀할 수 있습니다.'),
    ),
    SettingsSection.github =>
      widget.sync != null
          ? GitHubPanel(sync: widget.sync!)
          : info(tr('프로젝트 저장소에 연결하면 동기화 상태와 전송 대기열을 확인할 수 있습니다.')),
    SettingsSection.changes => changesPanel(),
    SettingsSection.notifications => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        settingsGroup(tr('작업 알림'), [
          (
            tr('내 알림'),
            tr('작업 배정, 검토 요청, 검토 결과를 확인합니다.'),
            tr('{value0}개 읽지 않음', args: {'value0': s.unreadNotificationCount}),
          ),
        ]),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: notifications,
          icon: const Icon(Icons.notifications_none_rounded, size: 18),
          label: Text(tr('알림 열기')),
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
              update(() => error = tr('이름을 입력하세요.'));
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
                  error = tr(
                    '이름 저장 실패 · 초안은 유지됩니다. {value0}',
                    args: {'value0': e},
                  );
                });
              }
            }
          }

          return DraftGuard(
            dirty: !saved && controller.text.trim() != original,
            busy: busy,
            onSave: save,
            child: IeumDialog(
              title: Text(tr('이름 변경')),
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
                    decoration: InputDecoration(labelText: tr('이름 / 닉네임')),
                  ),
                  Text(
                    tr('이 컴퓨터에서 연결한 프로젝트에 새 이름이 반영됩니다. GitHub 계정은 바뀌지 않습니다.'),
                  ),
                  if (controller.text.trim() != original)
                    Text(tr('저장하지 않은 변경사항')),
                  if (error.isNotEmpty)
                    Text(error, style: const TextStyle(color: Colors.red)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: busy ? null : () => Navigator.maybePop(ctx),
                  child: Text(tr('취소')),
                ),
                FilledButton(
                  onPressed: busy || controller.text.trim() == original
                      ? null
                      : save,
                  child: Text(busy ? tr('반영 중…') : tr('변경')),
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
    return tr('이름을 변경했습니다.');
  }

  Widget projectGeneralSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ProjectResourceSettings(
        store: s,
        sync: widget.sync,
        session: widget.session,
      ),
      const SizedBox(height: 32),
      settingsGroup(tr('프로젝트'), [
        (
          tr('프로젝트 이름'),
          tr('현재 열려 있는 프로젝트입니다.'),
          s.project?.name ?? tr('로컬 작업 공간'),
        ),
        (
          tr('데이터 저장 위치'),
          tr('이 컴퓨터의 작업과 전송 대기열을 보관합니다.'),
          s.filename == ':memory:' ? tr('임시 작업 공간') : s.filename,
        ),
        (
          tr('GitHub 저장소'),
          tr('팀의 작업 데이터를 공유하는 저장소입니다.'),
          widget.sync?.config.repository.isNotEmpty == true
              ? widget.sync!.config.slug
              : tr('연결되지 않음'),
        ),
      ]),
      const SizedBox(height: 32),
      settingsGroup(tr('현재 참여 상태'), [
        (
          tr('권한'),
          tr('이 프로젝트에서 부여받은 권한입니다.'),
          trRoleName(s.actor.role, s.actor.roleLabel),
        ),
        (
          tr('상태'),
          tr('비활성화된 참여자는 작업·업로드가 제한됩니다.'),
          s.actor.active ? tr('활성화') : tr('비활성화'),
        ),
      ]),
    ],
  );

  Widget generalSettings() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      settingsGroup(
        tr('계정'),
        [
          (tr('이름'), tr('참여 중인 모든 프로젝트에서 사용하는 표시 이름입니다.'), s.actor.name),
          (tr('GitHub 계정'), tr('표시 이름과 별개의 로그인 식별자입니다.'), s.actor.login),
        ],
        actions: {
          if (s.isProject && widget.session != null)
            tr('이름'): OutlinedButton.icon(
              key: const Key('change-account-name'),
              onPressed: nameBusy ? null : renameAccount,
              icon: const Icon(Icons.edit_outlined, size: 16),
              label: Text(nameBusy ? tr('이름 반영 중…') : tr('이름 변경')),
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
      const SizedBox(height: 24),
      settingsGroup(
        tr('앱 정보'),
        [(tr('이음 버전'), tr('새 버전을 확인하고 다운로드합니다.'), appVersion)],
        actions: {tr('이음 버전'): const UpdateButton()},
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
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ink),
      ),
      const SizedBox(height: 14),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        decoration: BoxDecoration(
          color: surface,
          border: Border.all(color: colors.line),
          borderRadius: BorderRadius.circular(WorkspaceUi.radius),
        ),
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(height: 1, color: border),
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
                style: TextStyle(fontSize: 11, color: muted, height: 1.5),
              ),
            ],
          );
          final valueText = SelectableText(
            row.$3,
            textAlign: TextAlign.left,
            style: TextStyle(fontSize: 12, color: muted, height: 1.5),
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
        title: Text(tr('작업을 삭제할까요?')),
        content: Text(
          tr(
            '“{value0}”\n\n목록·칸반·일정에서 삭제됩니다. GitHub 동기화 후 팀에도 반영됩니다. 앱에서 복원할 수 없습니다.',
            args: {'value0': task.title},
          ),
        ),
        actions: [
          TextButton(
            key: const Key('task-delete-cancel'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const Key('task-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xffc44848),
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('삭제')),
          ),
        ],
      ),
    );
    if (confirmed != true || !ctx.mounted) return;
    action(() {
      s.deleteTask(task.id, expectedVersion: task.version);
      Navigator.pop(ctx);
      message(tr('작업을 삭제했습니다.'));
    });
  }

  Widget taskDetailProperties(String title, Map<String, String> values) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: WorkspaceUi.sectionStyleOf(context)),
          const SizedBox(height: 14),
          for (final entry in values.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 100,
                    child: Text(
                      entry.key,
                      style: WorkspaceUi.captionStyleOf(context),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SelectableText(
                      entry.value.isEmpty ? tr('미정') : entry.value,
                      style: const TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );

  Widget taskDetailAssignment(WorkTask task, TaskHandoffPlan? transfer) {
    final groupAssignment = taskAssigneeId(task).isEmpty;
    return Container(
      key: ValueKey('task-detail-assignment-${task.id}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.subtle,
        borderRadius: BorderRadius.circular(WorkspaceUi.radius),
      ),
      child: Row(
        children: [
          groupAssignment
              ? CircleAvatar(
                  radius: 18,
                  backgroundColor: colors.subtle,
                  child: Icon(Icons.groups_outlined, size: 20, color: muted),
                )
              : avatar(s.member(taskAssigneeId(task)), size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('담당자'), style: WorkspaceUi.captionStyleOf(context)),
                const SizedBox(height: 3),
                Tooltip(
                  message: taskAssigneeLabel(task),
                  child: Text(
                    taskAssigneeLabel(task),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  taskPartLabel(task),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: WorkspaceUi.captionStyleOf(context),
                ),
              ],
            ),
          ),
          if (transfer != null) ...[
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 120),
              child: handoffButton(transfer, secondary: true),
            ),
          ],
        ],
      ),
    );
  }

  Widget detailBody(BuildContext ctx, WorkTask t) {
    if (t.isDeleted) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(tr('삭제된 작업입니다.')),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('닫기')),
            ),
          ],
        ),
      );
    }
    final lockReason = !s.canEditContent(t) ? s.editLockReason(t) : '';
    final history = s.activityFor(t.id);
    final handoffs = s.availableHandoffs(t);
    final transfers = s.availableTransfers(t);
    final transfer = transfers.firstOrNull;
    final primary = handoffs
        .where(
          (p) => const {
            'manual-start',
            'manual-resume',
            'manual-restore',
          }.contains(p.routeId),
        )
        .firstOrNull;
    final statusActions = handoffs
        .where((p) => p.routeId != primary?.routeId)
        .toList();
    return Column(
      children: [
        TaskDetailToolbar(
          taskId: t.id,
          displayId: shortId(t.id),
          title: t.title,
          statusKey: boardKey(t),
          statusLabel: boardStatuses[boardKey(t)]!,
          onClose: () => Navigator.pop(ctx),
          onEdit: s.canEdit(t) ? () => edit(t) : null,
          primaryAction: primary == null ? null : handoffButton(primary),
          statusActions: statusActions,
          onStatusSelected: confirmHandoff,
          menuActions: [
            if (s.canPin(t))
              TaskDetailMenuAction(
                key: Key('task-pin-detail-${t.id}'),
                label: t.isPinned ? tr('상단 고정 해제') : tr('상단에 고정'),
                icon: t.isPinned
                    ? Icons.push_pin_rounded
                    : Icons.push_pin_outlined,
                onPressed: () => toggleTaskPin(t),
              ),
            if (s.canSetTaskLock(t))
              TaskDetailMenuAction(
                key: Key('task-lock-${t.id}'),
                label: t.isLocked ? tr('잠금 해제') : tr('나만 수정하도록 잠금'),
                icon: t.isLocked
                    ? Icons.lock_open_rounded
                    : Icons.lock_outline_rounded,
                onPressed: () => action(
                  () => s.setTaskLocked(
                    t.id,
                    !t.isLocked,
                    expectedVersion: t.version,
                  ),
                ),
              ),
            if (s.canArchive(t))
              TaskDetailMenuAction(
                key: Key('task-archive-${t.id}'),
                label: t.isArchived ? tr('보관함에서 복원') : tr('보관함으로 이동'),
                icon: t.isArchived
                    ? Icons.unarchive_outlined
                    : Icons.inventory_2_outlined,
                onPressed: () => action(() {
                  s.setArchived(
                    t.id,
                    !t.isArchived,
                    expectedVersion: t.version,
                  );
                  Navigator.pop(ctx);
                  message(
                    t.isArchived ? tr('작업을 복원했습니다.') : tr('작업을 보관함으로 옮겼습니다.'),
                  );
                }),
              ),
            if (s.canDelete(t))
              TaskDetailMenuAction(
                key: Key('task-delete-${t.id}'),
                label: tr('작업 삭제'),
                icon: Icons.delete_outline,
                destructive: true,
                onPressed: () => confirmTaskDeletion(ctx, t),
              ),
          ],
        ),
        Expanded(
          child: ListView(
            key: ValueKey('task-detail-content-${t.id}'),
            padding: const EdgeInsets.all(24),
            children: [
              taskDetailAssignment(t, transfer),
              const SizedBox(height: 24),
              Text(
                tr('설명'),
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              if (t.description.isEmpty)
                Text(
                  tr('작성된 설명이 없습니다.'),
                  style: TextStyle(fontSize: 12, color: muted),
                )
              else
                MarkdownContent(data: t.description),
              const SizedBox(height: 24),
              TaskResourcesPanel(
                key: ValueKey('task-resources-${t.id}'),
                store: s,
                taskId: t.id,
                sync: widget.sync,
              ),
              const SizedBox(height: 24),
              taskDetailProperties(tr('작업 정보'), {
                tr('우선순위'): priorities[t.priority]!,
                tr('요청 유형'): purposeLabel(t),
                tr('등록 파트'): t.part,
                tr('잠금'): t.isLocked
                    ? tr(
                        '설정됨 · {value0}',
                        args: {'value0': s.member(t.lockedBy).name},
                      )
                    : tr('설정되지 않음'),
                if (s.project?.workflowSheet == null)
                  tr('검토 담당자'): s.member(t.reviewerId).name,
                if (!boardStatuses.containsKey(t.status))
                  tr('세부 상태'): trStageName(
                    t.status,
                    s.workflowStatusName(t.status),
                  ),
              }),
              Divider(height: 32, color: colors.line),
              taskDetailProperties(tr('일정'), {
                tr('시작일'): displayDate(t.assignedDate),
                tr('마감일'): displayDate(t.dueDate),
                tr('완료일'): t.completedDate.isEmpty
                    ? '—'
                    : displayDate(t.completedDate),
              }),
              Divider(height: 32, color: colors.line),
              taskDetailProperties(tr('작성 기록'), {
                tr('작성자'): t.creatorId.isEmpty
                    ? tr('기록 없음')
                    : s.member(t.creatorId).name,
                tr('작성일'): displayDateTime(t.createdAt),
                if (t.workflowSender.isNotEmpty)
                  tr('마지막 전달자'): s.member(t.workflowSender).name,
              }),
              if (t.reworkReason.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: colors.subtle,
                    borderRadius: BorderRadius.circular(WorkspaceUi.radius),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('전달 메시지'),
                        style: WorkspaceUi.sectionStyleOf(context),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(
                        t.reworkReason,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.6,
                          color: muted,
                        ),
                      ),
                    ],
                  ),
                ),
              Divider(height: 43, color: border),
              if (lockReason.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.lock_outline, size: 16, color: muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          lockReason,
                          style: TextStyle(
                            fontSize: 11,
                            color: muted,
                            height: 1.6,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              TaskCommentsPanel(
                key: ValueKey('comments-${t.id}'),
                store: s,
                task: t,
              ),
              if (t.transitionHistory.isNotEmpty) ...[
                Divider(height: 36, color: border),
                Text(
                  tr('상태 · 전달 기록'),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                for (final event in t.transitionHistory.reversed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${s.member(event['actorId']).name} · ${trStageName(event['from'], s.workflowStatusName(event['from']))} → ${trStageName(event['to'], s.workflowStatusName(event['to']))}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${tr(workflowPurposeLabels[event['purpose']] ?? '작업')} · ${event['recipientId'] == ''
                              ? event['recipientGroup'] == ''
                                    ? tr('모든 작업자')
                                    : workflowCurrentPartLabel(t.copy({'workflowTarget': event['recipientGroup'], 'workflowPerson': ''}), s.project)
                              : s.member(event['recipientId']).name} · ${displayDateTime(event['createdAt'])}',
                          style: TextStyle(fontSize: 10, color: muted),
                        ),
                        if ((event['comment'] as String).isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: SelectableText(
                              event['comment'],
                              style: TextStyle(fontSize: 11, color: muted),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],

              if (history.isNotEmpty) const SizedBox(height: 30),
              if (history.isNotEmpty)
                Text(
                  tr('활동 기록'),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              const SizedBox(height: 13),
              ...history.map(
                (a) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Text(
                    '${s.member(a['actorId']).name} · ${displayActivityMessage(a['message'])}',
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
