import 'package:flutter/material.dart';

enum SettingsSection {
  general('일반', '개인', Icons.tune_rounded, '버전 계정 이름'),
  projectGeneral('일반', '프로젝트', Icons.folder_outlined, '저장 폴더 저장소'),
  notifications('알림', '프로젝트', Icons.notifications_none_rounded, '앱 알림함 작업 배정'),
  team('참여자 관리', '프로젝트', Icons.people_outline_rounded, '팀원 역할 가입 승인'),
  roles('역할 · 권한', '프로젝트', Icons.admin_panel_settings_outlined, '역할 추가 생성 권한'),
  assignments('파트별 배정', '프로젝트', Icons.account_tree_outlined, '담당자 검토자 작업'),
  github('GitHub 동기화', '통합', Icons.sync_rounded, '저장소 브랜치 PR 전송'),
  changes('내 변경내역', '통합', Icons.history_rounded, '변경안 가져오기 내보내기');

  const SettingsSection(this.title, this.group, this.icon, this.keywords);
  final String title, group, keywords;
  final IconData icon;
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
  });

  final bool? personal;
  final String? projectName;
  final Widget? projectSelector;
  final SettingsSection selected;
  final ValueChanged<SettingsSection> onSelected;
  final Widget Function(SettingsSection) contentBuilder;

  @override
  State<SettingsShell> createState() => _SettingsShellState();
}

class _SettingsShellState extends State<SettingsShell> {
  final drawerKey = GlobalKey<ScaffoldState>();
  final search = TextEditingController();
  final navigationScroll = ScrollController();
  final contentScroll = ScrollController();

  @override
  void didUpdateWidget(covariant SettingsShell oldWidget) {
    super.didUpdateWidget(oldWidget);
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
              (widget.personal == null ||
                  (s == SettingsSection.general) == widget.personal) &&
              '${s.title} ${s.group} ${s.keywords}'.toLowerCase().contains(
                query,
              ),
        )
        .toList();
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 760;
        final navigationWidth = constraints.maxWidth < 960 ? 208.0 : 240.0;
        return Scaffold(
          key: drawerKey,
          backgroundColor: Colors.white,
          drawer: compact
              ? Drawer(
                  width: constraints.maxWidth.clamp(200.0, 280.0),
                  child: navigation(sections, 280),
                )
              : null,
          body: compact
              ? Column(
                  key: const Key('settings-shell'),
                  children: [
                    Container(
                      height: 52,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: const BoxDecoration(
                        color: Color(0xfff8f9f8),
                        border: Border(
                          bottom: BorderSide(color: Color(0xffe1e4e3)),
                        ),
                      ),
                      child: Row(
                        children: [
                          TextButton.icon(
                            key: const Key('settings-category-menu'),
                            onPressed: () =>
                                drawerKey.currentState?.openDrawer(),
                            icon: const Icon(Icons.menu_rounded, size: 19),
                            label: const Text('설정 항목'),
                          ),
                          const Spacer(),
                          Flexible(
                            child: Text(
                              widget.personal == true ? '개인 설정' : '프로젝트 설정',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: content(compact: true)),
                  ],
                )
              : Row(
                  key: const Key('settings-shell'),
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    navigation(sections, navigationWidth),
                    Expanded(child: content()),
                  ],
                ),
        );
      },
    );
  }

  Widget navigation(List<SettingsSection> sections, double width) => Container(
    key: const Key('settings-navigation'),
    width: width,
    padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
    decoration: const BoxDecoration(
      color: Color(0xfff8f9f8),
      border: Border(right: BorderSide(color: Color(0xffe1e4e3))),
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
          padding: const EdgeInsets.only(left: 8, bottom: 18),
          child: Text(
            widget.personal == null
                ? '설정'
                : widget.personal!
                ? '개인 설정'
                : '프로젝트 설정',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        if (widget.personal != true)
          TextField(
            key: const Key('settings-search'),
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '검색',
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              suffixIcon: search.text.trim().isEmpty
                  ? null
                  : IconButton(
                      tooltip: '검색 지우기',
                      icon: const Icon(Icons.close_rounded, size: 16),
                      onPressed: () => setState(search.clear),
                    ),
              fillColor: const Color(0xffecefee),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
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
                          group,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xff7d8380),
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
                              ? const Color(0xffe9edeb)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(8),
                          child: InkWell(
                            key: Key('settings-${section.name}'),
                            borderRadius: BorderRadius.circular(8),
                            onTap: () {
                              drawerKey.currentState?.closeDrawer();
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
                                    color: const Color(0xff505753),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      section.title,
                                      style: const TextStyle(fontSize: 12),
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
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('검색 결과가 없습니다.', style: TextStyle(fontSize: 12)),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );

  Widget content({bool compact = false}) => Material(
    color: Colors.white,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const Key('settings-page-header'),
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 28,
            20,
            compact ? 16 : 28,
            20,
          ),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0xffe8ebe9))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.selected.title,
                key: const Key('settings-content-title'),
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: Color(0xff242825),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.personal == false
                    ? '${widget.projectName ?? ''} · 이 프로젝트에만 적용'
                    : '계정과 이 컴퓨터의 앱 설정을 관리합니다.',
                key: widget.personal == false
                    ? const Key('settings-project-scope')
                    : null,
                style: const TextStyle(fontSize: 12, color: Color(0xff666e68)),
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
                compact ? 16 : 28,
                24,
                compact ? 16 : 28,
                36,
              ),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1120),
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
          ),
        ),
      ],
    ),
  );
}
