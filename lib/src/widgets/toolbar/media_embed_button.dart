import 'package:flutter/material.dart';

import '../../models/themes/quill_icon_theme.dart';
import 'quill_icon_button.dart';

const double _kDefaultIconSize = 18;
const double _kIconButtonFactor = 1.77;

class MediaEmbedButton extends StatelessWidget {
  const MediaEmbedButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.iconSize = _kDefaultIconSize,
    this.iconTheme,
    this.afterButtonPressed,
    this.semanticsIdentifier,
    this.focusNode,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final double iconSize;
  final QuillIconTheme? iconTheme;
  final VoidCallback? afterButtonPressed;
  final String? semanticsIdentifier;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return QuillIconButton(
      tooltip: tooltip,
      highlightElevation: 0,
      hoverElevation: 0,
      size: iconSize * _kIconButtonFactor,
      icon: Icon(
        icon,
        size: iconSize,
        color: iconTheme?.iconUnselectedColor ?? theme.iconTheme.color,
      ),
      fillColor: iconTheme?.iconUnselectedFillColor ?? theme.canvasColor,
      borderRadius: iconTheme?.borderRadius ?? 2,
      afterPressed: afterButtonPressed,
      semanticsIdentifier: semanticsIdentifier,
      focusNode: focusNode,
      onPressed: onPressed,
    );
  }
}
