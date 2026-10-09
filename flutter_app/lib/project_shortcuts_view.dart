import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'app_localizations.dart';
import 'desktop_platform.dart';
import 'github_sync.dart';
import 'models.dart';
import 'popup_ui.dart';
import 'shortcut_service_icon.dart';
import 'shortcut_site_icon.dart';
import 'store.dart';
import 'workspace_ui.dart';

typedef SaveProjectShortcuts = Future<void> Function(
  List<ProjectShortcut> shortcuts,
  List<ProjectShortcut>? expected,
);

class ProjectShortcutsView extends StatefulWidget {
  const ProjectShortcutsView({
    super.key,
    required this.store,
    this.repository,
    this.onSave,
    this.onOpen,
    this.discoverIcon,
  });

  final TaskStore store;
  final String? repository;
  final SaveProjectShortcuts? onSave;
  final Future<void> Function(String)? onOpen;
  final Future<ShortcutSiteIconResult?> Function(String)? discoverIcon;

  @override
  State<ProjectShortcutsView> createState() => _ProjectShortcutsViewState();
}

class _ProjectShortcutsViewState extends State<ProjectShortcutsView> {
  final _search = TextEditingController();
  bool _saving = false;
  String _preferencesKey = '';
  Set<String> _favorites = {};
  String _serviceFilter = 'all';
  String _sort = 'registered';
  bool _catalog = false;

