import 'package:flutter/material.dart';

class SheetMenuHeader extends PopupMenuEntry<String> {
  const SheetMenuHeader({
    super.key,
    required this.title,
    required this.subtitle,
  });
  final String title, subtitle;
  @override
  double get height => 56;
  @override
  bool represents(String? value) => false;
  @override
  State<SheetMenuHeader> createState() => _SheetMenuHeaderState();
}

class _SheetMenuHeaderState extends State<SheetMenuHeader> {
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 9, 12, 11),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xff38475c),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          widget.subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: Color(0xff929dac)),
        ),
      ],
    ),
  );
}

class SheetMenuAction extends PopupMenuEntry<String> {
  const SheetMenuAction({
    super.key,
    required this.value,
    required this.title,
    required this.icon,
    this.subtitle,
    this.color = const Color(0xff6b7e98),
    this.trailingIcon,
    this.danger = false,
  });
  final String value, title;
  final String? subtitle;
  final IconData icon;
  final IconData? trailingIcon;
  final Color color;
  final bool danger;
  @override
  double get height => subtitle == null ? 44 : 54;
  @override
  bool represents(String? value) => this.value == value;
  @override
  State<SheetMenuAction> createState() => _SheetMenuActionState();
}

class _SheetMenuActionState extends State<SheetMenuAction> {
  bool hovered = false, focused = false;

  @override
  Widget build(BuildContext context) {
    final active = hovered || focused;
    final color = widget.danger ? const Color(0xffb86a72) : widget.color;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: InkWell(
        onTap: () => Navigator.of(context).pop(widget.value),
        onHover: (value) => setState(() => hovered = value),
        onFocusChange: (value) => setState(() => focused = value),
        borderRadius: BorderRadius.circular(8),
        splashFactory: NoSplash.splashFactory,
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOutCubic,
          height: widget.height - 2,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: active
                ? widget.danger
                      ? const Color(0xfffcf0f1)
                      : const Color(0xffeff3f8)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(widget.icon, size: 16, color: color),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        color: widget.danger ? color : const Color(0xff344052),
                      ),
                    ),
                    if (widget.subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        widget.subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: Color(0xff8d99a8),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (widget.trailingIcon != null) ...[
                const SizedBox(width: 8),
                Icon(
                  widget.trailingIcon,
                  size: 14,
                  color: const Color(0xffa7b2c0),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
