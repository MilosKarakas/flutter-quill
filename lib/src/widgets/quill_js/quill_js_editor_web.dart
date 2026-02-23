// Web implementation of QuillJsEditorView using an iframe-based HtmlElementView
// + Quill.js. The iframe provides natural scroll/keyboard/focus isolation,
// preventing the browser from scrolling the parent Flutter page when the
// keyboard opens or when the user drags inside the editor.
//
// This file is only loaded on web via conditional export.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:ui' show Color;
import 'dart:ui_web' as ui_web;

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import '../default_styles.dart';
import 'inline_mark_css.dart';
import 'link_range_resolution.dart';
import 'quill_js_configurations.dart';

// ---------------------------------------------------------------------------
// JS interop helpers (work on any window context)
// ---------------------------------------------------------------------------

/// Represents a Quill.js selection range `{index, length}`.
extension type _JsRange._(JSObject _) implements JSObject {
  external int get index;
  external int get length;
}

/// Wrapper around a Quill.js 2.0 editor instance obtained from an iframe's
/// `contentWindow`. Methods map directly to Quill.js API calls.
///
/// Unlike the previous `@JS('Quill')` extension type, this one does NOT bind
/// to the main window's `Quill` global. Instead, we obtain the Quill
/// constructor from `iframe.contentWindow['Quill']` and call
/// `callAsConstructor` to create an instance. The returned [JSObject] is then
/// used with this extension type for strongly-typed access to Quill methods.
extension type _QuillJsInstance._(JSObject _) implements JSObject {
  external void format(String name, JSAny? value);
  external void formatText(int index, int length, String name, JSAny? value);
  external JSObject? getFormat();

  /// Overload of `getFormat` that accepts an index and length, returning the
  /// common format across the given range.
  @JS('getFormat')
  external JSObject? getFormatAt(int index, int length);

  external JSObject getContents();
  @JS('getContents')
  external JSObject getContentsRange(int index, int length);
  external void setContents(JSObject delta);
  external JSObject updateContents(JSObject delta, [JSString? source]);
  external _JsRange? getSelection([bool focus]);
  external void on(String event, JSFunction handler);
  external void enable(bool enabled);
  external String getText(int index, int length);
  external int getLength();
  external int getIndex(JSObject blot);
  external void focus();
  external void blur();
  external void deleteText(int index, int length);
  external void insertText(
    int index,
    String text, [
    JSAny? formatName,
    JSAny? formatValue,
  ]);
  external void setSelection(int index, int length);
  external void scrollSelectionIntoView();

  /// Like [setSelection] but with an explicit Quill source string.
  ///
  /// Pass `'silent'.toJS` to avoid firing the `selection-change` event,
  /// or `'api'.toJS` to fire it with a non-user source.
  @JS('setSelection')
  external void setSelectionWithSource(int index, int length, JSString source);
}

/// Wrapper around the Quill constructor function object.
///
/// Quill exposes a static `find(domNode, bubble)` helper on this object.
extension type _QuillJsConstructor._(JSObject _) implements JSObject {
  external JSObject? find(JSObject node, [bool bubble]);
}

/// Minimal wrappers for browser caret APIs used to map a tap point to a
/// text/caret offset before we trigger programmatic focus.
extension type _JsDomRange._(JSObject _) implements JSObject {
  external JSObject? get startContainer;
  external int get startOffset;
}

extension type _JsCaretPosition._(JSObject _) implements JSObject {
  external JSObject? get offsetNode;
  external int get offset;
}

extension type _DocumentCaretInterop._(JSObject _) implements JSObject {
  @JS('caretRangeFromPoint')
  external JSObject? caretRangeFromPoint(num x, num y);

  @JS('caretPositionFromPoint')
  external JSObject? caretPositionFromPoint(num x, num y);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

typedef _QuillSelection = ({int index, int length});
typedef _LinkRange = ({int index, int length});
typedef _LinkEditContext = ({_LinkRange range, String url});
typedef _TappedAnchor = ({web.HTMLAnchorElement anchor, String href});

/// Converts a Flutter [Color] to a CSS `rgba(...)` string.
String _colorToCss(Color c) {
  final a = (c.alpha / 255).toStringAsFixed(3);
  return 'rgba(${c.red}, ${c.green}, ${c.blue}, $a)';
}

const _genericFontFamilies = <String>{
  'serif',
  'sans-serif',
  'monospace',
  'cursive',
  'fantasy',
  'system-ui',
  'ui-serif',
  'ui-sans-serif',
  'ui-monospace',
  'ui-rounded',
  'emoji',
  'math',
  'fangsong',
};

String _cssSingleQuoted(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll('\'', r"\'");
  return '\'${escaped.trim()}\'';
}

String _cssDoubleQuoted(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

String _fontFamilyTokenToCss(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return '';
  }
  if (_genericFontFamilies.contains(trimmed.toLowerCase())) {
    return trimmed.toLowerCase();
  }
  return _cssSingleQuoted(trimmed);
}

String? _fontFamilyToCss(TextStyle style) {
  final families = <String>[];
  final family = style.fontFamily;
  if (family != null && family.trim().isNotEmpty) {
    families.add(_fontFamilyTokenToCss(family));
  }
  final fallbacks = style.fontFamilyFallback;
  if (fallbacks != null) {
    for (final fallback in fallbacks) {
      final familyToken = _fontFamilyTokenToCss(fallback);
      if (familyToken.isNotEmpty) {
        families.add(familyToken);
      }
    }
  }
  if (families.isEmpty) {
    return null;
  }
  return families.join(', ');
}

String? _fontVariationSettingsToCss(TextStyle style) {
  final fontVariations = style.fontVariations;
  if (fontVariations == null || fontVariations.isEmpty) {
    return null;
  }
  return fontVariations
      .map(
        (variation) => '${_cssDoubleQuoted(variation.axis)} ${variation.value}',
      )
      .join(', ');
}

String _sanitizeInlineCss(String css) {
  return css.replaceAll(RegExp(r'</style', caseSensitive: false), '<\\/style');
}

/// Appends CSS for [DefaultStyles] to [sb].
void _appendDefaultStylesCss(StringBuffer sb, DefaultStyles styles) {
  // Base editor styles from paragraph
  if (styles.paragraph != null) {
    sb.writeln('.ql-editor { ${_textStyleToCss(styles.paragraph!.style)} }');
  }
  // Placeholder (empty editor)
  if (styles.placeHolder != null) {
    final css = _textStyleToCss(styles.placeHolder!.style);
    sb.writeln('.ql-editor.ql-blank::before { $css }');
  }
  sb.write(buildQuillJsInlineMarkCss(styles));
  // Link
  if (styles.link != null) {
    sb.writeln('.ql-editor a { ${_textStyleToCss(styles.link!)} }');
  }
}

/// Converts [TextStyle] to CSS property string.
String _textStyleToCss(TextStyle style) {
  final css = StringBuffer();
  final fontFamily = _fontFamilyToCss(style);
  if (fontFamily != null) {
    css.write('font-family: $fontFamily;');
  }
  final variationSettings = _fontVariationSettingsToCss(style);
  if (variationSettings != null) {
    css.write('font-variation-settings: $variationSettings;');
  }
  if (style.fontSize != null) {
    css.write('font-size: ${style.fontSize}px;');
  }
  if (style.fontWeight != null) {
    final w = style.fontWeight!;
    css.write('font-weight: ${(w.index + 1) * 100};');
  }
  if (style.fontStyle != null) {
    css.write(
      'font-style: ${style.fontStyle == FontStyle.italic ? 'italic' : 'normal'};',
    );
  }
  if (style.height != null) {
    css.write('line-height: ${style.height};');
  }
  if (style.letterSpacing != null) {
    css.write('letter-spacing: ${style.letterSpacing}px;');
  }
  if (style.color != null) {
    css.write('color: ${_colorToCss(style.color!)};');
  }
  if (style.decoration != null && style.decoration != TextDecoration.none) {
    if (style.decoration!.contains(TextDecoration.underline)) {
      css.write('text-decoration: underline;');
    } else if (style.decoration!.contains(TextDecoration.lineThrough)) {
      css.write('text-decoration: line-through;');
    }
  }
  return css.toString();
}

/// Appends CSS for [QuillJsEditorStyle] to [sb].
void _appendQuillJsEditorStyleCss(StringBuffer sb, QuillJsEditorStyle style) {
  final editorCss = StringBuffer();
  if (style.fontFamily != null) {
    editorCss.write('font-family: ${style.fontFamily};');
  }
  if (style.fontVariationSettings != null &&
      style.fontVariationSettings!.trim().isNotEmpty) {
    editorCss.write('font-variation-settings: ${style.fontVariationSettings};');
  }
  if (style.fontSize != null) {
    editorCss.write('font-size: ${style.fontSize}px;');
  }
  if (style.lineHeight != null) {
    editorCss.write('line-height: ${style.lineHeight};');
  }
  if (style.letterSpacing != null) {
    editorCss.write('letter-spacing: ${style.letterSpacing}px;');
  }
  if (style.color != null) {
    editorCss.write('color: ${_colorToCss(style.color!)};');
  }
  if (style.caretColor != null) {
    editorCss.write('caret-color: ${_colorToCss(style.caretColor!)};');
  }
  if (style.selectionHandleColor != null) {
    editorCss.write(
      'accent-color: ${_colorToCss(style.selectionHandleColor!)};',
    );
  }
  if (editorCss.isNotEmpty) {
    sb.writeln('.ql-editor { $editorCss }');
  }
  if (style.selectionColor != null) {
    final c = _colorToCss(style.selectionColor!);
    sb.writeln('.ql-editor::selection { background-color: $c; }');
    sb.writeln('.ql-editor *::selection { background-color: $c; }');
  }
  if (style.placeholderColor != null) {
    final c = _colorToCss(style.placeholderColor!);
    sb.writeln('.ql-editor.ql-blank::before { color: $c !important; }');
  }
  if (style.linkColor != null) {
    final c = _colorToCss(style.linkColor!);
    sb.writeln('.ql-editor a { color: $c !important; }');
  }
  if (style.boldFontWeight != null) {
    final w = style.boldFontWeight is num
        ? (style.boldFontWeight as num).toString()
        : style.boldFontWeight.toString();
    sb.writeln('.ql-editor strong { font-weight: $w !important; }');
  }
  if (style.italicFontStyle != null) {
    sb.writeln(
      '.ql-editor em { font-style: ${style.italicFontStyle!} !important; }',
    );
  }
}

/// JSON.stringify — works on any JSObject regardless of origin window,
/// because JSObject identity is shared across same-origin frames.
@JS('JSON.stringify')
external JSString _mainJsonStringify(JSAny? obj);

@JS('JSON.parse')
external JSAny _mainJsonParse(JSString json);

// ---------------------------------------------------------------------------
// QuillJsEditorView — the web widget (iframe-based)
// ---------------------------------------------------------------------------

/// Embeds a Quill.js 2.0 rich-text editor inside an [HtmlElementView] backed
/// by an `<iframe>`.
///
/// The iframe provides:
/// - **Scroll isolation** — scroll events stay inside the iframe.
/// - **Focus isolation** — keyboard open/close does not scroll the parent page.
/// - **Touch isolation** — touch-drag does not move the Flutter layout.
///
/// This widget is only available on Flutter web. On other platforms the
/// conditional export provides a stub that shows a placeholder message.
class QuillJsEditorView extends StatefulWidget {
  final QuillJsEditorConfiguration configuration;
  final QuillJsEditorController controller;

