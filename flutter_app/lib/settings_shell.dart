import 'package:flutter/material.dart';

import 'app_localizations.dart';
import 'workspace_ui.dart';

enum SettingsSection {
  general('일반', '개인', Icons.tune_rounded, '버전 계정 이름'),
  design('디자인', '개인', Icons.palette_outlined, '테마 라이트 다크 모드 색상 포인트'),
  language('언어', '개인', Icons.language_rounded, '한국어 영어 번역 언어'),
  projectGeneral('일반', '프로젝트', Icons.folder_outlined, '저장 폴더 저장소'),
  notifications(
    '알림',
    '프로젝트',
    Icons.notifications_none_rounded,
    '앱 알림함 작업 배정 Discord 채널 웹훅 멘션',
  ),
  team('참여자 관리', '프로젝트', Icons.people_outline_rounded, '팀원 파트 가입 승인'),
  roles('파트', '프로젝트', Icons.admin_panel_settings_outlined, '파트 추가 수정 삭제 배정'),
  github('GitHub 동기화', '통합', Icons.sync_rounded, '저장소 브랜치 PR 전송'),
  changes('내 변경 기록', '통합', Icons.history_rounded, '변경안 가져오기 내보내기');

  const SettingsSection(this.title, this.group, this.icon, this.keywords);
  final String title, group, keywords;
  final IconData icon;

  bool get isPersonal => this == general || this == design || this == language;

  static SettingsSection fromSaved(Object? name) => switch (name) {
    'assignments' => roles,
    'workflow' => projectGeneral,
    _ => values.where((section) => section.name == name).firstOrNull ?? general,
  };
}

/// Independent navigation and content scrolling, following the desktop settings layout.
class SettingsShell extends StatefulWidget {
  const SettingsShell({
    super.key,
    required this.selected,
    required this.onSelected,
    required this.contentBuilder,
    this.personal,
    this.projectName,
    this.projectSelector,
    this.navigationOnly = false,
    this.contentOnly = false,
  });

  final bool? personal;
  final String? projectName;
  final Widget? projectSelector;
  final bool navigationOnly;
  final bool contentOnly;
  final SettingsSection selected;
  final ValueChanged<SettingsSection> onSelected;
  final Widget Function(SettingsSection) contentBuilder;

  @override
  State<SettingsShell> createState() => _SettingsShellState();
}

class _SettingsShellState extends State<SettingsShell> {
  final search = TextEditingController();
  final navigationScroll = ScrollController();
  final contentScroll = ScrollController();

  @override
  void didUpdateWidget(covariant SettingsShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.personal != widget.personal) {
      search.clear();
    }
    if (oldWidget.selected != widget.selected && contentScroll.hasClients) {
      contentScroll.jumpTo(0);
    }
  }

  @override
  void dispose() {
    search.dispose();
    navigationScroll.dispose();
    contentScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final sections = SettingsSection.values
        .where(
          (s) =>
              (widget.personal == null || s.isPersonal == widget.personal) &&
              '${s.title} ${s.group} ${s.keywords} ${tr(s.title)} ${tr(s.group)}'
                  .toLowerCase()
                  .contains(query),
        )
        .toList();
    if (widget.navigationOnly) {
      return navigation(sections, 210);
    }
    if (widget.contentOnly) {
      return KeyedSubtree(
        key: const Key('settings-shell'),
        child: detailView(),
      );
    }
    return Row(
      key: const Key('settings-shell'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        navigation(sections, 210),
        Expanded(child: detailView()),
      ],
    );
  }

  Widget detailView() => LayoutBuilder(
    builder: (context, constraints) =>
        content(compact: constraints.maxWidth < 760),
  );

  Widget navigation(List<SettingsSection> sections, double width) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: navigationPane(sections, width),
  );

  Widget navigationPane(
    List<SettingsSection> sections,
    double width,
  ) => Container(
    key: const Key('settings-navigation'),
    width: width,
    padding: const EdgeInsets.fromLTRB(12, 24, 12, 12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(
        right: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.personal == false && widget.projectSelector != null) ...[
          SizedBox(
            key: const Key('settings-project-selector'),
            width: double.infinity,
            child: widget.projectSelector!,
          ),
          const SizedBox(height: 18),
        ],
        Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 16),
          child: Text(
            tr(
              widget.personal == null
                  ? '설정'
                  : widget.personal!
                  ? '개인 설정'
                  : '프로젝트 설정',
            ),
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
        ),
        if (widget.personal != true)
          TextField(
            key: const Key('settings-search'),
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: tr('설정 검색'),
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              suffixIcon: search.text.trim().isEmpty
                  ? null
                  : IconButton(
                      tooltip: tr('검색 지우기'),
                      icon: const Icon(Icons.close_rounded, size: 16),
                      onPressed: () => setState(search.clear),
                    ),
              fillColor: Theme.of(context).colorScheme.surfaceContainerLow,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
            ),
          ),
        const SizedBox(height: 16),
        Expanded(
          child: Scrollbar(
            controller: navigationScroll,
            child: ListView(
              controller: navigationScroll,
              children: [
                for (final group in ['개인', '프로젝트', '통합'])
                  if (sections.any((s) => s.group == group)) ...[
                    if (widget.personal != true)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 12, 8, 8),
                        child: Text(
                          tr(group),
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                      ),
                    for (final section in sections.where(
                      (s) => s.group == group,
                    ))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Material(
                          color: section == widget.selected
                              ? Theme.of(context).colorScheme.primary
                                    .withValues(alpha: .1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            key: Key('settings-${section.name}'),
                            borderRadius: BorderRadius.circular(8),
                            onTap: () {
                              widget.onSelected(section);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    section.icon,
                                    size: 17,
                                    color: section == widget.selected
                                        ? Theme.of(context).colorScheme.primary
                                        : Theme.of(context)
                                              .colorScheme
                                              .onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      tr(section.title),
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: section == widget.selected
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurface,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                  ],
                if (sections.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      tr('검색 결과가 없습니다.'),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget content({bool compact = false}) => contentPane(compact: compact);

  Widget contentPane({bool compact = false}) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const Key('settings-page-header'),
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : WorkspaceUi.contentPadding,
            24,
            compact ? 16 : WorkspaceUi.contentPadding,
            20,
          ),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tr(widget.selected.title),
                key: const Key('settings-content-title'),
                style: WorkspaceUi.titleStyle.copyWith(
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.personal == false
                    ? widget.projectName?.isNotEmpty == true
                          ? '${widget.projectName} · ${tr('프로젝트 설정')}'
                          : tr('프로젝트 설정')
                    : tr('계정 및 앱 환경 설정'),
                key: widget.personal == false
                    ? const Key('settings-project-scope')
                    : null,
                style: WorkspaceUi.captionStyle.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Scrollbar(
            controller: contentScroll,
            child: SingleChildScrollView(
              key: const Key('settings-content-scroll'),
              controller: contentScroll,
              padding: EdgeInsets.fromLTRB(
                compact ? 16 : WorkspaceUi.contentPadding,
                24,
                compact ? 16 : WorkspaceUi.contentPadding,
                36,
              ),
              child: SizedBox(
                width: double.infinity,
                child: KeyedSubtree(
                  key: ValueKey(widget.selected),
                  child: widget.contentBuilder(widget.selected),
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
