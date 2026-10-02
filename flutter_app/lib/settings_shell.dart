import 'package:flutter/material.dart';

enum SettingsSection {
  general('일반', '개인', Icons.tune_rounded, '프로젝트 설정 저장 폴더 버전 계정'),
  notifications('알림', '개인', Icons.notifications_none_rounded, 'Discord 디스코드'),
  team('참여자 · 권한', '프로젝트', Icons.people_outline_rounded, '팀원 역할 가입 승인'),
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
  });

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
          (s) => '${s.title} ${s.group} ${s.keywords}'.toLowerCase().contains(
            query,
          ),
        )
        .toList();
    return Row(
      key: const Key('settings-shell'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          key: const Key('settings-navigation'),
          width: 240,
          padding: const EdgeInsets.fromLTRB(12, 18, 12, 12),
          decoration: const BoxDecoration(
            color: Color(0xfff8f9f8),
            border: Border(right: BorderSide(color: Color(0xffe1e4e3))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 8, bottom: 18),
                child: Text(
                  '설정',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              TextField(
                key: const Key('settings-search'),
                controller: search,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '검색',
                  prefixIcon: const Icon(Icons.search_rounded, size: 18),
                  suffixIcon: query.isEmpty
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
                                  onTap: () => widget.onSelected(section),
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
                                            style: const TextStyle(
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
                          const SizedBox(height: 12),
                        ],
                      if (sections.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            '검색 결과가 없습니다.',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: Colors.white,
            child: Scrollbar(
              controller: contentScroll,
              child: SingleChildScrollView(
                key: const Key('settings-content-scroll'),
                controller: contentScroll,
                padding: const EdgeInsets.fromLTRB(28, 48, 28, 36),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 960),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.selected.title,
                          key: const Key('settings-content-title'),
                          style: const TextStyle(
                            fontSize: 27,
                            fontWeight: FontWeight.w700,
                            color: Color(0xff242825),
                          ),
                        ),
                        const SizedBox(height: 32),
                        KeyedSubtree(
                          key: ValueKey(widget.selected),
                          child: widget.contentBuilder(widget.selected),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