  @override
  void didUpdateWidget(ProjectShortcutsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) _preferencesKey = '';
  }

  bool get _canEdit => widget.onSave != null && widget.store.actor.active;
  List<ProjectShortcut> get _entries => effectiveProjectShortcuts(
    widget.store.project?.shortcuts,
    repository: widget.repository,
  );

  void _loadPreferences() {
    final key =
        'ui.shortcuts.${widget.store.project?.id}.${widget.store.actor.id}';
    if (key == _preferencesKey) return;
    _preferencesKey = key;
    _favorites = {};
    _serviceFilter = 'all';
    _sort = 'registered';
    try {
      final value = jsonDecode(widget.store.meta(key));
      if (value is! Map) return;
      final favorites = value['favorites'];
      if (favorites is List) {
        _favorites = favorites
            .whereType<String>()
            .take(maxProjectShortcuts)
            .toSet();
      }
      if (shortcutServices.containsKey(value['service'])) {
        _serviceFilter = value['service'] as String;
      }
      if (value['sort'] == 'name') _sort = 'name';
    } on FormatException {
      // Older projects have no personal shortcut preferences.
    }
  }

  void _savePreferences({
    Set<String>? favorites,
    String? service,
    String? sort,
  }) {
    final currentIds = _entries.map((entry) => entry.id).toSet();
    final nextFavorites = (favorites ?? _favorites).intersection(currentIds);
    final nextService = service ?? _serviceFilter;
    final nextSort = sort ?? _sort;
    try {
      widget.store.setMeta(
        _preferencesKey,
        jsonEncode({
          'favorites': nextFavorites.toList(),
          'service': nextService,
          'sort': nextSort,
        }),
      );
      setState(() {
        _favorites = nextFavorites;
        _serviceFilter = nextService;
        _sort = nextSort;
      });
    } catch (_) {
      _notice(tr('표시 설정을 저장하지 못했습니다. 다시 시도해 주세요.'));
    }
  }

  void _toggleFavorite(ProjectShortcut entry) => _savePreferences(
    favorites: _favorites.contains(entry.id)
        ? ({..._favorites}..remove(entry.id))
        : {..._favorites, entry.id},
  );

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _open(ProjectShortcut entry) async {
    try {
      await (widget.onOpen ?? openDesktopUrl)(entry.url);
    } catch (_) {
      _notice(tr('링크를 열지 못했습니다. 주소를 확인해 주세요.'));
    }
  }

  Future<void> _save(
    List<ProjectShortcut> entries,
    List<ProjectShortcut>? expected,
  ) async {
    if (!_canEdit) throw StateError('승인된 참여자만 변경할 수 있습니다.');
    if (_saving) throw StateError('변경 사항을 저장하고 있습니다. 잠시 후 다시 시도해 주세요.');
    setState(() => _saving = true);
    try {
      await widget.onSave!(entries, expected);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([ProjectShortcut? entry, ProjectShortcut? preset]) async {
    if (!_canEdit || _saving) return;
    final original = _entries;
    final expected = widget.store.project?.shortcuts;
    await showDialog<void>(
      context: context,
      builder: (_) => _ShortcutEditor(
        initial: entry,
        preset: preset,
        discoverIcon: widget.discoverIcon ?? discoverShortcutSiteIcon,
        onSubmit: (saved) async {
          final next = [
            for (final item in original)
              if (item.id == saved.id) saved else item,
            if (entry == null) saved,
          ];
          await _save(next, expected);
        },
      ),
    );
    if (mounted && entry == null && _entries.length > original.length) {
      setState(() {
        _catalog = false;
        _search.clear();
      });
      _savePreferences(service: 'all');
      _notice(tr('바로가기 추가됨'));
    }
  }

  Future<void> _delete(ProjectShortcut entry) async {
    if (!_canEdit || _saving) return;
    final original = _entries;
    final expected = widget.store.project?.shortcuts;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('바로가기 삭제')),
        content: Text(
          tr('“{v0}” 바로가기를 삭제할까요?', args: {'v0': _entryName(entry)}),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('취소')),
          ),
          FilledButton(
            key: const Key('shortcut-confirm-delete'),
            style: FilledButton.styleFrom(
              backgroundColor: WorkspaceUi.colors(context).danger,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('삭제')),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _save(
        original.where((item) => item.id != entry.id).toList(),
        expected,
      );
      if (mounted && _favorites.contains(entry.id)) {
        _savePreferences(favorites: {..._favorites}..remove(entry.id));
      }
    } catch (error) {
      _notice(_errorMessage(error));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => LayoutBuilder(
      builder: (context, bounds) {
        _loadPreferences();
        final colors = WorkspaceUi.colors(context);
        final padding = bounds.maxWidth < 600 ? 16.0 : 24.0;
        final query = _search.text.trim().toLowerCase();
        final source = _catalog ? defaultProjectShortcuts : _entries;
        final entries = source
            .where(
              (entry) =>
                  '${_entryName(entry)} ${_entryDescription(entry)} ${entry.url}'
                      .toLowerCase()
                      .contains(query) &&
                  (_serviceFilter == 'all' ||
                      entry.resolvedService == _serviceFilter),
            )
            .toList();
        if (_sort == 'name') {
          entries.sort(
            (a, b) =>
                _entryName(a)
                    .toLowerCase()
                    .compareTo(_entryName(b).toLowerCase()),
          );
        }
        final favorites = entries
            .where((entry) => _favorites.contains(entry.id))
            .toList();
        final others = entries
            .where((entry) => !_favorites.contains(entry.id))
            .toList();
        final columns = bounds.maxWidth < 590
            ? 1
            : bounds.maxWidth < 870
            ? 2
            : bounds.maxWidth < 1160
            ? 3
            : 4;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 24, padding, 20),
              child: WorkspacePageHeader(
                title: tr('바로가기'),
                contextLabel: widget.store.project?.name,
                subtitle: tr('팀 도구와 자료의 바로가기를 관리하세요.'),
                actions: [
                  if (_canEdit)
                    FilledButton.icon(
                      key: const Key('shortcut-add'),
                      onPressed: _saving ? null : () => _edit(),
                      icon: const Icon(Icons.add_rounded, size: 17),
                      label: Text(tr('링크 추가')),
                    ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.line),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: padding),
              child: Wrap(
                spacing: 20,
                children: [
                  _tab(false, tr('등록된 바로가기'), _entries.length),
                  _tab(true, tr('도구 추가'), null),
                ],
              ),
            ),
            Divider(height: 1, color: colors.line),
            Padding(
              padding: EdgeInsets.fromLTRB(padding, 18, padding, 6),
              child: Wrap(
                spacing: 10,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: math.min(360, bounds.maxWidth - padding * 2),
                    child: TextField(
                      key: const Key('shortcuts-search'),
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: tr('바로가기 검색'),
                        prefixIcon: const Icon(Icons.search_rounded, size: 18),
                        suffixIcon: query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: tr('검색 지우기'),
                                onPressed: () => setState(_search.clear),
                                icon: const Icon(Icons.close_rounded, size: 16),
                              ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 156,
                    child: IeumSelect(
                      key: const Key('shortcuts-service-filter'),
                      value: _serviceFilter,
                      values: {
                        'all': tr('모든 서비스'),
                        for (final service in shortcutServices.entries)
                          service.key: tr(service.value),
                      },
                      onChanged: (value) => _savePreferences(service: value),
                    ),
                  ),
                  if (!_catalog)
                    SizedBox(
                      width: 120,
                      child: IeumSelect(
                        key: const Key('shortcuts-sort'),
                        value: _sort,
                        values: {'registered': tr('등록 순'), 'name': tr('이름 순')},
                        onChanged: (value) => _savePreferences(sort: value),
                      ),
                    ),
                  Text(
                    tr(
                      _catalog ? '도구 {v0}개' : '바로가기 {v0}개',
                      args: {'v0': entries.length},
                    ),
                    style: WorkspaceUi.captionStyleOf(context),
                  ),
                ],
              ),
            ),
            if (_saving) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: entries.isEmpty
                  ? Center(
                      child: SingleChildScrollView(
                        child: Padding(
                          padding: EdgeInsets.all(padding),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.bookmarks_outlined,
                                size: 30,
                                color: colors.muted,
                              ),
                              const SizedBox(height: 14),
                              Text(
                                tr(
                                  !_catalog && _entries.isEmpty
                                      ? '등록된 바로가기가 없습니다.'
                                      : '선택한 필터에 해당하는 바로가기가 없습니다.',
                                ),
                                textAlign: TextAlign.center,
                                style: WorkspaceUi.sectionStyleOf(context),
                              ),
                              const SizedBox(height: 7),
                              Text(
                                tr(
                                  !_catalog && _entries.isEmpty
                                      ? '팀 폴더나 채팅방 주소를 입력해 바로가기를 추가하세요.'
                                      : '검색어나 서비스 필터를 변경해 보세요.',
                                ),
                                textAlign: TextAlign.center,
                                style: WorkspaceUi.captionStyleOf(context),
                              ),
                              if (!_catalog && _entries.isEmpty) ...[
                                const SizedBox(height: 20),
                                OutlinedButton.icon(
                                  key: const Key('shortcuts-browse-tools'),
                                  onPressed: () => _selectTab(true),
                                  icon: const Icon(Icons.add_rounded, size: 16),
                                  label: Text(tr('도구 찾기')),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    )
                  : CustomScrollView(
                      key: const Key('shortcuts-grid'),
                      slivers: [
                        if (_catalog)
                          ..._section(
                            tr('추천 도구'),
                            entries,
                            columns,
                            padding,
                            catalog: true,
                          ),
                        if (!_catalog && favorites.isNotEmpty)
                          ..._section(tr('즐겨찾기'), favorites, columns, padding),
                        if (!_catalog && others.isNotEmpty)
                          ..._section(tr('팀 링크'), others, columns, padding),
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(
                            padding,
                            18,
                            padding,
                            padding,
                          ),
                          sliver: SliverToBoxAdapter(
                            child: Text(
                              tr(
                                _catalog
                                    ? '팀 주소를 등록해 브라우저에서 여세요.'
                                    : '개인별 즐겨찾기와 표시 설정은 이 기기에 저장됩니다.',
                              ),
                              style: WorkspaceUi.captionStyleOf(context),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    ),
  );

  void _selectTab(bool catalog) => setState(() {
    _catalog = catalog;
    _search.clear();
  });

  Widget _tab(bool catalog, String label, int? count) {
    final colors = WorkspaceUi.colors(context);
    final selected = _catalog == catalog;
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: selected ? colors.accent : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: TextButton(
        key: Key(
          catalog ? 'shortcuts-catalog-tab' : 'shortcuts-registered-tab',
        ),
        onPressed: () => _selectTab(catalog),
        style: TextButton.styleFrom(
          foregroundColor: selected ? colors.ink : colors.muted,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 14),
          textStyle: TextStyle(
            fontFamily: 'Malgun Gothic',
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
        child: Text(count == null ? label : '$label  $count'),
      ),
    );
  }

  List<Widget> _section(
    String title,
    List<ProjectShortcut> entries,
    int columns,
    double padding, {
    bool catalog = false,
  }) => [
    SliverPadding(
      padding: EdgeInsets.fromLTRB(padding, 20, padding, 12),
      sliver: SliverToBoxAdapter(
        child: Row(
          children: [
            Text(title, style: WorkspaceUi.sectionStyleOf(context)),
            const SizedBox(width: 8),
            Text(
              '${entries.length}',
              style: WorkspaceUi.captionStyleOf(context),
            ),
          ],
        ),
      ),
    ),
    SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: padding),
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          mainAxisExtent: catalog ? 174 : 142,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) =>
              catalog ? _catalogCard(entries[index]) : _card(entries[index]),
          childCount: entries.length,
        ),
      ),
    ),
  ];

  Widget _catalogCard(ProjectShortcut entry) {
    final colors = WorkspaceUi.colors(context);
    final registered = _entries
        .where((item) => item.resolvedService == entry.service)
        .length;
    final category = switch (entry.service) {
      'drive' || 'notion' => '문서',
      'jira' => '작업 관리',
      'discord' || 'kakao' || 'slack' => '커뮤니케이션',
      'github' => '개발',
      _ => '디자인',
    };
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('shortcut-catalog-${entry.service}'),
        onTap: _canEdit && !_saving ? () => _edit(null, entry) : null,
        hoverColor: colors.subtle,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _ServiceIcon(service: entry.service),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _entryName(entry),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colors.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          tr(category),
                          style: WorkspaceUi.captionStyleOf(context),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                _entryDescription(entry),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: WorkspaceUi.captionStyleOf(context),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      registered > 0
                          ? tr('등록 {v0}개', args: {'v0': registered})
                          : Uri.parse(entry.url).host
                                .replaceFirst(RegExp(r'^www\.'), ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 10, color: colors.muted),
                    ),
                  ),
                  if (_canEdit)
                    OutlinedButton(
                      key: Key('shortcut-catalog-add-${entry.service}'),
                      onPressed: _saving ? null : () => _edit(null, entry),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(
                          fontFamily: 'Malgun Gothic',
                          fontSize: 11,
                        ),
                      ),
                      child: Text(tr('추가')),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(ProjectShortcut entry) {
    final colors = WorkspaceUi.colors(context);
    final serviceHome = isShortcutServiceHome(entry);
    final favorite = _favorites.contains(entry.id);
    return Material(
      color: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.line),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('shortcut-open-${entry.id}'),
        onTap: () => _open(entry),
        hoverColor: colors.subtle,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _ServiceIcon(
                    service: entry.resolvedService,
                    pageUrl: entry.url,
                    iconUrl: entry.iconUrl,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _entryName(entry),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: colors.ink,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          Uri.parse(entry.url).host
                              .replaceFirst(RegExp(r'^www\.'), ''),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10, color: colors.muted),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    key: Key('shortcut-menu-${entry.id}'),
                    tooltip: tr('더보기'),
                    icon: Icon(
                      Icons.more_horiz_rounded,
                      size: 19,
                      color: colors.muted,
                    ),
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(28, 32),
                      maximumSize: const Size(28, 32),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onSelected: (action) async {
                      switch (action) {
                        case 'open':
                          await _open(entry);
                        case 'copy':
                          await Clipboard.setData(
                            ClipboardData(text: entry.url),
                          );
                          _notice(tr('링크를 복사했습니다.'));
                        case 'edit':
                          await _edit(entry);
                        case 'delete':
                          await _delete(entry);
                      }
                    },
                    itemBuilder: (_) => [
                      _menuItem('open', Icons.open_in_new_rounded, tr('열기')),
                      _menuItem(
                        'copy',
                        Icons.content_copy_rounded,
                        tr('링크 복사'),
                      ),
                      if (_canEdit) ...[
                        const PopupMenuDivider(),
                        _menuItem(
                          'edit',
                          Icons.edit_outlined,
                          tr('수정'),
                          enabled: !_saving,
                        ),
                        _menuItem(
                          'delete',
                          Icons.delete_outline_rounded,
                          tr('삭제'),
                          enabled: !_saving,
                          danger: true,
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                _entryDescription(entry),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: WorkspaceUi.captionStyleOf(context),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Tooltip(
                      message: entry.url,
                      child: Text(
                        entry.description.isEmpty
                            ? tr(serviceHome ? '서비스 홈' : '팀 링크')
                            : tr('열기'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10, color: colors.muted),
                      ),
                    ),
                  ),
                  Icon(Icons.north_east_rounded, size: 12, color: colors.muted),
                  const SizedBox(width: 4),
                  if (serviceHome && _canEdit)
                    TextButton(
                      key: Key('shortcut-setup-${entry.id}'),
                      onPressed: _saving ? null : () => _edit(entry),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(
                          fontFamily: 'Malgun Gothic',
                          fontSize: 10,
                        ),
                      ),
                      child: Text(tr('팀 주소 설정')),
                    ),
                  IconButton(
                    key: Key('shortcut-favorite-${entry.id}'),
                    tooltip: tr(favorite ? '즐겨찾기에서 제거' : '즐겨찾기에 추가'),
                    isSelected: favorite,
                    onPressed: () => _toggleFavorite(entry),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(
                      width: 28,
                      height: 28,
                    ),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(28, 28),
                      maximumSize: const Size(28, 28),
                      padding: EdgeInsets.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: CustomPaint(
                      size: const Size(16, 16),
                      painter: _FavoritePainter(
                        color: favorite ? colors.accent : colors.muted,
                        filled: favorite,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    bool enabled = true,
    bool danger = false,
  }) => PopupMenuItem(
    value: value,
    enabled: enabled,
    child: Row(
      children: [
        Icon(
          icon,
          size: 17,
          color: danger ? WorkspaceUi.colors(context).danger : null,
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: danger
              ? TextStyle(color: WorkspaceUi.colors(context).danger)
              : null,
        ),
      ],
    ),
  );
}

String _entryName(ProjectShortcut entry) {
  final starter = defaultProjectShortcuts
      .where((item) => item.id == entry.id)
      .firstOrNull;
  return starter?.name == entry.name ? tr(entry.name) : entry.name;
}

String _entryDescription(ProjectShortcut entry) {
  final starter = defaultProjectShortcuts
      .where((item) => item.id == entry.id)
      .firstOrNull;
  return starter?.description == entry.description
      ? tr(entry.description)
      : entry.description;
}

String _errorMessage(Object error) => error is GitHubFailure
    ? tr(error.message)
    : error is StateError
    ? tr(error.message)
    : tr('바로가기를 저장하지 못했습니다. 다시 시도해 주세요.');

class _ServiceIcon extends StatelessWidget {
  const _ServiceIcon({required this.service, this.pageUrl, this.iconUrl});
  final String service;
  final String? pageUrl, iconUrl;

  @override
  Widget build(BuildContext context) {
    final colors = WorkspaceUi.colors(context);
    final color = ShortcutServiceIcon.colorOf(context, service);
    String? normalizedPage;
    if (pageUrl != null) {
      try {
        normalizedPage = normalizeShortcutUrl(pageUrl!);
      } on StateError {
        /* Incomplete editor address. */
      }
    }
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: service == 'kakao'
            ? const Color(0xfffee500)
                  .withValues(alpha: colors.isDark ? .16 : .28)
            : color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: normalizedPage == null || iconUrl == null
          ? ShortcutServiceIcon(service: service, size: 28)
          : ShortcutSiteIcon(
              pageUrl: normalizedPage,
              iconUrl: iconUrl,
              size: 28,
              fallback: ShortcutServiceIcon(service: service, size: 28),
            ),
    );
  }
}

class _FavoritePainter extends CustomPainter {
  const _FavoritePainter({required this.color, required this.filled});
  final Color color;
  final bool filled;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2 - 1;
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final angle = -math.pi / 2 + i * math.pi / 5;
      final r = radius * (i.isEven ? 1 : .46);
      final point = center + Offset(math.cos(angle) * r, math.sin(angle) * r);
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_FavoritePainter oldDelegate) =>
      color != oldDelegate.color || filled != oldDelegate.filled;
}

class _ShortcutEditor extends StatefulWidget {
  const _ShortcutEditor({
    required this.onSubmit,
    required this.discoverIcon,
    this.initial,
    this.preset,
  });
  final ProjectShortcut? initial, preset;
  final Future<void> Function(ProjectShortcut) onSubmit;
  final Future<ShortcutSiteIconResult?> Function(String) discoverIcon;
  @override
  State<_ShortcutEditor> createState() => _ShortcutEditorState();
}

class _ShortcutEditorState extends State<_ShortcutEditor> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(
    text: widget.initial?.name ?? widget.preset?.name,
  );
  late final _url = TextEditingController(text: widget.initial?.url);
  late final _description = TextEditingController(
    text: widget.initial?.description ?? widget.preset?.description,
  );
  late final _id = widget.initial?.id ?? 'link-${const Uuid().v4()}';
  late String _service =
      widget.initial?.service ?? widget.preset?.service ?? 'custom';
  late bool _nameEdited = widget.initial != null || widget.preset != null;
  bool _manualService = false;
  bool _saving = false;
  String? _error;
  late String? _iconUrl = widget.initial?.iconUrl;
  Timer? _iconDebounce;
  Future<void>? _pendingIcon;
  int _iconGeneration = 0;
  bool _lookingForIcon = false;
  bool _iconRequested = false;
  bool _useDefaultIcon = false;

  void _scheduleIcon() {
    _iconDebounce?.cancel();
    try {
      normalizeShortcutUrl(_url.text);
    } on StateError {
      return;
    }
    _iconDebounce = Timer(const Duration(milliseconds: 650), () {
      _pendingIcon = _findIcon();
    });
  }

  Future<void> _findIcon() async {
    _iconDebounce?.cancel();
    String url;
    try {
      url = normalizeShortcutUrl(_url.text);
    } on StateError {
      return;
    }
    final generation = ++_iconGeneration;
    setState(() {
      _lookingForIcon = true;
      _iconRequested = true;
      _useDefaultIcon = false;
    });
    ShortcutSiteIconResult? result;
    try {
      result = await widget
          .discoverIcon(url)
          .timeout(const Duration(seconds: 10));
    } catch (_) {
      // A site's metadata is optional; unreachable pages do not block saving.
    }
    if (!mounted || generation != _iconGeneration) return;
    setState(() {
      _iconUrl = result?.url;
      _lookingForIcon = false;
    });
  }

  void _useDefault() => setState(() {
    _iconDebounce?.cancel();
    _iconGeneration++;
    _pendingIcon = null;
    _iconUrl = null;
    _lookingForIcon = false;
    _useDefaultIcon = true;
  });

  void _urlChanged(String value) => setState(() {
    _iconGeneration++;
    _pendingIcon = null;
    _iconUrl = null;
    _lookingForIcon = false;
    _iconRequested = false;
    _useDefaultIcon = false;
    final detected = inferShortcutService(value);
    if (!_manualService) _service = detected;
    if (!_nameEdited && detected != 'custom') {
      _name.text = shortcutServices[detected]!;
    }
    _scheduleIcon();
  });

  @override
  void dispose() {
    _iconGeneration++;
    _iconDebounce?.cancel();
    _name.dispose();
    _url.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || !_form.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      _iconDebounce?.cancel();
      if (!_useDefaultIcon && _iconUrl == null) {
        if (_pendingIcon != null) {
          await _pendingIcon;
        } else if (!_iconRequested) {
          _pendingIcon = _findIcon();
          await _pendingIcon;
        }
      }
      if (!mounted) return;
      final entry = ProjectShortcut.fromJson({
        'id': _id,
        'name': _name.text,
        'url': _url.text,
        'description': _description.text,
        'service': _service,
        if (_iconUrl != null) 'iconUrl': _iconUrl,
      });
      await widget.onSubmit(entry);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) setState(() => _error = _errorMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(tr(widget.initial == null ? '링크 추가' : '바로가기 수정')),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('shortcut-url'),
                  controller: _url,
                  autofocus: true,
                  onChanged: _urlChanged,
                  enabled: !_saving,
                  maxLength: 2048,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: tr('링크 주소'),
                    counterText: '',
                    helperText: tr('팀 폴더, 보드 또는 채팅방의 HTTPS 주소를 입력하세요.'),
                    helperMaxLines: 2,
                  ),
                  validator: (value) {
                    try {
                      normalizeShortcutUrl(value ?? '');
                      return null;
                    } on StateError catch (error) {
                      return tr(error.message);
                    }
                  },
                ),
                const SizedBox(height: 16),
                Container(
                  key: const Key('shortcut-icon-preview'),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: WorkspaceUi.colors(context).subtle,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      _ServiceIcon(
                        service: _service,
                        pageUrl: _url.text,
                        iconUrl: _iconUrl,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tr(
                                _iconUrl == null
                                    ? shortcutServices[_service]!
                                    : '사이트 아이콘',
                              ),
                              style: WorkspaceUi.sectionStyleOf(context),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              tr(
                                _lookingForIcon
                                    ? '아이콘 찾는 중…'
                                    : _iconUrl != null
                                    ? '사이트 아이콘을 가져왔습니다.'
                                    : _useDefaultIcon
                                    ? '선택한 서비스 아이콘을 사용합니다.'
                                    : _iconRequested
                                    ? '사이트 아이콘을 찾지 못해 기본 아이콘을 사용합니다.'
                                    : '주소를 입력하면 사이트 아이콘을 자동으로 가져옵니다.',
                              ),
                              style: WorkspaceUi.captionStyleOf(context),
                            ),
                          ],
                        ),
                      ),
                      if (_lookingForIcon)
                        const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 10,
                  children: [
                    TextButton(
                      key: const Key('shortcut-refresh-icon'),
                      onPressed:
                          _saving || _lookingForIcon || _url.text.trim().isEmpty
                          ? null
                          : () => _pendingIcon = _findIcon(),
                      child: Text(tr('아이콘 다시 찾기')),
                    ),
                    TextButton(
                      key: const Key('shortcut-default-icon'),
                      onPressed: _saving ? null : _useDefault,
                      child: Text(tr('기본 아이콘 사용')),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('shortcut-name'),
                  controller: _name,
                  onChanged: (_) => _nameEdited = true,
                  enabled: !_saving,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: tr('이름'),
                    counterText: '',
                  ),
                  validator: (value) => value?.trim().isNotEmpty == true
                      ? null
                      : tr('바로가기 이름을 입력해 주세요.'),
                ),
                const SizedBox(height: 16),
                IgnorePointer(
                  ignoring: _saving,
                  child: IeumSelect(
                    value: _service,
                    values: {
                      for (final entry in shortcutServices.entries)
                        entry.key: tr(entry.value),
                    },
                    label: tr('서비스'),
                    onChanged: (value) => setState(() {
                      _service = value;
                      _manualService = true;
                    }),
                  ),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('shortcut-description'),
                  controller: _description,
                  enabled: !_saving,
                  maxLength: 160,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: tr('설명 (선택)'),
                    counterText: '',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: TextStyle(
                      fontSize: 12,
                      color: WorkspaceUi.colors(context).danger,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const Key('shortcut-save'),
          onPressed: _saving ? null : _submit,
          child: Text(tr(_saving ? '저장 중…' : '저장')),
        ),
      ],
    ),
  );
}
