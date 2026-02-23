import 'dart:ui' show Color;

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/foundation.dart';

import '../../models/structs/copy_data.dart';
import '../default_styles.dart';

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
/// [existingUrl] is the current link URL if editing an existing link, null if creating new.
/// Return a [QuillJsLinkData] to create the link, or `null` to cancel.
typedef QuillJsLinkCreateCallback =
    Future<QuillJsLinkData?> Function({
      String? selectedText,
      String? existingUrl,
    });

/// Callback invoked when the user taps an existing link in the editor.
///
/// [url] is the current link URL, [text] is the displayed link text.
/// Return an updated [QuillJsLinkData] to modify the link, or `null` to
/// remove it.
typedef QuillJsLinkTappedCallback =
    Future<QuillJsLinkData?> Function(String url, String text);

/// Visual styling for the Quill.js editor content area.
///
/// All properties are optional — unset values fall back to the Quill.js
/// theme defaults (Snow theme).
class QuillJsEditorStyle {
  /// The CSS font-family value (e.g. `'Roboto, sans-serif'`).
  final String? fontFamily;

  /// CSS `font-variation-settings` value for variable fonts.
  ///
  /// Example: `"wght" 400, "wdth" 95`
  final String? fontVariationSettings;

  /// Font size in logical pixels.
  final double? fontSize;

  /// Line-height multiplier (e.g. `1.5`).
  final double? lineHeight;

  /// Letter spacing in logical pixels.
  final double? letterSpacing;

  /// Default text color.
  final Color? color;

  /// Color of the text cursor (caret).
  final Color? caretColor;

  /// Background color of the text selection highlight.
  final Color? selectionColor;

  /// Color for selection handles on mobile web (maps to CSS `accent-color`).
  ///
  /// Browser support is limited — works on Chrome/Android, but iOS Safari
  /// ignores it and uses the system tint color instead.
  final Color? selectionHandleColor;

  /// Color of the placeholder text shown when the editor is empty.
  final Color? placeholderColor;

  /// Color of hyperlinks in the editor content.
  final Color? linkColor;

  /// Font weight for bold text (e.g. `700`, `'bold'`).
  /// Applied to `strong` elements. Defaults to Quill theme (typically 700).
  final Object? boldFontWeight;

  /// Font style for italic text (e.g. `'italic'`, `'oblique'`).
  /// Applied to `em` elements. Defaults to Quill theme (typically italic).
  final String? italicFontStyle;

  const QuillJsEditorStyle({
    this.fontFamily,
    this.fontVariationSettings,
    this.fontSize,
    this.lineHeight,
    this.letterSpacing,
    this.color,
    this.caretColor,
    this.selectionColor,
    this.selectionHandleColor,
    this.placeholderColor,
    this.linkColor,
    this.boldFontWeight,
    this.italicFontStyle,
  });
}

/// Configuration for the Quill.js-based web editor.
class QuillJsEditorConfiguration {
  /// URL to your self-hosted quill.js (or quill.min.js) file.
  final String quillJsUrl;

  /// URL to your self-hosted Quill CSS theme file (e.g., quill.snow.css).
  /// If null, no theme CSS is loaded (you can include it in your index.html).
  final String? quillCssUrl;

  /// Additional CSS injected into the iframe `<style>` block.
  ///
  /// Useful for custom `@font-face` declarations required by [styles] or
  /// [style] (for example variable fonts shipped as Flutter web assets).
  ///
  /// Example:
  /// ```css
  /// @font-face {
  ///   font-family: 'RobotoFlex';
  ///   src: url('assets/assets/fonts/Roboto_Flex/RobotoFlex.ttf')
  ///        format('truetype-variations');
  /// }
  /// ```
  final String? customCss;

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

  /// Called once when the web editor is fully initialized and mounted.
  ///
  /// This fires after internal controller attachment and after the editor
  /// enters the ready state. The callback is dispatched in a post-frame
  /// callback so it is safe to request focus immediately.
  ///
  /// Example:
  /// ```dart
  /// onEditorReady: () {
  ///   myFocusNode.requestFocus();
  ///   controller.focus();
  /// },
  /// ```
  final VoidCallback? onEditorReady;

  /// Called after a text change is applied; return `false` to revert it.
  ///
  /// Quill.js applies changes before firing events, so this callback runs
  /// post-change. If it returns `false`, the change is reverted by restoring
  /// [oldDelta]. Use this for max-length enforcement, content validation, etc.
  ///
  /// [changeDelta] is the delta that was applied; [oldDelta] is the document
  /// before the change. A brief flicker may occur when reverting large changes.
  final bool Function(Delta changeDelta, Delta oldDelta)? onBeforeTextChange;

  /// When true, prevents list indentation (Tab key) if there is no preceding
  /// list item at the current indent level. This prevents "orphan" nesting.
  final bool preventOrphanListNesting;

