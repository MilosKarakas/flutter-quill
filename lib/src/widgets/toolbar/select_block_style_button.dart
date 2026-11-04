import 'package:flutter/material.dart';

import '../../models/themes/quill_icon_theme.dart';
import '../../translations/toolbar.i18n.dart';
import '../quill_js/block_style.dart';
import '../quill_js/quill_js_configurations.dart';

class SelectBlockStyleButton extends StatefulWidget {
  const SelectBlockStyleButton({
    required this.controller,
    required this.enabledFormats,
    this.iconSize = 18,
    this.iconTheme,
    this.afterButtonPressed,
    this.tooltip,
    this.focusNode,
    super.key,
  });

  final QuillJsEditorController controller;
  final List<String> enabledFormats;
  final double iconSize;
  final QuillIconTheme? iconTheme;
  final VoidCallback? afterButtonPressed;
  final String? tooltip;
  final FocusNode? focusNode;

  @override
  State<SelectBlockStyleButton> createState() => _SelectBlockStyleButtonState();
}

class _SelectBlockStyleButtonState extends State<SelectBlockStyleButton> {
  final MenuController _menuController = MenuController();
  bool _editorIgnoresPointers = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onFormat);
  }

  @override
  void didUpdateWidget(SelectBlockStyleButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _releaseEditorPointers();
      oldWidget.controller.removeListener(_onFormat);
      widget.controller.addListener(_onFormat);
    }
  }

  @override
  void dispose() {
    _releaseEditorPointers();
    widget.controller.removeListener(_onFormat);
    super.dispose();
  }

  void _onFormat() {
    if (mounted) setState(() {});
  }

  void _holdEditorPointers() {
    if (_editorIgnoresPointers) return;
    _editorIgnoresPointers = true;
    widget.controller.setEditorIgnoresPointers(true);
  }

  void _releaseEditorPointers() {
    if (!_editorIgnoresPointers) return;
    _editorIgnoresPointers = false;
    widget.controller.setEditorIgnoresPointers(false);
  }

  void _apply(BlockStyleChoice choice) {
    _releaseEditorPointers();
    final applied = widget.controller.applyBlockStyle(choice);
    if (applied) widget.afterButtonPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final items = blockStyleMenu(widget.enabledFormats);
    final current = widget.controller.formatState.blockStyle;
    final shown = items.contains(current) ? current : BlockStyleChoice.paragraph;
    final color = widget.iconTheme?.iconUnselectedColor ?? Theme.of(context).iconTheme.color;
    final labelStyle = TextStyle(color: color, fontSize: widget.iconSize * 0.75);
    return MenuAnchor(
      controller: _menuController,
      childFocusNode: widget.focusNode,
      onOpen: _holdEditorPointers,
      onClose: _releaseEditorPointers,
      menuChildren: [
        for (final choice in items)
          MenuItemButton(
            onPressed: () => _apply(choice),
            child: SizedBox(
              width: 132,
              child: Text(choice.label.i18n, style: labelStyle),
            ),
          ),
      ],
      builder: (context, menu, child) {
        return Tooltip(
          message: widget.tooltip ?? 'Header style'.i18n,
          child: SizedBox(
            height: widget.iconSize * 1.77,
            width: 148,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                focusNode: widget.focusNode,
                onTap: () {
                  if (menu.isOpen) {
                    menu.close();
                  } else {
                    menu.open();
                  }
                },
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        shown.label.i18n,
                        overflow: TextOverflow.ellipsis,
                        style: labelStyle,
                      ),
                    ),
                    Icon(Icons.arrow_drop_down, size: widget.iconSize, color: color),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
