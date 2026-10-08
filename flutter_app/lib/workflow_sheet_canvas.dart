import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'models.dart';
import 'workflow_sheet_style.dart';
import 'workflow_sheet_menu.dart';
import 'workflow_sheet_handoff.dart';

class WorkflowSheetCanvas extends StatefulWidget {
  const WorkflowSheetCanvas({
    super.key,
    this.stageCatalog = defaultWorkflowStages,
    this.roles = const [],
    this.people = const [],
    this.parts = const [],
    this.value,
    this.onChanged,
    this.readOnly = false,
  });
  final List<WorkflowStage> stageCatalog;
  final List<ProjectRole> roles;
  final List<Person> people;
  final List<String> parts;
  final WorkflowSheet? value;
  final ValueChanged<WorkflowSheet>? onChanged;
  final bool readOnly;

  @override
  State<WorkflowSheetCanvas> createState() => _WorkflowSheetCanvasState();
}

class _WorkflowSheetCanvasState extends State<WorkflowSheetCanvas> {
  final nodes = <String, String>{};
  final initialIds = <String>[];
  final placedPositions = <String, Offset>{};
  final viewportKey = GlobalKey();
  int nextInstance = 0;
  Map<String, String> get catalog => {
    for (final stage in widget.stageCatalog) stage.id: stage.name,
  };
  Map<String, String> get stages {
    final labels = catalog;
    return {
      for (final node in nodes.entries)
        node.key: labels[node.value] ?? '삭제된 단계',
    };
  }

  @override
  void initState() {
    super.initState();
    if (widget.value != null) {
      loadSheet(widget.value!);
      return;
    }
    for (final stage in widget.stageCatalog) {
      if (const {'todo', 'doing', 'review', 'done'}.contains(stage.id)) {
        nodes[stage.id] = stage.id;
        initialIds.add(stage.id);
      }
    }
  }

