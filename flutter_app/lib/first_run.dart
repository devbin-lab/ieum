import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'app_preferences.dart';
import 'project_catalog.dart';
import 'startup_surface.dart';
import 'workspace_ui.dart';

/// A project catalog is also an installation marker for users who never changed
/// appearance settings. Merely checking for a file would accept corrupt data.
bool hasSavedProjectCatalog(File file) {
  for (final candidate in [file, File('${file.path}.bak')]) {
    if (!candidate.existsSync()) continue;
    try {
      final data = jsonDecode(candidate.readAsStringSync());
      if (data is! Map) continue;
      if (data['path'] is String && data['repository'] is String) return true;
      if (data['schema'] != 2 || data['accounts'] is! Map) continue;
      for (final account in (data['accounts'] as Map).entries) {
        if (!RegExp(r'^gh-[0-9]+$').hasMatch('${account.key}') ||
            account.value is! Map) {
          continue;
        }
        final projects = account.value['projects'];
        if (projects is! List) continue;
        for (final project in projects) {
          try {
            SavedProject.fromJson(Map<String, dynamic>.from(project));
            return true;
          } catch (_) {
            // Invalid rows do not prove this installation has been used.
          }
        }
      }
    } catch (_) {
      // A damaged catalog must not prevent the initial screen from opening.
    }
  }
  return false;
}

/// GitHub restoration is deferred until the local wizard finishes. Once the
/// project gate is started, revisiting setup keeps its authenticated state alive.
class FirstRunGate extends StatefulWidget {
  const FirstRunGate({
    super.key,
    required this.preferences,
    required this.builder,
    this.existingProject = false,
  });
  final AppPreferences preferences;
  final bool existingProject;
  final Widget Function(VoidCallback openInitialSettings) builder;
  @override
  State<FirstRunGate> createState() => _FirstRunGateState();
}

class _FirstRunGateState extends State<FirstRunGate> {
  late bool showingSetup =
      !widget.preferences.onboardingComplete && !widget.existingProject;
  late bool childStarted = !showingSetup;

  void openInitialSettings() => setState(() => showingSetup = true);
  void finished() => setState(() {
    showingSetup = false;
    childStarted = true;
  });

  @override
  Widget build(BuildContext context) {
    final setup = FirstRunWizard(
      preferences: widget.preferences,
      onFinished: finished,
    );
    if (!childStarted) return setup;
    return IndexedStack(
      index: showingSetup ? 1 : 0,
      children: [
        widget.builder(openInitialSettings),
        showingSetup ? setup : const SizedBox.shrink(),
      ],
    );
  }
}

class FirstRunWizard extends StatefulWidget {
  const FirstRunWizard({
    super.key,
    required this.preferences,
    required this.onFinished,
  });
  final AppPreferences preferences;
  final VoidCallback onFinished;
  @override
  State<FirstRunWizard> createState() => _FirstRunWizardState();
}

class _FirstRunWizardState extends State<FirstRunWizard> {
  int step = 0;
  bool saving = false;
  String? saveError;
  String copy(String ko, String en) =>
      widget.preferences.languageCode == 'en' ? en : ko;