  /// Intercepts paste operations inside the iframe.
  ///
  /// Called when the user pastes into the editor. Return a [Delta] to apply
  /// custom formatted content, or `null` to let Quill handle the paste as usual.
  /// Matches [QuillEditor.onPasteInterceptor] API.
  final Delta? Function(String? plainText, String? html)? onPasteInterceptor;

  /// Intercepts copy operations inside the iframe.
  ///
  /// Called when the user copies from the editor. Return [CopyClipboardData]
  /// to write rich text to the clipboard, or `null` for default behavior.
  /// Matches [QuillEditor.onCopyInterceptor] API.
  final CopyInterceptor? onCopyInterceptor;

  /// Styles for the editor, using the same [DefaultStyles] API as [QuillEditor].
  /// Enables sharing one configuration between native and web editors.
  /// Applied first to text-level defaults (`.ql-editor`, links, placeholder,
  /// bold/italic, etc.).
  final DefaultStyles? styles;

  /// Visual styling for the editor content area (font, colors, etc.).
  /// Applied after [styles] to override/add iframe CSS for caret, selection,
  /// colors, font properties, and related visual details.
  ///
  /// When both [styles] and [style] are null, Quill.js theme defaults apply.
  final QuillJsEditorStyle? style;

  /// When true, the cursor is moved to the end of the document and the editor
  /// scrolls to make it visible — but only on the **first focus gain**, and
  /// only if the user has not already positioned the caret themselves.
  ///
  /// This avoids the focus-stealing side-effect of the old
  /// `moveCursorToEndOnInit` approach, which called `setSelection` at init
  /// time and implicitly focused the editor.
  ///
  /// Defaults to `false`.
  final bool moveCursorToEndOnFirstFocus;

  /// Whether tapping outside the editor should automatically blur it and
  /// dismiss the on-screen keyboard.
  ///
  /// Uses Flutter's [TapRegion] mechanism: any pointer-down event that lands
  /// outside the editor's tap region group causes the editor to blur.
  ///
  /// To prevent toolbar buttons from triggering the blur, wrap your toolbar
  /// widget in a [TapRegion] with the same [tapRegionGroupId]:
  ///
  /// ```dart
  /// TapRegion(
  ///   groupId: myGroupId,
  ///   child: MyToolbar(controller: controller),
  /// )
  /// ```
  ///
  /// Defaults to `true`.
  final bool unfocusOnTapOutside;

  /// Enables scroll handoff from the inner editor to outer Flutter scrollables.
  ///
  /// When enabled, wheel/touch deltas that cannot be consumed by the editor
  /// (already at top/bottom bounds or not scrollable) are forwarded to:
  /// 1) [onOuterScrollDelta], if provided; otherwise
  /// 2) the nearest ancestor [Scrollable] found by [QuillJsEditorView].
  ///
  /// Defaults to `false`.
  final bool enableOuterScrollHandoff;

  /// Optional callback receiving residual vertical scroll delta from the editor.
  ///
  /// Positive values mean scrolling down; negative means up.
  /// If null, [QuillJsEditorView] applies deltas to the nearest ancestor
  /// [Scrollable] when [enableOuterScrollHandoff] is true.
  final ValueChanged<double>? onOuterScrollDelta;

  /// Enables editor self-sizing based on content with [minLines] and [maxLines].
  ///
  /// When enabled, [QuillJsEditorView] computes its own height from text style,
  /// content, and available width; once [maxLines] is reached, internal editor
  /// scrolling is used.
  final bool autoResizeToContent;

  /// Minimum visible line count when [autoResizeToContent] is enabled.
  final int minLines;

  /// Maximum visible line count when [autoResizeToContent] is enabled.
  final int maxLines;

  /// Horizontal text padding used by auto-resize measurements.
  ///
  /// Should match the editor's CSS horizontal padding for accurate wrapping.
  final double autoResizeHorizontalPadding;

  /// Vertical text padding used by auto-resize measurements.
  ///
  /// Should match top + bottom editor CSS padding.
  final double autoResizeVerticalPadding;

  const QuillJsEditorConfiguration({
    required this.quillJsUrl,
    this.quillCssUrl,
    this.customCss,
    this.initialContent,
    this.placeholder,
    this.readOnly = false,
    this.onLinkCreate,
    this.onLinkTapped,
    this.onContentChanged,
    this.onEditorReady,
    this.onBeforeTextChange,
    this.preventOrphanListNesting = true,
    this.onPasteInterceptor,
    this.onCopyInterceptor,
    this.styles,
    this.style,
    this.moveCursorToEndOnFirstFocus = false,
    this.unfocusOnTapOutside = true,
    this.enableOuterScrollHandoff = false,
    this.onOuterScrollDelta,
    this.autoResizeToContent = false,
    this.minLines = 1,
    this.maxLines = 1,
    this.autoResizeHorizontalPadding = 32,
    this.autoResizeVerticalPadding = 24,
  }) : assert(minLines > 0),
       assert(maxLines >= minLines),
       assert(autoResizeHorizontalPadding >= 0),
       assert(autoResizeVerticalPadding >= 0);
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

