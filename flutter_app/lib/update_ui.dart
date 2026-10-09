import 'app_localizations.dart';

import 'package:flutter/material.dart';

import 'app_update.dart';
import 'app_release.dart';
import 'desktop_platform.dart';

class UpdateScope extends InheritedNotifier<AppUpdater> {
  const UpdateScope({
    super.key,
    required AppUpdater updater,
    required this.restart,
    required super.child,
    this.supportsAutomaticInstall = true,
  }) : super(notifier: updater);
  final Future<void> Function() restart;
  final bool supportsAutomaticInstall;
  static UpdateScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpdateScope>();
}

class UpdateButton extends StatelessWidget {
  const UpdateButton({super.key});
  @override
  Widget build(BuildContext context) {
    final scope = UpdateScope.of(context);
    if (scope != null && !scope.supportsAutomaticInstall) {
      return TextButton.icon(
        key: const Key('app-update-button'),
        icon: const Icon(Icons.open_in_new_rounded, size: 15),
        label: Text(tr('Linux 업데이트 다운로드'), style: TextStyle(fontSize: 11)),
        onPressed: () async {
          try {
            await openDesktopUrl(
              'https://github.com/$updateRepository/releases/latest',
            );
          } catch (_) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    tr(
                      'https://github.com/{v0}/releases/latest 에서 Linux 빌드를 받으세요.',
                      args: {'v0': updateRepository},
                    ),
                  ),
                ),
              );
            }
          }
        },
      );
    }
    if (scope == null) return const SizedBox.shrink();
    final updater = scope.notifier!;
    return Tooltip(
      message: updater.ready
          ? tr(
              '{v0} · 다음 실행 때 자동 적용',
              args: {'v0': ReleaseVersion(updater.readyVersion).label},
            )
          : updater.lastError.isEmpty
          ? tr(
              '현재 {v0} · 클릭하여 확인',
              args: {'v0': ReleaseVersion(updater.currentVersion).label},
            )
          : trError(updater.lastError),
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
        label: Text(tr(updater.message), style: const TextStyle(fontSize: 10)),
      ),
    );
  }
}
