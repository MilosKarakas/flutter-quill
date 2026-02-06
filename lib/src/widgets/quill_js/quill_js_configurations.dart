import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/foundation.dart';

/// Data representing a link (used in create/edit callbacks).
class QuillJsLinkData {
  /// The URL of the link.
  final String url;

  /// Optional display text for the link. If null, the URL is used as the text.
  final String? text;

  const QuillJsLinkData({required this.url, this.text});
}

/// Callback invoked when the user requests to create a new link.
///
/// [selectedText] is the currently selected text in the editor, if any.
/// Return a [QuillJsLinkData] to create the link, or `null` to cancel.
typedef QuillJsLinkCreateCallback = Future<QuillJsLinkData?> Function(
    String? selectedText);

/// Callback invoked when the user taps an existing link in the editor.
///
/// [url] is the current link URL, [text] is the displayed link text.
/// Return an updated [QuillJsLinkData] to modify the link, or `null` to
/// remove it.
typedef QuillJsLinkTappedCallback = Future<QuillJsLinkData?> Function(
    String url, String text);

/// Configuration for the Quill.js-based web editor.
class QuillJsEditorConfiguration {
  /// URL to your self-hosted quill.js (or quill.min.js) file.
  final String quillJsUrl;

  /// URL to your self-hosted Quill CSS theme file (e.g., quill.snow.css).
  /// If null, no theme CSS is loaded (you can include it in your index.html).
  final String? quillCssUrl;

  /// Initial content as a [Delta]. If null, the editor starts empty.
  final Delta? initialContent;

  /// Placeholder text shown when the editor is empty.
  final String? placeholder;

  /// Whether the editor is read-only.
  final bool readOnly;

  /// Callback to create a new link via a custom dialog.
  final QuillJsLinkCreateCallback? onLinkCreate;

  /// Callback when an existing link is tapped in the editor.
  /// Use this to show a custom edit/remove dialog for existing links.
  final QuillJsLinkTappedCallback? onLinkTapped;

  /// Called whenever the editor content changes (user edits only).
  final ValueChanged<Delta>? onContentChanged;

  /// When true, prevents list indentation (Tab key) if there is no preceding
  /// list item at the current indent level. This prevents "orphan" nesting.
  final bool preventOrphanListNesting;

  const QuillJsEditorConfiguration({
    required this.quillJsUrl,
    this.quillCssUrl,
    this.initialContent,
    this.placeholder,
    this.readOnly = false,
    this.onLinkCreate,
    this.onLinkTapped,
    this.onContentChanged,
    this.preventOrphanListNesting = true,
  });
}

/// Represents the current formatting state at the cursor/selection in
/// the Quill.js editor, used to keep the toolbar in sync.
class QuillJsFormatState {
  final bool bold;
  final bool italic;
  final bool underline;

  /// The current list type: `'ordered'`, `'bullet'`, or `null` if not a list.
  final String? list;

  /// The current link URL, or `null` if the cursor is not inside a link.
  final String? link;

