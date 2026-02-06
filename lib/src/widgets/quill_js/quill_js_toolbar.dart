import 'package:flutter/material.dart';

import 'quill_js_configurations.dart';
import 'quill_js_editor.dart';

/// A Flutter toolbar for controlling the [QuillJsEditorView].
///
/// Displays formatting buttons (bold, italic, underline, ordered list,
/// unordered list, link). The toolbar listens to the
/// [QuillJsEditorController] to keep button states in sync with the
/// editor's current selection formatting.
class QuillJsToolbar extends StatelessWidget {
  /// The controller shared with the [QuillJsEditorView].
  final QuillJsEditorController controller;

  /// Whether the toolbar buttons should be enabled.
  /// When false, all formatting buttons are disabled.
  final bool enabled;

  const QuillJsToolbar({
    super.key,
    required this.controller,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.formatState;
        final isEnabled = enabled && controller.isAttached;

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).dividerColor,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              // Bold
              _ToolbarButton(
                icon: Icons.format_bold,
                tooltip: 'Bold',
                isActive: state.bold,
                isEnabled: isEnabled,
                onPressed: controller.toggleBold,
              ),
              // Italic
              _ToolbarButton(
                icon: Icons.format_italic,
                tooltip: 'Italic',
                isActive: state.italic,
                isEnabled: isEnabled,
                onPressed: controller.toggleItalic,
              ),
              // Underline
              _ToolbarButton(
                icon: Icons.format_underlined,
                tooltip: 'Underline',
                isActive: state.underline,
                isEnabled: isEnabled,
                onPressed: controller.toggleUnderline,
              ),

              const _ToolbarDivider(),

              // Ordered list
              _ToolbarButton(
                icon: Icons.format_list_numbered,
                tooltip: 'Ordered List',
                isActive: state.list == 'ordered',
                isEnabled: isEnabled,
                onPressed: controller.toggleOrderedList,
              ),
              // Bullet list
              _ToolbarButton(
                icon: Icons.format_list_bulleted,
                tooltip: 'Bullet List',
                isActive: state.list == 'bullet',
                isEnabled: isEnabled,
                onPressed: controller.toggleBulletList,
              ),

              const _ToolbarDivider(),

              // Link
              _ToolbarButton(
                icon: Icons.link,
                tooltip: 'Link',
                isActive: state.link != null,
                isEnabled: isEnabled,
                onPressed: controller.requestLink,
              ),
            ],
          ),
        );
      },
    );
  }

}

// ---------------------------------------------------------------------------
// Private helper widgets
// ---------------------------------------------------------------------------

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final bool isEnabled;
  final VoidCallback onPressed;

  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.isActive,
    required this.isEnabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isEnabled ? onPressed : null,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isActive
                  ? theme.colorScheme.primaryContainer
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(
              icon,
              size: 20,
              color: !isEnabled
                  ? theme.disabledColor
                  : isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolbarDivider extends StatelessWidget {
  const _ToolbarDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 24,
      margin: const EdgeInsets.symmetric(horizontal: 6),
      color: Theme.of(context).dividerColor,
    );
  }
}

// ---------------------------------------------------------------------------
// QuillJsEditorWidget — convenience wrapper
// ---------------------------------------------------------------------------

/// A convenience widget that combines the [QuillJsToolbar] and
/// [QuillJsEditorView] in a vertical layout.
///
/// This is the simplest way to use the Quill.js editor. For more control
/// over layout, use [QuillJsToolbar] and [QuillJsEditorView] separately.
///
/// ```dart
/// QuillJsEditorWidget(
///   controller: controller,
///   configuration: QuillJsEditorConfiguration(
///     quillJsUrl: '/assets/quill.min.js',
///     quillCssUrl: '/assets/quill.snow.css',
///     onLinkCreate: (selectedText) async {
///       // Show your custom link dialog and return QuillJsLinkData
///     },
///     onLinkTapped: (url, text) async {
///       // Show your custom edit/remove dialog
///     },
///   ),
/// )
/// ```
class QuillJsEditorWidget extends StatelessWidget {
  final QuillJsEditorController controller;
  final QuillJsEditorConfiguration configuration;

  /// Whether to show the toolbar. Defaults to true.
  final bool showToolbar;

  const QuillJsEditorWidget({
    super.key,
    required this.controller,
    required this.configuration,
    this.showToolbar = true,
  });

  @override
  Widget build(BuildContext context) {
    // QuillJsEditorView is imported via conditional export, so this import
    // works on both web and non-web (with the stub).
    return Column(
      children: [
        if (showToolbar)
          QuillJsToolbar(
            controller: controller,
            enabled: !configuration.readOnly,
          ),
        Expanded(
          child: _buildEditorView(),
        ),
      ],
    );
  }

  Widget _buildEditorView() {
    return QuillJsEditorView(
      configuration: configuration,
      controller: controller,
    );
  }
}

