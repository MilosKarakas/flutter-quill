import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/themes/quill_icon_theme.dart';
import '../../translations/toolbar.i18n.dart';
import '../quill_js/block_style.dart';
import '../quill_js/quill_js_configurations.dart';

const double _kMinTriggerWidth = 96;
const double _kMaxTriggerWidth = 220;
const double _kMenuItemMinWidth = 96;
const double _kHorizontalPadding = 8;
const double _kCheckSlotWidth = 28;

/// Whether the block-style dropdown should rebuild for [next].
@visibleForTesting
bool blockStyleDropdownNeedsRebuild(
  BlockStyleChoice? previous,
  BlockStyleChoice next,
) =>
    previous != next;

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
  BlockStyleChoice? _lastBlockStyle;
  bool _lastMixed = false;

  Object? _widthCacheKey;
  double? _cachedTriggerWidth;

  @override
  void initState() {
    super.initState();
    _lastBlockStyle = widget.controller.formatState.blockStyle;
    _lastMixed = widget.controller.formatState.blockStyleMixed;
    widget.controller.addListener(_onFormat);
  }

  @override
  void didUpdateWidget(SelectBlockStyleButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _releaseEditorPointers();
      oldWidget.controller.removeListener(_onFormat);
      widget.controller.addListener(_onFormat);
      _lastBlockStyle = widget.controller.formatState.blockStyle;
      _lastMixed = widget.controller.formatState.blockStyleMixed;
    }
    if (oldWidget.enabledFormats != widget.enabledFormats ||
        oldWidget.iconSize != widget.iconSize) {
      _widthCacheKey = null;
      _cachedTriggerWidth = null;
    }
  }

  @override
  void dispose() {
    _releaseEditorPointers();
    widget.controller.removeListener(_onFormat);
    super.dispose();
  }

  void _onFormat() {
    if (!mounted) return;
    final state = widget.controller.formatState;
    final next = state.blockStyle;
    if (!blockStyleDropdownNeedsRebuild(_lastBlockStyle, next) &&
        state.blockStyleMixed == _lastMixed) {
      return;
    }
    _lastBlockStyle = next;
    _lastMixed = state.blockStyleMixed;
    setState(() {});
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

  TextStyle _baseLabelStyle(BuildContext context) {
    final color = widget.iconTheme?.iconUnselectedColor ??
        Theme.of(context).iconTheme.color;
    return TextStyle(color: color, fontSize: widget.iconSize * 0.75);
  }

  TextStyle _menuLabelStyle(BlockStyleChoice choice, TextStyle base) {
    final baseSize = base.fontSize ?? 14;
    switch (choice) {
      case BlockStyleChoice.heading1:
        return base.copyWith(
          fontSize: baseSize * 1.5,
          fontWeight: FontWeight.w600,
          height: 1.1,
        );
      case BlockStyleChoice.heading2:
        return base.copyWith(
          fontSize: baseSize * 1.35,
          fontWeight: FontWeight.w600,
          height: 1.1,
        );
      case BlockStyleChoice.heading3:
        return base.copyWith(
          fontSize: baseSize * 1.25,
          fontWeight: FontWeight.w600,
          height: 1.1,
        );
      case BlockStyleChoice.heading4:
        return base.copyWith(
          fontSize: baseSize * 1.15,
          fontWeight: FontWeight.w600,
          height: 1.1,
        );
      case BlockStyleChoice.heading5:
        return base.copyWith(
          fontSize: baseSize * 1.05,
          fontWeight: FontWeight.w600,
          height: 1.1,
        );
      case BlockStyleChoice.heading6:
        return base.copyWith(
          fontSize: baseSize,
          fontWeight: FontWeight.w600,
          height: 1.1,
        );
      case BlockStyleChoice.preformatted:
        return base.copyWith(fontFamily: 'monospace', height: 1.2);
      case BlockStyleChoice.paragraph:
        return base;
    }
  }

  double _measureLabelWidth(
    String text,
    TextStyle style,
    TextDirection direction,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: direction,
      maxLines: 1,
    )..layout();
    return painter.width;
  }

  double _triggerWidth(
    BuildContext context,
    List<BlockStyleChoice> items,
    TextStyle baseStyle,
  ) {
    final locale = Localizations.localeOf(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    final cacheKey = Object.hash(
      locale,
      textScale,
      baseStyle.fontSize,
      baseStyle.color,
      Object.hashAll(items),
    );
    if (_widthCacheKey == cacheKey && _cachedTriggerWidth != null) {
      return _cachedTriggerWidth!;
    }

    final direction = Directionality.of(context);
    var widest = 0.0;
    for (final choice in items) {
      final width =
          _measureLabelWidth(choice.label.i18n, baseStyle, direction);
      if (width > widest) widest = width;
    }
    final arrow = widget.iconSize;
    final width = (_kHorizontalPadding * 2 + widest + arrow)
        .clamp(_kMinTriggerWidth, _kMaxTriggerWidth);
    _widthCacheKey = cacheKey;
    _cachedTriggerWidth = width;
    return width;
  }

  @override
  Widget build(BuildContext context) {
    final items = blockStyleMenu(widget.enabledFormats);
    final formatState = widget.controller.formatState;
    final current = formatState.blockStyle;
    final BlockStyleChoice? shown = formatState.blockStyleMixed
        ? null
        : (items.contains(current) ? current : BlockStyleChoice.paragraph);
    final baseStyle = _baseLabelStyle(context);
    final triggerWidth = _triggerWidth(context, items, baseStyle);
    final color = baseStyle.color;

    return MenuAnchor(
      controller: _menuController,
      childFocusNode: widget.focusNode,
      onOpen: _holdEditorPointers,
      onClose: _releaseEditorPointers,
      menuChildren: [
        for (final choice in items)
          MenuItemButton(
            onPressed: () => _apply(choice),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: _kMenuItemMinWidth),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: _kCheckSlotWidth,
                    child: choice == shown
                        ? Icon(
                            Icons.check,
                            size: widget.iconSize * 0.85,
                            color: color,
                          )
                        : null,
                  ),
                  Flexible(
                    child: Text(
                      choice.label.i18n,
                      style: _menuLabelStyle(choice, baseStyle),
                      overflow: TextOverflow.visible,
                      softWrap: false,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
      builder: (context, menu, child) {
        return Tooltip(
          message: widget.tooltip ?? 'Header style'.i18n,
          child: SizedBox(
            height: widget.iconSize * 1.77,
            width: triggerWidth,
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
                    const SizedBox(width: _kHorizontalPadding),
                    Expanded(
                      child: Text(
                        shown?.label.i18n ?? '',
                        overflow: TextOverflow.ellipsis,
                        style: baseStyle,
                      ),
                    ),
                    Icon(
                      Icons.arrow_drop_down,
                      size: widget.iconSize,
                      color: color,
                    ),
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