  Future<void> complete() async {
    if (saving) return;
    setState(() {
      saving = true;
      saveError = null;
    });
    final completed = await widget.preferences.completeOnboarding();
    if (!mounted) return;
    if (completed) {
      widget.onFinished();
    } else {
      setState(() {
        saving = false;
        saveError = copy(
          '설정을 저장하지 못했습니다. 다시 시도해 주세요.',
          'Could not save your preferences. Please try again.',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.preferences,
    builder: (context, _) {
      final colors = WorkspaceUi.colors(context);
      return StartupSurface(
        title: copy('팀의 일을,\n하나의 흐름으로.', 'Keep your team\nin the same flow.'),
        description: copy(
          '작업과 일정, 전달 기록을 한곳에서 관리하세요.\n이음이 팀의 다음 단계를 연결합니다.',
          'Bring tasks, schedules, and handoffs together.\nIEUM keeps the next step clear.',
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    copy('처음 시작하기', 'Getting started'),
                    style: TextStyle(fontSize: 12, color: colors.muted),
                  ),
                ),
                Text(
                  '${step + 1} / 3',
                  style: TextStyle(fontSize: 12, color: colors.muted),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (var index = 0; index < 3; index++) ...[
                  if (index > 0) const SizedBox(width: 6),
                  Expanded(
                    child: Container(
                      height: 3,
                      decoration: BoxDecoration(
                        color: index <= step ? colors.accent : colors.line,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 26),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 130),
              child: Column(
                key: ValueKey(step),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: switch (step) {
                  0 => welcome(colors),
                  1 => choices(colors),
                  _ => ready(colors),
                },
              ),
            ),
            if (saveError != null) ...[
              const SizedBox(height: 14),
              Text(
                saveError!,
                style: TextStyle(color: colors.danger, fontSize: 12),
              ),
            ],
            const SizedBox(height: 26),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (step > 0)
                  TextButton.icon(
                    key: const Key('setup-back'),
                    onPressed: saving ? null : () => setState(() => step--),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: Text(copy('이전', 'Back')),
                  )
                else
                  TextButton(
                    key: const Key('setup-skip'),
                    onPressed: saving ? null : complete,
                    child: Text(copy('기본 설정으로 시작', 'Use defaults')),
                  ),
                FilledButton.icon(
                  key: Key(step == 2 ? 'setup-finish' : 'setup-next'),
                  onPressed: saving
                      ? null
                      : step == 2
                      ? complete
                      : () => setState(() => step++),
                  icon: Icon(
                    step == 2 ? Icons.arrow_forward : Icons.chevron_right,
                    size: 18,
                  ),
                  label: Text(
                    saving
                        ? copy('저장 중…', 'Saving…')
                        : step == 2
                        ? copy('이음 시작하기', 'Start IEUM')
                        : step == 0
                        ? copy('시작하기', 'Get started')
                        : copy('계속', 'Continue'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    },
  );

  List<Widget> heading(String title, String description) => [
    Text(
      title,
      style: const TextStyle(
        fontSize: 24,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: -.5,
      ),
    ),
    const SizedBox(height: 10),
    Text(
      description,
      style: TextStyle(
        fontSize: 13,
        height: 1.7,
        color: WorkspaceUi.colors(context).muted,
      ),
    ),
    const SizedBox(height: 24),
  ];

  List<Widget> welcome(WorkspaceColors colors) => [
    ...heading(
      copy('이음에 오신 것을 환영합니다', 'Welcome to IEUM'),
      copy(
        '몇 가지 기본 설정만 고르면 준비가 끝납니다.\n선택한 설정은 나중에 언제든 바꿀 수 있어요.',
        'Choose a few preferences to make this space yours.\nYou can change them anytime.',
      ),
    ),
    _SetupNote(
      icon: Icons.tune_outlined,
      title: copy('나에게 맞는 화면', 'Make it yours'),
      description: copy(
        '언어, 화면 모드, 포인트 컬러를 선택하세요.',
        'Choose your language, theme, and accent color.',
      ),
    ),
    const SizedBox(height: 18),
    _SetupNote(
      icon: Icons.lock_outline,
      title: copy('GitHub 계정으로 연결', 'Connect with GitHub'),
      description: copy(
        '설정을 마치면 로그인하고 팀 프로젝트를 열 수 있습니다.',
        'Sign in after setup to open or create a team project.',
      ),
    ),
    const SizedBox(height: 18),
    _SetupNote(
      icon: Icons.cloud_done_outlined,
      title: copy('자동 저장되는 작업 공간', 'Your work, saved'),
      description: copy(
        '작업은 이 컴퓨터에 저장되고 GitHub와 동기화됩니다.',
        'Your work is saved on this device and synced with GitHub.',
      ),
    ),
  ];

  List<Widget> choices(WorkspaceColors colors) => [
    ...heading(
      copy('편안한 작업 환경을 골라보세요', 'Choose your working style'),
      copy('변경 사항은 화면에 바로 적용됩니다.', 'Your choices apply immediately.'),
    ),
    Text(
      copy('언어', 'Language'),
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 8),
    DropdownButtonFormField<String>(
      key: const Key('setup-language'),
      initialValue: widget.preferences.languageCode,
      isExpanded: true,
      decoration: const InputDecoration(isDense: true),
      items: const [
        DropdownMenuItem(value: 'ko', child: Text('한국어')),
        DropdownMenuItem(value: 'en', child: Text('English')),
      ],
      onChanged: saving
          ? null
          : (value) {
              if (value != null) widget.preferences.setLanguage(value);
            },
    ),
    const SizedBox(height: 22),
    Text(
      copy('화면 모드', 'Theme'),
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 10),
    LayoutBuilder(
      builder: (context, bounds) {
        final width = bounds.maxWidth >= 440
            ? (bounds.maxWidth - 16) / 3
            : bounds.maxWidth;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (mode, label, icon) in [
              (
                ThemeMode.system,
                copy('시스템', 'System'),
                Icons.brightness_auto_outlined,
              ),
              (
                ThemeMode.light,
                copy('라이트', 'Light'),
                Icons.light_mode_outlined,
              ),
              (ThemeMode.dark, copy('다크', 'Dark'), Icons.dark_mode_outlined),
            ])
              SizedBox(
                width: width,
                child: _ThemeOption(
                  key: Key('setup-theme-${mode.name}'),
                  title: label,
                  icon: icon,
                  selected: widget.preferences.themeMode == mode,
                  onTap: saving
                      ? null
                      : () => widget.preferences.setThemeMode(mode),
                ),
              ),
          ],
        );
      },
    ),
    const SizedBox(height: 22),
    Text(
      copy('포인트 컬러', 'Accent color'),
      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 10),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _AccentOption(
          key: const Key('setup-accent-monochrome'),
          label: copy('흑백', 'Monochrome'),
          color: colors.ink,
          monochrome: true,
          selected: widget.preferences.monochromeAccent,
          onTap: saving ? null : widget.preferences.setMonochromeAccent,
        ),
        for (final (label, english, color) in const [
          ('보라', 'Purple', AppPreferences.defaultAccent),
          ('파랑', 'Blue', Color(0xff3478d4)),
          ('청록', 'Teal', Color(0xff16878c)),
          ('초록', 'Green', Color(0xff398759)),
          ('주황', 'Orange', Color(0xffc26c2d)),
          ('분홍', 'Pink', Color(0xffbe4b83)),
        ])
          _AccentOption(
            key: Key('setup-accent-${color.toARGB32().toRadixString(16)}'),
            label: copy(label, english),
            color: color,
            selected:
                !widget.preferences.monochromeAccent &&
                widget.preferences.accentColor == color,
            onTap: saving
                ? null
                : () => widget.preferences.setAccentColor(color),
          ),
      ],
    ),
    const SizedBox(height: 16),
    Text(
      copy(
        '프로젝트 데이터에는 영향을 주지 않는 개인 설정입니다.',
        'These personal preferences do not affect project data.',
      ),
      style: TextStyle(fontSize: 11, height: 1.5, color: colors.muted),
    ),
  ];

  List<Widget> ready(WorkspaceColors colors) => [
    Container(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colors.accent.withValues(alpha: .08),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(Icons.check_rounded, size: 28, color: colors.accent),
      ),
    ),
    const SizedBox(height: 20),
    ...heading(
      copy('시작할 준비가 됐어요', 'You’re ready to go'),
      copy(
        '이제 GitHub 계정으로 로그인하세요.\n프로젝트를 만들거나 초대받은 팀에 참여할 수 있습니다.',
        'Sign in with your GitHub account next.\nCreate a project or join your team.',
      ),
    ),
    Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.subtle,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SummaryRow(
            label: copy('언어', 'Language'),
            value: widget.preferences.languageCode == 'en' ? 'English' : '한국어',
          ),
          const SizedBox(height: 12),
          _SummaryRow(
            label: copy('화면 모드', 'Theme'),
            value: switch (widget.preferences.themeMode) {
              ThemeMode.system => copy('시스템 설정', 'Follow system'),
              ThemeMode.light => copy('라이트', 'Light'),
              ThemeMode.dark => copy('다크', 'Dark'),
            },
          ),
          const SizedBox(height: 12),
          _SummaryRow(
            label: copy('포인트 컬러', 'Accent color'),
            value: widget.preferences.monochromeAccent
                ? copy('흑백', 'Monochrome')
                : '#${(widget.preferences.accentColor.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0').toUpperCase()}',
            dot: widget.preferences.accentColor,
          ),
        ],
      ),
    ),
    const SizedBox(height: 18),
    Text(
      copy(
        '설정 → 개인 설정에서 언제든 변경할 수 있습니다.',
        'You can adjust these anytime in Personal settings.',
      ),
      style: TextStyle(fontSize: 11, height: 1.6, color: colors.muted),
    ),
  ];
}

