import 'package:flutter/material.dart';

import 'project_catalog.dart';

class ProjectPicker extends StatelessWidget {
  const ProjectPicker({
    super.key,
    required this.projects,
    required this.activePath,
    required this.onSelected,
    required this.onCreate,
    required this.onJoin,
    this.busy = false,
    this.onSettings,
  });
  final List<SavedProject> projects;
  final String activePath;
  final ValueChanged<SavedProject> onSelected;
  final VoidCallback onCreate, onJoin;
  final bool busy;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final active = projects.where((p) => p.path == activePath).firstOrNull;
    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(Colors.white),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
        minimumSize: const WidgetStatePropertyAll(Size(260, 0)),
        maximumSize: const WidgetStatePropertyAll(Size(340, 440)),
        elevation: const WidgetStatePropertyAll(14),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Color(0xffe9e5ef)),
          ),
        ),
      ),
      menuChildren: [
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: Text(
            '내 프로젝트',
            style: TextStyle(fontSize: 11, color: Color(0xff9990a5)),
          ),
        ),
        for (final project in projects)
          MenuItemButton(
            key: ValueKey('project-option-${project.path}'),
            onPressed: busy || project.path == activePath
                ? null
                : () => onSelected(project),
            leadingIcon: Icon(
              project.path == activePath
                  ? Icons.check_circle_rounded
                  : Icons.folder_outlined,
              size: 18,
              color: const Color(0xff7963d5),
            ),
            child: SizedBox(
              width: 225,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      project.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      project.config.slug,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xff9990a5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const Divider(height: 12),
        if (onSettings != null)
          MenuItemButton(
            key: const Key('project-settings'),
            onPressed: busy ? null : onSettings,
            leadingIcon: const Icon(Icons.tune_rounded, size: 18),
            child: const Text('프로젝트 설정'),
          ),
        MenuItemButton(
          key: const Key('project-create-menu'),
          onPressed: busy ? null : onCreate,
          leadingIcon: const Icon(Icons.add_rounded, size: 18),
          child: const Text('새 프로젝트 만들기'),
        ),
        MenuItemButton(
          key: const Key('project-join-menu'),
          onPressed: busy ? null : onJoin,
          leadingIcon: const Icon(Icons.group_add_outlined, size: 18),
          child: const Text('프로젝트 참여하기'),
        ),
      ],
      builder: (context, controller, child) => Tooltip(
        message: '${active?.name ?? '프로젝트 선택'} · ${projects.length}개 프로젝트',
        child: TextButton(
          key: const Key('project-picker'),
          onPressed: busy
              ? null
              : () =>
                    controller.isOpen ? controller.close() : controller.open(),
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xff302b3c),
            minimumSize: const Size(0, 44),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            backgroundColor: const Color(0xffecefee),
          ),
          child: Row(
            children: [
              if (busy)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                const Icon(Icons.folder_outlined, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  active?.name ?? '프로젝트 선택',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.unfold_more_rounded, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}
