import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'models.dart';

class WorkflowAutomationTree extends StatefulWidget {
  const WorkflowAutomationTree({
    super.key,
    required this.stages,
    required this.connections,
    required this.roleName,
    this.onEdit,
    this.stageCatalog = const [],
    this.initialImportedStageIds = const [],
    this.onImportedStagesChanged,
    this.initialSheetState = const {},
    this.onSheetChanged,
    this.onConnect,
    this.onDisconnect,
    this.onImportStage,
  });
  final List<WorkflowStage> stages, stageCatalog;
  final List<WorkflowConnection> connections;
  final String Function(String) roleName;
  final ValueChanged<WorkflowConnection>? onEdit;
  final List<String> initialImportedStageIds;
  final ValueChanged<List<String>>? onImportedStagesChanged;
  final Map<String, dynamic> initialSheetState;
  final ValueChanged<Map<String, dynamic>>? onSheetChanged;
  final Future<bool> Function(WorkflowConnection)? onConnect;
  final Future<bool> Function(List<String>)? onDisconnect;
  final Future<bool> Function(String)? onImportStage;

  @override
  State<WorkflowAutomationTree> createState() => WorkflowAutomationTreeState();
}

class WorkflowAutomationTreeState extends State<WorkflowAutomationTree>
    with TickerProviderStateMixin {
  static const nodeWidth = 100.0, nodeHeight = 42.0;
  static const columnStep = 212.0, rowStep = 132.0;
  final scroll = ScrollController();
  final offsets = <String, Offset>{};
  final springs = <String, AnimationController>{};
  final imported = <int, String>{};
  var nextInstance = 0;
  String? dragging;
  bool _menuOpen = false;
  bool _connectingBusy = false;
  _TreeNode? _connectingFrom;
  final hidden = <String>{};
  final bindings = <String, List<String>>{};
  List<_SheetLink> _visibleLinks = [];

  Map<String, WorkflowStage> get catalog => {
    for (final stage in [...widget.stageCatalog, ...widget.stages])
      stage.id: stage,
  };

  @override
  void initState() {
    super.initState();
    final state = widget.initialSheetState;
    hidden.addAll((state['hidden'] as List? ?? []).whereType<String>());
    for (final entry in (state['bindings'] as Map? ?? {}).entries) {
      if (entry.key is String &&
          entry.value is List &&
          (entry.value as List).length == 2 &&
          (entry.value as List).every((v) => v is String)) {
        bindings[entry.key as String] = List<String>.from(entry.value);
      }
    }
    final stored = state['imported'];
    if (stored is List) {
      for (final item in stored) {
        if (item is Map &&
            item['instance'] is int &&
            item['stage'] is String &&
            catalog.containsKey(item['stage'])) {
          imported[item['instance'] as int] = item['stage'] as String;
          nextInstance = math.max(nextInstance, (item['instance'] as int) + 1);
        }
      }
      return;
    }
    for (final id in widget.initialImportedStageIds) {
      if (catalog.containsKey(id) && id != 'review' && id != 'rework') {
        imported[nextInstance++] = id;
      }
    }
  }

  @override
  void didUpdateWidget(covariant WorkflowAutomationTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_connectingFrom != null && !catalog.containsKey(_connectingFrom!.id)) {
      cancelConnection();
    }
    final removed = imported.entries
        .where((e) => !catalog.containsKey(e.value))
        .map((e) => e.key)
        .toList();
    for (final id in removed) {
      imported.remove(id);
      springs.remove('loaded-$id')?.dispose();
      offsets.remove('loaded-$id');
    }
    if (removed.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) notifyImports();
      });
    }
  }

  @override
  void dispose() {
    scroll.dispose();
    for (final spring in springs.values) {
      spring.dispose();
    }
    super.dispose();
  }

  void notifyImports() {
    widget.onImportedStagesChanged?.call(imported.values.toList());
    widget.onSheetChanged?.call({
      'hidden': hidden.toList(),
      'bindings': bindings,
      'imported': [
        for (final item in imported.entries)
          {'instance': item.key, 'stage': item.value},
      ],
    });
  }

  void cancelConnection() {
    if (_connectingBusy) return;
    setState(() => _connectingFrom = null);
  }

  void restoreFlow() {
    setState(() {
      hidden.clear();
      bindings.clear();
      _connectingFrom = null;
    });
    notifyImports();
  }

  RelativeRect _menuPosition(Offset global) {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(global);
    return RelativeRect.fromRect(
      Rect.fromLTWH(point.dx, point.dy, 0, 0),
      Offset.zero & overlay.size,
    );
  }

  Future<void> openLibrary(Offset position) async {
    if (!mounted || _menuOpen) return;
    _menuOpen = true;
    try {
      await _showLibrary(position);
    } finally {
      _menuOpen = false;
    }
  }

  Future<void> _showLibrary(Offset position) async {
    final selected = await showMenu<String>(
      context: context,
      position: _menuPosition(position),
      constraints: const BoxConstraints(
        minWidth: 200,
        maxWidth: 280,
        maxHeight: 420,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      items: [
        const PopupMenuItem<String>(
          enabled: false,
          height: 34,
          child: Text(
            '단계 불러오기',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        for (final stage in catalog.values.where((s) => s.id != 'rework'))
          PopupMenuItem<String>(
            key: Key('automation-load-${stage.id}'),
            value: stage.id,
            height: 38,
            child: Row(
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 16,
                  color: stageColor(stage.id),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    stage.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    if (!mounted || selected == null) return;
    if (widget.onImportStage != null &&
        !await widget.onImportStage!(selected)) {
      return;
    }
    if (!mounted) return;
    if (catalog.containsKey(selected)) {
      setState(() => imported[nextInstance++] = selected);
    }
    notifyImports();
  }

  Future<void> _cardMenu(_TreeNode node, Offset position) async {
    if (!mounted || _menuOpen || _connectingBusy) return;
    _menuOpen = true;
    String? action;
    try {
      action = await showMenu<String>(
        context: context,
        position: _menuPosition(position),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        items: [
          PopupMenuItem<String>(
            key: const Key('automation-card-connect'),
            value: 'connect',
            enabled: widget.onConnect != null && node.id != 'done',
            child: const Row(
              children: [
                Icon(Icons.link, size: 17),
                SizedBox(width: 10),
                Text('연결'),
              ],
            ),
          ),
          PopupMenuItem<String>(
            key: const Key('automation-card-delete'),
            value: 'delete',
            enabled:
                widget.onDisconnect != null ||
                !_visibleLinks.any(
                  (l) =>
                      l.from.viewId == node.viewId ||
                      l.to.viewId == node.viewId,
                ),
            child: const Row(
              children: [
                Icon(Icons.delete_outline, size: 17),
                SizedBox(width: 10),
                Text('삭제'),
              ],
            ),
          ),
        ],
      );
    } finally {
      _menuOpen = false;
    }
    if (!mounted) return;
    if (action == 'connect') {
      setState(() => _connectingFrom = node);
    } else if (action == 'delete') {
      final keys = _visibleLinks
          .where(
            (l) => l.from.viewId == node.viewId || l.to.viewId == node.viewId,
          )
          .map((l) => l.connection.key)
          .toSet()
          .toList();
      final removed =
          keys.isEmpty ||
          await (widget.onDisconnect?.call(keys) ?? Future.value(false));
      if (!mounted || !removed) return;
      springs.remove(node.viewId)?.dispose();
      setState(() {
        if (node.importedInstance != null) {
          imported.remove(node.importedInstance);
        } else {
          hidden.add(node.viewId);
        }
        offsets.remove(node.viewId);
        bindings.removeWhere((key, value) => value.contains(node.viewId));
        if (_connectingFrom?.viewId == node.viewId) _connectingFrom = null;
      });
      notifyImports();
    }
  }

  Future<void> _selectTarget(_TreeNode target) async {
    final source = _connectingFrom;
    if (source == null || _connectingBusy || widget.onConnect == null) return;
    if (source.id == target.id) return;
    final action = source.id == 'review'
        ? (target.id == 'done' ? 'approve' : 'reject')
        : 'advance';
    final existing = widget.connections
        .where((c) => c.from == source.id && c.action == action)
        .firstOrNull;
    final connection = WorkflowConnection(
      source.id,
      target.id,
      action: action,
      actor:
          existing?.actor ??
          (source.id == 'review' || target.id == 'done'
              ? 'reviewer'
              : 'assignee'),
      roles: existing?.roles ?? const [],
      taskParts: existing?.taskParts ?? const [],
      actorParts: existing?.actorParts ?? const [],
      assignedOnly: existing?.assignedOnly ?? false,
      allWorkers: existing?.allWorkers ?? true,
      returnAssigneeId: existing?.returnAssigneeId ?? '',
    );
    setState(() => _connectingBusy = true);
    final saved = await widget.onConnect!(connection);
    if (!mounted) return;
    setState(() {
      _connectingBusy = false;
      if (saved) {
        bindings[connection.key] = [source.viewId, target.viewId];
        _connectingFrom = null;
      }
    });
    if (saved) notifyImports();
  }

  Color stageColor(String id) => switch (id) {
    'review' => const Color(0xffbc8c43),
    'rework' => const Color(0xffa0445a),
    _ => const Color(0xff7963d5),
  };

  void startDrag(String id) {
    setState(() => dragging = id);
    springs[id]?.stop();
  }

  void move(String id, Offset delta, Offset anchor, Size canvas) {
    final next = (offsets[id] ?? Offset.zero) + delta;
    setState(() {
      offsets[id] = Offset(
        (anchor.dx + next.dx).clamp(8.0, canvas.width - nodeWidth - 8) -
            anchor.dx,
        (anchor.dy + next.dy).clamp(
              nodeHeight / 2 + 8,
              canvas.height - nodeHeight / 2 - 18,
            ) -
            anchor.dy,
      );
    });
  }

  void settle(String id, [Offset velocity = Offset.zero]) {
    final origin = offsets[id] ?? Offset.zero;
    setState(() => dragging = null);
    if (origin.distance < 0.5 || MediaQuery.disableAnimationsOf(context)) {
      setState(() => offsets.remove(id));
      return;
    }
    final spring = springs.putIfAbsent(
      id,
      () => AnimationController.unbounded(vsync: this),
    );
    spring.stop();
    spring.value = 1;
    void update() {
      if (mounted) setState(() => offsets[id] = origin * spring.value);
    }

    spring.addListener(update);
    final speed =
        ((velocity.dx * origin.dx + velocity.dy * origin.dy) /
                origin.distanceSquared)
            .clamp(-6.0, 6.0);
    spring
        .animateWith(
          SpringSimulation(
            const SpringDescription(mass: 1, stiffness: 260, damping: 24),
            1,
            0,
            speed,
            tolerance: const Tolerance(distance: 0.001, velocity: 0.001),
          ),
        )
        .whenCompleteOrCancel(() {
          spring.removeListener(update);
          if (mounted && dragging != id && !spring.isAnimating) {
            setState(() => offsets.remove(id));
          }
        });
  }

  Widget _card(_TreeNode node, Map<String, WorkflowStage> names, Size canvas) {
    final active = dragging == node.viewId;
    final selecting = _connectingFrom != null;
    final target = selecting && _connectingFrom!.id != node.id;
    final id = node.id;
    return Positioned(
      key: ValueKey(node.viewId),
      left: node.position.dx,
      top: node.position.dy - nodeHeight / 2,
      width: nodeWidth,
      height: nodeHeight,
      child: MouseRegion(
        cursor: active ? SystemMouseCursors.grabbing : SystemMouseCursors.grab,
        child: GestureDetector(
          onPanStart: (_) => startDrag(node.viewId),
          onPanUpdate: (details) =>
              move(node.viewId, details.delta, node.anchor, canvas),
          onPanEnd: (details) =>
              settle(node.viewId, details.velocity.pixelsPerSecond),
          onPanCancel: () => settle(node.viewId),
          onSecondaryTapUp: (details) =>
              _cardMenu(node, details.globalPosition),
          child: Tooltip(
            message: node.reference
                ? '기존 ${names[id]?.name} 단계로 돌아갑니다.'
                : names[id]?.name ?? id,
            child: Material(
              key: node.importedInstance != null
                  ? Key('automation-loaded-${node.importedInstance}')
                  : node.reference
                  ? Key('automation-reference-$id-${node.viewId}')
                  : Key('automation-node-$id'),
              elevation: active ? 6 : 0,
              shadowColor: const Color(0x337963d5),
              color: id == 'review'
                  ? const Color(0xfffff5e8)
                  : id == 'rework'
                  ? const Color(0xfffff0f2)
                  : const Color(0xfff3f0fa),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(7),
                side: BorderSide(
                  color:
                      active || target || _connectingFrom?.viewId == node.viewId
                      ? stageColor(id)
                      : const Color(0xffddd7eb),
                ),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(7),
                onTap: selecting
                    ? () => _selectTarget(node)
                    : widget.onEdit == null || node.children.isEmpty
                    ? null
                    : () => widget.onEdit!(node.children.first.incoming!),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                    child: Text(
                      '${node.reference ? '↩ ' : ''}${names[id]?.name ?? id}',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xff302b3c),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _edge(_SheetLink link) {
    final parent = link.from, child = link.to;
    final connection = link.connection;
    final executor = connection.allWorkers
        ? '모든 작업자'
        : connection.assignedOnly
        ? '지정 ${workflowActorLabels[connection.actor]}'
        : connection.actorParts.isNotEmpty
        ? '${connection.actorParts.join(', ')} 전체'
        : workflowActorLabels[connection.actor]!;
    final part = connection.taskParts.isEmpty
        ? '모든 파트'
        : connection.taskParts.join(', ');
    final condition = connection.allWorkers
        ? '모든 작업자'
        : '$part · $executor'
              '${connection.actorParts.isEmpty ? '' : ' · 소속: ${connection.actorParts.join(', ')}'}'
              '${connection.roles.isEmpty ? '' : ' · 기존 역할 제한: ${connection.roles.map(widget.roleName).join(', ')}'}';
    return Positioned(
      left: (parent.position.dx + nodeWidth + child.position.dx) / 2 - 46,
      top: child.position.dy - 66,
      width: 92,
      height: 56,
      child: Tooltip(
        message: condition,
        child: Material(
          color: Colors.white,
          child: InkWell(
            key: Key(
              'automation-connection-${connection.from}-${connection.action}',
            ),
            borderRadius: BorderRadius.circular(6),
            onTap: widget.onEdit == null
                ? null
                : () => widget.onEdit!(connection),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    switch (connection.action) {
                      'approve' => '승인',
                      'reject' => '반려',
                      _ => parent.id == 'rework' ? '복귀' : '전환',
                    },
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xff7963d5),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    connection.allWorkers ? '모든 작업자' : '$part\n$executor',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 10,
                      height: 1.2,
                      color: Color(0xff6e687b),
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

  @override
  Widget build(BuildContext context) {
    final names = catalog;
    final visited = <String>{};
    _TreeNode walk(String id, WorkflowConnection? incoming) {
      final reference = !visited.add(id);
      return _TreeNode(
        id,
        incoming,
        reference,
        reference
            ? 'reference-${incoming!.from}-${incoming.action}-$id'
            : 'node-$id',
        reference
            ? []
            : widget.connections
                  .where((c) => c.from == id)
                  .map((c) => walk(c.to, c))
                  .toList(),
      );
    }

    final roots = <_TreeNode>[];
    for (final stage in widget.stages) {
      if (!visited.contains(stage.id)) roots.add(walk(stage.id, null));
    }
    final nodes = <_TreeNode>[];
    void place(_TreeNode node, double top, int depth) {
      node.anchor = Offset(
        16 + depth * columnStep,
        top + node.leaves * rowStep / 2 + 20,
      );
      node.position = node.anchor + (offsets[node.viewId] ?? Offset.zero);
      nodes.add(node);
      var next = top;
      for (final child in node.children) {
        place(child, next, depth + 1);
        next += child.leaves * rowStep;
      }
    }

    var top = 0.0;
    for (final root in roots) {
      place(root, top, 0);
      top += root.leaves * rowStep + 32;
    }
    final importedTop = top + 32;
    var index = 0;
    for (final entry in imported.entries) {
      final node = _TreeNode(
        entry.value,
        null,
        false,
        'loaded-${entry.key}',
        [],
        importedInstance: entry.key,
      );
      node.anchor = Offset(
        16 + (index % 3) * columnStep,
        importedTop + 60 + (index ~/ 3) * rowStep,
      );
      node.position = node.anchor + (offsets[node.viewId] ?? Offset.zero);
      nodes.add(node);
      index++;
    }
    final visible = nodes
        .where((node) => !hidden.contains(node.viewId))
        .toList();
    final byId = {for (final node in visible) node.viewId: node};
    final links = <_SheetLink>[];
    for (final parent in nodes) {
      for (final child in parent.children) {
        final connection = child.incoming!;
        final binding = bindings[connection.key];
        final boundFrom = binding == null ? null : byId[binding.first];
        final boundTo = binding == null ? null : byId[binding.last];
        final from = boundFrom?.id == connection.from
            ? boundFrom
            : byId[parent.viewId];
        final to = boundTo?.id == connection.to ? boundTo : byId[child.viewId];
        if (from != null && to != null) {
          links.add(_SheetLink(from, to, connection));
        }
      }
    }
    _visibleLinks = links;
    final depth = roots.isEmpty
        ? 1
        : roots.map((r) => r.depth).reduce(math.max);
    final contentWidth = math.max(
      (depth - 1) * columnStep + nodeWidth + 32,
      imported.isEmpty
          ? 0.0
          : (math.min(imported.length, 3) - 1) * columnStep + nodeWidth + 32,
    );
    final height = math.max(
      360.0,
      imported.isEmpty
          ? top + 100
          : importedTop + 120 + ((imported.length - 1) ~/ 3) * rowStep,
    );
    return LayoutBuilder(
      builder: (context, bounds) {
        final width = math.max(bounds.maxWidth, contentWidth);
        final canvas = Size(width, height);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_connectingFrom != null)
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${names[_connectingFrom!.id]?.name} → 연결할 카드를 선택하세요.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0xff7963d5),
                      ),
                    ),
                  ),
                  TextButton(
                    key: const Key('automation-cancel-connect'),
                    onPressed: _connectingBusy ? null : cancelConnection,
                    child: const Text('취소'),
                  ),
                ],
              ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: cancelConnection,
              onSecondaryTapUp: (details) =>
                  openLibrary(details.globalPosition),
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context)
                    .copyWith(scrollbars: false),
                child: Scrollbar(
                  controller: scroll,
                  thumbVisibility: width > bounds.maxWidth,
                  scrollbarOrientation: ScrollbarOrientation.bottom,
                  child: SingleChildScrollView(
                    controller: scroll,
                    primary: false,
                    scrollDirection: Axis.horizontal,
                    child: SizedBox(
                      key: const Key('automation-canvas'),
                      width: width,
                      height: height,
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        children: [
                          Positioned.fill(
                            child: CustomPaint(
                              painter: _TreeLines(links, nodeWidth),
                            ),
                          ),
                          for (var i = 1; i < roots.length; i++)
                            Positioned(
                              left: 16,
                              top: roots[i].anchor.dy - 52,
                              child: const Text(
                                '미연결 단계',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xff827a90),
                                ),
                              ),
                            ),
                          if (imported.isNotEmpty)
                            Positioned(
                              left: 16,
                              top: importedTop,
                              child: const Text(
                                '불러온 단계',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xff6e687b),
                                ),
                              ),
                            ),
                          for (final link in links) _edge(link),
                          for (final node in visible.where(
                            (n) => n.viewId != dragging,
                          ))
                            _card(node, names, canvas),
                          for (final node in visible.where(
                            (n) => n.viewId == dragging,
                          ))
                            _card(node, names, canvas),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _TreeNode {
  _TreeNode(
    this.id,
    this.incoming,
    this.reference,
    this.viewId,
    this.children, {
    this.importedInstance,
  });
  final String id, viewId;
  final WorkflowConnection? incoming;
  final bool reference;
  final int? importedInstance;
  final List<_TreeNode> children;
  Offset anchor = Offset.zero, position = Offset.zero;
  int get leaves =>
      children.isEmpty ? 1 : children.fold(0, (n, c) => n + c.leaves);
  int get depth =>
      children.isEmpty ? 1 : 1 + children.map((c) => c.depth).reduce(math.max);
}

class _SheetLink {
  _SheetLink(this.from, this.to, this.connection);
  final _TreeNode from, to;
  final WorkflowConnection connection;
}

class _TreeLines extends CustomPainter {
  _TreeLines(this.links, this.nodeWidth);
  final List<_SheetLink> links;
  final double nodeWidth;
  @override
  void paint(Canvas canvas, Size size) {
    final pen = Paint()
      ..color = const Color(0xffbcb6c8)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    for (final link in links) {
      final start = link.from.position + Offset(nodeWidth, 0);
      final end = link.to.position;
      final jointX = start.dx + 8;
      canvas.drawPath(
        Path()
          ..moveTo(start.dx, start.dy)
          ..lineTo(jointX, start.dy)
          ..lineTo(jointX, end.dy)
          ..lineTo(end.dx, end.dy),
        pen,
      );
      canvas.drawPath(
        Path()
          ..moveTo(end.dx - 4, end.dy - 3)
          ..lineTo(end.dx, end.dy)
          ..lineTo(end.dx - 4, end.dy + 3),
        pen,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TreeLines oldDelegate) => true;
}