  @override
  void didUpdateWidget(covariant WorkflowSheetCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != null &&
        jsonEncode(widget.value!.json) != jsonEncode(oldWidget.value?.json)) {
      loadSheet(widget.value!);
      return;
    }
    if (widget.value != null) return;
    final current = catalog.keys.toSet();
    final removed = nodes.entries
        .where((node) => !current.contains(node.value))
        .map((node) => node.key)
        .toSet();
    nodes.removeWhere((id, _) => removed.contains(id));
    initialIds.removeWhere(removed.contains);
    placedPositions.removeWhere((id, _) => removed.contains(id));
    cardOffsets.removeWhere((id, _) => removed.contains(id));
    connections.removeWhere(
      (link) => removed.contains(link.$1) || removed.contains(link.$2),
    );
    handoffs.removeWhere((link, _) => !connections.contains(link));
    if (removed.contains(connectingFrom)) connectingFrom = null;
  }

  double zoom = 1;
  Offset camera = Offset.zero;
  final cardOffsets = <String, Offset>{};
  String? draggingCard;
  Offset? dragPosition;
  Offset? sheetDragPosition;
  (String, String, int)? draggingLabel;
  Offset? labelDragPosition;
  Size viewportSize = Size.zero;
  final connections = <(String, String)>{};
  final handoffs = <(String, String), List<SheetHandoffRule>>{};
  int nextRoute = 0;
  String error = '';
  bool editingConnection = false;

  String newRouteId() =>
      'route-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${++nextRoute}';

  void loadSheet(WorkflowSheet sheet) {
    nodes.clear();
    initialIds.clear();
    placedPositions.clear();
    cardOffsets.clear();
    connections.clear();
    handoffs.clear();
    for (final node in sheet.nodes) {
      nodes[node.id] = node.stageId;
      placedPositions[node.id] = Offset(node.x, node.y);
    }
    for (final route in sheet.routes) {
      final link = (route.from, route.to);
      connections.add(link);
      (handoffs[link] ??= []).add(
        SheetHandoffRule(
          id: route.id,
          source: route.source,
          destination: route.destination,
          person: route.person,
          action: route.action,
          name: route.name,
          operation: route.operation,
          assignment: route.assignment,
          purpose: route.purpose,
          requiredPurpose: route.requiredPurpose,
          commentRequired: route.commentRequired,
          requiredFields: route.requiredFields,
          trigger: route.trigger,
          labelDx: route.labelDx,
          labelDy: route.labelDy,
        ),
      );
    }
    draggingCard = null;
    dragPosition = null;
    draggingLabel = null;
    labelDragPosition = null;
    connectingFrom = null;
    error = '';
  }

  void emitSheet() {
    if (widget.readOnly || widget.onChanged == null) return;
    widget.onChanged!(
      WorkflowSheet(
        nodes: [
          for (final node in nodes.entries)
            WorkflowSheetNode(
              node.key,
              node.value,
              x: cardPosition(node.key).dx,
              y: cardPosition(node.key).dy,
            ),
        ],
        routes: [
          for (final link in connections)
            for (final route in routesFor(link))
              WorkflowSheetRoute(
                id: route.id.isEmpty ? newRouteId() : route.id,
                from: link.$1,
                to: link.$2,
                source: route.source,
                destination: route.destination,
                person: route.person,
                action: route.action,
                name: route.name,
                operation: route.operation,
                assignment: route.assignment,
                purpose: route.purpose,
                requiredPurpose: route.requiredPurpose,
                commentRequired: route.commentRequired,
                requiredFields: route.requiredFields,
                trigger: route.trigger,
                labelDx: route.labelDx,
                labelDy: route.labelDy,
              ),
        ],
      ),
    );
  }

  List<SheetHandoffRule> routesFor((String, String) link) =>
      handoffs[link] ?? const [SheetHandoffRule()];

  Future<void> editConnection((String, String) link, int index) async {
    if (widget.readOnly || editingConnection) return;
    editingConnection = true;
    List<SheetHandoffRule>? result;
    try {
      result = await editSheetHandoff(
        context,
        from: stages[link.$1]!,
        to: stages[link.$2]!,
        routes: routesFor(link),
        roles: widget.roles,
        people: widget.people,
        parts: widget.parts,
        fromStage: nodes[link.$1]!,
        toStage: nodes[link.$2]!,
        toCategory:
            widget.stageCatalog
                .where((stage) => stage.id == nodes[link.$2])
                .firstOrNull
                ?.resolvedCategory ??
            '',
        initialIndex: index,
      );
    } finally {
      editingConnection = false;
    }
    if (!mounted || result == null || !connections.contains(link)) return;
    final nextRoutes = result;
    if (handoffs.entries
                .where((e) => e.key != link)
                .fold<int>(0, (sum, e) => sum + e.value.length) +
            result.length >
        300) {
      setState(() => error = '자동화 경로는 최대 300개까지 등록할 수 있습니다.');
      return;
    }
    setState(() {
      if (nextRoutes.isEmpty) {
        connections.remove(link);
        handoffs.remove(link);
      } else {
        handoffs[link] = [
          for (final route in nextRoutes)
            SheetHandoffRule(
              id: route.id.isEmpty ? newRouteId() : route.id,
              source: route.source,
              destination: route.destination,
              person: route.person,
              action: route.action,
              name: route.name,
              operation: route.operation,
              assignment: route.assignment,
              purpose: route.purpose,
              requiredPurpose: route.requiredPurpose,
              commentRequired: route.commentRequired,
              requiredFields: route.requiredFields,
              trigger: route.trigger,
              labelDx: route.labelDx,
              labelDy: route.labelDy,
            ),
        ];
      }
    });
    emitSheet();
    sheetFocus.requestFocus();
  }

  final sheetFocus = FocusNode(debugLabel: 'workflow sheet');
  String? connectingFrom;
  bool menuOpen = false;

  @override
  void dispose() {
    sheetFocus.dispose();
    super.dispose();
  }

  void cancelConnection() => setState(() => connectingFrom = null);

  ({RelativeRect anchor, double width, double maxHeight}) menuPlacement(
    Offset position,
    double preferredWidth,
    double expectedHeight,
  ) {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final board = viewportKey.currentContext!.findRenderObject() as RenderBox;
    final origin = overlay.globalToLocal(board.localToGlobal(Offset.zero));
    final area = origin & board.size;
    final point = overlay.globalToLocal(position);
    final width = math.min(preferredWidth, math.max(96.0, area.width - 16));
    final maxHeight = math.max(80.0, area.height - 16);
    final height = math.min(expectedHeight, maxHeight);
    final left = point.dx.clamp(
      area.left + 8,
      math.max(area.left + 8, area.right - width - 8),
    );
    final top = point.dy.clamp(
      area.top + 8,
      math.max(area.top + 8, area.bottom - height - 8),
    );
    return (
      anchor: RelativeRect.fromRect(
        Rect.fromLTWH(left.toDouble(), top.toDouble(), width, 1),
        Offset.zero & overlay.size,
      ),
      width: width,
      maxHeight: maxHeight,
    );
  }

  Future<void> sheetMenu(Offset position) async {
    if (widget.readOnly || menuOpen || nodes.length >= 100) return;
    menuOpen = true;
    try {
      final placement = menuPlacement(
        position,
        232,
        68 + math.max(1, widget.stageCatalog.length) * 44.0,
      );
      final selected = await showMenu<String>(
        context: context,
        popUpAnimationStyle: sheetMenuAnimation,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shadowColor: const Color(0x381f3552),
        shape: sheetMenuShape,
        menuPadding: const EdgeInsets.all(6),
        constraints: BoxConstraints(
          minWidth: placement.width,
          maxWidth: placement.width,
          maxHeight: placement.maxHeight,
        ),
        position: placement.anchor,
        items: [
          const SheetMenuHeader(title: '단계 불러오기', subtitle: '선택한 단계를 시트에 추가'),
          for (final stage in widget.stageCatalog)
            SheetMenuAction(
              key: Key('workflow-sheet-import-${stage.id}'),
              value: stage.id,
              title: stage.name,
              icon: stage.isCompleted
                  ? Icons.task_alt_rounded
                  : stage.locksContent
                  ? Icons.fact_check_outlined
                  : stage.resolvedCategory == 'inProgress'
                  ? Icons.timelapse_rounded
                  : Icons.radio_button_unchecked_rounded,
              trailingIcon: Icons.add_rounded,
            ),
          if (widget.stageCatalog.isEmpty)
            const PopupMenuItem<String>(
              enabled: false,
              child: Text('등록된 작업 단계가 없습니다.'),
            ),
        ],
      );
      if (!mounted || selected == null || !catalog.containsKey(selected)) {
        return;
      }
      final box = viewportKey.currentContext!.findRenderObject() as RenderBox;
      final local = box.globalToLocal(position);
      final world = (local - camera) / zoom - viewportSize.center(Offset.zero);
      String id;
      do {
        id = '$selected-copy-${++nextInstance}';
      } while (nodes.containsKey(id));
      setState(() {
        nodes[id] = selected;
        placedPositions[id] = world;
        connectingFrom = null;
      });
      emitSheet();
      sheetFocus.requestFocus();
    } finally {
      menuOpen = false;
    }
  }

  Future<void> cardMenu(String id, Offset position) async {
    if (widget.readOnly || menuOpen) return;
    menuOpen = true;
    try {
      final placement = menuPlacement(position, 248, 176);
      final action = await showMenu<String>(
        context: context,
        popUpAnimationStyle: sheetMenuAnimation,
        color: Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 2,
        shadowColor: const Color(0x381f3552),
        shape: sheetMenuShape,
        menuPadding: const EdgeInsets.all(6),
        constraints: BoxConstraints(
          minWidth: placement.width,
          maxWidth: placement.width,
          maxHeight: placement.maxHeight,
        ),
        position: placement.anchor,
        items: [
          SheetMenuHeader(title: stages[id] ?? '카드', subtitle: '카드 작업'),
          const SheetMenuAction(
            key: Key('workflow-sheet-connect-menu'),
            value: 'connect',
            title: '연결',
            subtitle: '다른 카드와 이어 붙이기',
            icon: Icons.link_rounded,
          ),
          const SheetMenuAction(
            key: Key('workflow-sheet-delete-menu'),
            value: 'delete',
            title: '삭제',
            subtitle: '이 카드와 연결선 지우기',
            icon: Icons.delete_outline_rounded,
            danger: true,
          ),
        ],
      );
      if (!mounted || action == null || !nodes.containsKey(id)) return;
      if (action == 'delete') {
        deleteCard(id);
      } else if (action == 'connect') {
        setState(() => connectingFrom = id);
      }
      sheetFocus.requestFocus();
    } finally {
      menuOpen = false;
    }
  }

  void deleteCard(String id) {
    if (widget.readOnly) return;
    setState(() {
      nodes.remove(id);
      placedPositions.remove(id);
      cardOffsets.remove(id);
      connections.removeWhere((link) => link.$1 == id || link.$2 == id);
      handoffs.removeWhere((link, _) => !connections.contains(link));
      if (connectingFrom == id) connectingFrom = null;
      if (draggingCard == id) {
        draggingCard = null;
        dragPosition = null;
      }
      // Keep the original layout slots so other cards do not jump on deletion.
    });
    emitSheet();
  }

  void selectCard(String id) {
    sheetFocus.requestFocus();
    final source = connectingFrom;
    if (widget.readOnly || source == null) return;
    final link = (source, id);
    if (connections.contains(link)) {
      setState(() => connectingFrom = null);
      editConnection(link, routesFor(link).length);
      return;
    }
    if (handoffs.values.fold<int>(0, (sum, routes) => sum + routes.length) >=
        300) {
      return;
    }
    setState(() {
      connections.add((source, id));
      handoffs.putIfAbsent(
        (source, id),
        () => [
          SheetHandoffRule(
            id: newRouteId(),
            action:
                widget.stageCatalog
                        .where((stage) => stage.id == nodes[id])
                        .firstOrNull
                        ?.isCompleted ==
                    true
                ? 'approve'
                : nodes[source] == 'review'
                ? 'reject'
                : 'advance',
          ),
        ],
      );
      connectingFrom = null;
      error = '';
    });
    emitSheet();
  }

  Rect cardRect(String id) {
    final center =
        (viewportSize.center(Offset.zero) + cardPosition(id)) * zoom + camera;
    return Rect.fromCenter(
      center: center,
      width: 120 * zoom,
      height: 48 * zoom,
    );
  }

  Offset cardPosition(String id) {
    if (placedPositions.containsKey(id)) {
      return placedPositions[id]! + (cardOffsets[id] ?? Offset.zero);
    }
    final columns = viewportSize.width >= 570
        ? 4
        : viewportSize.width >= 270
        ? 2
        : 1;
    final index = initialIds.indexOf(id);
    final rows = (initialIds.length / columns).ceil();
    final initial = Offset(
      (index % columns - (columns - 1) / 2) * 150,
      (index ~/ columns - (rows - 1) / 2) * 100,
    );
    return initial + (cardOffsets[id] ?? Offset.zero);
  }

  void zoomSheet(double wheelDelta) {
    final next = (zoom * math.exp(-wheelDelta / 300)).clamp(0.4, 3.0);
    if (next == zoom) return;
    setState(() {
      final center = viewportSize.center(Offset.zero);
      camera = center - (center - camera) * (next / zoom);
      zoom = next;
    });
  }

  void fitCards() {
    Rect? bounds;
    for (final id in nodes.keys) {
      final rect = cardRect(id);
      bounds = bounds?.expandToInclude(rect) ?? rect;
    }
    for (final link in connections) {
      for (var i = 0; i < routesFor(link).length; i++) {
        final rect = badgeRect(link, i);
        bounds = bounds?.expandToInclude(rect) ?? rect;
      }
    }
    if (bounds == null) return;
    final next =
        (zoom *
                math.min(
                  (viewportSize.width - 64) / bounds.width,
                  (viewportSize.height - 140) / bounds.height,
                ))
            .clamp(0.4, 1.0);
    setState(() {
      camera =
          viewportSize.center(Offset.zero) -
          (bounds!.center - camera) * (next / zoom);
      zoom = next;
    });
  }

  void arrangeCards() {
    if (widget.readOnly || nodes.isEmpty) return;
    final order = <String>[
      ...widget.stageCatalog.map((stage) => stage.id),
      ...nodes.values.where((id) => !catalog.containsKey(id)).toSet(),
    ].where((id) => nodes.containsValue(id)).toList();
    setState(() {
      for (var column = 0; column < order.length; column++) {
        final ids = nodes.keys
            .where((id) => nodes[id] == order[column])
            .toList();
        for (var row = 0; row < ids.length; row++) {
          placedPositions[ids[row]] = Offset(
            (column - (order.length - 1) / 2) * 280,
            (row - (ids.length - 1) / 2) * 200,
          );
        }
      }
      cardOffsets.clear();
      for (final link in connections) {
        handoffs[link] = [
          for (final rule in routesFor(link)) rule.withLabelOffset(Offset.zero),
        ];
      }
      connectingFrom = null;
    });
    fitCards();
    emitSheet();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: const Key('workflow-sheet-render-boundary'),
    child: Focus(
      focusNode: sheetFocus,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape &&
            connectingFrom != null) {
          cancelConnection();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: ClipRect(
        child: Listener(
          key: const Key('workflow-sheet-viewport'),
          behavior: HitTestBehavior.opaque,
          onPointerSignal: (event) {
            if (event is PointerScrollEvent && event.scrollDelta.dy != 0) {
              GestureBinding.instance.pointerSignalResolver.register(
                event,
                (_) => zoomSheet(event.scrollDelta.dy),
              );
            }
          },
          child: LayoutBuilder(
            key: viewportKey,
            builder: (context, constraints) {
              viewportSize = constraints.biggest;
              return MouseRegion(
                cursor: connectingFrom != null
                    ? SystemMouseCursors.precise
                    : sheetDragPosition == null
                    ? SystemMouseCursors.grab
                    : SystemMouseCursors.grabbing,
                child: GestureDetector(
                  key: const Key('workflow-sheet-pan'),
                  dragStartBehavior: DragStartBehavior.down,
                  behavior: HitTestBehavior.opaque,
                  onSecondaryTapUp: (details) =>
                      sheetMenu(details.globalPosition),
                  onTap: () {
                    sheetFocus.requestFocus();
                    if (connectingFrom != null) cancelConnection();
                  },
                  onPanStart: connectingFrom != null
                      ? null
                      : (details) => setState(() {
                          sheetDragPosition = details.globalPosition;
                        }),
                  onPanUpdate: connectingFrom != null
                      ? null
                      : (details) => setState(() {
                          camera += details.globalPosition - sheetDragPosition!;
                          sheetDragPosition = details.globalPosition;
                        }),
                  onPanEnd: (_) => setState(() => sheetDragPosition = null),
                  onPanCancel: () => setState(() => sheetDragPosition = null),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: IgnorePointer(
                          child: RepaintBoundary(
                            child: CustomPaint(
                              painter: WorkflowSheetGridPainter(
                                zoom: zoom,
                                camera: camera,
                              ),
                            ),
                          ),
                        ),
                      ),
                      for (final link in connections)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              key: Key(
                                'workflow-sheet-link-${link.$1}-${link.$2}',
                              ),
                              painter: WorkflowSheetLinkPainter(
                                from: cardRect(link.$1),
                                to: cardRect(link.$2),
                                zoom: zoom,
                                labelCenter: badgeRect(link, 0).center,
                                color: sheetRouteColor(
                                  routesFor(link).first.action,
                                ),
                              ),
                            ),
                          ),
                        ),
                      for (final link in connections)
                        for (var i = 1; i < routesFor(link).length; i++)
                          Positioned.fill(
                            child: IgnorePointer(
                              child: CustomPaint(
                                painter: WorkflowSheetLinkPainter(
                                  from: cardRect(link.$1),
                                  to: cardRect(link.$2),
                                  zoom: zoom,
                                  laneOffset: -i * 72 * zoom,
                                  labelCenter: badgeRect(link, i).center,
                                  color: sheetRouteColor(
                                    routesFor(link)[i].action,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      for (final link in connections)
                        for (var i = 0; i < routesFor(link).length; i++)
                          connectionBadge(link, i),
                      for (final stage in stages.entries)
                        Positioned(
                          key: ValueKey('workflow-sheet-position-${stage.key}'),
                          left:
                              (constraints.maxWidth / 2 +
                                      cardPosition(stage.key).dx -
                                      60) *
                                  zoom +
                              camera.dx,
                          top:
                              (constraints.maxHeight / 2 +
                                      cardPosition(stage.key).dy -
                                      24) *
                                  zoom +
                              camera.dy,
                          width: 120 * zoom,
                          height: 48 * zoom,
                          child: FittedBox(
                            child: MouseRegion(
                              cursor: connectingFrom != null
                                  ? SystemMouseCursors.click
                                  : draggingCard == stage.key
                                  ? SystemMouseCursors.grabbing
                                  : SystemMouseCursors.grab,
                              child: GestureDetector(
                                dragStartBehavior: DragStartBehavior.down,
                                behavior: HitTestBehavior.opaque,
                                onSecondaryTapUp: (details) =>
                                    cardMenu(stage.key, details.globalPosition),
                                onTap: () => selectCard(stage.key),
                                onPanStart:
                                    widget.readOnly || connectingFrom != null
                                    ? null
                                    : (details) => setState(() {
                                        draggingCard = stage.key;
                                        dragPosition = details.globalPosition;
                                      }),
                                onPanUpdate:
                                    widget.readOnly || connectingFrom != null
                                    ? null
                                    : (details) => setState(() {
                                        // Use screen distances so dragging follows the mouse at
                                        // every zoom level without applying the scale twice.
                                        cardOffsets[stage.key] =
                                            (cardOffsets[stage.key] ??
                                                Offset.zero) +
                                            (details.globalPosition -
                                                    dragPosition!) /
                                                zoom;
                                        dragPosition = details.globalPosition;
                                      }),
                                onPanEnd: (_) {
                                  setState(() {
                                    draggingCard = null;
                                    dragPosition = null;
                                  });
                                  emitSheet();
                                },
                                onPanCancel: () {
                                  setState(() {
                                    draggingCard = null;
                                    dragPosition = null;
                                  });
                                  emitSheet();
                                },
                                child: WorkflowSheetCardFace(
                                  id: stage.key,
                                  title: stage.value,
                                  stageId: nodes[stage.key]!,
                                  category:
                                      widget.stageCatalog
                                          .where(
                                            (item) =>
                                                item.id == nodes[stage.key],
                                          )
                                          .firstOrNull
                                          ?.resolvedCategory ??
                                      '',
                                  locksContent:
                                      widget.stageCatalog
                                          .where(
                                            (item) =>
                                                item.id == nodes[stage.key],
                                          )
                                          .firstOrNull
                                          ?.locksContent ??
                                      false,
                                  selected: connectingFrom == stage.key,
                                  dragging: draggingCard == stage.key,
                                ),
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 18,
                        left: 18,
                        right: 18,
                        child: IgnorePointer(
                          child: Row(
                            children: [
                              const Icon(
                                Icons.account_tree_outlined,
                                size: 16,
                                color: Color(0xff8c9aaf),
                              ),
                              const SizedBox(width: 8),
                              const Expanded(
                                child: Text(
                                  '자동화 시트',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Color(0xff46546a),
                                  ),
                                ),
                              ),
                              if (error.isNotEmpty)
                                Expanded(
                                  child: Text(
                                    error,
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Color(0xffb86a72),
                                    ),
                                  ),
                                )
                              else if (constraints.maxWidth >= 360)
                                Text(
                                  '카드 ${nodes.length} · 연결 ${connections.length}',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Color(0xff929eaf),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 16,
                        right: 16,
                        child: WorkflowSheetToolbar(
                          zoom: zoom,
                          compact: constraints.maxWidth < 300,
                          onZoomIn: () => zoomSheet(-60),
                          onZoomOut: () => zoomSheet(60),
                          onFit: fitCards,
                          onArrange: widget.readOnly ? null : arrangeCards,
                        ),
                      ),
                      if (connectingFrom != null)
                        Positioned(
                          top: 52,
                          left: 16,
                          right: 16,
                          child: Material(
                            key: const Key('workflow-sheet-connect-mode'),
                            color: const Color(0xffeef2f7),
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding: const EdgeInsets.only(left: 12),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      '${stages[connectingFrom]} → 연결할 카드를 선택하세요.',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: sheetAccent,
                                      ),
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: '연결 취소',
                                    onPressed: cancelConnection,
                                    icon: const Icon(
                                      Icons.close_rounded,
                                      size: 16,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );

  Rect badgeRect((String, String) link, int index) {
    final from = cardRect(link.$1), to = cardRect(link.$2);
    final center = link.$1 == link.$2
        ? from.center + Offset(106 * zoom, -28 * zoom)
        : (from.center + to.center) / 2;
    final width = math.min(168.0, math.max(96.0, viewportSize.width - 24));
    final rule = routesFor(link)[index];
    final height = rule.name.isEmpty ? 44.0 : 60.0;
    final returning = to.center.dx < from.center.dx - 20;
    return Rect.fromLTWH(
      center.dx - width / 2 + rule.labelDx * zoom,
      (returning
              ? math.min(from.top, to.top) - 100 * zoom
              : center.dy - 24 * zoom) -
          (height + 2) -
          index * 74 * zoom +
          rule.labelDy * zoom,
      width,
      height,
    );
  }

  Widget connectionBadge((String, String) link, int index) {
    final rect = badgeRect(link, index);
    final labelId = (link.$1, link.$2, index);
    void finishDrag() {
      setState(() {
        draggingLabel = null;
        labelDragPosition = null;
      });
      emitSheet();
    }

    final label = sheetHandoffLabel(
      routesFor(link)[index],
      widget.roles,
      widget.people,
      widget.parts,
    );
    return Positioned(
      left: rect.left,
      top: rect.top,
      width: rect.width,
      child: Tooltip(
        message: '$label\n클릭하여 조건 편집 · 드래그하여 이동',
        child: MouseRegion(
          cursor: widget.readOnly
              ? SystemMouseCursors.basic
              : draggingLabel == labelId
              ? SystemMouseCursors.grabbing
              : SystemMouseCursors.grab,
          child: GestureDetector(
            dragStartBehavior: DragStartBehavior.down,
            onPanStart: widget.readOnly
                ? null
                : (details) {
                    sheetFocus.requestFocus();
                    setState(() {
                      draggingLabel = labelId;
                      labelDragPosition = details.globalPosition;
                    });
                  },
            onPanUpdate: widget.readOnly
                ? null
                : (details) => setState(() {
                    final rule = routesFor(link)[index];
                    final offset =
                        Offset(rule.labelDx, rule.labelDy) +
                        (details.globalPosition - labelDragPosition!) / zoom;
                    handoffs[link] = [...routesFor(link)]
                      ..[index] = rule.withLabelOffset(
                        Offset(
                          offset.dx.clamp(-100000, 100000).toDouble(),
                          offset.dy.clamp(-100000, 100000).toDouble(),
                        ),
                      );
                    labelDragPosition = details.globalPosition;
                  }),
            onPanEnd: widget.readOnly ? null : (_) => finishDrag(),
            onPanCancel: widget.readOnly ? null : finishDrag,
            child: Material(
              color: Colors.white,
              elevation: draggingLabel == labelId ? 4 : 1,
              shadowColor: const Color(0x181e3553),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(
                  color: draggingLabel == labelId
                      ? sheetAccent
                      : const Color(0xffe0e6ef),
                ),
              ),
              child: InkWell(
                key: Key('workflow-sheet-route-${link.$1}-${link.$2}-$index'),
                borderRadius: BorderRadius.circular(10),
                onTap: widget.readOnly
                    ? null
                    : () => editConnection(link, index),
                child: SizedBox(
                  height: rect.height,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: sheetRouteColor(
                              routesFor(link)[index].action,
                            ).withValues(alpha: .10),
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Icon(
                            switch (routesFor(link)[index].action) {
                              'approve' => Icons.check_rounded,
                              'reject' => Icons.undo_rounded,
                              _ => Icons.arrow_forward_rounded,
                            },
                            size: 14,
                            color: sheetRouteColor(
                              routesFor(link)[index].action,
                            ),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            label.replaceFirst(' → ', '\n→ '),
                            maxLines: routesFor(link)[index].name.isEmpty
                                ? 2
                                : 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              height: 1.4,
                              color: Color(0xff52647e),
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.drag_indicator_rounded,
                          size: 12,
                          color: Color(0xffbac4d2),
                        ),
                      ],
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
}

class WorkflowSheetLinkPainter extends CustomPainter {
  const WorkflowSheetLinkPainter({
    required this.from,
    required this.to,
    required this.zoom,
    this.laneOffset = 0,
    this.labelCenter,
    this.color = const Color(0xff94a5bf),
  });
  final Rect from, to;
  final double zoom;
  final double laneOffset;
  final Offset? labelCenter;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final delta = to.center - from.center;
    final looping = delta.distance < 1;
    final returning = delta.dx < -20;
    final horizontal = delta.dx.abs() >= delta.dy.abs();
    final direction = horizontal
        ? Offset(delta.dx >= 0 ? 1 : -1, 0)
        : Offset(0, delta.dy >= 0 ? 1 : -1);
    final start = looping
        ? from.centerRight
        : returning
        ? from.topCenter
        : from.center +
              Offset(
                direction.dx * from.width / 2,
                direction.dy * from.height / 2,
              );
    final end = looping
        ? to.topCenter
        : returning
        ? to.topCenter
        : to.center -
              Offset(direction.dx * to.width / 2, direction.dy * to.height / 2);
    final bend = math.max(24 * zoom, (end - start).distance / 2);
    final lane = Offset(0, laneOffset);
    final returnY = math.min(from.top, to.top) - 134 * zoom + laneOffset;
    final first = looping
        ? start + Offset(100 * zoom, -12 * zoom + laneOffset)
        : returning
        ? Offset(start.dx, returnY)
        : start + direction * bend + lane;
    final second = looping
        ? end + Offset(0, -144 * zoom + laneOffset)
        : returning
        ? Offset(end.dx, returnY)
        : end - direction * bend + lane;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = (1.4 * zoom).clamp(1.0, 3.0);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..cubicTo(first.dx, first.dy, second.dx, second.dy, end.dx, end.dy);
    canvas.drawPath(path, paint);
    final middle = (start + first * 3 + second * 3 + end) / 8;
    canvas.drawLine(
      middle,
      labelCenter ?? middle - Offset(0, 24 * zoom + 2),
      Paint()
        ..color = color.withValues(alpha: .55)
        ..strokeWidth = 1,
    );
    final tangent = end - second;
    final incoming = tangent.distance > 0
        ? tangent / tangent.distance
        : direction;
    final normal = Offset(-incoming.dy, incoming.dx);
    final length = 7 * zoom;
    final arrow = Path()
      ..moveTo(
        (end - incoming * length + normal * length / 2).dx,
        (end - incoming * length + normal * length / 2).dy,
      )
      ..lineTo(end.dx, end.dy)
      ..lineTo(
        (end - incoming * length - normal * length / 2).dx,
        (end - incoming * length - normal * length / 2).dy,
      );
    canvas.drawPath(arrow, paint);
  }

  @override
  bool shouldRepaint(covariant WorkflowSheetLinkPainter oldDelegate) =>
      from != oldDelegate.from ||
      to != oldDelegate.to ||
      zoom != oldDelegate.zoom ||
      labelCenter != oldDelegate.labelCenter ||
      color != oldDelegate.color ||
      laneOffset != oldDelegate.laneOffset;
}
