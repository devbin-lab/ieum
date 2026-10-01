import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import 'models.dart';
import 'store.dart';
import 'task_editor.dart';

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
Widget avatar(String id, {double size = 28}) {
  final p = person(id);
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
  const IeumApp({super.key, required this.store});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '이음 · Flutter',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      fontFamily: 'Malgun Gothic',
      colorScheme: ColorScheme.fromSeed(
        seedColor: purple,
        surface: Colors.white,
      ),
      scaffoldBackgroundColor: canvas,
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
    home: Workspace(store: store),
  );
}

class Workspace extends StatefulWidget {
  final TaskStore store;
  const Workspace({super.key, required this.store});
  @override
  State<Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<Workspace> {
  int page = 0;
  String search = '', part = '', scope = 'all';
  bool fileBusy = false;
  TaskStore get s => widget.store;
  static const titles = ['칸반보드', '일정 · 작업', '내 변경내역', '연결 설정'];
  static const subtitles = [
    '작업의 흐름을 한눈에.',
    '담당자와 날짜를 함께 확인하세요.',
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
          builder: (ctx) => AlertDialog(
            title: const Text('통합 전 확인이 필요해요'),
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
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('알림 미리보기'),
        content: SizedBox(
          width: 470,
          height: 440,
          child: AnimatedBuilder(
            animation: s,
            builder: (_, _) => ListView(
              children: [
                const Text(
                  'Discord 연결 전의 로컬 이벤트입니다. 외부로 전송하지 않습니다.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
                const SizedBox(height: 20),
                if (s.notifications.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(30),
                    child: Text('작업을 등록하거나 상태를 변경해 보세요.'),
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
                        badge('미리보기'),
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
                          '${n['eventType'] == 'task.created' ? '새 작업 등록' : statuses[n['status']]!} → ${person(n['recipientId']).name}',
                          style: const TextStyle(fontSize: 11, color: muted),
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
                  topbar(),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (ctx, constraints) => SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(34, 34, 34, 30),
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
                                          titles[page],
                                          style: const TextStyle(
                                            fontSize: 27,
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -1,
                                          ),
                                        ),
                                        const SizedBox(height: 9),
                                        Text(
                                          subtitles[page],
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: muted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  FilledButton.icon(
                                    key: const Key('new-task'),
                                    onPressed: () => edit(),
                                    icon: const Icon(Icons.add, size: 18),
                                    label: const Text(
                                      '작업 등록',
                                      style: TextStyle(fontSize: 12),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 30),
                              if (page < 2) ...[
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
                                    const Text(
                                      '예시 데이터로 흐름을 테스트해 보세요.',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: muted,
                                      ),
                                    ),
                                    const Spacer(),
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
                                if (page == 0)
                                  board(filtered, constraints.maxWidth - 68)
                                else
                                  schedule(filtered),
                              ],
                              if (page == 2) changesPanel(),
                              if (page == 3) settingsPanel(),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  Container(
                    height: 43,
                    padding: const EdgeInsets.symmetric(horizontal: 34),
                    decoration: const BoxDecoration(
                      border: Border(top: BorderSide(color: border)),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.circle, size: 6, color: Color(0xff68aa8d)),
                        SizedBox(width: 7),
                        Text(
                          'SQLite에 자동 저장',
                          style: TextStyle(fontSize: 9, color: muted),
                        ),
                        Spacer(),
                        Text(
                          '이음 0.1 · Flutter 데스크톱',
                          style: TextStyle(fontSize: 9, color: muted),
                        ),
                      ],
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
  Widget sidebar() => Container(
    width: 228,
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(right: BorderSide(color: border)),
    ),
    padding: const EdgeInsets.fromLTRB(18, 30, 18, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Container(
                width: 39,
                height: 39,
                decoration: BoxDecoration(
                  color: purple,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Center(
                  child: Icon(
                    Icons.all_inclusive,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
              const SizedBox(width: 11),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '이음',
                    style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    'IEUM',
                    style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 3,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 35),
        Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: const Color(0xfff0edf9),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.folder_copy_outlined,
                  size: 19,
                  color: purple,
                ),
              ),
              const SizedBox(width: 9),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '졸업작품 팀',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  SizedBox(height: 4),
                  Text('예시 프로젝트', style: TextStyle(fontSize: 10, color: muted)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        const Padding(
          padding: EdgeInsets.only(left: 13),
          child: Text('작업 공간', style: TextStyle(fontSize: 10, color: muted)),
        ),
        const SizedBox(height: 10),
        ...List.generate(
          4,
          (i) => Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Material(
              color: page == i ? const Color(0xffefebfc) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                key: Key('nav-$i'),
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => page = i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        [
                          Icons.dashboard_outlined,
                          Icons.calendar_month_outlined,
                          Icons.merge_outlined,
                          Icons.link,
                        ][i],
                        size: 19,
                        color: page == i ? purple : muted,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        titles[i],
                        style: TextStyle(
                          fontSize: 12,
                          color: page == i ? purple : muted,
                          fontWeight: page == i
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                      if (i == 2 && s.changes.isNotEmpty) ...[
                        const Spacer(),
                        badge('${s.changes.length}', color: purple),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        const Spacer(),
        const Padding(
          padding: EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.circle, size: 6, color: Color(0xff68aa8d)),
                  SizedBox(width: 7),
                  Text(
                    '개인 작업 공간',
                    style: TextStyle(fontSize: 10, color: muted),
                  ),
                ],
              ),
              SizedBox(height: 10),
              Text(
                '내 변경은 이 컴퓨터에 저장돼요.\n통합 전까지 팀원에게 반영되지 않아요.',
                style: TextStyle(fontSize: 10, color: muted, height: 1.8),
              ),
            ],
          ),
        ),
        const Divider(color: border, height: 35),
        const Row(
          children: [
            Text('테스트 사용자', style: TextStyle(fontSize: 10, color: muted)),
            Spacer(),
            Text(
              'DEMO',
              style: TextStyle(fontSize: 9, color: muted, letterSpacing: 1),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            avatar(s.profileId),
            const SizedBox(width: 9),
            Expanded(
              child: DropdownButton<String>(
                key: const Key('profile'),
                value: s.profileId,
                isExpanded: true,
                underline: const SizedBox(),
                style: const TextStyle(fontSize: 12, color: ink),
                items: members
                    .map(
                      (m) => DropdownMenuItem(value: m.id, child: Text(m.name)),
                    )
                    .toList(),
                onChanged: (value) => s.setProfile(value!),
              ),
            ),
          ],
        ),
        const Text(
          '역할을 바꿔 검토 과정을 테스트하세요.',
          style: TextStyle(fontSize: 9, color: muted),
        ),
      ],
    ),
  );
  Widget topbar() => Container(
    height: 76,
    padding: const EdgeInsets.symmetric(horizontal: 34),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: border)),
    ),
    child: Row(
      children: [
        const Text('졸업작품 팀', style: TextStyle(fontSize: 11, color: muted)),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 13),
          child: Text('/', style: TextStyle(color: border)),
        ),
        Text(titles[page], style: const TextStyle(fontSize: 11, color: muted)),
        const Spacer(),
        badge('Flutter · 로컬 프로토타입', color: purple),
        const SizedBox(width: 13),
        IconButton(
          tooltip: '알림 미리보기',
          onPressed: notifications,
          icon: Badge(
            isLabelVisible: s.notifications.isNotEmpty,
            smallSize: 5,
            backgroundColor: purple,
            child: const Icon(
              Icons.notifications_none_outlined,
              size: 20,
              color: muted,
            ),
          ),
        ),
        const SizedBox(width: 10),
        avatar(s.profileId),
      ],
    ),
  );
  Widget stats(List<WorkTask> tasks) => Row(
    children: List.generate(
      4,
      (i) => Expanded(
        child: Container(
          margin: EdgeInsets.only(right: i < 3 ? 15 : 0),
          height: 97,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(11),
          ),
          child: Row(
            children: [
              Column(
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
              const Spacer(),
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
  Widget toolbar() => Wrap(
    alignment: WrapAlignment.spaceBetween,
    runSpacing: 12,
    spacing: 20,
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
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
      Row(
        mainAxisSize: MainAxisSize.min,
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
          const SizedBox(width: 9),
          SizedBox(
            width: 140,
            child: DropdownButtonFormField<String>(
              key: ValueKey('filter-$part'),
              initialValue: part,
              style: const TextStyle(fontSize: 11, color: ink),
              items: [
                const DropdownMenuItem(value: '', child: Text('모든 파트')),
                ...rules.map(
                  (r) => DropdownMenuItem(value: r.part, child: Text(r.part)),
                ),
              ],
              onChanged: (value) => setState(() => part = value!),
            ),
          ),
        ],
      ),
    ],
  );
  Widget board(List<WorkTask> tasks, double available) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
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
                  message: person(t.currentId).name,
                  child: avatar(t.currentId, size: 25),
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
                      '${person(t.reviewerId).name} 검토 대기',
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
    width: double.infinity,
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: border),
      borderRadius: BorderRadius.circular(10),
    ),
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
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
                  DataCell(Text(person(t.assigneeId).name)),
                  DataCell(Text(person(t.currentId).name)),
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
            '기준 통합본: ${s.baseRevision} · 커밋과 PR은 아직 연결되지 않았습니다.',
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
        '같은 항목이 양쪽에서 다르게 바뀌면 통합을 멈추고 충돌을 표시합니다. 내보내기는 변경안, 가져오기는 승인된 전체 통합본 형식입니다.',
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
  Widget settingsPanel() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: integration(
              'GitHub',
              '앱 연동 예정',
              Icons.merge_outlined,
              '개인 브랜치와 PR로 변경을 검토하고,\n승인된 통합본을 팀과 공유합니다.',
              'devbin-lab / ieum',
              '현재는 JSON 내보내기 / 가져오기를 지원합니다.',
            ),
          ),
          const SizedBox(width: 22),
          Expanded(
            child: integration(
              'Discord',
              '미연결',
              Icons.chat_bubble_outline,
              '작업 등록 · 검토 · 재작업 · 완료를\n담당자에게 안내하도록 준비합니다.',
              '알림 미리보기 ${s.notifications.length}건',
              '외부 메시지는 전송하지 않습니다.',
              button: OutlinedButton(
                onPressed: notifications,
                child: const Text(
                  '알림 대기 목록 보기',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 29),
      heading('파트별 기본 배정', '파트를 선택하면 기본 작업자와 검토자가 자동으로 배정됩니다.'),
      const SizedBox(height: 18),
      Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(10),
        ),
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
          rows: rules
              .map(
                (r) => DataRow(
                  cells: [
                    DataCell(Text(r.part)),
                    DataCell(Text(person(r.assigneeId).name)),
                    DataCell(Text(person(r.reviewerId).name)),
                    DataCell(Text(r.nextPart.isEmpty ? '—' : r.nextPart)),
                  ],
                ),
              )
              .toList(),
        ),
      ),
      info(
        '공유 서버 없이 개인 SQLite를 사용합니다. GitHub 인증·자동 PR, Discord 전송, 후속 파트의 새 작업 생성은 다음 구현 단계입니다.',
      ),
    ],
  );
  Widget integration(
    String name,
    String state,
    IconData icon,
    String description,
    String target,
    String note, {
    Widget? button,
  }) => Container(
    padding: const EdgeInsets.all(27),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: border),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(13),
              decoration: BoxDecoration(
                color: const Color(0xfff0ecfa),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: purple, size: 27),
            ),
            const Spacer(),
            badge(state),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          name,
          style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Text(
          description,
          style: const TextStyle(fontSize: 12, color: muted, height: 1.9),
        ),
        const SizedBox(height: 23),
        SelectableText(
          target,
          style: const TextStyle(fontSize: 12, color: purple),
        ),
        const SizedBox(height: 18),
        ?button,
        const SizedBox(height: 17),
        Text(note, style: const TextStyle(fontSize: 10, color: muted)),
      ],
    ),
  );
  Widget detailBody(BuildContext ctx, WorkTask t) {
    final actor = person(s.profileId);
    final canEdit = actor.id == t.assigneeId || actor.role == 'manager';
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
          '작업 담당자': person(t.assigneeId).name,
          '검토 담당자': person(t.reviewerId).name,
          '현재 처리자': person(t.currentId).name,
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
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (canEdit)
              OutlinedButton(
                onPressed: () => edit(t),
                child: const Text('작업 수정'),
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
              '${person(a['actorId']).name} · ${a['message']}',
              style: const TextStyle(fontSize: 11, color: muted),
            ),
          ),
        ),
      ],
    );
  }
}