  /// Optional [FocusNode] for two-way focus bridging between Flutter and the
  /// HTML editor. When provided:
  /// - Gaining focus on the [focusNode] will focus the JS editor.
  /// - Clicking into the JS editor will request focus on the [focusNode].
  final FocusNode? focusNode;

  /// Whether to automatically focus the editor once Quill.js is loaded and
  /// ready. Defaults to `false`.
  final bool autoFocus;

  /// Optional widget to display while Quill.js is loading. When null, the
  /// area is left empty (transparent) during loading.
  final Widget? loadingBuilder;

  /// An optional group identifier for the [TapRegion] used to implement
  /// [QuillJsEditorConfiguration.unfocusOnTapOutside].
  ///
  /// When set, the editor registers in this tap-region group. Wrap companion
  /// widgets (e.g. your formatting toolbar) in a [TapRegion] with the same
  /// [tapRegionGroupId] so that taps on the toolbar are considered "inside"
  /// and do not blur the editor.
  final Object? tapRegionGroupId;

  const QuillJsEditorView({
    super.key,
    required this.configuration,
    required this.controller,
    this.focusNode,
    this.autoFocus = false,
    this.loadingBuilder,
    this.tapRegionGroupId,
  });

  @override
  State<QuillJsEditorView> createState() => _QuillJsEditorViewState();
}

class _QuillJsEditorViewState extends State<QuillJsEditorView> {
  static int _nextId = 0;

  late final String _viewType;
  late final web.HTMLIFrameElement _iframe;

  /// Reference to the Quill.js editor div inside the iframe (`#editor`).
  /// Set after the iframe loads and Quill is initialised.
  web.HTMLElement? _editorDiv;

  _QuillJsInstance? _quill;
  _QuillJsConstructor? _quillConstructor;

  _LoadState _loadState = _LoadState.loading;
  String? _errorMessage;

  // Event listener references for cleanup
  JSFunction? _tabKeyHandlerJs;
  JSFunction? _enterKeyHandlerJs;
  JSFunction? _escapeKeyHandlerJs;
  JSFunction? _linkClickHandlerJs;
  JSFunction? _linkTouchStartHandlerJs;
  JSFunction? _linkPointerDownHandlerJs;
  JSFunction? _tapFocusTouchStartHandlerJs;
  JSFunction? _tapFocusPointerDownHandlerJs;
  JSFunction? _iframeLoadHandlerJs;
  JSFunction? _pasteHandlerJs;
  JSFunction? _copyHandlerJs;
  JSFunction? _cutHandlerJs;

  // Parent-window viewport fix listeners
  JSFunction? _viewportResizeHandlerJs;
  JSFunction? _parentScrollResetJs;
  String? _savedHtmlOverflow;
  String? _savedBodyOverflow;
  int _lowKeyboardFramesWhileFocused = 0;

  static const double _keyboardOpenThresholdPx = 50.0;
  static const int _keyboardCloseConfirmFrames = 3;

  void _scheduleKeyboardRefreshRetries([int retries = 2]) {
    for (var i = 1; i <= retries; i++) {
      Future<void>.delayed(
        Duration(milliseconds: 16 * i),
        () {
          if (!mounted) return;
          _refreshKeyboardHeightFromViewport();
        },
      );
    }
  }

  void _refreshKeyboardHeightFromViewport() {
    final vv = web.window.visualViewport;
    if (vv == null) return;

    final layoutHeight = web.window.innerHeight.toDouble();
    final currentVisibleBottom = vv.height + vv.offsetTop;
    final kbByHeight = math.max(0.0, layoutHeight - vv.height);
    final kbByVisibleBottom = math.max(0.0, layoutHeight - currentVisibleBottom);
    final kb = math.max(kbByHeight, kbByVisibleBottom);
    final hasFocusIntent = _editorHasFocus || (widget.focusNode?.hasFocus ?? false);

    // When editor is not focused, always treat keyboard as closed.
    if (!hasFocusIntent) {
      _lowKeyboardFramesWhileFocused = 0;
      widget.controller.keyboardHeight.value = 0.0;
      return;
    }

    // Fail-safe: while focused, require multiple consecutive low readings
    // before closing, so one bad frame cannot drop the inset to zero.
    if (kb > _keyboardOpenThresholdPx) {
      _lowKeyboardFramesWhileFocused = 0;
      widget.controller.keyboardHeight.value = kb;
      _scheduleEnsureSelectionVisible(const Duration(milliseconds: 24));
    } else {
      _lowKeyboardFramesWhileFocused++;
      if (_lowKeyboardFramesWhileFocused >= _keyboardCloseConfirmFrames) {
        widget.controller.keyboardHeight.value = 0.0;
      }
    }
  }

  // Focus bridging state
  bool _isSyncingFocus = false;
  bool _editorHasFocus = false;
  bool _pendingDomFocusSync = false;
  int _focusSyncEpoch = 0;

  static const Duration _domFocusRetryDelay = Duration(milliseconds: 40);
  static const int _domFocusRetryCount = 3;

  // When true, the text-change handler skips firing onContentChanged.
  // Used to suppress notifications during programmatic setContents calls.
  bool _suppressContentChanged = false;

  // When true, we are reverting a change via onBeforeTextChange; skip the
  // callback to avoid re-entry when our setContents fires text-change.
  bool _isReverting = false;

  // Ensures onEditorReady is fired only once per mounted editor instance.
  bool _didNotifyEditorReady = false;

  // --- First-focus cursor placement state (moveCursorToEndOnFirstFocus) ---
  // True after the one-shot cursor-to-end has been applied (or skipped).
  bool _didApplyInitialCursorPlacement = false;
  // True once the user has made any selection/caret change from a user source
  // (pointer-down, keyboard navigation, etc.) before the first-focus apply.
  bool _didUserInteractWithSelection = false;

  // Prevents duplicate link dialogs when toolbar is tapped repeatedly.
  bool _isHandlingLinkRequest = false;
  bool _isHandlingLinkTapAction = false;
  bool _skipNextLinkClick = false;
  Delta _contentForAutoResize = Delta()..insert('\n');

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _contentForAutoResize = widget.configuration.initialContent ?? (Delta()..insert('\n'));

    _viewType = 'quill-js-editor-${_nextId++}';

    // Build the iframe element with srcdoc containing the editor HTML.
    _iframe = web.document.createElement('iframe') as web.HTMLIFrameElement
      ..style.setProperty('width', '100%')
      ..style.setProperty('height', '100%')
      ..style.setProperty('border', 'none')
      ..setAttribute('srcdoc', _buildSrcdoc());