class _SetupNote extends StatelessWidget {
  const _SetupNote({
    required this.icon,
    required this.title,
    required this.description,
  });
  final IconData icon;
  final String title, description;
  @override
  Widget build(BuildContext context) {
    final colors = WorkspaceUi.colors(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: colors.subtle,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 18, color: colors.muted),
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                description,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: colors.muted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    super.key,
    required this.title,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String title;
  final IconData icon;
  final bool selected;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final colors = WorkspaceUi.colors(context);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? colors.accent.withValues(alpha: .07) : colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: selected ? colors.accent : colors.line),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 18,
                  color: selected ? colors.accent : colors.muted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title, style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AccentOption extends StatelessWidget {
  const _AccentOption({
    super.key,
    required this.label,
    required this.color,
    required this.selected,
    required this.onTap,
    this.monochrome = false,
  });
  final String label;
  final Color color;
  final bool selected, monochrome;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: label,
    child: Tooltip(
      message: label,
      child: InkResponse(
        onTap: onTap,
        radius: 24,
        child: Container(
          width: 42,
          height: 42,
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected
                  ? WorkspaceUi.colors(context).ink
                  : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: monochrome ? null : color,
              border: monochrome
                  ? Border.all(color: WorkspaceUi.colors(context).line)
                  : null,
              gradient: monochrome
                  ? const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white,
                        Colors.white,
                        Colors.black,
                        Colors.black,
                      ],
                      stops: [0, .499, .5, 1],
                    )
                  : null,
            ),
            child: selected && !monochrome
                ? const Icon(Icons.check, size: 17, color: Colors.white)
                : null,
          ),
        ),
      ),
    ),
  );
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({required this.label, required this.value, this.dot});
  final String label, value;
  final Color? dot;
  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    spacing: 12,
    runSpacing: 4,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: WorkspaceUi.colors(context).muted,
        ),
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot != null) ...[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ],
          Text(value, style: const TextStyle(fontSize: 12)),
        ],
      ),
    ],
  );
}
