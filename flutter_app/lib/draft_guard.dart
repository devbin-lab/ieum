import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// All exits, including Escape/barrier taps, keep failed and unsaved drafts.
class DraftGuard extends StatefulWidget {
  const DraftGuard({
    super.key,
    required this.dirty,
    required this.onSave,
    required this.child,
    this.busy = false,
  });
  final bool dirty, busy;
  final Future<void> Function() onSave;
  final Widget child;
  @override
  State<DraftGuard> createState() => _DraftGuardState();
}

class _DraftGuardState extends State<DraftGuard> with WindowListener {
  static final open = <_DraftGuardState>[];
  static bool closingWindow = false;
  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      open.add(this);
      windowManager.addListener(this);
      unawaited(windowManager.setPreventClose(true).catchError((_) {}));
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      open.remove(this);
      windowManager.removeListener(this);
      unawaited(
        windowManager.setPreventClose(open.isNotEmpty).catchError((_) {}),
      );
    }
    super.dispose();
  }

  @override
  void onWindowClose() {
    if (closingWindow || open.isEmpty || open.last != this) return;
    unawaited(closeWindow());
  }

  Future<void> closeWindow() async {
    closingWindow = true;
    try {
      // Nested role/member editors are resolved from the foreground inward.
      for (final guard in open.reversed.toList()) {
        if (guard.mounted && !await guard.requestExit()) return;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (open.any((g) => !g.discard && (g.widget.dirty || g.widget.busy))) {
        return;
      }
      await windowManager.destroy();
    } catch (_) {
      // A missing native plugin must not dismiss an unsaved editor.
    } finally {
      closingWindow = false;
    }
  }

  bool asking = false, discard = false;
  Future<bool> requestExit() async {
    if (widget.busy || asking) return false;
    if (discard) return true;
    if (!widget.dirty) {
      setState(() => discard = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
      return true;
    }
    asking = true;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('저장하지 않은 변경사항'),
        content: const Text('변경사항을 저장하거나 버릴 수 있습니다. 저장 실패 시 편집 내용이 유지됩니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('계속 편집'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'discard'),
            child: const Text('변경 버리기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('저장'),
          ),
        ],
      ),
    );
    asking = false;
    if (!mounted) return true;
    if (choice == 'save') {
      await widget.onSave();
      return !mounted || !widget.dirty;
    }
    if (choice == 'discard' && mounted) {
      setState(() => discard = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context);
      });
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: discard || (!widget.dirty && !widget.busy),
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) requestExit();
    },
    child: widget.child,
  );
}