    // Register platform view factory
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId, {Object? params}) => _iframe,
    );

    // Listen for the iframe to finish loading (Quill.js will be ready).
    _iframeLoadHandlerJs = ((web.Event _) {
      _onIframeLoaded();
    }).toJS;
    _iframe.addEventListener('load', _iframeLoadHandlerJs);

    _setupFocusBridge();
  }

  @override
  void didUpdateWidget(QuillJsEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.configuration.readOnly != oldWidget.configuration.readOnly) {
      _quill?.enable(!widget.configuration.readOnly);
    }

    if (widget.focusNode != oldWidget.focusNode) {
      oldWidget.focusNode?.removeListener(_onFlutterFocusChanged);
      _focusSyncEpoch++;
      _pendingDomFocusSync = false;
      _setupFocusBridge();
    }

    if (widget.configuration.initialContent != oldWidget.configuration.initialContent) {
      _contentForAutoResize =
          widget.configuration.initialContent ?? (Delta()..insert('\n'));
    }
  }

  @override
  void dispose() {
    _teardownFocusBridge();
    _detachController();

    // Remove iframe load listener
    if (_iframeLoadHandlerJs != null) {
      _iframe.removeEventListener('load', _iframeLoadHandlerJs);
    }

    // Remove DOM event listeners inside the iframe
    if (_editorDiv != null) {
      if (_tabKeyHandlerJs != null) {
        _editorDiv!.removeEventListener('keydown', _tabKeyHandlerJs, true.toJS);
      }
      if (_enterKeyHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'keydown',
          _enterKeyHandlerJs,
          true.toJS,
        );
      }
      if (_escapeKeyHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'keydown',
          _escapeKeyHandlerJs,
          true.toJS,
        );
      }
      if (_linkClickHandlerJs != null) {
        _editorDiv!.removeEventListener('click', _linkClickHandlerJs);
      }
      if (_linkTouchStartHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'touchstart',
          _linkTouchStartHandlerJs,
          true.toJS,
        );
      }
      if (_linkPointerDownHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'pointerdown',
          _linkPointerDownHandlerJs,
          true.toJS,
        );
      }
      if (_tapFocusTouchStartHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'touchstart',
          _tapFocusTouchStartHandlerJs,
          true.toJS,
        );
      }
      if (_tapFocusPointerDownHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'pointerdown',
          _tapFocusPointerDownHandlerJs,
          true.toJS,
        );
      }
      if (_pasteHandlerJs != null) {
        _editorDiv!.removeEventListener('paste', _pasteHandlerJs, true.toJS);
      }
      if (_copyHandlerJs != null) {
        _editorDiv!.removeEventListener('copy', _copyHandlerJs, true.toJS);
      }
      if (_cutHandlerJs != null) {
        _editorDiv!.removeEventListener('cut', _cutHandlerJs, true.toJS);
      }
    }

    // Remove parent-window viewport / scroll-lock listeners
    if (_viewportResizeHandlerJs != null) {
      web.window.visualViewport?.removeEventListener(
        'resize',
        _viewportResizeHandlerJs,
      );
    }
    widget.controller.keyboardHeight.value = 0.0;

    if (_parentScrollResetJs != null) {
      web.window.removeEventListener('scroll', _parentScrollResetJs, true.toJS);
    }

    // Restore parent overflow now that the editor is gone
    _restoreParentOverflow();

    super.dispose();
  }

  // ------------------------------------------------------------------
  // Iframe srcdoc generation
  // ------------------------------------------------------------------

  /// Builds the full HTML document that will be loaded into the iframe via
  /// `srcdoc`. Quill.js and its CSS are loaded via `<script>` and `<link>`
  /// tags inside this document.
  String _buildSrcdoc() {
    final config = widget.configuration;
    final dynamicCss = StringBuffer();
    final customCss = config.customCss == null
        ? ''
        : _sanitizeInlineCss(config.customCss!);

    if (config.styles != null) {
      _appendDefaultStylesCss(dynamicCss, config.styles!);
    }
    if (config.style != null) {
      _appendQuillJsEditorStyleCss(dynamicCss, config.style!);
    }

    // --- Build the CSS link tag ---
    final cssLink = config.quillCssUrl != null
        ? '<link rel="stylesheet" href="${_escapeHtml(config.quillCssUrl!)}">'
        : '';

    return '''<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
$cssLink
<style>
html, body {
  margin: 0;
  padding: 0;
  height: 100%;
  overflow: hidden;
}
.ql-container.ql-snow { border: none !important; font-size: 16px; }
.ql-editor {
  padding: 12px 16px;
  min-height: 100%;
  height: 100%;
  box-sizing: border-box;
  overflow-y: auto;
  outline: none;
}
.ql-editor.ql-blank::before { font-style: normal; color: rgba(0,0,0,0.38); }
.ql-editor a { cursor: pointer; color: #1a73e8; text-decoration: underline; }
$dynamicCss
$customCss
</style>
</head>
<body>
<div id="editor"></div>
<script src="${_escapeHtml(config.quillJsUrl)}"></script>
</body>
</html>''';
  }

  /// Minimal HTML escaping for attribute values in srcdoc.
  static String _escapeHtml(String s) =>
      s.replaceAll('&', '&amp;').replaceAll('"', '&quot;');

  // ------------------------------------------------------------------
  // Initialisation (after iframe loads)
  // ------------------------------------------------------------------

  void _onIframeLoaded() {
    if (!mounted) return;

    try {
      final contentWindow = _iframe.contentWindow;
      final contentDoc = _iframe.contentDocument;
      if (contentWindow == null || contentDoc == null) {
        throw StateError('iframe contentWindow/contentDocument is null');
      }

      // Find the #editor div inside the iframe
      _editorDiv = contentDoc.querySelector('#editor') as web.HTMLElement?;
      if (_editorDiv == null) {
        throw StateError('Could not find #editor inside iframe');
      }

      // Check that Quill.js loaded successfully inside the iframe
      final quillGlobal = (contentWindow as JSObject)['Quill'];
      if (!quillGlobal.isDefinedAndNotNull) {
        throw StateError(
          'Quill.js did not load inside iframe. Check quillJsUrl.',
        );
      }

      _setupQuill(contentWindow as JSObject);

      setState(() => _loadState = _LoadState.ready);
      _scheduleOnEditorReadyCallback();
      _scheduleDeferredDomFocusSync();

      // Auto-focus after the build pass so the HtmlElementView is visible.
      if (widget.autoFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _quill == null) return;
          _quill!.focus();
          _editorHasFocus = true;
          _onJsFocusChanged(hasFocus: true);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadState = _LoadState.error;
        _errorMessage = e.toString();
      });
    }
  }

  void _scheduleOnEditorReadyCallback() {
    if (_didNotifyEditorReady) return;
    final onEditorReady = widget.configuration.onEditorReady;
    if (onEditorReady == null) return;

    _didNotifyEditorReady = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_loadState != _LoadState.ready) return;
      if (!widget.controller.isAttached) return;
      onEditorReady();
    });
  }

  void _setupQuill(JSObject iframeWindow) {
    final config = widget.configuration;

    final options =
        <String, dynamic>{
              'theme': 'snow',
              'modules': <String, dynamic>{
                'toolbar': false, // toolbar is handled by Flutter
              },
              'formats': <String>[
                'bold',
                'italic',
                'underline',
                'list',
                'link',
                'indent',
              ],
              if (config.placeholder != null) 'placeholder': config.placeholder,
              'readOnly': config.readOnly,
            }.jsify()
            as JSObject;

    // Obtain the Quill constructor from the iframe's window and create
    // the editor instance inside the iframe's document.
    final quillConstructor = iframeWindow['Quill'] as JSFunction;
    _quillConstructor = quillConstructor as _QuillJsConstructor;
    final jsQuill = quillConstructor.callAsConstructor<JSObject>(
      _editorDiv!,
      options,
    );
    _quill = jsQuill as _QuillJsInstance;

    // Set initial content
    if (config.initialContent != null) {
      _quill!.setContents(_deltaToJs(config.initialContent!));
    }

    _setupEventListeners();
    _setupTapFocusInterception();
    _setupLinkClickHandler();
    _setupEnterKeyHandler();
    _setupEscapeKeyHandler();
    _setupClipboardInterceptors();

    if (config.preventOrphanListNesting) {
      _setupTabKeyHandler();
    }

    _attachController();
    _setupParentViewportFixes();
  }

  // ------------------------------------------------------------------
  // Focus bridging (Flutter FocusNode <-> JS editor focus)
  // ------------------------------------------------------------------

  void _setupFocusBridge() {
    final node = widget.focusNode;
    node?.addListener(_onFlutterFocusChanged);

    // If Flutter focus was obtained before the web editor attached, replay
    // ownership sync once callbacks become available.
    if (node?.hasFocus ?? false) {
      _syncDomFocusOwnership(force: true);
    }
  }

  void _teardownFocusBridge() {
    widget.focusNode?.removeListener(_onFlutterFocusChanged);
  }

  /// Flutter FocusNode changed -> sync to JS editor.
  void _onFlutterFocusChanged() {
    final node = widget.focusNode;
    if (node == null) return;

    if (!node.hasFocus) {
      _pendingDomFocusSync = false;
      _focusSyncEpoch++;
      widget.controller.keyboardHeight.value = 0.0;
      if (!widget.controller.isAttached) return;
      _withFocusSyncGuard(widget.controller.blur);
      return;
    }

    _syncDomFocusOwnership(force: true);
  }

  void _syncDomFocusOwnership({bool force = false}) {
    if (!mounted) return;
    final node = widget.focusNode;
    if (node == null) return;

    if (!node.hasFocus) return;

    if (!widget.controller.isAttached) {
      if (force) _pendingDomFocusSync = true;
      return;
    }

    final epoch = ++_focusSyncEpoch;
    _pendingDomFocusSync = false;
    _withFocusSyncGuard(widget.controller.focus);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _runDeferredDomFocusAttempt(epoch);
    });

    for (var i = 1; i <= _domFocusRetryCount; i++) {
      Future<void>.delayed(
        Duration(microseconds: _domFocusRetryDelay.inMicroseconds * i),
        () => _runDeferredDomFocusAttempt(epoch),
      );
    }
  }

  void _runDeferredDomFocusAttempt(int epoch) {
    if (!mounted) return;
    if (epoch != _focusSyncEpoch) return;
    final node = widget.focusNode;
    if (node == null || !node.hasFocus) return;
    if (!widget.controller.isAttached) return;
    _withFocusSyncGuard(widget.controller.focus);
  }

  /// Blurs the JS editor and proactively mirrors blur to Flutter focus.
  ///
  /// In some iframe/browser paths Quill's `selection-change(null)` can be
  /// dropped, leaving Flutter focused while DOM focus is already gone. That
  /// stale state prevents a later `requestFocus()` from emitting a new focus
  /// change event. We sync Flutter focus eagerly to keep both sides aligned.
  void _blurEditorAndSyncFlutterFocus() {
    final quill = _quill;
    if (quill == null) return;
    quill.blur();
    _editorHasFocus = false;
    _onJsFocusChanged(hasFocus: false);
  }

  void _withFocusSyncGuard(VoidCallback action) {
    if (_isSyncingFocus) return;
    _isSyncingFocus = true;
    try {
      action();
    } finally {
      _isSyncingFocus = false;
    }
  }

  void _scheduleDeferredDomFocusSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_loadState != _LoadState.ready) return;
      final node = widget.focusNode;
      if (node == null) return;
      if (_pendingDomFocusSync || node.hasFocus) {
        _syncDomFocusOwnership(force: true);
      }
    });
  }

  /// JS editor focus changed -> sync to Flutter FocusNode.
  void _onJsFocusChanged({required bool hasFocus}) {
    final node = widget.focusNode;
    if (node == null || _isSyncingFocus) return;
    _isSyncingFocus = true;
    try {
      if (hasFocus && !node.hasFocus) {
        node.requestFocus();
      } else if (!hasFocus && node.hasFocus) {
        node.unfocus();
      }
    } finally {
      _isSyncingFocus = false;
    }
  }

  // ------------------------------------------------------------------
  // Parent-window viewport fixes
  // ------------------------------------------------------------------

  /// Sets up two complementary fixes that the iframe alone cannot solve:
  ///
  /// 1. **Visual Viewport keyboard detection** — The parent window's
  ///    `visualViewport` shrinks when the mobile keyboard opens. We listen
  ///    for `resize` events and write the keyboard height to
  ///    `widget.controller.keyboardHeight` so the host Flutter layout can
  ///    add bottom padding (since `MediaQuery.viewInsets.bottom` is always
  ///    0 on Flutter Web).
  ///
  /// 2. **Permanent parent-page scroll lock** — On iOS Safari, focusing an
  ///    element inside an iframe still triggers the browser's "scroll to
  ///    show focused element" behaviour on the *parent* page, which pushes
  ///    the app bar off-screen. We prevent this by:
  ///    - Setting `overflow: hidden` on `<html>` and `<body>` **once** when
  ///      the editor mounts (restored only in `dispose()`).
  ///    - Adding a `scroll` event listener on `window` that immediately
  ///      resets `scrollTop` to 0 whenever the browser tries to scroll.
  ///
  ///    This is safe because Flutter Web renders entirely in a canvas — it
  ///    does not use native html/body scrolling.
  void _setupParentViewportFixes() {
    // --- Visual Viewport keyboard height detection ---
    final vv = web.window.visualViewport;
    if (vv != null) {
      _viewportResizeHandlerJs = ((web.Event _) {
        _refreshKeyboardHeightFromViewport();
      }).toJS;
      vv.addEventListener('resize', _viewportResizeHandlerJs);
    }

    // --- Permanent parent-page scroll lock ---
    _lockParentScroll();

    // Belt-and-suspenders: if anything still triggers a parent-page scroll
    // (e.g. iOS keyboard animation), immediately snap back to 0.
    _parentScrollResetJs = ((web.Event _) {
      final html = web.document.documentElement as web.HTMLElement?;
      if ((html?.scrollTop ?? 0) != 0) html?.scrollTop = 0;
      if ((web.document.body?.scrollTop ?? 0) != 0) {
        web.document.body?.scrollTop = 0;
      }
    }).toJS;
    web.window.addEventListener('scroll', _parentScrollResetJs, true.toJS);
  }

  /// Locks the parent page scroll by setting `overflow: hidden` on `<html>`
  /// and `<body>`. Called once at setup; restored only in `dispose()`.
  void _lockParentScroll() {
    final html = web.document.documentElement as web.HTMLElement?;
    final body = web.document.body;

    // Save current overflow so we can restore in dispose.
    _savedHtmlOverflow = html?.style.getPropertyValue('overflow') ?? '';
    _savedBodyOverflow = body?.style.getPropertyValue('overflow') ?? '';

    html?.style.setProperty('overflow', 'hidden');
    body?.style.setProperty('overflow', 'hidden');

    // Reset any existing scroll offset.
    html?.scrollTop = 0;
    body?.scrollTop = 0;
  }

  /// Restores the parent page overflow to whatever it was before we locked it.
  void _restoreParentOverflow() {
    final html = web.document.documentElement as web.HTMLElement?;
    html?.style.setProperty('overflow', _savedHtmlOverflow ?? '');
    web.document.body?.style.setProperty('overflow', _savedBodyOverflow ?? '');
  }

  // ------------------------------------------------------------------
  // Quill.js event listeners
  // ------------------------------------------------------------------

  /// Returns the total character length of insert operations in [delta].
  static int _deltaLength(Delta delta) {
    int len = 0;
    for (final op in delta.toList()) {
      if (op.isInsert) {
        len += op.length ?? 0;
      }
    }
    return len;
  }

  /// Computes the cursor position to restore after reverting a change.
  /// For inserts: cursor was at the insert index. For deletes: cursor was after
  /// the deleted text (e.g. backspace). Returns 0 if no content-changing op.
  static int _cursorPositionToRestoreAfterRevert(Delta changeDelta) {
    int offset = 0;
    for (final op in changeDelta.toList()) {
      if (op.isRetain) {
        offset += op.length ?? 0;
      } else if (op.isInsert) {
        return offset; // Cursor was at offset before the insert.
      } else if (op.isDelete) {
        return offset + (op.length ?? 0); // Cursor was after deleted text.
      }
    }
    return offset;
  }

  void _setupEventListeners() {
    // text-change: (delta, oldContents, source) => void
    // Fires when document content changes (typing, deletions, insertions).
    // Note: Format-only changes (like Cmd+B on selected text) do NOT fire this.
    _quill!.on(
      'text-change',
      ((JSAny? changeDeltaJs, JSAny? oldContentsJs, JSAny? source) {
        final src = (source as JSString?)?.toDart;
        if (src == 'user' || src == 'api') {
          if (_isReverting) {
            _isReverting = false;
            _onTextChanged();
          } else {
            final callback = widget.configuration.onBeforeTextChange;
            if (callback != null &&
                changeDeltaJs != null &&
                oldContentsJs != null) {
              final changeDeltaObj = changeDeltaJs;
              final oldContentsObj = oldContentsJs;
              if (changeDeltaObj is! JSObject || oldContentsObj is! JSObject) {
                _onTextChanged();
              } else {
                final changeDelta = _jsToDelta(changeDeltaObj);
                final oldDelta = _jsToDelta(oldContentsObj);
                if (!callback(changeDelta, oldDelta)) {
                  _isReverting = true;
                  _suppressContentChanged = true;
                  final cursorPos = _cursorPositionToRestoreAfterRevert(
                    changeDelta,
                  );
                  _quill!.setContents(oldContentsObj);
                  final len = _quill!.getLength();
                  final clamped = cursorPos.clamp(0, len > 0 ? len - 1 : 0);
                  _quill!.setSelection(clamped, 0);
                  _suppressContentChanged = false;
                  return;
                }
                _onTextChanged();
              }
            } else {
              _onTextChanged();
            }
          }
          // Sync format state after a short delay to ensure format is applied
          Future.delayed(const Duration(milliseconds: 10), () {
            if (mounted) _syncFormatState();
          });
        }
      }).toJS,
    );

    // selection-change: (range, oldRange, source) => void
    // Fires when selection changes OR when formats are applied to selected text.
    // We forward the source so we can distinguish user vs api/silent changes.
    _quill!.on(
      'selection-change',
      ((JSAny? range, JSAny? oldRange, JSAny? source) {
        _onSelectionChanged(range as JSObject?, (source as JSString?)?.toDart);
      }).toJS,
    );
  }

  void _onTextChanged() {
    if (_suppressContentChanged) return;
    final delta = _getContentsDelta();
    _contentForAutoResize = delta;
    if (widget.configuration.autoResizeToContent && mounted) {
      setState(() {});
    }
    widget.configuration.onContentChanged?.call(delta);
    _scheduleEnsureSelectionVisible();
  }

  void _onSelectionChanged(JSObject? range, String? source) {
    // range == null means the editor lost focus
    if (range == null) {
      widget.controller.keyboardHeight.value = 0.0;
      _editorHasFocus = false;
      _onJsFocusChanged(hasFocus: false);
      return;
    }

    // While a link action sheet/dialog is active, Quill can emit non-user
    // selection updates that would incorrectly re-focus the editor on mobile.
    if (_isHandlingLinkTapAction && source != 'user') {
      _editorHasFocus = false;
      _refreshKeyboardHeightFromViewport();
      _scheduleKeyboardRefreshRetries();
      return;
    }

    final wasFocused = _editorHasFocus;
    _editorHasFocus = true;
    _onJsFocusChanged(hasFocus: true);
    _refreshKeyboardHeightFromViewport();

    // Track user-originated selection/caret changes (pointer-down, keyboard
    // navigation, explicit range selections). Programmatic changes tagged as
    // 'api' or 'silent' are ignored so they don't poison the guard.
    if (source == 'user') {
      _didUserInteractWithSelection = true;
    }

    // On focus transition (was blurred, now focused), attempt first-focus
    // cursor placement if the feature is enabled.
    if (!wasFocused) {
      _maybeMoveCursorToEndOnFirstFocus();
    }

    // Sync format state whenever selection changes (cursor moves, text selected, etc.)
    _syncFormatState();
    if (source == 'user') {
      _scheduleEnsureSelectionVisible();
    }
  }

  /// One-shot: moves the cursor to the end of the document on first focus gain,
  /// provided the user has not already positioned the caret themselves.
  void _maybeMoveCursorToEndOnFirstFocus() {
    if (_didApplyInitialCursorPlacement) return;
    if (!widget.configuration.moveCursorToEndOnFirstFocus) return;
    if (_didUserInteractWithSelection) return;
    if (_loadState != _LoadState.ready || _quill == null) return;

    final length = _quill!.getLength();
    if (length > 0) {
      // Use 'silent' source so this programmatic move does not fire another
      // selection-change event and does not feed back into
      // _didUserInteractWithSelection.
      _quill!.setSelectionWithSource(length - 1, 0, 'silent'.toJS);
    }

    // Scroll the Quill editor container inside the iframe to the bottom.
    final qlContainer = _iframe.contentDocument?.querySelector('.ql-container');
    if (qlContainer != null) {
      (qlContainer as web.HTMLElement).scrollTop = qlContainer.scrollHeight;
    }

    _didApplyInitialCursorPlacement = true;
  }

  // ------------------------------------------------------------------
  // Tap-focus interception (iOS Safari tap-pan workaround)
  // ------------------------------------------------------------------

  void _setupTapFocusInterception() {
    final editorDiv = _editorDiv!;

    _tapFocusTouchStartHandlerJs = ((web.Event event) {
      _interceptTapFocus(event);
    }).toJS;

    _tapFocusPointerDownHandlerJs = ((web.Event event) {
      final pointerEvent = event as web.PointerEvent;
      // Touch/pen paths can trigger iOS focus-scroll assist. Mouse focus is
      // typically stable and should keep native behaviour.
      if (pointerEvent.pointerType.toLowerCase() == 'mouse') {
        return;
      }
      _interceptTapFocus(event);
    }).toJS;

    editorDiv.addEventListener(
      'touchstart',
      _tapFocusTouchStartHandlerJs!,
      true.toJS,
    );
    editorDiv.addEventListener(
      'pointerdown',
      _tapFocusPointerDownHandlerJs!,
      true.toJS,
    );
  }

  void _interceptTapFocus(web.Event event) {
    final quill = _quill;
    final editorDiv = _editorDiv;
    if (quill == null || editorDiv == null) return;
    if (_editorHasFocus) return;

    // Keep existing link-tap behaviour (dialog callback path) untouched.
    if (_findTappedAnchorFromEvent(event, editorDiv) != null) {
      return;
    }

    final clientPoint = _extractClientPoint(event);
    if (clientPoint == null) return;

    event.preventDefault();
    event.stopPropagation();

    final tapIndex = _resolveTapIndex(clientPoint.$1, clientPoint.$2);
    _focusEditorFromInterceptedTap(tapIndex);
  }

  (double, double)? _extractClientPoint(web.Event event) {
    if (event is web.PointerEvent) {
      return (event.clientX.toDouble(), event.clientY.toDouble());
    }
    if (event is web.TouchEvent) {
      final touches = event.changedTouches;
      if (touches.length <= 0) return null;
      final touch = touches.item(0);
      if (touch == null) return null;
      return (touch.clientX.toDouble(), touch.clientY.toDouble());
    }
    return null;
  }

  int? _resolveTapIndex(double clientX, double clientY) {
    final doc = _iframe.contentDocument;
    final quill = _quill;
    final quillConstructor = _quillConstructor;
    if (doc == null || quill == null || quillConstructor == null) return null;
    final docJs = doc as JSObject;
    final docInterop = _DocumentCaretInterop._(docJs);

    web.Node? node;
    int offset = 0;

    if (docJs['caretRangeFromPoint'].isDefinedAndNotNull) {
      try {
        final rangeObj = docInterop.caretRangeFromPoint(clientX, clientY);
        if (rangeObj != null) {
          final range = _JsDomRange._(rangeObj);
          final startNode = range.startContainer;
          if (startNode != null) {
            node = startNode as web.Node;
            offset = range.startOffset;
          }
        }
      } catch (_) {
        // Ignore and try the alternate caret API below.
      }
    }

    if (node == null && docJs['caretPositionFromPoint'].isDefinedAndNotNull) {
      try {
        final caretObj = docInterop.caretPositionFromPoint(clientX, clientY);
        if (caretObj != null) {
          final caret = _JsCaretPosition._(caretObj);
          final offsetNode = caret.offsetNode;
          if (offsetNode != null) {
            node = offsetNode as web.Node;
            offset = caret.offset;
          }
        }
      } catch (_) {
        // No usable caret API in this browser/iframe path.
      }
    }

    if (node == null) return null;
    final blot = quillConstructor.find(node as JSObject, true);
    if (blot == null) return null;

    final baseIndex = quill.getIndex(blot);
    if (baseIndex < 0) return null;

    if (node is web.Text) {
      final localOffset = offset.clamp(0, node.data.length);
      return baseIndex + localOffset;
    }
    return baseIndex;
  }

  void _focusEditorFromInterceptedTap(int? tapIndex) {
    final quill = _quill;
    if (quill == null) return;

    // Mark this as user-driven so first-focus move-to-end does not override
    // the tapped caret placement.
    _didUserInteractWithSelection = true;

    quill.focus();
    _editorHasFocus = true;
    _onJsFocusChanged(hasFocus: true);
    _refreshKeyboardHeightFromViewport();

    if (tapIndex == null) return;

    void applySelection() {
      if (!mounted || _quill == null) return;
      final length = _quill!.getLength();
      final maxIndex = length > 0 ? length - 1 : 0;
      final clamped = tapIndex.clamp(0, maxIndex).toInt();
      _quill!.setSelection(clamped, 0);
    }

    // Apply now and retry briefly so selection wins over async focus settling.
    applySelection();
    for (var i = 1; i <= 2; i++) {
      Future<void>.delayed(
        Duration(milliseconds: 16 * i),
        () {
          applySelection();
          _refreshKeyboardHeightFromViewport();
        },
      );
    }
  }

  // ------------------------------------------------------------------
  // Link click interception
  // ------------------------------------------------------------------

  void _setupLinkClickHandler() {
    final editorDiv = _editorDiv!;

    void handleAnchorTap(web.Event event, {bool skipNextClick = false}) {
      final tapped = _findTappedAnchorFromEvent(event, editorDiv);
      if (tapped == null) return;

      event.preventDefault();
      event.stopPropagation();

      if (skipNextClick) {
        _skipNextLinkClick = true;
      }

      final text = tapped.anchor.textContent ?? '';
      _handleLinkTapped(tapped.href, text, tappedAnchor: tapped.anchor);
    }

    _linkTouchStartHandlerJs = ((web.Event event) {
      handleAnchorTap(event, skipNextClick: true);
    }).toJS;

    _linkPointerDownHandlerJs = ((web.Event event) {
      final pointerEvent = event as web.PointerEvent;
      if (pointerEvent.pointerType.toLowerCase() != 'touch') {
        return;
      }
      handleAnchorTap(event, skipNextClick: true);
    }).toJS;

    _linkClickHandlerJs = ((web.Event event) {
      if (_skipNextLinkClick) {
        _skipNextLinkClick = false;
        return;
      }
      handleAnchorTap(event);
    }).toJS;

    editorDiv.addEventListener(
      'touchstart',
      _linkTouchStartHandlerJs!,
      true.toJS,
    );
    editorDiv.addEventListener(
      'pointerdown',
      _linkPointerDownHandlerJs!,
      true.toJS,
    );
    editorDiv.addEventListener('click', _linkClickHandlerJs);
  }

  _TappedAnchor? _findTappedAnchorFromEvent(
    web.Event event,
    web.HTMLElement editorDiv,
  ) {
    final target = event.target;
    if (target is! web.Node) {
      return null;
    }

    web.Node? node = target;
    while (node != null && node != editorDiv) {
      if (node is web.HTMLAnchorElement) {
        final href = _rawHrefFromAnchor(node);
        if (href != null) {
          return (anchor: node, href: href);
        }
      }
      node = node.parentNode;
    }
    return null;
  }

  String? _rawHrefFromAnchor(web.HTMLAnchorElement anchor) {
    // Use getAttribute to get the raw href as stored by Quill.js, not
    // anchor.href which resolves relative to the page origin.
    try {
      final attrHref = anchor.getAttribute('href');
      if (attrHref != null && attrHref.isNotEmpty) {
        return attrHref;
      }
    } catch (_) {
      // Some browser/interop paths can expose null-typed href attributes.
    }

    try {
      final resolvedHref = anchor.href;
      if (resolvedHref.isNotEmpty) {
        return resolvedHref;
      }
    } catch (_) {
      // Fall through: treat anchor as non-link and do not intercept tap.
    }
    return null;
  }

  // ------------------------------------------------------------------
  // Clipboard paste/copy interceptors
  // ------------------------------------------------------------------

  void _setupClipboardInterceptors() {
    final pasteInterceptor = widget.configuration.onPasteInterceptor;
    final copyInterceptor = widget.configuration.onCopyInterceptor;
    if (pasteInterceptor == null && copyInterceptor == null) return;

    final editorDiv = _editorDiv!;

    if (pasteInterceptor != null) {
      _pasteHandlerJs = ((web.Event event) {
        final clipEvent = event as web.ClipboardEvent;
        final data = clipEvent.clipboardData;
        if (data == null) return;

        final plainText = data.getData('text/plain');
        final html = data.getData('text/html');
        final plain = plainText.isNotEmpty ? plainText : null;
        final htmlContent = html.isNotEmpty ? html : null;

        final pasteDelta = pasteInterceptor(plain, htmlContent);
        if (pasteDelta == null || pasteDelta.isEmpty) return;

        event.preventDefault();
        event.stopPropagation();

        final sel = _getQuillSelection(focus: true);
        final index = sel?.index ?? 0;

        final pasteOps = pasteDelta.toJson() as List;
        final combinedOps = [
          {'retain': index},
          ...pasteOps,
        ];
        final combined = Delta.fromJson(combinedOps);
        _suppressContentChanged = true;
        _quill!.updateContents(_deltaToJs(combined), 'api'.toJS);
        _suppressContentChanged = false;

        final pasteLength = _deltaLength(pasteDelta);
        _quill!.setSelection(index + pasteLength, 0);
      }).toJS;
      editorDiv.addEventListener('paste', _pasteHandlerJs!, true.toJS);
    }

    if (copyInterceptor != null) {
      _copyHandlerJs = ((web.Event event) {
        final sel = _getQuillSelection();
        if (sel == null || sel.length == 0) return;

        final plainText = _quill!.getText(sel.index, sel.length);
        final selDelta = _quill!.getContentsRange(sel.index, sel.length);
        final delta = _jsToDelta(selDelta);

        final result = copyInterceptor(plainText, delta);
        if (result == null) return;

        event.preventDefault();
        event.stopPropagation();

        final clipEvent = event as web.ClipboardEvent;
        final data = clipEvent.clipboardData;
        if (data != null) {
          data.setData('text/plain', result.plainText);
          if (result.html != null) {
            data.setData('text/html', result.html!);
          }
        }
      }).toJS;
      editorDiv.addEventListener('copy', _copyHandlerJs!, true.toJS);

      _cutHandlerJs = ((web.Event event) {
        final sel = _getQuillSelection();
        if (sel == null || sel.length == 0) return;

        final plainText = _quill!.getText(sel.index, sel.length);
        final selDelta = _quill!.getContentsRange(sel.index, sel.length);
        final delta = _jsToDelta(selDelta);

        final result = copyInterceptor(plainText, delta);
        if (result == null) return;

        event.preventDefault();
        event.stopPropagation();

        final clipEvent = event as web.ClipboardEvent;
        final data = clipEvent.clipboardData;
        if (data != null) {
          data.setData('text/plain', result.plainText);
          if (result.html != null) {
            data.setData('text/html', result.html!);
          }
        }
        _quill!.deleteText(sel.index, sel.length);
        _quill!.setSelection(sel.index, 0);
      }).toJS;
      editorDiv.addEventListener('cut', _cutHandlerJs!, true.toJS);
    }
  }

  Future<void> _handleLinkTapped(
    String href,
    String text, {
    web.HTMLAnchorElement? tappedAnchor,
  }) async {
    if (_isHandlingLinkTapAction || _quill == null) return;
    _isHandlingLinkTapAction = true;
    try {
      // Let Quill process the tap first so selection state can settle.
      await Future.delayed(const Duration(milliseconds: 10));
      if (!mounted || _quill == null) return;

      final linkRange = _resolveTappedLinkRange(
        href,
        tappedAnchor: tappedAnchor,
      );

      final callback = widget.configuration.onLinkTapped;
      if (callback == null) return;

      // Blur editor to dismiss keyboard before showing link dialog
      _blurEditorAndSyncFlutterFocus();
      final linkText = linkRange != null
          ? _quill!.getText(linkRange.index, linkRange.length)
          : text;
      final result = await callback(href, linkText);
      if (!mounted || _quill == null) return;
      if (linkRange == null) return;

      if (result == null) {
        // Remove the link
        _quill!.formatText(
          linkRange.index,
          linkRange.length,
          'link',
          false.toJS,
        );
        _quill!.setSelectionWithSource(
          linkRange.index + linkRange.length,
          0,
          'silent'.toJS,
        );
      } else {
        if (result.text != null && result.text != linkText) {
          // Replace text and set new link
          _quill!.deleteText(linkRange.index, linkRange.length);
          _quill!.insertText(
            linkRange.index,
            result.text!,
            'link'.toJS,
            result.url.toJS,
          );
          _quill!.setSelectionWithSource(
            linkRange.index + result.text!.length,
            0,
            'silent'.toJS,
          );
        } else {
          // Update URL only
          _quill!.formatText(
            linkRange.index,
            linkRange.length,
            'link',
            result.url.toJS,
          );
          _quill!.setSelectionWithSource(
            linkRange.index + linkRange.length,
            0,
            'silent'.toJS,
          );
        }
      }

      // Ensure editing focus is restored after the async link action flow so
      // keyboard-height synchronization has a reliable focused state.
      _quill!.focus();
      _editorHasFocus = true;
      _onJsFocusChanged(hasFocus: true);
    } finally {
      _isHandlingLinkTapAction = false;
      if (mounted) {
        _refreshKeyboardHeightFromViewport();
        _scheduleKeyboardRefreshRetries();
      }
    }
  }

  _LinkRange? _resolveTappedLinkRange(
    String href, {
    web.HTMLAnchorElement? tappedAnchor,
  }) {
    final fromAnchor = tappedAnchor != null
        ? _findLinkRangeFromAnchorNode(tappedAnchor)
        : null;
    final sel = _getQuillSelection();
    final fromSelection = sel != null ? _findLinkRange(sel.index) : null;
    final fromHrefFallback = _findLinkRangeByHref(href);

    return resolveQuillJsTappedLinkRange(
      tappedHref: href,
      rangeFromAnchor: fromAnchor,
      hrefFromAnchorRange: _hrefForRange(fromAnchor),
      rangeFromSelection: fromSelection,
      hrefFromSelectionRange: _hrefForRange(fromSelection),
      rangeFromHrefFallback: fromHrefFallback,
    );
  }

  _LinkRange? _findLinkRangeFromAnchorNode(web.HTMLAnchorElement anchor) {
    final quill = _quill;
    final quillConstructor = _quillConstructor;
    if (quill == null || quillConstructor == null) return null;

    try {
      final blot = quillConstructor.find(anchor as JSObject, true);
      if (blot == null) return null;
      final index = quill.getIndex(blot);
      if (index < 0) return null;
      return _findLinkRange(index);
    } catch (_) {
      return null;
    }
  }

  String? _hrefForRange(_LinkRange? range) {
    if (range == null) return null;
    final format = _getFormatAt(range.index, 1);
    final href = format['link'];
    return href is String ? href : null;
  }

  // ------------------------------------------------------------------
  // Tab key handling (list nesting prevention)
  // ------------------------------------------------------------------

  void _setupTabKeyHandler() {
    _tabKeyHandlerJs = ((web.Event event) {
      final keyEvent = event as web.KeyboardEvent;
      if (keyEvent.key == 'Tab' && !keyEvent.shiftKey) {
        if (!_canIndentCurrentLine()) {
          event.preventDefault();
          event.stopPropagation();
        }
      }
    }).toJS;

    // Use capture phase so we fire before Quill's keyboard handler
    _editorDiv!.addEventListener('keydown', _tabKeyHandlerJs, true.toJS);
  }

  /// Returns `true` if the current line is allowed to be indented.
  ///
  /// A list item can only be indented if the preceding list line has an
  /// indent level >= the current line's indent level (i.e., there is a
  /// "parent" item to nest under).
  bool _canIndentCurrentLine() {
    if (_quill == null) return false;

    final sel = _getQuillSelection();
    if (sel == null) return false;

    final format = _getFormat();
    if (!format.containsKey('list')) return true; // not in a list

    final currentIndent = (format['indent'] as num?)?.toInt() ?? 0;

    // Find the previous line by locating the last '\n' before the cursor
    // in the plain text. This avoids fragile Delta op parsing.
    final textBeforeCursor = _quill!.getText(0, sel.index);
    final prevNewline = textBeforeCursor.lastIndexOf('\n');

    if (prevNewline < 0) {
      // Cursor is on the very first line — no parent to nest under.
      return false;
    }

    // Query Quill.js for the block format at that '\n' character.
    final prevFormat = _getFormatAt(prevNewline, 1);
    if (!prevFormat.containsKey('list')) return false;

    final prevIndent = (prevFormat['indent'] as num?)?.toInt() ?? 0;
    return prevIndent >= currentIndent;
  }

  // ------------------------------------------------------------------
  // Enter key handling (preserve inline formatting on new line)
  // ------------------------------------------------------------------

  void _setupEnterKeyHandler() {
    _enterKeyHandlerJs = ((web.Event event) {
      final keyEvent = event as web.KeyboardEvent;
      if (keyEvent.key == 'Enter' && !keyEvent.shiftKey) {
        // Get current format before Enter is processed
        final format = _getFormat();
        final hasInlineFormat =
            format['bold'] == true ||
            format['italic'] == true ||
            format['underline'] == true;

        if (hasInlineFormat) {
          // Let Quill handle the Enter key first
          // Then apply the formatting to the new line
          Future.delayed(const Duration(milliseconds: 10), () {
            if (!mounted || _quill == null) return;

            // Apply the same formatting to the new line
            if (format['bold'] == true) {
              _quill!.format('bold', true.toJS);
            }
            if (format['italic'] == true) {
              _quill!.format('italic', true.toJS);
            }
            if (format['underline'] == true) {
              _quill!.format('underline', true.toJS);
            }

            // Sync toolbar state
            _syncFormatState();
          });
        }
      }
    }).toJS;

    // Use capture phase so we can read format before Quill processes Enter
    _editorDiv!.addEventListener('keydown', _enterKeyHandlerJs, true.toJS);
  }

  // ------------------------------------------------------------------
  // Escape key handling (move focus out of editor on web)
  // ------------------------------------------------------------------

  void _setupEscapeKeyHandler() {
    _escapeKeyHandlerJs = ((web.Event event) {
      final keyEvent = event as web.KeyboardEvent;
      if (keyEvent.key == 'Escape' || keyEvent.key == 'Esc') {
        event.preventDefault();
        event.stopPropagation();

        final node = widget.focusNode;
        final shouldAdvanceFocus = node?.hasFocus ?? false;
        _blurEditorAndSyncFlutterFocus();
        if (shouldAdvanceFocus) {
          node!.nextFocus();
        }
      }
    }).toJS;

    // Use capture phase to handle escape before Quill/browser defaults.
    _editorDiv!.addEventListener('keydown', _escapeKeyHandlerJs, true.toJS);
  }

  // ------------------------------------------------------------------
  // Cursor / scroll helpers
  // ------------------------------------------------------------------

  bool _pendingEnsureSelectionVisible = false;

  void _scheduleEnsureSelectionVisible([
    Duration delay = const Duration(milliseconds: 12),
  ]) {
    if (_pendingEnsureSelectionVisible) return;
    _pendingEnsureSelectionVisible = true;
    Future<void>.delayed(delay, () {
      _pendingEnsureSelectionVisible = false;
      if (!mounted) return;
      _ensureSelectionVisible();
    });
  }

  /// Scrolls the editor just enough to keep the active selection visible.
  void _ensureSelectionVisible() {
    final quill = _quill;
    if (quill == null) return;
    try {
      quill.scrollSelectionIntoView();
    } catch (_) {
      // Best-effort only. If unsupported in runtime Quill build, ignore.
    }
  }

  /// Moves the cursor to the very end of the document and scrolls the
  /// Quill container so the cursor is visible.
  void _moveCursorToEndAndScroll() {
    if (_quill == null) return;

    final length = _quill!.getLength();
    if (length > 0) {
      _quill!.setSelection(length - 1, 0);
    }

    // Scroll the Quill editor container inside the iframe to the bottom.
    final qlContainer = _iframe.contentDocument?.querySelector('.ql-container');
    if (qlContainer != null) {
      (qlContainer as web.HTMLElement).scrollTop = qlContainer.scrollHeight;
    }
  }

  // ------------------------------------------------------------------
  // Controller attachment
  // ------------------------------------------------------------------

  /// Helper to preserve scroll position during format operations
  void _formatWithScrollPreservation(String formatName, JSAny? value) {
    final container = _iframe.contentDocument?.querySelector('.ql-editor');
    final scrollTop = (container as web.HTMLElement?)?.scrollTop ?? 0;

    _quill!.format(formatName, value);

    // Restore scroll position after a short delay
    Future.delayed(const Duration(milliseconds: 10), () {
      if (container != null && mounted) {
        container.scrollTop = scrollTop;
      }
    });
  }

  void _attachController() {
    widget.controller.attachCallbacks(
      toggleBold: () {
        final fmt = _getFormat();
        _formatWithScrollPreservation('bold', (!(fmt['bold'] == true)).toJS);
        _syncFormatState();
      },
      toggleItalic: () {
        final fmt = _getFormat();
        _formatWithScrollPreservation(
          'italic',
          (!(fmt['italic'] == true)).toJS,
        );
        _syncFormatState();
      },
      toggleUnderline: () {
        final fmt = _getFormat();
        _formatWithScrollPreservation(
          'underline',
          (!(fmt['underline'] == true)).toJS,
        );
        _syncFormatState();
      },
      toggleOrderedList: () {
        final fmt = _getFormat();
        if (fmt['list'] == 'ordered') {
          _formatWithScrollPreservation('list', false.toJS);
        } else {
          _formatWithScrollPreservation('list', 'ordered'.toJS);
        }
        _syncFormatState();
      },
      toggleBulletList: () {
        final fmt = _getFormat();
        if (fmt['list'] == 'bullet') {
          _formatWithScrollPreservation('list', false.toJS);
        } else {
          _formatWithScrollPreservation('list', 'bullet'.toJS);
        }
        _syncFormatState();
      },
      requestLink: _handleRequestLink,
      getContents: _getContentsDelta,
      setContents: (delta) {
        _suppressContentChanged = true;
        _quill!.setContents(_deltaToJs(delta));
        _suppressContentChanged = false;
        _contentForAutoResize = delta;
        if (widget.configuration.autoResizeToContent && mounted) {
          setState(() {});
        }
      },
      scrollToEnd: _moveCursorToEndAndScroll,
      ensureSelectionVisible: _ensureSelectionVisible,
      clear: () {
        _suppressContentChanged = true;
        final cleared = Delta()..insert('\n');
        _quill!.setContents(_deltaToJs(cleared));
        _suppressContentChanged = false;
        _contentForAutoResize = cleared;
        if (widget.configuration.autoResizeToContent && mounted) {
          setState(() {});
        }
        _moveCursorToEndAndScroll();
      },
      setSelection: (index, length) {
        _quill!.setSelection(index, length);
      },
      insertText: (index, text, attributes) {
        if (attributes != null &&
            attributes.containsKey('link') &&
            attributes['link'] != null) {
          final url = attributes['link']!.toString();
          _quill!.insertText(index, text, 'link'.toJS, url.toJS);
        } else {
          _quill!.insertText(index, text);
        }
      },
      replaceText: (index, length, replacement) {
        _quill!.deleteText(index, length);
        _quill!.insertText(index, replacement);
        _quill!.setSelection(index + replacement.length, 0);
      },
      insertTextAtCursor: (text) {
        final sel = _getQuillSelection(focus: true);
        final idx =
            sel?.index ??
            ((_quill!.getLength() > 1) ? _quill!.getLength() - 1 : 0);
        final len = sel?.length ?? 0;
        _quill!.deleteText(idx, len);
        _quill!.insertText(idx, text);
        _quill!.setSelection(idx + text.length, 0);
      },
      focus: () => _quill!.focus(),
      blur: () => _quill!.blur(),
    );
  }

  void _detachController() {
    widget.controller.detach();
  }

  /// Reads the current format from Quill and pushes it to the controller.
  void _syncFormatState() {
    final format = _getFormat();
    final sel = _getQuillSelection();
    final isCollapsed = sel == null || sel.length == 0;

    // For collapsed selections (just cursor), link format shouldn't be active
    // because typing won't continue the link.
    final state = QuillJsFormatState(
      bold: format['bold'] == true,
      italic: format['italic'] == true,
      underline: format['underline'] == true,
      list: format['list'] is String ? format['list'] as String : null,
      link: (!isCollapsed && format['link'] is String)
          ? format['link'] as String
          : null,
    );
    widget.controller.updateFormatState(state);
  }

  // ------------------------------------------------------------------
  // Link create / edit
  // ------------------------------------------------------------------

  Future<void> _handleRequestLink() async {
    if (_isHandlingLinkRequest || _quill == null) return;
    if (widget.configuration.onLinkCreate == null) return;

    _isHandlingLinkRequest = true;
    try {
      // Snapshot the current selection without forcing editor focus. On mobile
      // web, forcing focus can reopen the keyboard before the dialog appears.
      final selection = _getQuillSelection();
      final editContext = _resolveLinkEditContext(selection);

      if (editContext != null) {
        await _handleLinkEdit(
          currentUrl: editContext.url,
          linkRange: editContext.range,
        );
      } else {
        await _handleLinkCreate(initialSelection: selection);
      }
    } finally {
      _isHandlingLinkRequest = false;
    }
  }

  Future<void> _handleLinkCreate({_QuillSelection? initialSelection}) async {
    final callback = widget.configuration.onLinkCreate;
    if (callback == null) return;

    final sel = initialSelection ?? _getQuillSelection();
    String? selectedText;
    if (sel != null && sel.length > 0) {
      selectedText = _quill!.getText(sel.index, sel.length);
    }

    final result = await callback(selectedText: selectedText);
    if (result == null || !mounted || _quill == null) return;

    if (sel != null && sel.length > 0) {
      if (result.text != null && result.text != selectedText) {
        _quill!.deleteText(sel.index, sel.length);
        _quill!.insertText(
          sel.index,
          result.text!,
          'link'.toJS,
          result.url.toJS,
        );
        _quill!.setSelection(sel.index + result.text!.length, 0);
      } else {
        _quill!.formatText(sel.index, sel.length, 'link', result.url.toJS);
        _quill!.setSelection(sel.index + sel.length, 0);
      }
    } else {
      final docEnd = _quill!.getLength() - 1;
      final maxInsert = docEnd < 0 ? 0 : docEnd;
      final insertIdx = (sel?.index ?? maxInsert).clamp(0, maxInsert).toInt();
      final text = result.text ?? result.url;
      _quill!.insertText(insertIdx, text, 'link'.toJS, result.url.toJS);
      _quill!.setSelection(insertIdx + text.length, 0);
    }
  }

  Future<void> _handleLinkEdit({
    required String currentUrl,
    required _LinkRange linkRange,
  }) async {
    final callback = widget.configuration.onLinkCreate;
    if (callback == null) return;

    final linkText = _quill!.getText(linkRange.index, linkRange.length);

    // Call onLinkCreate with both the existing text and URL for pre-filling
    final result = await callback(
      selectedText: linkText,
      existingUrl: currentUrl,
    );
    if (!mounted || _quill == null || result == null) return;

    // Delete the old link and insert the new one
    _quill!.deleteText(linkRange.index, linkRange.length);
    final text = result.text ?? result.url;
    _quill!.insertText(linkRange.index, text, 'link'.toJS, result.url.toJS);
    _quill!.setSelection(linkRange.index + text.length, 0);
  }

  _LinkEditContext? _resolveLinkEditContext(_QuillSelection? selection) {
    if (selection == null || _quill == null) return null;

    final linkRange = _findLinkRange(selection.index);
    if (linkRange == null) return null;

    final rangeFormat = _getFormatAt(linkRange.index, 1);
    final rangeUrl = rangeFormat['link'];
    if (rangeUrl is String && rangeUrl.isNotEmpty) {
      return (range: linkRange, url: rangeUrl);
    }

    final selectionFormat = _getFormat();
    final selectionUrl = selectionFormat['link'];
    if (selectionUrl is String && selectionUrl.isNotEmpty) {
      return (range: linkRange, url: selectionUrl);
    }

    return null;
  }

  // ------------------------------------------------------------------
  // Quill.js helpers
  // ------------------------------------------------------------------

  _QuillSelection? _getQuillSelection({bool focus = false}) {
    final sel = focus ? _quill!.getSelection(true) : _quill!.getSelection();
    if (sel == null) return null;
    return (index: sel.index, length: sel.length);
  }

  Map<String, dynamic> _getFormat() {
    final formatObj = _quill?.getFormat();
    if (formatObj == null) return {};
    try {
      final jsonStr = _mainJsonStringify(formatObj).toDart;
      if (jsonStr.isEmpty || jsonStr == '{}') return {};
      return (jsonDecode(jsonStr) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  /// Returns the format at a specific [index] spanning [length] characters.
  Map<String, dynamic> _getFormatAt(int index, int length) {
    final formatObj = _quill?.getFormatAt(index, length);
    if (formatObj == null) return {};
    try {
      final jsonStr = _mainJsonStringify(formatObj).toDart;
      if (jsonStr.isEmpty || jsonStr == '{}') return {};
      return (jsonDecode(jsonStr) as Map).cast<String, dynamic>();
    } catch (_) {
      return {};
    }
  }

  Delta _getContentsDelta() {
    final jsContents = _quill!.getContents();
    return _jsToDelta(jsContents);
  }

  /// Finds the contiguous range of a link that contains [cursorIndex].
  _LinkRange? _findLinkRange(int cursorIndex) {
    final delta = _getContentsDelta();
    final ops = delta.toList();

    int offset = 0;
    for (final op in ops) {
      final data = op.data;
      final len = data is String ? data.length : 1;
      final attrs = op.attributes;

      if (attrs != null && attrs.containsKey('link')) {
        if (cursorIndex >= offset && cursorIndex < offset + len) {
          return (index: offset, length: len);
        }
      }

      offset += len;
    }
    return null;
  }

  /// Finds the first contiguous link range whose `link` attribute matches [href].
  ///
  /// This is used as a fallback only; when duplicate href values exist, this
  /// returns the first match in document order.
  _LinkRange? _findLinkRangeByHref(String href) {
    final delta = _getContentsDelta();
    final ops = delta.toList();

    int offset = 0;
    int? currentStart;
    int currentLength = 0;
    String? currentHref;

    _LinkRange? flushCurrentRange() {
      if (currentStart != null && currentHref == href && currentLength > 0) {
        return (index: currentStart, length: currentLength);
      }
      return null;
    }

    for (final op in ops) {
      final data = op.data;
      final len = data is String ? data.length : 1;
      final attrs = op.attributes;
      final opHref = attrs != null ? attrs['link'] as String? : null;

      if (opHref != null) {
        if (currentStart == null || currentHref != opHref) {
          final matched = flushCurrentRange();
          if (matched != null) return matched;
          currentStart = offset;
          currentLength = len;
          currentHref = opHref;
        } else {
          currentLength += len;
        }
      } else {
        final matched = flushCurrentRange();
        if (matched != null) return matched;
        currentStart = null;
        currentLength = 0;
        currentHref = null;
      }

      offset += len;
    }

    return flushCurrentRange();
  }

  // ------------------------------------------------------------------
  // Delta conversion
  // ------------------------------------------------------------------

  static JSObject _deltaToJs(Delta delta) {
    final json = jsonEncode({'ops': delta.toJson()});
    return _mainJsonParse(json.toJS) as JSObject;
  }

  static Delta _jsToDelta(JSObject jsDelta) {
    final jsonStr = _mainJsonStringify(jsDelta).toDart;
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    return Delta.fromJson(map['ops'] as List);
  }

  static String _plainTextFromDelta(Delta delta) {
    final buffer = StringBuffer();
    for (final op in delta.toList()) {
      if (!op.isInsert) continue;
      final data = op.data;
      if (data is String) {
        buffer.write(data);
      } else {
        buffer.write('\uFFFC');
      }
    }
    final text = buffer.toString();
    if (text.isEmpty) {
      return '';
    }
    // Quill documents always end with a terminal newline sentinel. For visual
    // line counting we must ignore that single trailing newline, otherwise
    // min/max lines become effectively N+1.
    if (text.endsWith('\n')) {
      return text.substring(0, text.length - 1);
    }
    return text;
  }

  double? _parseCssPx(String? value) {
    if (value == null) return null;
    final trimmed = value.trim().toLowerCase();
    if (!trimmed.endsWith('px')) return null;
    return double.tryParse(trimmed.substring(0, trimmed.length - 2));
  }

  web.HTMLElement? _quillEditorElement() =>
      _iframe.contentDocument?.querySelector('.ql-editor') as web.HTMLElement?;

  double? _computedEditorLineHeightPx() {
    final editor = _quillEditorElement();
    if (editor == null) return null;
    final styles = web.window.getComputedStyle(editor);
    final lineHeight = _parseCssPx(styles.getPropertyValue('line-height'));
    if (lineHeight != null) return lineHeight;
    final fontSize = _parseCssPx(styles.getPropertyValue('font-size'));
    if (fontSize != null) {
      return fontSize * (widget.configuration.style?.lineHeight ?? 1.5);
    }
    return null;
  }

  ({double top, double bottom})? _computedEditorVerticalPaddingPx() {
    final editor = _quillEditorElement();
    if (editor == null) return null;
    final styles = web.window.getComputedStyle(editor);
    final top = _parseCssPx(styles.getPropertyValue('padding-top'));
    final bottom = _parseCssPx(styles.getPropertyValue('padding-bottom'));
    if (top == null || bottom == null) return null;
    return (top: top, bottom: bottom);
  }

  double _resolveAutoResizeHeight(double maxWidth, TextDirection textDirection) {
    final cfg = widget.configuration;
    final style = cfg.style;
    final fontSize = style?.fontSize ?? 16.0;
    final lineHeightMultiplier = style?.lineHeight ?? 1.5;
    final lineHeightPx = fontSize * lineHeightMultiplier;
    final contentWidth = math.max(0.0, maxWidth - cfg.autoResizeHorizontalPadding);

    if (contentWidth <= 0) {
      return lineHeightPx * cfg.minLines + cfg.autoResizeVerticalPadding;
    }

    final text = _plainTextFromDelta(_contentForAutoResize);
    final layoutText = text.isEmpty ? ' ' : text;
    final textPainter = TextPainter(
      text: TextSpan(
        text: layoutText,
        style: TextStyle(
          fontSize: fontSize,
          height: lineHeightMultiplier,
          letterSpacing: style?.letterSpacing,
          fontFamily: style?.fontFamily,
        ),
      ),
      textDirection: textDirection,
      maxLines: null,
    )..layout(maxWidth: contentWidth);

    final lineMetrics = textPainter.computeLineMetrics();
    final wrappedLineCount = lineMetrics.length;
    final explicitLineCount = text.isEmpty ? 1 : '\n'.allMatches(text).length + 1;
    final visibleLineCount = math.max(wrappedLineCount, explicitLineCount).clamp(
      cfg.minLines,
      cfg.maxLines,
    );
    final domLineHeightPx = _computedEditorLineHeightPx() ?? lineHeightPx;
    final domPadding = _computedEditorVerticalPaddingPx();
    final topPaddingPx = domPadding?.top ?? (cfg.autoResizeVerticalPadding / 2);
    final bottomPaddingPx =
        domPadding?.bottom ?? (cfg.autoResizeVerticalPadding / 2);
    final domVerticalPaddingPx = topPaddingPx + bottomPaddingPx;

    if (math.max(wrappedLineCount, explicitLineCount) >= cfg.maxLines) {
      // Do not include bottom padding at clamp height; otherwise the top of
      // line N+1 can remain visible by up to that padding amount.
      return domLineHeightPx * cfg.maxLines + topPaddingPx;
    }

    double visibleTextHeight = 0;
    if (lineMetrics.isNotEmpty) {
      for (var i = 0; i < visibleLineCount; i++) {
        if (i < lineMetrics.length) {
          visibleTextHeight += lineMetrics[i].height;
        } else {
          visibleTextHeight += textPainter.preferredLineHeight;
        }
      }
    } else {
      visibleTextHeight = textPainter.preferredLineHeight * visibleLineCount;
    }

    return visibleTextHeight + domVerticalPaddingPx;
  }

  // ------------------------------------------------------------------
  // Tap-outside handling
  // ------------------------------------------------------------------

  void _onTapOutside(PointerDownEvent _) {
    if (!_editorHasFocus || _quill == null) return;
    _blurEditorAndSyncFlutterFocus();
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    Widget child = Stack(
      children: [
        HtmlElementView(viewType: _viewType),
        if (_loadState == _LoadState.loading && widget.loadingBuilder != null)
          Positioned.fill(child: widget.loadingBuilder!),
        if (_loadState == _LoadState.error)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.white,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Failed to load editor:\n${_errorMessage ?? 'Unknown error'}',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.red.shade700),
                  ),
                ),
              ),
            ),
          ),
      ],
    );

    if (widget.configuration.unfocusOnTapOutside) {
      child = TapRegion(
        groupId: widget.tapRegionGroupId,
        onTapOutside: _onTapOutside,
        child: child,
      );
    }

    final node = widget.focusNode;
    if (node != null) {
      // Ensure the provided FocusNode is attached to Flutter's focus tree.
      // Without this, requestFocus() from client code can be a no-op.
      child = Focus(focusNode: node, child: child);
    }

    if (widget.configuration.autoResizeToContent) {
      final wrappedChild = child;
      child = LayoutBuilder(
        builder: (context, constraints) {
          final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
          final height = _resolveAutoResizeHeight(
            constraints.maxWidth,
            direction,
          );
          return SizedBox(height: height, child: wrappedChild);
        },
      );
    }

    return child;
  }
}

enum _LoadState { loading, ready, error }
