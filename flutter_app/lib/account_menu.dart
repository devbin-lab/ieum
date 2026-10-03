import 'package:flutter/material.dart';

/// The workspace account actions live here so navigation stays focused on work.
class AccountMenu extends StatelessWidget {
  const AccountMenu({
    super.key,
    required this.name,
    required this.role,
    required this.avatar,
    required this.onSettings,
    this.onSignOut,
    this.profileControl,
    this.onProjectSettings,
  });

  final String name, role;
  final Widget avatar;
  final VoidCallback onSettings;
  final VoidCallback? onSignOut;
  final Widget? profileControl;
  final VoidCallback? onProjectSettings;

  @override
  Widget build(BuildContext context) => MenuAnchor(
    style: MenuStyle(
      alignment: Alignment.topLeft,
      backgroundColor: const WidgetStatePropertyAll(Colors.white),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      padding: const WidgetStatePropertyAll(EdgeInsets.all(6)),
      minimumSize: const WidgetStatePropertyAll(Size(260, 0)),
      maximumSize: const WidgetStatePropertyAll(Size(300, 360)),
      elevation: const WidgetStatePropertyAll(12),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xffe1e4e3)),
        ),
      ),
    ),
    menuChildren: [
      Padding(
        key: const Key('account-menu-summary'),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        child: SizedBox(
          width: 228,
          child: Row(
            children: [
              avatar,
              const SizedBox(width: 10),
              Expanded(child: identity()),
            ],
          ),
        ),
      ),
      if (profileControl != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          child: SizedBox(width: 228, height: 42, child: profileControl),
        ),
      const Divider(height: 1),
      MenuItemButton(
        key: const Key('account-settings'),
        onPressed: onSettings,
        leadingIcon: const Icon(Icons.settings_outlined, size: 18),
        child: const Text('개인 설정', style: TextStyle(fontSize: 12)),
      ),
      if (onProjectSettings != null)
        MenuItemButton(
          key: const Key('project-settings'),
          onPressed: onProjectSettings,
          leadingIcon: const Icon(Icons.folder_outlined, size: 18),
          child: const Text('프로젝트 설정', style: TextStyle(fontSize: 12)),
        ),
      if (onSignOut != null) ...[
        const Divider(height: 1),
        MenuItemButton(
          key: const Key('account-sign-out'),
          onPressed: onSignOut,
          leadingIcon: const Icon(Icons.logout_rounded, size: 18),
          child: const Text('로그아웃', style: TextStyle(fontSize: 12)),
        ),
      ],
    ],
    builder: (context, controller, child) => Tooltip(
      message: '$name · $role',
      child: IconButton(
        key: const Key('sidebar-account'),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
        padding: EdgeInsets.zero,
        icon: avatar,
      ),
    ),
  );

  Widget identity() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 3),
      Text(
        role,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 10, color: Color(0xff9990a5)),
      ),
    ],
  );
}
