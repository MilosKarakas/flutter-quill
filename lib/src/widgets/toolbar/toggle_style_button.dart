import 'package:flutter/material.dart';

import '../../models/documents/attribute.dart';
import '../../models/themes/quill_icon_theme.dart';
import '../../utils/widgets.dart';
import '../controller.dart';
import '../quill_js/quill_js_configurations.dart';
import '../toolbar.dart';

typedef ToggleStyleButtonBuilder = Widget Function(
  BuildContext context,
  Attribute attribute,
  IconData icon,
  Color? fillColor,
  bool? isToggled,
  VoidCallback? onPressed,
  VoidCallback? afterPressed, [
  double iconSize,
  QuillIconTheme? iconTheme,
  String? semanticsIdentifier,
]);

class ToggleStyleButton extends StatefulWidget {
  const ToggleStyleButton({
    required this.attribute,
    required this.icon,
    this.controller,
    this.quillJsController,
    this.iconSize = kDefaultIconSize,
    this.fillColor,
    this.childBuilder = defaultToggleStyleButtonBuilder,
    this.iconTheme,
    this.afterButtonPressed,
    this.tooltip,
    this.semanticsIdentifier,
    Key? key,
  })  : assert(controller != null || quillJsController != null,
            'Either controller or quillJsController must be provided'),
        super(key: key);

  final Attribute attribute;

  final IconData icon;
  final double iconSize;

  final Color? fillColor;

  final QuillController? controller;
  final QuillJsEditorController? quillJsController;

  final ToggleStyleButtonBuilder childBuilder;

  ///Specify an icon theme for the icons in the toolbar
  final QuillIconTheme? iconTheme;

  final VoidCallback? afterButtonPressed;
  final String? tooltip;
  final String? semanticsIdentifier;

  /// Whether this button uses the QuillJs controller path.
  bool get _usesQuillJs => quillJsController != null;

  /// The [ChangeNotifier] to listen to — works for both controller types.
  ChangeNotifier get _listenable =>
      (quillJsController ?? controller) as ChangeNotifier;

  @override
  _ToggleStyleButtonState createState() => _ToggleStyleButtonState();
}

class _ToggleStyleButtonState extends State<ToggleStyleButton> {
  bool? _isToggled;

  @override
  void initState() {
    super.initState();
    _isToggled = _getIsToggled();
    widget._listenable.addListener(_didChangeEditingValue);
  }

  @override
  Widget build(BuildContext context) {
    return UtilityWidgets.maybeTooltip(
      message: widget.tooltip,
      child: widget.childBuilder(
        context,
        widget.attribute,
        widget.icon,
        widget.fillColor,
        _isToggled,
        _toggleAttribute,
        widget.afterButtonPressed,
        widget.iconSize,
        widget.iconTheme,
        widget.semanticsIdentifier,
      ),
    );
  }

  @override
  void didUpdateWidget(covariant ToggleStyleButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget._listenable != widget._listenable) {
      oldWidget._listenable.removeListener(_didChangeEditingValue);
      widget._listenable.addListener(_didChangeEditingValue);
      _isToggled = _getIsToggled();
    }
  }

  @override
  void dispose() {
    widget._listenable.removeListener(_didChangeEditingValue);
    super.dispose();
  }

  void _didChangeEditingValue() {
    setState(() => _isToggled = _getIsToggled());
  }

  bool _getIsToggled() {
    if (widget._usesQuillJs) {
      return _getIsToggledQuillJs();
    }
    return _getIsToggledClassic(
        widget.controller!.getSelectionStyle().attributes);
  }

  bool _getIsToggledQuillJs() {
    final state = widget.quillJsController!.formatState;
    final key = widget.attribute.key;
    if (key == Attribute.bold.key) return state.bold;
    if (key == Attribute.italic.key) return state.italic;
    if (key == Attribute.underline.key) return state.underline;
    if (key == Attribute.list.key) {
      if (widget.attribute.value == 'ordered') {
        return state.list == 'ordered';
      }
      if (widget.attribute.value == 'bullet') {
        return state.list == 'bullet';
      }
    }
    return false;
  }

  bool _getIsToggledClassic(Map<String, Attribute> attrs) {
    if (widget.attribute.key == Attribute.list.key ||
        widget.attribute.key == Attribute.script.key) {
      final attribute = attrs[widget.attribute.key];
      if (attribute == null) {
        return false;
      }
      return attribute.value == widget.attribute.value;
    }
    return attrs.containsKey(widget.attribute.key);
  }

  void _toggleAttribute() {
    if (widget._usesQuillJs) {
      _toggleAttributeQuillJs();
    } else {
      widget.controller!.formatSelection(_isToggled!
          ? Attribute.clone(widget.attribute, null)
          : widget.attribute);
    }
  }

  void _toggleAttributeQuillJs() {
    final ctrl = widget.quillJsController!;
    final key = widget.attribute.key;
    if (key == Attribute.bold.key) {
      ctrl.toggleBold();
    } else if (key == Attribute.italic.key) {
      ctrl.toggleItalic();
    } else if (key == Attribute.underline.key) {
      ctrl.toggleUnderline();
    } else if (key == Attribute.list.key) {
      if (widget.attribute.value == 'ordered') {
        ctrl.toggleOrderedList();
      } else if (widget.attribute.value == 'bullet') {
        ctrl.toggleBulletList();
      }
    }
  }
}

Widget defaultToggleStyleButtonBuilder(
  BuildContext context,
  Attribute attribute,
  IconData icon,
  Color? fillColor,
  bool? isToggled,
  VoidCallback? onPressed,
  VoidCallback? afterPressed, [
  double iconSize = kDefaultIconSize,
  QuillIconTheme? iconTheme,
  String? semanticsIdentifier,
]) {
  final theme = Theme.of(context);
  final isEnabled = onPressed != null;
  final iconColor = isEnabled
      ? isToggled == true
          ? (iconTheme?.iconSelectedColor ??
              theme
                  .primaryIconTheme.color) //You can specify your own icon color
          : (iconTheme?.iconUnselectedColor ?? theme.iconTheme.color)
      : (iconTheme?.disabledIconColor ?? theme.disabledColor);
  final fill = isEnabled
      ? isToggled == true
          ? (iconTheme?.iconSelectedFillColor ??
              Theme.of(context).primaryColor) //Selected icon fill color
          : (iconTheme?.iconUnselectedFillColor ??
              theme.canvasColor) //Unselected icon fill color :
      : (iconTheme?.disabledIconFillColor ??
          (fillColor ?? theme.canvasColor)); //Disabled icon fill color
  return QuillIconButton(
    highlightElevation: 0,
    hoverElevation: 0,
    size: iconSize * kIconButtonFactor,
    icon: Icon(icon, size: iconSize, color: iconColor),
    fillColor: fill,
    onPressed: onPressed,
    afterPressed: afterPressed,
    borderRadius: iconTheme?.borderRadius ?? 2,
    semanticsIdentifier: semanticsIdentifier,
  );
}
