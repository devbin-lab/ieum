import 'package:flutter/material.dart';

import 'app_update.dart';

class UpdateScope extends InheritedNotifier<AppUpdater> {
  const UpdateScope({
    super.key,
    required AppUpdater updater,
    required this.restart,
    required super.child,
  }) : super(notifier: updater);
  final Future<void> Function() restart;
  static UpdateScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>();
}

class UpdateButton extends StatelessWidget {
  const UpdateButton({super.key});
  @override
  Widget build(BuildContext context) {
    final scope = UpdateScope.of(context);
    if (scope == null) return const SizedBox.shrink();
    final updater = scope.notifier!;
    return Tooltip(
      message: updater.ready
          ? '${updater.readyVersion} · 다음 실행 때 자동 적용'
          : updater.lastError.isEmpty
          ? '현재 ${updater.currentVersion} · 클릭하여 확인'
          : updater.lastError,
      child: TextButton.icon(
        key: const Key('app-update-button'),
        onPressed: updater.busy
            ? null
            : updater.ready
            ? scope.restart
            : updater.check,
        icon: updater.busy
            ? SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  value: updater.message.contains('다운로드')
                      ? updater.progress
                      : null,
                ),
              )
            : Icon(
                updater.ready
                    ? Icons.restart_alt_rounded
                    : Icons.system_update_alt_rounded,
                size: 15,
              ),
        label: Text(updater.message, style: const TextStyle(fontSize: 10)),
      ),
    );
  }
}
