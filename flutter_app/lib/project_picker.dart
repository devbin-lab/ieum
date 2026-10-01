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
  });
  final List<SavedProject> projects;
  final String activePath;
  final ValueChanged<SavedProject> onSelected;
  final VoidCallback onCreate, onJoin;
  final bool busy;

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
      builder: (context, controller, child) => InkWell(
        key: const Key('project-picker'),
        borderRadius: BorderRadius.circular(10),
        onTap: busy
            ? null
            : () => controller.isOpen ? controller.close() : controller.open(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
          child: Row(
            children: [
              const Icon(
                Icons.workspaces_outline,
                size: 20,
                color: Color(0xff7963d5),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      active?.name ?? '프로젝트',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      busy ? '프로젝트 준비 중…' : '${projects.length}개 프로젝트',
                      style: const TextStyle(
                        fontSize: 10,
                        color: Color(0xff9990a5),
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.unfold_more_rounded,
                size: 18,
                color: Color(0xff9990a5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