  /// The current virtual-keyboard height in logical pixels.
  ///
  /// On mobile web, `MediaQuery.viewInsets.bottom` is always **zero** — it
  /// does not reflect the on-screen keyboard.  The editor view works around
  /// this by listening to the browser's Visual Viewport API and updating this
  /// notifier whenever the keyboard opens or closes.
  ///
  /// Use this in your layout to add bottom padding or shrink the available
  /// height exactly like you would with `viewInsets.bottom` on native:
  ///
  /// ```dart
  /// ValueListenableBuilder<double>(
  ///   valueListenable: controller.keyboardHeight,
  ///   builder: (_, kbHeight, child) {
  ///     return Padding(
  ///       padding: EdgeInsets.only(bottom: kbHeight),
  ///       child: child,
  ///     );
  ///   },
  ///   child: /* ... */,
  /// )
  /// ```
  final ValueNotifier<double> keyboardHeight = ValueNotifier<double>(0);

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
  ///
  /// This operation is asynchronous because it usually opens a dialog and
  /// waits for user input.
  Future<void> requestLink() =>
      _callbacks?.requestLink.call() ?? Future<void>.value();

  /// Gets the current editor content as a [Delta].
  Delta get contents =>
      _callbacks?.getContents.call() ?? (Delta()..insert('\n'));

  /// Sets the editor content from a [Delta].
  set contents(Delta delta) => _callbacks?.setContents(delta);

  /// Scrolls the editor to the end of its content and places the cursor
  /// at the very end. Useful after setting initial content.
  void scrollToEnd() => _callbacks?.scrollToEnd.call();

  /// Ensures the current selection/caret is visible in the editor viewport.
  ///
  /// Unlike [scrollToEnd], this preserves the current cursor/selection.
  void ensureSelectionVisible() => _callbacks?.ensureSelectionVisible.call();

  /// Clears all editor content and resets to an empty document.
  /// Equivalent to [QuillController.clear].
  void clear() => _callbacks?.clear.call();

  /// Sets the cursor/selection to the given range.
  /// [index] is the start offset, [length] is the selection length.
  /// Use [length] of 0 for a collapsed cursor.
  void setSelection(int index, int length) =>
      _callbacks?.setSelection(index, length);

  /// Moves the cursor to the given offset (collapsed selection).
  void moveCursorToPosition(int offset) => setSelection(offset, 0);

  /// Inserts [text] at [index], optionally with [attributes] (e.g. `{'link': url}`).
  void insertText(int index, String text, [Map<String, dynamic>? attributes]) =>
      _callbacks?.insertText(index, text, attributes);

  /// Replaces [length] characters at [index] with [replacement].
  void replaceText(int index, int length, String replacement) =>
      _callbacks?.replaceText(index, length, replacement);

  /// Inserts [text] at the current cursor/selection.
  /// If text is selected, replaces the selection; otherwise inserts at cursor.
  void insertTextAtCursor(String text) => _callbacks?.insertTextAtCursor(text);

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
    required AsyncCallback requestLink,
    required Delta Function() getContents,
    required void Function(Delta) setContents,
    required VoidCallback scrollToEnd,
    required VoidCallback ensureSelectionVisible,
    required VoidCallback clear,
    required void Function(int index, int length) setSelection,
    required void Function(int index, String text, Map<String, dynamic>?)
    insertText,
    required void Function(int index, int length, String replacement)
    replaceText,
    required void Function(String text) insertTextAtCursor,
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
      scrollToEnd: scrollToEnd,
      ensureSelectionVisible: ensureSelectionVisible,
      clear: clear,
      setSelection: setSelection,
      insertText: insertText,
      replaceText: replaceText,
      insertTextAtCursor: insertTextAtCursor,
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
    keyboardHeight.dispose();
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
  final AsyncCallback requestLink;
  final Delta Function() getContents;
  final void Function(Delta) setContents;
  final VoidCallback scrollToEnd;
  final VoidCallback ensureSelectionVisible;
  final VoidCallback clear;
  final void Function(int index, int length) setSelection;
  final void Function(int index, String text, Map<String, dynamic>?) insertText;
  final void Function(int index, int length, String replacement) replaceText;
  final void Function(String text) insertTextAtCursor;
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
    required this.scrollToEnd,
    required this.ensureSelectionVisible,
    required this.clear,
    required this.setSelection,
    required this.insertText,
    required this.replaceText,
    required this.insertTextAtCursor,
    required this.focus,
    required this.blur,
  });
}