  const QuillJsFormatState({
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.list,
    this.link,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is QuillJsFormatState &&
          bold == other.bold &&
          italic == other.italic &&
          underline == other.underline &&
          list == other.list &&
          link == other.link;

  @override
  int get hashCode => Object.hash(bold, italic, underline, list, link);
}

/// Controller for the Quill.js web editor.
///
/// Provides formatting commands, content access, and format state for the
/// toolbar. The editor view attaches its internal JS interop callbacks when
/// mounted, and detaches them when unmounted.
///
/// Usage:
/// ```dart
/// final controller = QuillJsEditorController();
///
/// // In your widget tree:
/// QuillJsToolbar(controller: controller),
/// Expanded(child: QuillJsEditorView(controller: controller, configuration: config)),
///
/// // Read content:
/// final delta = controller.contents;
///
/// // Set content:
/// controller.contents = someDelta;
/// ```
class QuillJsEditorController extends ChangeNotifier {
  QuillJsFormatState _formatState = const QuillJsFormatState();

  /// The current formatting state at the cursor/selection.
  /// Updated automatically by the editor view on selection changes.
  QuillJsFormatState get formatState => _formatState;

  /// Whether the editor view has been mounted and the JS interop is active.
  bool get isAttached => _callbacks != null;

  // -- Internal callback set, wired by the editor view --
  _EditorCallbacks? _callbacks;

  // -- Public API --

  /// Toggles bold formatting at the current selection.
  void toggleBold() => _callbacks?.toggleBold.call();

  /// Toggles italic formatting at the current selection.
  void toggleItalic() => _callbacks?.toggleItalic.call();

  /// Toggles underline formatting at the current selection.
  void toggleUnderline() => _callbacks?.toggleUnderline.call();

  /// Toggles ordered list formatting for the current line.
  void toggleOrderedList() => _callbacks?.toggleOrderedList.call();

  /// Toggles bullet list formatting for the current line.
  void toggleBulletList() => _callbacks?.toggleBulletList.call();

  /// Requests a link creation or edit via the configured callbacks.
  /// If the cursor is on an existing link, triggers [onLinkTapped].
  /// Otherwise, triggers [onLinkCreate].
  void requestLink() => _callbacks?.requestLink.call();

  /// Gets the current editor content as a [Delta].
  Delta get contents =>
      _callbacks?.getContents.call() ?? (Delta()..insert('\n'));

  /// Sets the editor content from a [Delta].
  set contents(Delta delta) => _callbacks?.setContents(delta);

  /// Focuses the editor.
  void focus() => _callbacks?.focus.call();

  /// Removes focus from the editor.
  void blur() => _callbacks?.blur.call();

  /// Called by the editor view to update the format state.
  /// Notifies listeners (toolbar) to rebuild.
  void updateFormatState(QuillJsFormatState state) {
    if (_formatState != state) {
      _formatState = state;
      notifyListeners();
    }
  }

  /// Attaches the interop callbacks from the editor view.
  ///
  /// This is called internally by [QuillJsEditorView] when it mounts.
  /// You should not need to call this directly.
  void attachCallbacks({
    required VoidCallback toggleBold,
    required VoidCallback toggleItalic,
    required VoidCallback toggleUnderline,
    required VoidCallback toggleOrderedList,
    required VoidCallback toggleBulletList,
    required VoidCallback requestLink,
    required Delta Function() getContents,
    required void Function(Delta) setContents,
    required VoidCallback focus,
    required VoidCallback blur,
  }) {
    _callbacks = _EditorCallbacks(
      toggleBold: toggleBold,
      toggleItalic: toggleItalic,
      toggleUnderline: toggleUnderline,
      toggleOrderedList: toggleOrderedList,
      toggleBulletList: toggleBulletList,
      requestLink: requestLink,
      getContents: getContents,
      setContents: setContents,
      focus: focus,
      blur: blur,
    );
  }

  /// Detaches all callbacks. Called by the editor view on dispose.
  void detach() {
    _callbacks = null;
  }

  @override
  void dispose() {
    detach();
    super.dispose();
  }
}

/// Internal holder for editor interop callbacks.
class _EditorCallbacks {
  final VoidCallback toggleBold;
  final VoidCallback toggleItalic;
  final VoidCallback toggleUnderline;
  final VoidCallback toggleOrderedList;
  final VoidCallback toggleBulletList;
  final VoidCallback requestLink;
  final Delta Function() getContents;
  final void Function(Delta) setContents;
  final VoidCallback focus;
  final VoidCallback blur;

  const _EditorCallbacks({
    required this.toggleBold,
    required this.toggleItalic,
    required this.toggleUnderline,
    required this.toggleOrderedList,
    required this.toggleBulletList,
    required this.requestLink,
    required this.getContents,
    required this.setContents,
    required this.focus,
    required this.blur,
  });
}
