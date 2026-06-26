// Web implementation of QuillJsEditorView using an iframe-based HtmlElementView
// + Quill.js. The iframe provides natural scroll/keyboard/focus isolation,
// preventing the browser from scrolling the parent Flutter page when the
// keyboard opens or when the user drags inside the editor.
//
// This file is only loaded on web via conditional export.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:ui' show Color;
import 'dart:ui_web' as ui_web;

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart' show rootBundle;
import 'package:web/web.dart' as web;

import '../../models/structs/copy_data.dart';
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
typedef _ScrollTransfer = ({double innerConsumed, double outerRemainder});

enum _TouchScrollOwner { undecided, inner, outer }

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

class _QuillJsEditorViewState extends State<QuillJsEditorView>
    with TickerProviderStateMixin {
  static int _nextId = 0;

  /// Set to `true` to emit verbose `KLAPP_FOCUS` focus/keyboard diagnostics.
  ///
  /// Off by default so production builds stay quiet. When enabled, traces are
  /// only emitted in debug builds (see the `assert` in [_traceFocus]).
  static const bool _kFocusTraceEnabled = false;

  void _traceFocus(String event, [Map<String, Object?> data = const {}]) {
    if (!_kFocusTraceEnabled) {
      return;
    }
    assert(() {
      final timestamp = DateTime.now().toIso8601String();
      debugPrint(
        'KLAPP_FOCUS $timestamp QuillJsEditorView $event ${data.toString()}',
      );
      return true;
    }());
  }

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
  JSFunction? _shiftTabKeyHandlerJs;
  JSFunction? _linkClickHandlerJs;
  JSFunction? _linkTouchStartHandlerJs;
  JSFunction? _linkPointerDownHandlerJs;
  JSFunction? _tapFocusTouchStartHandlerJs;
  JSFunction? _tapFocusTouchEndHandlerJs;
  JSFunction? _tapFocusTouchCancelHandlerJs;
  JSFunction? _tapFocusPointerDownHandlerJs;
  JSFunction? _tapFocusPointerUpHandlerJs;
  JSFunction? _iframeLoadHandlerJs;
  JSFunction? _pasteHandlerJs;
  JSFunction? _copyHandlerJs;
  JSFunction? _cutHandlerJs;
  JSFunction? _outerScrollWheelHandlerJs;
  JSFunction? _outerScrollTouchStartHandlerJs;
  JSFunction? _outerScrollTouchMoveHandlerJs;
  JSFunction? _outerScrollTouchEndHandlerJs;
  JSFunction? _outerScrollTouchCancelHandlerJs;
  JSFunction? _outerScrollPointerDownHandlerJs;
  JSFunction? _outerScrollPointerUpHandlerJs;
  JSFunction? _outerScrollPointerCancelHandlerJs;
  JSFunction? _outerScrollCompositionStartHandlerJs;
  JSFunction? _outerScrollCompositionEndHandlerJs;

  // Parent-window viewport fix listeners
  JSFunction? _viewportResizeHandlerJs;
  JSFunction? _parentScrollResetJs;
  String? _savedHtmlOverflow;
  String? _savedBodyOverflow;
  int _lowKeyboardFramesWhileFocused = 0;
  Timer? _nullSelectionFocusLossTimer;
  bool _isPasteInProgress = false;

  /// Timestamp of the most recent `visualViewport` resize. Used by the
  /// stable-phase resize guard to recognise the IME/viewport transition
  /// window during which a transient blur must not close the keyboard.
  DateTime? _lastViewportResizeAt;

  /// Number of times the null-selection teardown has been re-armed while the
  /// editor still holds DOM focus during a resize. Bounded so the guard can
  /// never loop indefinitely if focus is genuinely lost.
  int _nullSelectionRecheckCount = 0;

  /// Synchronous `focusout` handler on the editor that re-asserts DOM focus
  /// when the iframe `contenteditable` is blurred by an `adjustResize`-driven
  /// viewport resize (which would otherwise make the WebView close the IME).
  JSFunction? _editorFocusRetentionHandlerJs;

  /// Bounded counter for [_editorFocusRetentionHandlerJs] so a genuinely lost
  /// focus (user dismiss, navigation) cannot trigger an unbounded refocus loop.
  int _domFocusRetainCount = 0;
  DateTime? _domFocusRetainWindowStart;

  static const double _keyboardOpenThresholdPx = 50.0;
  static const int _keyboardCloseConfirmFrames = 3;

  /// Window after a `visualViewport` resize during which an editable
  /// invalidation (Quill `selection-change(null)`) is treated as a transient
  /// side-effect of the keyboard/viewport animation rather than a real blur.
  ///
  /// Android WebView under `SOFT_INPUT_ADJUST_RESIZE` briefly invalidates the
  /// focused editable while resizing for the keyboard; the IME transition
  /// typically settles within ~200-400ms.
  static const Duration _imeResizeGuardWindow = Duration(milliseconds: 400);

  /// Maximum number of bounded re-checks the resize guard performs before it
  /// allows the teardown to proceed, even if DOM focus still appears present.
  static const int _maxNullSelectionRechecks = 3;

  /// Sliding window and cap for synchronous DOM focus retention. If more than
  /// [_maxDomFocusRetainAttempts] blurs are retained within this window, focus
  /// is treated as genuinely lost and retention stops (prevents loops).
  static const Duration _domFocusRetainWindow = Duration(milliseconds: 1200);
  static const int _maxDomFocusRetainAttempts = 12;

  // ------------------------------------------------------------------
  // Android IME warm-up handoff
  // ------------------------------------------------------------------
  //
  // On Android WebView under `SOFT_INPUT_ADJUST_RESIZE`, a *cold* tap that
  // focuses the Quill `contenteditable` opens the soft keyboard and shrinks the
  // WebView window in the same frame. That viewport resize races the still
  // settling contenteditable focus and Chromium drops it to the iframe `<body>`
  // (`iframeActiveTag: BODY`), which tells Android to hide the IME again. The
  // editable cannot be re-focused into a re-shown keyboard without a fresh user
  // gesture, so reactive refocus loops only flicker.
  //
  // The fix mirrors the path users found reliable by hand (focus a normal text
  // field first, then move into Quill once the keyboard is already up): within
  // the tap gesture we focus a hidden native `<input>` — which survives the
  // resize far better than a contenteditable, just like a Flutter `TextField`
  // does — and only once the viewport has settled do we transfer focus to
  // Quill. The handoff happens with the keyboard already open and no further
  // resize, so the editable never blurs.

  /// Hidden native input used to open the soft keyboard ahead of the Quill
  /// focus handoff. Only created on Android web.
  web.HTMLInputElement? _imeWarmupInput;
  JSFunction? _imeWarmupInputBlurHandlerJs;

  /// True between focusing [_imeWarmupInput] and transferring focus to Quill.
  bool _warmupHandoffPending = false;
  int? _warmupTapIndex;
  DateTime? _warmupStartedAt;
  Timer? _warmupSettleTimer;
  DateTime? _warmupLastRefocusAt;

  /// Absolute viewport height (px) captured when the warm-up began, used as the
  /// baseline to detect the keyboard-driven shrink.
  double? _warmupBaselineViewportHeight;

  /// Tallest viewport height (px) observed during this view's lifetime, i.e. the
  /// "no keyboard" reference. Lets us recognise a tap that arrives while the
  /// keyboard is *already* open (current height sits well below this).
  double _maxViewportHeight = 0;

  /// Height (px) we are currently checking for stability, and when it last
  /// changed beyond [_warmupHeightStableEpsilonPx].
  double? _warmupSettleHeight;
  DateTime? _warmupHeightStableSince;

  /// How often, while waiting for the keyboard to open, we re-issue
  /// `showSoftInput` by blur+refocusing the warm-up input.
  static const Duration _warmupRefocusInterval = Duration(milliseconds: 110);

  /// Minimum absolute viewport shrink (px) that counts as the soft keyboard
  /// opening. Large enough to ignore navigation/app-bar/inset layout changes
  /// (tens of px) that some WebView hosts emit on screen entry, but well below
  /// a real soft keyboard (hundreds of px).
  static const double _warmupKeyboardShrinkMinPx = 120;

  /// Fractional fallback for the shrink threshold, for short/landscape windows
  /// where a keyboard may be a smaller absolute size.
  static const double _warmupKeyboardShrinkMinFraction = 0.15;

  /// Two height samples within this many px are treated as "the same height".
  static const double _warmupHeightStableEpsilonPx = 6;

  /// Set just after a handoff completes. While active, transient
  /// `activeElement == <body>` readings (the WebView can take a few frames to
  /// move DOM focus from `<body>` onto `.ql-editor` after `quill.focus()`) must
  /// not let Flutter steal focus back via `requestFocus()`, which would close
  /// the keyboard and restart the steal/reacquire flicker.
  DateTime? _warmupHandoffGuardUntil;
  static const Duration _warmupHandoffGuardWindow = Duration(
    milliseconds: 1200,
  );

  bool _withinWarmupHandoffGuard() {
    final until = _warmupHandoffGuardUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  /// How long the (shrunk) viewport height must stay stable after the keyboard
  /// opened before we hand focus to Quill. Long enough to bridge a multi-stage
  /// keyboard animation so no further resize blurs the editor post-handoff.
  static const Duration _warmupHeightStableWindow = Duration(milliseconds: 180);

  /// Hard cap so a missed/edge-case keyboard signal can never strand focus on
  /// the hidden input. The keyboard usually opens well within this.
  static const Duration _warmupMaxWait = Duration(milliseconds: 900);
  static const Duration _warmupPollInterval = Duration(milliseconds: 40);

  bool? _cachedIsAndroidWeb;
  bool? _cachedIsIOSWeb;

  /// Whether this is an Android web environment, where the IME warm-up handoff
  /// applies. iOS and desktop keep their existing, working focus path.
  bool get _isAndroidWeb => _cachedIsAndroidWeb ??=
      web.window.navigator.userAgent.toLowerCase().contains('android');

  bool get _isIOSWeb {
    if (_cachedIsIOSWeb != null) return _cachedIsIOSWeb!;
    final ua = web.window.navigator.userAgent.toLowerCase();
    _cachedIsIOSWeb =
        ua.contains('iphone') || ua.contains('ipad') || ua.contains('ipod');
    return _cachedIsIOSWeb!;
  }

  bool get _isMobileWeb => _isAndroidWeb || _isIOSWeb;

  /// True when a soft keyboard or mobile acquisition path is active.
  bool _isSoftKeyboardContext() {
    return _isMobileWeb ||
        _warmupHandoffPending ||
        _focusPhase == _FocusPhase.acquiring ||
        _withinImeResizeGuard() ||
        _isKeyboardLikelyOpen() ||
        widget.controller.keyboardHeight.value > 0;
  }

  void _scheduleKeyboardRefreshRetries([int retries = 2]) {
    for (var i = 1; i <= retries; i++) {
      Future<void>.delayed(Duration(milliseconds: 16 * i), () {
        if (!mounted) return;
        _refreshKeyboardHeightFromViewport();
      });
    }
  }

  /// Schedules keyboard-height refreshes at longer intervals to catch
  /// keyboards that are still animating open when focus is first established.
  /// The resize listener may have been registered after the initial viewport
  /// resize, so these retries re-read the viewport once the animation settles.
  static const List<int> _keyboardSettleDelaysMs = [100, 200, 400];

  void _scheduleKeyboardSettleRetries() {
    for (final delayMs in _keyboardSettleDelaysMs) {
      Future<void>.delayed(Duration(milliseconds: delayMs), () {
        if (!mounted) return;
        _refreshKeyboardHeightFromViewport();
      });
    }
  }

  /// Delays focus-loss processing when Quill reports a null selection.
  ///
  /// On Android mobile web, the browser can emit transient null-selection
  /// events during keyboard/viewport resize animation even though the editor
  /// is still logically focused. Immediately treating these as focus loss
  /// tears down keyboard height and syncs [FocusNode.unfocus], which closes
  /// the keyboard before the user can type.
  ///
  /// If a non-null selection arrives within the window the timer is cancelled,
  /// preventing the false focus loss.
  void _scheduleNullSelectionFocusLoss() {
    if (_shouldSuppressUnfocusDuringAcquisition()) return;
    if (_nullSelectionFocusLossTimer?.isActive ?? false) return;
    if (_isPasteInProgress) return;

    _nullSelectionRecheckCount = 0;
    _traceFocus('selection_null_debounce_scheduled', {
      'delayMs': 80,
      'focusPhase': _focusPhase.name,
      'editorHasFocus': _editorHasFocus,
      'flutterHasFocus': widget.focusNode?.hasFocus,
    });
    _nullSelectionFocusLossTimer = Timer(
      const Duration(milliseconds: 80),
      _processNullSelectionFocusLoss,
    );
  }

  /// True while we are inside the [_imeResizeGuardWindow] following the most
  /// recent `visualViewport` resize.
  bool _withinImeResizeGuard() {
    final lastResizeAt = _lastViewportResizeAt;
    return lastResizeAt != null &&
        DateTime.now().difference(lastResizeAt) < _imeResizeGuardWindow;
  }

  /// True when the iframe currently owns DOM focus and we must not perform a
  /// Flutter-side `FocusNode.requestFocus()` that would steal it.
  ///
  /// On Flutter web, requesting focus on the wrapping [FocusNode] moves browser
  /// DOM focus to the Flutter glass pane, which blurs the iframe's
  /// `contenteditable` and makes the WebView close the IME. While the JS editor
  /// already owns DOM focus and a soft keyboard is involved, re-asserting
  /// Flutter focus starts a tug-of-war (steal -> reacquire -> steal) that
  /// flickers the keyboard — and after acquisition stabilizes, the next
  /// selection change would otherwise steal focus and close the keyboard
  /// mid-typing. In all of these states DOM focus is authoritative and must be
  /// left untouched.
  ///
  /// Desktop browsers are unaffected: there is no soft keyboard, so
  /// [QuillJsEditorController.keyboardHeight] stays 0, no viewport resize
  /// occurs, and the phase is never `acquiring` outside the mobile tap path.
  bool _shouldPreserveDomFocusOverFlutter() {
    if (_explicitBlurRequested) return false;
    // Right after a warm-up handoff the WebView can transiently report
    // `<body>` as active while DOM focus settles onto `.ql-editor`. Preserve
    // DOM ownership through that window so Flutter never steals it back.
    if (_withinWarmupHandoffGuard()) return true;
    if (!_hasDomEditorFocus()) return false;
    return _focusPhase == _FocusPhase.acquiring ||
        _withinImeResizeGuard() ||
        widget.controller.keyboardHeight.value > 0;
  }

  /// Whether a `focusout` on the editor should be treated as a transient
  /// resize-driven blur and immediately re-focused, rather than a real blur.
  ///
  /// Gated tightly so it only fights to keep focus while a soft keyboard is
  /// actively involved (cold-focus acquisition or an in-flight viewport
  /// resize), never on user-driven dismiss (`_explicitBlurRequested`), link or
  /// read-only flows.
  bool _shouldRetainDomFocusOnBlur() {
    if (_explicitBlurRequested) return false;
    if (widget.configuration.readOnly) return false;
    if (_isHandlingLinkTapAction || _isHandlingLinkRequest) return false;
    // During a warm-up the editor is intentionally blurred so focus can sit on
    // the hidden input while the keyboard (re)opens; do not fight that blur.
    if (_warmupHandoffPending) return false;
    if (!_editorHasFocus && !(widget.focusNode?.hasFocus ?? false)) {
      return false;
    }
    // A transient resize blur always coincides with an in-flight viewport
    // resize or the cold-focus window. A deliberate dismiss (tap outside,
    // toolbar dialog, etc.) does not, so it falls through and is not fought.
    return _focusPhase == _FocusPhase.acquiring || _withinImeResizeGuard();
  }

  /// Registers the synchronous focus-retention handler inside the iframe.
  void _setupDomFocusRetention() {
    final editorDiv = _editorDiv;
    if (editorDiv == null) return;
    _editorFocusRetentionHandlerJs = ((web.Event event) {
      _handleEditorFocusOut(event);
    }).toJS;
    // `focusout` bubbles, so listening on the container catches blurs of the
    // inner `.ql-editor` contenteditable.
    editorDiv.addEventListener('focusout', _editorFocusRetentionHandlerJs!);
  }

  void _handleEditorFocusOut(web.Event event) {
    if (!mounted || _loadState != _LoadState.ready) return;
    if (!_shouldRetainDomFocusOnBlur()) return;

    final editor = _quillEditorElement();
    if (editor == null) return;

    // Decisive diagnostic: where did focus actually go? Distinguishes a native
    // window-resize blur (parent activeElement stays the <iframe>) from Flutter
    // re-grabbing focus to its glass pane on a resize re-render.
    web.EventTarget? related;
    if (event.isA<web.FocusEvent>()) {
      related = (event as web.FocusEvent).relatedTarget;
    }
    _traceFocus('dom_focus_out', {
      'relatedTag': related.isA<web.Element>()
          ? (related as web.Element).tagName
          : (related == null ? 'null' : 'non-element'),
      'parentActiveTag': web.document.activeElement?.tagName ?? 'null',
      'parentActiveId': web.document.activeElement?.id ?? '',
      'iframeActiveTag':
          _iframe.contentDocument?.activeElement?.tagName ?? 'null',
    });

    // If focus is moving to another node still inside the editor (e.g. caret
    // re-targeting), there is nothing to retain.
    if (related != null &&
        related.isA<web.Node>() &&
        editor.contains(related as web.Node)) {
      return;
    }

    final now = DateTime.now();
    if (_domFocusRetainWindowStart == null ||
        now.difference(_domFocusRetainWindowStart!) > _domFocusRetainWindow) {
      _domFocusRetainWindowStart = now;
      _domFocusRetainCount = 0;
    }
    if (_domFocusRetainCount >= _maxDomFocusRetainAttempts) {
      _traceFocus('dom_focus_retain_exhausted', {
        'focusPhase': _focusPhase.name,
        'attempts': _domFocusRetainCount,
      });
      return;
    }
    _domFocusRetainCount++;
    _traceFocus('dom_focus_retain_refocus', {
      'focusPhase': _focusPhase.name,
      'attempt': _domFocusRetainCount,
      'withinResizeGuard': _withinImeResizeGuard(),
    });
    // Re-focus synchronously within the focusout turn so the WebView IME is not
    // torn down by the adjustResize-driven blur.
    editor.focus();
  }

  /// Creates the hidden native input used for the Android IME warm-up handoff.
  ///
  /// Crucially it lives in the **parent (main-frame) document**, not the
  /// iframe. Under `SOFT_INPUT_ADJUST_RESIZE` Chromium resets focus *inside
  /// subframes* to `<body>` on the keyboard-driven window resize, but preserves
  /// main-frame focus (this is why a Flutter `TextField` keeps the keyboard up
  /// while an iframe editable does not). Opening the keyboard from a main-frame
  /// input therefore lets it survive the resize; only once that resize has
  /// settled do we move focus into the iframe, with no further resize to blur
  /// it. No-op off Android.
  /// Resolves the document the warm-up input should live in.
  ///
  /// The warm-up only works if the input is in a frame whose focus is **not**
  /// reset to `<body>` by the `SOFT_INPUT_ADJUST_RESIZE` window resize — i.e.
  /// the top frame. When the klapp app itself runs inside another page (e.g. a
  /// native wrapper that embeds it in an iframe with its own top bar), our own
  /// `document` is a *subframe* and its focus gets reset just like the Quill
  /// iframe, so the keyboard closes even with the input focused.
  ///
  /// This climbs to the highest **same-origin** ancestor document so the input
  /// lands in the real top frame when reachable. If the top is cross-origin
  /// (unreadable), it falls back to the nearest readable ancestor, then to our
  /// own document.
  ({web.Document doc, bool framed, bool climbedOut}) _resolveWarmupDocument() {
    final selfDoc = web.document;
    var framed = false;
    try {
      framed = web.window.parent != web.window.self ||
          web.window.top != web.window.self;
    } catch (_) {
      framed = true;
    }

    // Best: the absolute top frame (survives the resize focus reset).
    try {
      final top = web.window.top;
      if (top != null && top.document.body != null) {
        return (
          doc: top.document,
          framed: framed,
          climbedOut: !identical(top.document, selfDoc),
        );
      }
    } catch (_) {
      // Top is cross-origin; fall through.
    }

    // Next best: the immediate parent, if same-origin.
    try {
      final parent = web.window.parent;
      if (parent != null && parent.document.body != null) {
        return (
          doc: parent.document,
          framed: framed,
          climbedOut: !identical(parent.document, selfDoc),
        );
      }
    } catch (_) {
      // Parent is cross-origin; fall through.
    }

    return (doc: selfDoc, framed: framed, climbedOut: false);
  }

  void _setupImeWarmupInput() {
    if (!_isAndroidWeb) return;
    final resolved = _resolveWarmupDocument();
    final doc = resolved.doc;
    final body = doc.body;
    if (body == null) return;

    _traceFocus('warmup_input_setup', {
      'framed': resolved.framed,
      'climbedOut': resolved.climbedOut,
    });

    final input =
        doc.createElement('input') as web.HTMLInputElement
          ..type = 'text'
          ..setAttribute('autocomplete', 'off')
          ..setAttribute('autocorrect', 'off')
          ..setAttribute('autocapitalize', 'off')
          ..setAttribute('spellcheck', 'false')
          ..setAttribute('aria-hidden', 'true')
          ..setAttribute('tabindex', '-1')
          ..setAttribute('inputmode', 'text');
    // Rendered (so it is focusable and can open the IME) but visually inert and
    // non-interactive. `font-size: 16px` avoids Android focus-zoom.
    input.style.cssText =
        'position:fixed;top:0;left:0;width:1px;height:1px;'
        'opacity:0;padding:0;border:0;margin:0;font-size:16px;'
        'background:transparent;color:transparent;caret-color:transparent;'
        'pointer-events:none;z-index:-2147483648;';

    // Defensively keep the input's own value empty: focus is handed to Quill
    // before typing, but guard against any stray input event.
    _imeWarmupInputBlurHandlerJs = ((web.Event _) {
      input.value = '';
    }).toJS;
    input.addEventListener('input', _imeWarmupInputBlurHandlerJs!);

    body.appendChild(input);
    _imeWarmupInput = input;
  }

  /// Whether an intercepted tap should route through the warm-up handoff
  /// rather than focusing Quill directly. Only on Android, and only when the
  /// warm-up input exists and the editor is not read-only.
  ///
  /// We skip the warm-up only when the editor already owns DOM focus **and** the
  /// keyboard is actually open — i.e. an in-place caret-move tap during active
  /// editing. Crucially, after a system-button keyboard dismiss the editor
  /// keeps DOM focus while the keyboard is *down*; re-focusing that already
  /// focused contenteditable does not reliably re-open the IME (it flashes open
  /// then closes), so that case must still go through the warm-up.
  bool _shouldUseImeWarmupHandoff() {
    if (!_isAndroidWeb) return false;
    if (_imeWarmupInput == null) return false;
    if (widget.configuration.readOnly) return false;
    if (_hasDomEditorFocus() && _isKeyboardLikelyOpen()) return false;
    return true;
  }

  /// Heuristic for whether the soft keyboard is currently open, using the
  /// absolute viewport shrink (the reliable signal under ADJUST_RESIZE, where
  /// the computed keyboard height stays ~0). Compares the current height to the
  /// tallest height seen this session.
  bool _isKeyboardLikelyOpen() {
    if (_maxViewportHeight <= 0) return false;
    final shrink = _maxViewportHeight - _currentViewportHeight();
    final threshold = math.max(
      _warmupKeyboardShrinkMinPx,
      _maxViewportHeight * _warmupKeyboardShrinkMinFraction,
    );
    return shrink >= threshold;
  }

  /// Opens the soft keyboard via the hidden input, then defers the actual Quill
  /// focus until the viewport has settled (see [_setupImeWarmupInput] docs).
  void _beginImeWarmupHandoff(int? tapIndex) {
    _clearExplicitBlurGuard(reason: 'ime_warmup_handoff');
    final input = _imeWarmupInput;
    if (input == null) {
      _focusQuillFromTap(tapIndex);
      return;
    }

    // A single tap can surface as both pointerdown and touchstart; keep the
    // first warm-up (and its resolved caret) rather than restarting it.
    if (_warmupHandoffPending) {
      _traceFocus('warmup_focus_input_ignored_pending', {'tapIndex': tapIndex});
      return;
    }

    _warmupHandoffPending = true;
    _warmupTapIndex = tapIndex;
    _warmupStartedAt = DateTime.now();
    _warmupLastRefocusAt = null;
    _warmupSettleHeight = null;
    _warmupHeightStableSince = null;
    final baselineHeight = _currentViewportHeight();
    _warmupBaselineViewportHeight = baselineHeight;
    if (baselineHeight > _maxViewportHeight) {
      _maxViewportHeight = baselineHeight;
    }
    _didUserInteractWithSelection = true;

    // Keep acquisition semantics so transient frames during the keyboard
    // animation are not treated as a focus loss.
    _beginAcquisition(reason: 'intercepted_tap_warmup');

    _traceFocus('warmup_focus_input', {'tapIndex': tapIndex});
    // Must run synchronously within the tap gesture so the WebView honours the
    // user activation and shows the soft keyboard.
    input.focus();

    _warmupSettleTimer?.cancel();
    _warmupSettleTimer = Timer.periodic(
      _warmupPollInterval,
      (_) => _pollImeWarmupSettle(),
    );
  }

  void _pollImeWarmupSettle() {
    if (!mounted || !_warmupHandoffPending) {
      _warmupSettleTimer?.cancel();
      _warmupSettleTimer = null;
      return;
    }

    final startedAt = _warmupStartedAt;
    if (startedAt == null) {
      _completeImeWarmupHandoff(reason: 'no_start');
      return;
    }

    final now = DateTime.now();
    final elapsed = now.difference(startedAt);
    if (elapsed >= _warmupMaxWait) {
      _completeImeWarmupHandoff(reason: 'max_wait');
      return;
    }

    final current = _currentViewportHeight();
    if (current > _maxViewportHeight) {
      _maxViewportHeight = current;
    }

    // The keyboard signal under SOFT_INPUT_ADJUST_RESIZE is an *absolute*
    // viewport-height shrink (Flutter's layout shrinks with the window, so the
    // computed keyboard height stays ~0, but the height itself drops). Require a
    // shrink large enough to be a keyboard and not a navigation/inset layout
    // change — the latter is exactly what makes a plain resize event misfire in
    // some WebView hosts. We also treat a tap that arrives with the viewport
    // already well below the tallest-seen height as "keyboard already open".
    final baseline = _warmupBaselineViewportHeight ?? current;
    final shrinkThreshold = math.max(
      _warmupKeyboardShrinkMinPx,
      baseline * _warmupKeyboardShrinkMinFraction,
    );
    final keyboardOpen = (baseline - current) >= shrinkThreshold ||
        (_maxViewportHeight - current) >= shrinkThreshold;

    if (keyboardOpen) {
      // Hand off only once the shrunk height stops changing, so a multi-stage
      // keyboard animation is fully settled and no resize blurs the editor
      // after focus moves into the iframe.
      final settleHeight = _warmupSettleHeight;
      if (settleHeight == null ||
          (current - settleHeight).abs() > _warmupHeightStableEpsilonPx) {
        _warmupSettleHeight = current;
        _warmupHeightStableSince = now;
        return;
      }
      final stableSince = _warmupHeightStableSince;
      if (stableSince != null &&
          now.difference(stableSince) >= _warmupHeightStableWindow) {
        _completeImeWarmupHandoff(reason: 'keyboard_settled');
      }
      return;
    }

    // Keyboard has not opened yet. The common cause is the tap landing while a
    // previous IME-hide animation was still in flight, so Android dropped the
    // initial showSoftInput. Re-issue it by blur+refocusing the parent input (a
    // plain focus() on the already-active input is a no-op). Throttled so it
    // does not churn; the keyboard is not up here so the blur cannot flicker.
    // Crucially we do NOT hand off until a real shrink is observed (or the
    // max-wait cap fires) — handing off before the viewport actually shrinks is
    // what lets a host's spurious layout resize close the keyboard.
    final input = _imeWarmupInput;
    if (input != null) {
      final lastRefocus = _warmupLastRefocusAt;
      if (lastRefocus == null ||
          now.difference(lastRefocus) >= _warmupRefocusInterval) {
        _warmupLastRefocusAt = now;
        // The input may live in the parent/top document, so check focus against
        // its own owner document rather than ours.
        if (identical(input.ownerDocument?.activeElement, input)) {
          input.blur();
        }
        input.focus();
      }
    }
  }

  /// Current absolute viewport height in CSS px. Prefers `visualViewport`
  /// (tracks the soft keyboard) and falls back to `window.innerHeight`.
  double _currentViewportHeight() {
    final vv = web.window.visualViewport;
    if (vv != null) {
      return vv.height;
    }
    return web.window.innerHeight.toDouble();
  }

  void _completeImeWarmupHandoff({required String reason}) {
    _warmupSettleTimer?.cancel();
    _warmupSettleTimer = null;
    if (!_warmupHandoffPending) return;
    _warmupHandoffPending = false;

    final tapIndex = _warmupTapIndex;
    _warmupTapIndex = null;
    _warmupStartedAt = null;
    _warmupBaselineViewportHeight = null;
    _warmupSettleHeight = null;
    _warmupHeightStableSince = null;

    if (!mounted || _quill == null) return;

    _traceFocus('warmup_handoff_complete', {
      'reason': reason,
      'tapIndex': tapIndex,
      'iframeActiveTag':
          _iframe.contentDocument?.activeElement?.tagName ?? 'null',
    });

    // Guard the settling window: the WebView may report `<body>` as the active
    // element for a few frames after `quill.focus()`, and we must not let that
    // transient state trigger a Flutter focus steal.
    _warmupHandoffGuardUntil = DateTime.now().add(_warmupHandoffGuardWindow);

    // Transfer focus from the hidden input to Quill. The keyboard is already
    // open and no resize is in flight, so this editable->editable move keeps the
    // IME up instead of hiding/re-showing it.
    _focusQuillFromTap(tapIndex);
  }

  void _cancelImeWarmupHandoff() {
    _warmupSettleTimer?.cancel();
    _warmupSettleTimer = null;
    _warmupHandoffPending = false;
    _warmupTapIndex = null;
    _warmupStartedAt = null;
    _warmupLastRefocusAt = null;
    _warmupBaselineViewportHeight = null;
    _warmupSettleHeight = null;
    _warmupHeightStableSince = null;
    _warmupHandoffGuardUntil = null;
  }

  /// Decides whether a debounced null-selection event is a genuine blur or a
  /// transient side-effect of a keyboard/viewport resize.
  ///
  /// Under Android WebView `SOFT_INPUT_ADJUST_RESIZE`, the focused editable is
  /// briefly invalidated while the viewport resizes for the keyboard, which
  /// surfaces as `selection-change(null)` even though DOM focus never left the
  /// editor. Closing the keyboard on that event causes the open/close flicker.
  ///
  /// The guard only defers when an explicit blur was not requested, the editor
  /// still holds DOM focus, and we are inside the post-resize transition
  /// window. It is bounded by [_maxNullSelectionRechecks] so a genuine focus
  /// loss can never be suppressed indefinitely.
  void _processNullSelectionFocusLoss() {
    if (!mounted || _isPasteInProgress) return;

    final withinResizeGuard = _withinImeResizeGuard();

    if (!_explicitBlurRequested &&
        withinResizeGuard &&
        _hasDomEditorFocus() &&
        _nullSelectionRecheckCount < _maxNullSelectionRechecks) {
      _nullSelectionRecheckCount++;
      _traceFocus('selection_null_resize_guard', {
        'action': 'defer_close',
        'recheck': _nullSelectionRecheckCount,
        'focusPhase': _focusPhase.name,
      });
      // Re-check once the current resize-guard window elapses. If DOM focus is
      // gone by then (or a non-null selection arrived and cancelled us), the
      // re-check resolves correctly without tearing down on a transient frame.
      _nullSelectionFocusLossTimer = Timer(
        _imeResizeGuardWindow,
        _processNullSelectionFocusLoss,
      );
      return;
    }

    // Genuine blur: DOM focus is gone, an explicit blur was requested, the
    // resize window has elapsed, or we exhausted the bounded re-checks.
    _traceFocus('selection_null_debounce_fired', {
      'action': 'close_keyboard_and_unfocus',
      'recheck': _nullSelectionRecheckCount,
      'domHasFocus': _hasDomEditorFocus(),
    });
    _nullSelectionRecheckCount = 0;
    widget.controller.keyboardHeight.value = 0.0;
    _editorHasFocus = false;
    _onJsFocusChanged(hasFocus: false);
  }

  void _cancelPendingNullSelectionFocusLoss() {
    _nullSelectionFocusLossTimer?.cancel();
    _nullSelectionFocusLossTimer = null;
    _nullSelectionRecheckCount = 0;
  }

  void _refreshKeyboardHeightFromViewport() {
    final vv = web.window.visualViewport;
    if (vv == null) return;

    final layoutHeight = web.window.innerHeight.toDouble();
    final currentVisibleBottom = vv.height + vv.offsetTop;
    final kbByHeight = math.max(0.0, layoutHeight - vv.height);
    final kbByVisibleBottom = math.max(
      0.0,
      layoutHeight - currentVisibleBottom,
    );

    // Use Flutter's own layout height as the reference. This avoids
    // double-handling when a native container (e.g. WKWebView) resizes for
    // the keyboard: if Flutter has already shrunk its layout to match,
    // flutterHeight equals vv.height and kb stays 0. If Flutter hasn't
    // resized (e.g. regular Safari), flutterHeight remains large and
    // the difference correctly measures the keyboard.
    final flutterHeight = MediaQuery.sizeOf(context).height;
    final kbByFlutter = math.max(0.0, flutterHeight - vv.height);

    final kb = math.max(kbByHeight, math.max(kbByVisibleBottom, kbByFlutter));
    final hasFocusIntent =
        _editorHasFocus || (widget.focusNode?.hasFocus ?? false);

    // During acquisition, transient focus oscillations can happen before JS and
    // Flutter focus ownership converge. Do not force-close on those frames.
    if (!hasFocusIntent && _shouldSuppressUnfocusDuringAcquisition()) {
      if (_isAcquisitionExpired()) {
        _cancelAcquisition(reason: 'viewport_no_focus_timeout');
      }
      return;
    }

    // When editor is not focused, always treat keyboard as closed.
    if (!hasFocusIntent) {
      _lowKeyboardFramesWhileFocused = 0;
      widget.controller.keyboardHeight.value = 0.0;
      return;
    }

    if (_focusPhase == _FocusPhase.acquiring) {
      if (_isAcquisitionExpired()) {
        _cancelAcquisition(reason: 'viewport_timeout');
      }

      // During acquisition, low keyboard samples are treated as transient and
      // must not close the keyboard path.
      if (kb > _keyboardOpenThresholdPx) {
        _lowKeyboardFramesWhileFocused = 0;
        _stableKeyboardFramesDuringAcquisition++;
        widget.controller.keyboardHeight.value = kb;
        _scheduleEnsureSelectionVisible(const Duration(milliseconds: 24));
        if (_hasObservedStableSelectionDuringAcquisition &&
            _stableKeyboardFramesDuringAcquisition >= 2) {
          _setPhaseStableIfAcquiring(reason: 'keyboard_stable_during_acquire');
        }
      } else if (_hasObservedStableSelectionDuringAcquisition &&
          _hasDomEditorFocus() &&
          _isKeyboardLikelyOpen()) {
        // Some in-app browsers report kb=0 while the viewport still shrinks.
        _stableKeyboardFramesDuringAcquisition++;
        if (_stableKeyboardFramesDuringAcquisition >= 2) {
          _setPhaseStableIfAcquiring(
            reason: 'viewport_shrink_stable_during_acquire',
          );
        }
      } else {
        _stableKeyboardFramesDuringAcquisition = 0;
      }
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
  _FocusPhase _focusPhase = _FocusPhase.idle;
  DateTime? _acquisitionStartedAt;
  int _acquisitionCycle = 0;
  bool _hasObservedStableSelectionDuringAcquisition = false;
  int _stableKeyboardFramesDuringAcquisition = 0;
  int _nullSelectionEventsDuringAcquisition = 0;
  int _jsFocusLossEventsDuringAcquisition = 0;
  int _reacquireAttemptsDuringAcquisition = 0;

  /// True while [controller.focus] is running. Iframe DOM focus can make the
  /// wrapping [FocusNode] briefly report `hasFocus=false`; ignore that blur.
  bool _isApplyingFocusToJs = false;

  bool _flutterFocusSyncToJsScheduled = false;

  /// Queued JS→Flutter sync when blocked by [_isSyncingFocus].
  bool? _pendingJsToFlutterFocusSync;
  bool _jsToFlutterFocusSyncScheduled = false;

  static const Duration _domFocusRetryDelay = Duration(milliseconds: 40);
  static const int _domFocusRetryCount = 3;
  static const Duration _maxAcquisitionWindow = Duration(milliseconds: 900);

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
  bool _isImeComposing = false;
  bool _isSelectionGestureActive = false;
  int _lastSelectionLength = 0;
  double? _touchLastClientY;
  bool _touchGestureActive = false;
  _TouchScrollOwner _touchScrollOwner = _TouchScrollOwner.undecided;
  double _touchGestureDistancePx = 0.0;
  double _pendingOuterTouchDelta = 0.0;
  int? _touchOuterFlushRafId;
  int _outerTouchDeltaDirection = 0;

  // Velocity tracking for touch fling (outer scroll momentum after lift)
  final List<(double timestampMs, double clientY)> _touchVelocitySamples = [];
  static const int _maxVelocitySamples = 5;
  static const double _flingVelocityThreshold = 50.0; // px/s

  // Fling animation state
  Ticker? _outerFlingTicker;
  ClampingScrollSimulation? _outerFlingSimulation;
  double _outerFlingLastPosition = 0.0;
  DateTime? _ignoreTapOutsideUntil;
  bool _pendingEmptyTouchTapFocus = false;
  (double, double)? _pendingEmptyTouchTapPoint;

  static const String _bundledQuillJsAsset =
      'packages/flutter_quill/assets/js/quill.min.js';
  static Future<String>? _quillJsSourceFuture;
  String? _quillJsSource;

  static const double _touchHandoffDecisionThresholdPx = 10.0;
  static const double _touchBoundaryHysteresisPx = 8.0;
  static const double _touchOuterDeltaMinPx = 0.75;
  static const double _touchOuterDirectionFlipGuardPx = 2.0;
  static const double _touchOuterPendingDropOnFlipPx = 3.0;
  static const double _touchOuterEndFlushMinPx = 1.0;
  static const double _emptyTapFocusSlopPx = 8.0;
  static const Duration _tapOutsideIgnoreAfterIntercept = Duration(
    milliseconds: 350,
  );
  Timer? _acquisitionStableFromSelectionTimer;
  static const Duration _acquisitionSelectionSettleWindow = Duration(
    milliseconds: 280,
  );

  static const List<int> _acquisitionReacquireDelaysMs = <int>[
    0,
    32,
    72,
    140,
    240,
    380,
    560,
    760,
    980,
  ];
  bool _explicitBlurRequested = false;
  DateTime? _suppressEditorRefocusUntil;

  bool _isWithinExplicitBlurGuard() {
    final until = _suppressEditorRefocusUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  void _clearExplicitBlurGuard({required String reason}) {
    if (_suppressEditorRefocusUntil == null) return;
    _traceFocus('explicit_blur_guard_cleared', {'reason': reason});
    _suppressEditorRefocusUntil = null;
  }

  void _cancelAcquisitionStableFromSelectionSchedule() {
    _acquisitionStableFromSelectionTimer?.cancel();
    _acquisitionStableFromSelectionTimer = null;
  }

  /// Promotes acquisition to stable when selection + DOM focus hold, for hosts
  /// where [keyboardHeight] stays 0 even though the keyboard is open.
  void _scheduleAcquisitionStableFromSelection() {
    if (_focusPhase != _FocusPhase.acquiring) return;
    _acquisitionStableFromSelectionTimer?.cancel();
    _acquisitionStableFromSelectionTimer = Timer(
      _acquisitionSelectionSettleWindow,
      () {
        _acquisitionStableFromSelectionTimer = null;
        if (!mounted) return;
        if (_focusPhase != _FocusPhase.acquiring) return;
        if (!_hasObservedStableSelectionDuringAcquisition) return;
        if (!_hasDomEditorFocus()) return;
        if (_explicitBlurRequested) return;
        if (_stableKeyboardFramesDuringAcquisition >= 2) return;
        _setPhaseStableIfAcquiring(
          reason: _isKeyboardLikelyOpen()
              ? 'selection_with_viewport_shrink'
              : 'selection_dom_stable_settle',
        );
      },
    );
  }

  void _setFocusPhase(_FocusPhase phase) {
    _focusPhase = phase;
  }

  void _beginAcquisition({required String reason}) {
    if (_focusPhase == _FocusPhase.acquiring && !_isAcquisitionExpired()) {
      return;
    }
    _acquisitionCycle++;
    _acquisitionStartedAt = DateTime.now();
    _hasObservedStableSelectionDuringAcquisition = false;
    _stableKeyboardFramesDuringAcquisition = 0;
    _nullSelectionEventsDuringAcquisition = 0;
    _jsFocusLossEventsDuringAcquisition = 0;
    _reacquireAttemptsDuringAcquisition = 0;
    _explicitBlurRequested = false;
    _setFocusPhase(_FocusPhase.acquiring);
    _scheduleAcquisitionKeepAliveReacquire();
    assert(() {
      debugPrint('QuillJsEditorView: acquiring started ($reason)');
      return true;
    }());
  }

  void _scheduleAcquisitionKeepAliveReacquire() {
    final cycle = _acquisitionCycle;
    for (final delayMs in _acquisitionReacquireDelaysMs) {
      Future<void>.delayed(Duration(milliseconds: delayMs), () {
        if (!mounted) return;
        if (_acquisitionCycle != cycle) return;
        if (_focusPhase != _FocusPhase.acquiring) return;
        if (_isAcquisitionExpired()) {
          _cancelAcquisition(reason: 'keepalive_timeout');
          return;
        }
        _attemptAcquisitionFocusReacquire(trigger: 'keepalive');
      });
    }
  }

  void _markStableSelectionObserved() {
    _hasObservedStableSelectionDuringAcquisition = true;
  }

  bool _isAcquisitionExpired() {
    final startedAt = _acquisitionStartedAt;
    if (startedAt == null) return false;
    return DateTime.now().difference(startedAt) > _maxAcquisitionWindow;
  }

  void _setPhaseStableIfAcquiring({required String reason}) {
    if (_focusPhase != _FocusPhase.acquiring) return;
    _cancelAcquisitionStableFromSelectionSchedule();
    final hadStableSelection = _hasObservedStableSelectionDuringAcquisition;
    final stableKeyboardFrames = _stableKeyboardFramesDuringAcquisition;
    final nullSelections = _nullSelectionEventsDuringAcquisition;
    final jsFocusLosses = _jsFocusLossEventsDuringAcquisition;
    final reacquireAttempts = _reacquireAttemptsDuringAcquisition;
    _setFocusPhase(_FocusPhase.stable);
    _acquisitionStartedAt = null;
    _stableKeyboardFramesDuringAcquisition = 0;
    _nullSelectionEventsDuringAcquisition = 0;
    _jsFocusLossEventsDuringAcquisition = 0;
    _reacquireAttemptsDuringAcquisition = 0;
    _traceFocus('acquisition_summary', {
      'cycle': _acquisitionCycle,
      'result': 'stable',
      'reason': reason,
      'selectionStableObserved': hadStableSelection,
      'stableKeyboardFrames': stableKeyboardFrames,
      'nullSelectionsDuringAcquire': nullSelections,
      'jsFocusLossDuringAcquire': jsFocusLosses,
      'reacquireAttemptsDuringAcquire': reacquireAttempts,
    });
    assert(() {
      debugPrint(
        'QuillJsEditorView: stable ($reason, '
        'selection=$hadStableSelection, kbFrames=$stableKeyboardFrames)',
      );
      return true;
    }());
  }

  void _cancelAcquisition({required String reason}) {
    if (_focusPhase != _FocusPhase.acquiring) return;
    _cancelAcquisitionStableFromSelectionSchedule();
    final nullSelections = _nullSelectionEventsDuringAcquisition;
    final jsFocusLosses = _jsFocusLossEventsDuringAcquisition;
    final reacquireAttempts = _reacquireAttemptsDuringAcquisition;
    _setFocusPhase(_FocusPhase.idle);
    _acquisitionStartedAt = null;
    _hasObservedStableSelectionDuringAcquisition = false;
    _stableKeyboardFramesDuringAcquisition = 0;
    _nullSelectionEventsDuringAcquisition = 0;
    _jsFocusLossEventsDuringAcquisition = 0;
    _reacquireAttemptsDuringAcquisition = 0;
    _traceFocus('acquisition_summary', {
      'cycle': _acquisitionCycle,
      'result': 'canceled',
      'reason': reason,
      'nullSelectionsDuringAcquire': nullSelections,
      'jsFocusLossDuringAcquire': jsFocusLosses,
      'reacquireAttemptsDuringAcquire': reacquireAttempts,
    });
    assert(() {
      debugPrint('QuillJsEditorView: acquiring canceled ($reason)');
      return true;
    }());
  }

  void _resetFocusPhaseState() {
    _cancelAcquisitionStableFromSelectionSchedule();
    _setFocusPhase(_FocusPhase.idle);
    _acquisitionStartedAt = null;
    _hasObservedStableSelectionDuringAcquisition = false;
    _stableKeyboardFramesDuringAcquisition = 0;
    _explicitBlurRequested = false;
    _domFocusRetainCount = 0;
    _domFocusRetainWindowStart = null;
    _cancelImeWarmupHandoff();
  }

  bool _shouldSuppressUnfocusDuringAcquisition() {
    return _focusPhase == _FocusPhase.acquiring && !_explicitBlurRequested;
  }

  bool _shouldSuppressOuterHandoffDuringAcquisition() {
    return _focusPhase == _FocusPhase.acquiring;
  }

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  @override
  void initState() {
    super.initState();
    _contentForAutoResize =
        widget.configuration.initialContent ?? (Delta()..insert('\n'));

    _viewType = 'quill-js-editor-${_nextId++}';

    _iframe = web.document.createElement('iframe') as web.HTMLIFrameElement
      ..style.setProperty('width', '100%')
      ..style.setProperty('height', '100%')
      ..style.setProperty('border', 'none');

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
    _loadQuillJsAndBuildSrcdoc();
  }

  Future<void> _loadQuillJsAndBuildSrcdoc() async {
    final externalUrl = widget.configuration.quillJsUrl;
    if (externalUrl != null) {
      final response = await web.window.fetch(externalUrl.toJS).toDart;
      _quillJsSource = (await response.text().toDart).toDart;
    } else {
      _quillJsSourceFuture ??= rootBundle.loadString(_bundledQuillJsAsset);
      _quillJsSource = await _quillJsSourceFuture!;
    }
    if (!mounted) return;
    _iframe.setAttribute('srcdoc', _buildSrcdoc());
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
      _pendingJsToFlutterFocusSync = null;
      _flutterFocusSyncToJsScheduled = false;
      _jsToFlutterFocusSyncScheduled = false;
      _isApplyingFocusToJs = false;
      _setupFocusBridge();
    }

    if (widget.configuration.initialContent !=
        oldWidget.configuration.initialContent) {
      _contentForAutoResize =
          widget.configuration.initialContent ?? (Delta()..insert('\n'));
    }

    if (_loadState == _LoadState.ready &&
        _quill != null &&
        widget.configuration.placeholder !=
            oldWidget.configuration.placeholder) {
      _syncQuillPlaceholderDataAttribute();
    }
  }

  /// Quill only reads the placeholder at construction; keep `data-placeholder`
  /// in sync for `.ql-blank::before { content: attr(data-placeholder) }`.
  void _syncQuillPlaceholderDataAttribute() {
    final doc = _iframe.contentDocument;
    if (doc == null) return;
    final editor = doc.querySelector('.ql-editor') as web.HTMLElement?;
    if (editor == null) return;
    final p = widget.configuration.placeholder;
    if (p == null || p.isEmpty) {
      editor.removeAttribute('data-placeholder');
    } else {
      editor.setAttribute('data-placeholder', p);
    }
  }

  @override
  void dispose() {
    _cancelAcquisitionStableFromSelectionSchedule();
    _pendingJsToFlutterFocusSync = null;
    _flutterFocusSyncToJsScheduled = false;
    _jsToFlutterFocusSyncScheduled = false;
    _isApplyingFocusToJs = false;
    _teardownFocusBridge();
    _detachController();
    _cancelOuterFlushRaf();

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
      if (_shiftTabKeyHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'keydown',
          _shiftTabKeyHandlerJs,
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
      if (_tapFocusTouchEndHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'touchend',
          _tapFocusTouchEndHandlerJs,
          true.toJS,
        );
      }
      if (_tapFocusTouchCancelHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'touchcancel',
          _tapFocusTouchCancelHandlerJs,
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
      if (_tapFocusPointerUpHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'pointerup',
          _tapFocusPointerUpHandlerJs,
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
      if (_outerScrollWheelHandlerJs != null) {
        _editorDiv!.removeEventListener('wheel', _outerScrollWheelHandlerJs);
      }
      if (_outerScrollTouchStartHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'touchstart',
          _outerScrollTouchStartHandlerJs,
        );
      }
      if (_outerScrollTouchMoveHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'touchmove',
          _outerScrollTouchMoveHandlerJs,
        );
      }
      if (_outerScrollTouchEndHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'touchend',
          _outerScrollTouchEndHandlerJs,
        );
      }
      if (_outerScrollTouchCancelHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'touchcancel',
          _outerScrollTouchCancelHandlerJs,
        );
      }
      if (_outerScrollPointerDownHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'pointerdown',
          _outerScrollPointerDownHandlerJs,
        );
      }
      if (_outerScrollPointerUpHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'pointerup',
          _outerScrollPointerUpHandlerJs,
        );
      }
      if (_outerScrollPointerCancelHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'pointercancel',
          _outerScrollPointerCancelHandlerJs,
        );
      }
      if (_outerScrollCompositionStartHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'compositionstart',
          _outerScrollCompositionStartHandlerJs,
        );
      }
      if (_outerScrollCompositionEndHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'compositionend',
          _outerScrollCompositionEndHandlerJs,
        );
      }
      if (_editorFocusRetentionHandlerJs != null) {
        _editorDiv!.removeEventListener(
          'focusout',
          _editorFocusRetentionHandlerJs,
        );
      }
    }

    _cancelImeWarmupHandoff();
    if (_imeWarmupInput != null) {
      if (_imeWarmupInputBlurHandlerJs != null) {
        _imeWarmupInput!.removeEventListener(
          'input',
          _imeWarmupInputBlurHandlerJs,
        );
      }
      _imeWarmupInput!.remove();
      _imeWarmupInput = null;
    }

    _nullSelectionFocusLossTimer?.cancel();
    _stopOuterFling();
    _cancelOuterFlushRaf();

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
    _resetFocusPhaseState();

    super.dispose();
  }

  // ------------------------------------------------------------------
  // Iframe srcdoc generation
  // ------------------------------------------------------------------

  /// Builds the full HTML document that will be loaded into the iframe via
  /// `srcdoc`. Quill.js is inlined as a `<script>` block to avoid CSP
  /// restrictions on `srcdoc` iframes (e.g. Firefox).
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
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no,interactive-widget=resizes-visual">
$cssLink
<style>
html, body {
  margin: 0;
  padding: 0;
  height: 100%;
  overflow: hidden;
}

/* --- Inlined Quill Snow theme (content-critical subset) --- */
.ql-container {
  box-sizing: border-box;
  font-family: Helvetica, Arial, sans-serif;
  font-size: 13px;
  height: 100%;
  margin: 0;
  position: relative;
}
.ql-container.ql-disabled .ql-tooltip { visibility: hidden; }
.ql-container:not(.ql-disabled) li[data-list=checked] > .ql-ui,
.ql-container:not(.ql-disabled) li[data-list=unchecked] > .ql-ui { cursor: pointer; }
.ql-clipboard {
  left: -100000px;
  height: 1px;
  overflow-y: hidden;
  position: absolute;
  top: 50%;
}
.ql-clipboard p { margin: 0; padding: 0; }
.ql-editor {
  box-sizing: border-box;
  counter-reset: list-0 list-1 list-2 list-3 list-4 list-5 list-6 list-7 list-8 list-9;
  line-height: 1.42;
  height: 100%;
  outline: none;
  overflow-y: auto;
  padding: 8px 16px;
  tab-size: 4;
  -moz-tab-size: 4;
  text-align: left;
  white-space: pre-wrap;
  word-wrap: break-word;
}
.ql-editor > * { cursor: text; }
.ql-editor p, .ql-editor ol, .ql-editor pre,
.ql-editor blockquote, .ql-editor h1, .ql-editor h2,
.ql-editor h3, .ql-editor h4, .ql-editor h5, .ql-editor h6 {
  margin: 0;
  padding: 0;
}
@supports (counter-set: none) {
  .ql-editor p, .ql-editor h1, .ql-editor h2, .ql-editor h3,
  .ql-editor h4, .ql-editor h5, .ql-editor h6 {
    counter-set: list-0 list-1 list-2 list-3 list-4 list-5 list-6 list-7 list-8 list-9;
  }
}
@supports not (counter-set: none) {
  .ql-editor p, .ql-editor h1, .ql-editor h2, .ql-editor h3,
  .ql-editor h4, .ql-editor h5, .ql-editor h6 {
    counter-reset: list-0 list-1 list-2 list-3 list-4 list-5 list-6 list-7 list-8 list-9;
  }
}
.ql-editor table { border-collapse: collapse; }
.ql-editor td { border: 1px solid #000; padding: 2px 5px; }
.ql-editor ol { padding-left: 1.5em; }
.ql-editor li {
  list-style-type: none;
  padding-left: 1.5em;
  position: relative;
}
.ql-editor li > .ql-ui:before {
  display: inline-block;
  margin-left: -1.5em;
  margin-right: .3em;
  text-align: right;
  white-space: nowrap;
  width: 1.2em;
}
.ql-editor li[data-list=checked] > .ql-ui,
.ql-editor li[data-list=unchecked] > .ql-ui { color: #777; }
.ql-editor li[data-list=bullet] > .ql-ui:before { content: '\\2022'; }
.ql-editor li[data-list=checked] > .ql-ui:before { content: '\\2611'; }
.ql-editor li[data-list=unchecked] > .ql-ui:before { content: '\\2610'; }
@supports (counter-set: none) {
  .ql-editor li[data-list] { counter-set: list-1 list-2 list-3 list-4 list-5 list-6 list-7 list-8 list-9; }
}
@supports not (counter-set: none) {
  .ql-editor li[data-list] { counter-reset: list-1 list-2 list-3 list-4 list-5 list-6 list-7 list-8 list-9; }
}
.ql-editor li[data-list=ordered] { counter-increment: list-0; }
.ql-editor li[data-list=ordered] > .ql-ui:before { content: counter(list-0, decimal) '. '; }
.ql-editor li[data-list=ordered].ql-indent-1 { counter-increment: list-1; }
.ql-editor li[data-list=ordered].ql-indent-1 > .ql-ui:before { content: counter(list-1, lower-alpha) '. '; }
@supports (counter-set: none) {
  .ql-editor li[data-list].ql-indent-1 { counter-set: list-2 list-3 list-4 list-5 list-6 list-7 list-8 list-9; }
}
@supports not (counter-set: none) {
  .ql-editor li[data-list].ql-indent-1 { counter-reset: list-2 list-3 list-4 list-5 list-6 list-7 list-8 list-9; }
}
.ql-editor li[data-list=ordered].ql-indent-2 { counter-increment: list-2; }
.ql-editor li[data-list=ordered].ql-indent-2 > .ql-ui:before { content: counter(list-2, lower-roman) '. '; }
@supports (counter-set: none) {
  .ql-editor li[data-list].ql-indent-2 { counter-set: list-3 list-4 list-5 list-6 list-7 list-8 list-9; }
}
@supports not (counter-set: none) {
  .ql-editor li[data-list].ql-indent-2 { counter-reset: list-3 list-4 list-5 list-6 list-7 list-8 list-9; }
}
.ql-editor li[data-list=ordered].ql-indent-3 { counter-increment: list-3; }
.ql-editor li[data-list=ordered].ql-indent-3 > .ql-ui:before { content: counter(list-3, decimal) '. '; }
@supports (counter-set: none) {
  .ql-editor li[data-list].ql-indent-3 { counter-set: list-4 list-5 list-6 list-7 list-8 list-9; }
}
@supports not (counter-set: none) {
  .ql-editor li[data-list].ql-indent-3 { counter-reset: list-4 list-5 list-6 list-7 list-8 list-9; }
}
.ql-editor li[data-list=ordered].ql-indent-4 { counter-increment: list-4; }
.ql-editor li[data-list=ordered].ql-indent-4 > .ql-ui:before { content: counter(list-4, lower-alpha) '. '; }
@supports (counter-set: none) {
  .ql-editor li[data-list].ql-indent-4 { counter-set: list-5 list-6 list-7 list-8 list-9; }
}
@supports not (counter-set: none) {
  .ql-editor li[data-list].ql-indent-4 { counter-reset: list-5 list-6 list-7 list-8 list-9; }
}
.ql-editor li[data-list=ordered].ql-indent-5 { counter-increment: list-5; }
.ql-editor li[data-list=ordered].ql-indent-5 > .ql-ui:before { content: counter(list-5, lower-roman) '. '; }
@supports (counter-set: none) {
  .ql-editor li[data-list].ql-indent-5 { counter-set: list-6 list-7 list-8 list-9; }
}
@supports not (counter-set: none) {
  .ql-editor li[data-list].ql-indent-5 { counter-reset: list-6 list-7 list-8 list-9; }
}
.ql-editor li[data-list=ordered].ql-indent-6 { counter-increment: list-6; }
.ql-editor li[data-list=ordered].ql-indent-6 > .ql-ui:before { content: counter(list-6, decimal) '. '; }
@supports (counter-set: none) {
  .ql-editor li[data-list].ql-indent-6 { counter-set: list-7 list-8 list-9; }
}
@supports not (counter-set: none) {
  .ql-editor li[data-list].ql-indent-6 { counter-reset: list-7 list-8 list-9; }
}
.ql-editor li[data-list=ordered].ql-indent-7 { counter-increment: list-7; }
.ql-editor li[data-list=ordered].ql-indent-7 > .ql-ui:before { content: counter(list-7, lower-alpha) '. '; }
@supports (counter-set: none) {
  .ql-editor li[data-list].ql-indent-7 { counter-set: list-8 list-9; }
}
@supports not (counter-set: none) {
  .ql-editor li[data-list].ql-indent-7 { counter-reset: list-8 list-9; }
}
.ql-editor li[data-list=ordered].ql-indent-8 { counter-increment: list-8; }
.ql-editor li[data-list=ordered].ql-indent-8 > .ql-ui:before { content: counter(list-8, lower-roman) '. '; }
@supports (counter-set: none) {
  .ql-editor li[data-list].ql-indent-8 { counter-set: list-9; }
}
@supports not (counter-set: none) {
  .ql-editor li[data-list].ql-indent-8 { counter-reset: list-9; }
}
.ql-editor li[data-list=ordered].ql-indent-9 { counter-increment: list-9; }
.ql-editor li[data-list=ordered].ql-indent-9 > .ql-ui:before { content: counter(list-9, decimal) '. '; }
.ql-editor .ql-indent-1:not(.ql-direction-rtl) { padding-left: 3em; }
.ql-editor li.ql-indent-1:not(.ql-direction-rtl) { padding-left: 4.5em; }
.ql-editor .ql-indent-1.ql-direction-rtl.ql-align-right { padding-right: 3em; }
.ql-editor li.ql-indent-1.ql-direction-rtl.ql-align-right { padding-right: 4.5em; }
.ql-editor .ql-indent-2:not(.ql-direction-rtl) { padding-left: 6em; }
.ql-editor li.ql-indent-2:not(.ql-direction-rtl) { padding-left: 7.5em; }
.ql-editor .ql-indent-2.ql-direction-rtl.ql-align-right { padding-right: 6em; }
.ql-editor li.ql-indent-2.ql-direction-rtl.ql-align-right { padding-right: 7.5em; }
.ql-editor .ql-indent-3:not(.ql-direction-rtl) { padding-left: 9em; }
.ql-editor li.ql-indent-3:not(.ql-direction-rtl) { padding-left: 10.5em; }
.ql-editor .ql-indent-3.ql-direction-rtl.ql-align-right { padding-right: 9em; }
.ql-editor li.ql-indent-3.ql-direction-rtl.ql-align-right { padding-right: 10.5em; }
.ql-editor .ql-indent-4:not(.ql-direction-rtl) { padding-left: 12em; }
.ql-editor li.ql-indent-4:not(.ql-direction-rtl) { padding-left: 13.5em; }
.ql-editor .ql-indent-4.ql-direction-rtl.ql-align-right { padding-right: 12em; }
.ql-editor li.ql-indent-4.ql-direction-rtl.ql-align-right { padding-right: 13.5em; }
.ql-editor .ql-indent-5:not(.ql-direction-rtl) { padding-left: 15em; }
.ql-editor li.ql-indent-5:not(.ql-direction-rtl) { padding-left: 16.5em; }
.ql-editor .ql-indent-5.ql-direction-rtl.ql-align-right { padding-right: 15em; }
.ql-editor li.ql-indent-5.ql-direction-rtl.ql-align-right { padding-right: 16.5em; }
.ql-editor .ql-indent-6:not(.ql-direction-rtl) { padding-left: 18em; }
.ql-editor li.ql-indent-6:not(.ql-direction-rtl) { padding-left: 19.5em; }
.ql-editor .ql-indent-6.ql-direction-rtl.ql-align-right { padding-right: 18em; }
.ql-editor li.ql-indent-6.ql-direction-rtl.ql-align-right { padding-right: 19.5em; }
.ql-editor .ql-indent-7:not(.ql-direction-rtl) { padding-left: 21em; }
.ql-editor li.ql-indent-7:not(.ql-direction-rtl) { padding-left: 22.5em; }
.ql-editor .ql-indent-7.ql-direction-rtl.ql-align-right { padding-right: 21em; }
.ql-editor li.ql-indent-7.ql-direction-rtl.ql-align-right { padding-right: 22.5em; }
.ql-editor .ql-indent-8:not(.ql-direction-rtl) { padding-left: 24em; }
.ql-editor li.ql-indent-8:not(.ql-direction-rtl) { padding-left: 25.5em; }
.ql-editor .ql-indent-8.ql-direction-rtl.ql-align-right { padding-right: 24em; }
.ql-editor li.ql-indent-8.ql-direction-rtl.ql-align-right { padding-right: 25.5em; }
.ql-editor .ql-indent-9:not(.ql-direction-rtl) { padding-left: 27em; }
.ql-editor li.ql-indent-9:not(.ql-direction-rtl) { padding-left: 28.5em; }
.ql-editor .ql-indent-9.ql-direction-rtl.ql-align-right { padding-right: 27em; }
.ql-editor li.ql-indent-9.ql-direction-rtl.ql-align-right { padding-right: 28.5em; }
.ql-editor li.ql-direction-rtl { padding-right: 1.5em; }
.ql-editor li.ql-direction-rtl > .ql-ui:before {
  margin-left: .3em;
  margin-right: -1.5em;
  text-align: left;
}
.ql-editor table { table-layout: fixed; width: 100%; }
.ql-editor table td { outline: none; }
.ql-editor .ql-code-block-container { font-family: monospace; }
.ql-editor .ql-video { display: block; max-width: 100%; }
.ql-editor .ql-video.ql-align-center { margin: 0 auto; }
.ql-editor .ql-video.ql-align-right { margin: 0 0 0 auto; }
.ql-editor .ql-bg-black { background-color: #000; }
.ql-editor .ql-bg-red { background-color: #e60000; }
.ql-editor .ql-bg-orange { background-color: #f90; }
.ql-editor .ql-bg-yellow { background-color: #ff0; }
.ql-editor .ql-bg-green { background-color: #008a00; }
.ql-editor .ql-bg-blue { background-color: #06c; }
.ql-editor .ql-bg-purple { background-color: #93f; }
.ql-editor .ql-color-white { color: #fff; }
.ql-editor .ql-color-red { color: #e60000; }
.ql-editor .ql-color-orange { color: #f90; }
.ql-editor .ql-color-yellow { color: #ff0; }
.ql-editor .ql-color-green { color: #008a00; }
.ql-editor .ql-color-blue { color: #06c; }
.ql-editor .ql-color-purple { color: #93f; }
.ql-editor .ql-font-serif { font-family: Georgia, Times New Roman, serif; }
.ql-editor .ql-font-monospace { font-family: Monaco, Courier New, monospace; }
.ql-editor .ql-size-small { font-size: .75em; }
.ql-editor .ql-size-large { font-size: 1.5em; }
.ql-editor .ql-size-huge { font-size: 2.5em; }
.ql-editor .ql-direction-rtl { direction: rtl; text-align: inherit; }
.ql-editor .ql-align-center { text-align: center; }
.ql-editor .ql-align-justify { text-align: justify; }
.ql-editor .ql-align-right { text-align: right; }
.ql-editor .ql-ui { position: absolute; }
.ql-editor.ql-blank::before {
  color: rgba(0,0,0,0.6);
  content: attr(data-placeholder);
  font-style: italic;
  left: 15px;
  pointer-events: none;
  position: absolute;
  right: 15px;
}
.ql-snow { box-sizing: border-box; }
.ql-snow * { box-sizing: border-box; }
.ql-snow .ql-hidden { display: none; }
.ql-snow .ql-editor h1 { font-size: 2em; }
.ql-snow .ql-editor h2 { font-size: 1.5em; }
.ql-snow .ql-editor h3 { font-size: 1.17em; }
.ql-snow .ql-editor h4 { font-size: 1em; }
.ql-snow .ql-editor h5 { font-size: .83em; }
.ql-snow .ql-editor h6 { font-size: .67em; }
.ql-snow .ql-editor a { text-decoration: underline; }
.ql-snow .ql-editor blockquote {
  border-left: 4px solid #ccc;
  margin-bottom: 5px;
  margin-top: 5px;
  padding-left: 16px;
}
.ql-snow .ql-editor code,
.ql-snow .ql-editor .ql-code-block-container {
  background-color: #f0f0f0;
  border-radius: 3px;
}
.ql-snow .ql-editor .ql-code-block-container {
  margin-bottom: 5px;
  margin-top: 5px;
  padding: 5px 10px;
}
.ql-snow .ql-editor code { font-size: 85%; padding: 2px 4px; }
.ql-snow .ql-editor .ql-code-block-container {
  background-color: #23241f;
  color: #f8f8f2;
  overflow: visible;
}
.ql-snow .ql-editor img { max-width: 100%; }
.ql-snow a { color: #06c; }
.ql-container.ql-snow { border: 1px solid #ccc; }
.ql-code-block-container { position: relative; }
.ql-code-block-container .ql-ui { right: 5px; top: 5px; }

/* --- Editor overrides (applied after theme) --- */
.ql-container.ql-snow { border: none !important; font-size: 16px; }
.ql-editor {
  padding: 12px 16px;
  min-height: 100%;
  height: 100%;
  box-sizing: border-box;
  overflow-y: auto;
  overscroll-behavior-y: contain;
  -webkit-overflow-scrolling: touch;
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
<script>${_quillJsSource!.replaceAll('</script>', r'<\/script>')}</script>
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
    if (_loadState == _LoadState.ready) return;
    if (_quillJsSource == null) return;

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

      if (widget.autoFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _quill == null) return;
          _traceFocus('autofocus_requested');
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
      _traceFocus('editor_ready_callback');
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
    _setupImeWarmupInput();
    _setupDomFocusRetention();
    _setupLinkClickHandler();
    _setupEnterKeyHandler();
    _setupEscapeKeyHandler();
    if (config.onShiftTabPressed != null) {
      _setupShiftTabKeyHandler();
    }
    _setupClipboardInterceptors();
    _setupOuterScrollHandoff();

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
      _scheduleFlutterFocusSyncToJs();
    }
  }

  void _teardownFocusBridge() {
    widget.focusNode?.removeListener(_onFlutterFocusChanged);
  }

  /// Flutter [FocusNode] changed -> sync to JS editor (post-frame).
  ///
  /// DOM focus/blur must not run synchronously inside [FocusNode] listener
  /// callbacks — that re-enters [FocusManager.applyFocusChangesIfNeeded].
  void _onFlutterFocusChanged() {
    final node = widget.focusNode;
    if (node == null) return;

    _traceFocus('flutter_focus_listener', {
      'hasFocus': node.hasFocus,
      'hasPrimaryFocus': node.hasPrimaryFocus,
      'canRequestFocus': node.canRequestFocus,
    });
    _scheduleFlutterFocusSyncToJs();
  }

  void _scheduleFlutterFocusSyncToJs() {
    if (_flutterFocusSyncToJsScheduled) return;
    _flutterFocusSyncToJsScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flutterFocusSyncToJsScheduled = false;
      if (!mounted) return;
      _applyFlutterFocusSyncToJs();
    });
  }

  void _applyFlutterFocusSyncToJs() {
    final node = widget.focusNode;
    if (node == null) return;

    // While the warm-up input is holding the keyboard open ahead of the
    // handoff, do not let Flutter focus changes touch the iframe. Focusing the
    // hidden parent input makes the FocusNode report focus, which would
    // otherwise pull focus into the iframe mid-resize and blur it — exactly the
    // race the warm-up exists to avoid. The handoff focuses Quill itself.
    if (_warmupHandoffPending) {
      _traceFocus('flutter_focus_sync_skipped_warmup', {
        'hasFocus': node.hasFocus,
      });
      return;
    }

    if (!node.hasFocus) {
      // In some Android WebView containers, Flutter focus can transiently drop
      // during cold acquisition while DOM focus is still active. Blurring JS
      // here tears down IME and causes keyboard open/close churn.
      if (!_explicitBlurRequested && _hasDomEditorFocus()) {
        _traceFocus('flutter_blur_ignored_dom_still_focused', {
          'focusPhase': _focusPhase.name,
        });
        // Do NOT re-assert Flutter focus while the JS editor owns DOM focus
        // during acquisition / IME resize: requestFocus() would steal DOM
        // focus from the iframe and close the keyboard, starting a flicker
        // loop. DOM focus is authoritative here; leave it untouched.
        if (!_shouldPreserveDomFocusOverFlutter()) {
          // Desktop DOM-first mouse focus can ping-pong if we keep re-queuing
          // Flutter requestFocus() while the editor already owns DOM focus.
          // Mobile/WebView transient Flutter drops during IME resize must keep
          // the existing re-queue path.
          if (!_isSoftKeyboardContext() && _editorHasFocus) {
            _traceFocus('flutter_blur_sync_skipped_desktop_dom_owns', {
              'focusPhase': _focusPhase.name,
            });
          } else {
            _queueJsToFlutterFocusSync(true);
          }
        }
        return;
      }
      if (_isApplyingFocusToJs) {
        return;
      }
      if (_shouldSuppressUnfocusDuringAcquisition()) {
        return;
      }
      // On Android, context-menu paste briefly removes platform-view focus
      // before the paste event arrives. Don't tear down keyboard state
      // while a paste operation is in flight.
      if (_isPasteInProgress) {
        return;
      }
      _pendingDomFocusSync = false;
      _focusSyncEpoch++;
      _traceFocus('flutter_to_js_blur', {'reason': 'flutter_focus_lost'});
      widget.controller.keyboardHeight.value = 0.0;
      if (!widget.controller.isAttached) {
        return;
      }
      _blurJsEditor();
      return;
    }

    _syncDomFocusOwnership(force: true);
  }

  void _focusJsEditor() {
    // Never focus the iframe editor while the warm-up input owns the keyboard;
    // the handoff is the only path allowed to move focus into the iframe.
    if (_warmupHandoffPending) {
      _traceFocus('js_focus_requested_skipped_warmup', {});
      return;
    }
    _traceFocus('js_focus_requested', {'via': 'focus_bridge'});
    _isApplyingFocusToJs = true;
    try {
      _withFocusSyncGuard(widget.controller.focus);
    } finally {
      _isApplyingFocusToJs = false;
      _flushPendingJsToFlutterFocusSync();
    }
  }

  void _blurJsEditor() {
    _traceFocus('js_blur_requested', {'via': 'focus_bridge'});
    _withFocusSyncGuard(widget.controller.blur);
  }

  void _syncDomFocusOwnership({bool force = false}) {
    if (!mounted) return;
    final node = widget.focusNode;
    if (node == null) return;

    if (!node.hasFocus) {
      return;
    }

    if (!widget.controller.isAttached) {
      if (force) _pendingDomFocusSync = true;
      return;
    }

    if (_hasDomEditorFocus()) {
      _pendingDomFocusSync = false;
      return;
    }

    final epoch = ++_focusSyncEpoch;
    _pendingDomFocusSync = false;
    _focusJsEditor();

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
    if (epoch != _focusSyncEpoch) {
      return;
    }
    final node = widget.focusNode;
    if (node == null || !node.hasFocus) {
      return;
    }
    if (!widget.controller.isAttached) {
      return;
    }
    if (_hasDomEditorFocus()) {
      return;
    }
    _focusJsEditor();
  }

  /// Blurs the JS editor and proactively mirrors blur to Flutter focus.
  ///
  /// In some iframe/browser paths Quill's `selection-change(null)` can be
  /// dropped, leaving Flutter focused while DOM focus is already gone. That
  /// stale state prevents a later `requestFocus()` from emitting a new focus
  /// change event. We sync Flutter focus eagerly to keep both sides aligned.
  void _blurEditorAndSyncFlutterFocus() {
    _cancelImeWarmupHandoff();
    _setFocusPhase(_FocusPhase.blurring);
    final explicitBlurRequested = _explicitBlurRequested;
    assert(() {
      debugPrint(
        'QuillJsEditorView: blur start (explicit=$explicitBlurRequested)',
      );
      return true;
    }());
    final quill = _quill;
    if (quill == null) {
      _setFocusPhase(_FocusPhase.idle);
      _explicitBlurRequested = false;
      return;
    }
    quill.blur();
    _editorHasFocus = false;
    _onJsFocusChanged(hasFocus: false);
    _setFocusPhase(_FocusPhase.idle);
    _explicitBlurRequested = false;
  }

  void _withFocusSyncGuard(VoidCallback action) {
    if (_isSyncingFocus) {
      return;
    }
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

  void _attemptAcquisitionFocusReacquire({required String trigger}) {
    // While the warm-up input holds focus to keep the keyboard open, never pull
    // focus onto the contenteditable: that is exactly the resize-racing focus
    // the warm-up exists to avoid. The handoff transfers focus once settled.
    if (_warmupHandoffPending) {
      _traceFocus('acquisition_reacquire_skipped_warmup', {'trigger': trigger});
      return;
    }
    // Just after handoff, DOM focus is settling onto the editor. Don't fight it
    // with Flutter requestFocus(); the focusout retention handler keeps the
    // editor focused if anything knocks it to <body>.
    if (_withinWarmupHandoffGuard()) {
      _traceFocus('acquisition_reacquire_skipped_handoff_guard', {
        'trigger': trigger,
      });
      return;
    }
    if (!_shouldSuppressUnfocusDuringAcquisition()) return;
    if (_loadState != _LoadState.ready) return;
    if (!widget.controller.isAttached) return;
    if (_hasDomEditorFocus()) return;

    // During an in-flight viewport resize, do not fight for focus on a timer:
    // the synchronous focusout retention handler is responsible for holding DOM
    // focus, and re-opening the editor here would re-trigger the
    // keyboard -> resize -> blur loop that produced the open/close flicker.
    if (_withinImeResizeGuard()) {
      _traceFocus('acquisition_reacquire_skipped_resize', {
        'trigger': trigger,
        'focusPhase': _focusPhase.name,
      });
      return;
    }

    final node = widget.focusNode;
    if (node != null && !node.hasFocus) {
      // During acquisition, Flutter focus can transiently drop before DOM focus
      // settles in WebView. Re-request focus to preserve editor focus intent.
      node.requestFocus();
    }

    _reacquireAttemptsDuringAcquisition++;
    _traceFocus('acquisition_reacquire_focus', {
      'trigger': trigger,
      'focusPhase': _focusPhase.name,
      'editorHasFocus': _editorHasFocus,
      'flutterHasFocus': node?.hasFocus,
      'reacquireAttemptsDuringAcquire': _reacquireAttemptsDuringAcquisition,
    });
    _focusJsEditor();
    _refreshKeyboardHeightFromViewport();
    _scheduleKeyboardSettleRetries();
  }

  /// JS editor focus changed -> sync to Flutter [FocusNode].
  void _onJsFocusChanged({required bool hasFocus}) {
    final node = widget.focusNode;
    if (node == null) return;
    _traceFocus('js_focus_changed', {
      'hasFocus': hasFocus,
      'focusPhase': _focusPhase.name,
      'flutterHasFocus': node.hasFocus,
      'editorHasFocus': _editorHasFocus,
    });
    if (!hasFocus && _shouldSuppressUnfocusDuringAcquisition()) {
      _jsFocusLossEventsDuringAcquisition++;
      _attemptAcquisitionFocusReacquire(trigger: 'js_focus_lost');
      return;
    }

    if (_isSyncingFocus || _isApplyingFocusToJs) {
      _queueJsToFlutterFocusSync(hasFocus);
      return;
    }

    _applyJsToFlutterFocusSync(hasFocus);
  }

  void _queueJsToFlutterFocusSync(bool jsHasFocus) {
    final node = widget.focusNode;
    if (node == null) return;

    if (jsHasFocus && !node.hasFocus) {
      _pendingJsToFlutterFocusSync = true;
    } else if (!jsHasFocus && node.hasFocus) {
      _pendingJsToFlutterFocusSync = false;
    } else {
      return;
    }
    _scheduleJsToFlutterFocusSyncFlush();
  }

  void _scheduleJsToFlutterFocusSyncFlush() {
    if (_jsToFlutterFocusSyncScheduled) return;
    _jsToFlutterFocusSyncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jsToFlutterFocusSyncScheduled = false;
      _flushPendingJsToFlutterFocusSync();
    });
  }

  void _flushPendingJsToFlutterFocusSync() {
    if (!mounted) return;
    if (_isSyncingFocus || _isApplyingFocusToJs) {
      _scheduleJsToFlutterFocusSyncFlush();
      return;
    }

    final pending = _pendingJsToFlutterFocusSync;
    if (pending == null) return;
    _pendingJsToFlutterFocusSync = null;

    final node = widget.focusNode;
    if (node == null) return;

    if (pending && !node.hasFocus) {
      _applyJsToFlutterFocusSync(true);
    } else if (!pending && node.hasFocus) {
      _applyJsToFlutterFocusSync(false);
    }
  }

  void _applyJsToFlutterFocusSync(bool jsHasFocus) {
    final node = widget.focusNode;
    if (node == null || _isSyncingFocus || _isApplyingFocusToJs) {
      _queueJsToFlutterFocusSync(jsHasFocus);
      return;
    }
    if (jsHasFocus && _isWithinExplicitBlurGuard()) {
      _traceFocus('js_focus_sync_suppressed_explicit_blur_guard');
      return;
    }
    if (!jsHasFocus && _shouldSuppressUnfocusDuringAcquisition()) {
      return;
    }
    // Resize guard: a JS focus-loss reported while the editor still holds DOM
    // focus during the IME/viewport transition is a transient WebView artifact,
    // not a real blur. Ignore it without tearing down. We intentionally do NOT
    // re-queue an upward focus sync here, because that would lead to a
    // requestFocus() that steals DOM focus and closes the keyboard.
    if (!jsHasFocus &&
        !_explicitBlurRequested &&
        _withinImeResizeGuard() &&
        _hasDomEditorFocus()) {
      _traceFocus('js_blur_ignored_resize_guard', {
        'focusPhase': _focusPhase.name,
      });
      _editorHasFocus = true;
      return;
    }
    // Never steal DOM focus from the iframe while it is authoritative: calling
    // requestFocus() on the Flutter side here moves browser focus to the glass
    // pane and closes the WebView IME, triggering a reacquire/steal flicker.
    if (jsHasFocus && !node.hasFocus && _shouldPreserveDomFocusOverFlutter()) {
      _traceFocus('flutter_request_focus_skipped_dom_owns', {
        'focusPhase': _focusPhase.name,
      });
      _editorHasFocus = true;
      return;
    }

    _isSyncingFocus = true;
    try {
      if (jsHasFocus && !node.hasFocus) {
        _traceFocus('flutter_request_focus_from_js');
        node.requestFocus();
      } else if (!jsHasFocus && node.hasFocus) {
        _traceFocus('flutter_unfocus_from_js');
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
        _lastViewportResizeAt = DateTime.now();
        final height = vv.height;
        if (height > _maxViewportHeight) {
          _maxViewportHeight = height;
        }
        _refreshKeyboardHeightFromViewport();
      }).toJS;
      vv.addEventListener('resize', _viewportResizeHandlerJs);
      // Seed the "no keyboard" reference immediately so the first warm-up tap
      // has a sane tallest-height baseline even before any resize fires.
      if (vv.height > _maxViewportHeight) {
        _maxViewportHeight = vv.height;
      }
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
    _traceFocus('selection_change', {
      'isNull': range == null,
      'source': source,
      'focusPhase': _focusPhase.name,
      'editorHasFocus': _editorHasFocus,
      'flutterHasFocus': widget.focusNode?.hasFocus,
    });
    if (range == null) {
      _lastSelectionLength = 0;
      _isSelectionGestureActive = false;
      if (_shouldSuppressUnfocusDuringAcquisition()) {
        _nullSelectionEventsDuringAcquisition++;
        if (_isAcquisitionExpired()) {
          _cancelAcquisition(reason: 'selection_null_timeout');
        } else {
          _attemptAcquisitionFocusReacquire(trigger: 'selection_null');
        }
        return;
      }
      if (_focusPhase == _FocusPhase.acquiring && _isAcquisitionExpired()) {
        _cancelAcquisition(reason: 'selection_null_timeout');
      }
      _scheduleNullSelectionFocusLoss();
      return;
    }

    // A valid range arrived — cancel any pending debounced focus loss.
    _cancelPendingNullSelectionFocusLoss();
    _markStableSelectionObserved();
    if (_focusPhase == _FocusPhase.acquiring) {
      _scheduleAcquisitionStableFromSelection();
    }

    final jsRange = _JsRange._(range);
    _lastSelectionLength = jsRange.length;

    // While a link action sheet/dialog is active, Quill can emit non-user
    // selection updates that would incorrectly re-focus the editor on mobile.
    if (_isHandlingLinkTapAction && source != 'user') {
      _editorHasFocus = false;
      _refreshKeyboardHeightFromViewport();
      _scheduleKeyboardRefreshRetries();
      return;
    }

    final wasFocused = _editorHasFocus;
    if (_isWithinExplicitBlurGuard()) {
      // Allow user-driven caret moves to refocus the editor; only block
      // programmatic api/silent selection updates that steal focus back after
      // an explicit tap-outside (e.g. subject click).
      if (source != 'user') {
        _traceFocus('selection_change_suppressed_explicit_blur_guard', {
          'source': source,
        });
        return;
      }
      _clearExplicitBlurGuard(reason: 'selection_user');
    }
    _editorHasFocus = true;
    _onJsFocusChanged(hasFocus: true);
    _refreshKeyboardHeightFromViewport();

    // Track user-originated selection/caret changes (pointer-down, keyboard
    // navigation, explicit range selections). Programmatic changes tagged as
    // 'api' or 'silent' are ignored so they don't poison the guard.
    if (source == 'user') {
      _didUserInteractWithSelection = true;
      if (_touchGestureActive) {
        _isSelectionGestureActive = true;
      }
    }

    // On focus transition (was blurred, now focused), attempt first-focus
    // cursor placement if the feature is enabled.  Also schedule longer-
    // interval keyboard retries: the resize listener may have been registered
    // after the keyboard opened, so we re-read the viewport once it settles.
    if (!wasFocused) {
      _maybeMoveCursorToEndOnFirstFocus();
      _scheduleKeyboardSettleRetries();
    }
    // Do not mark acquisition as stable on the first non-null selection.
    //
    // On Android WebView cold-open paths, Quill can emit:
    //   selection(non-null) -> selection(null)
    // within the same keyboard animation window. Promoting to stable here
    // disables acquisition-time blur suppression too early and allows the
    // transient null to close IME.
    //
    // Acquisition should become stable only after viewport-derived keyboard
    // readings also stabilize (see _refreshKeyboardHeightFromViewport).

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

    _tapFocusTouchEndHandlerJs = ((web.Event event) {
      if (!_pendingEmptyTouchTapFocus) return;
      _completeEmptyTouchTapFocus(event: event);
      event.preventDefault();
      event.stopPropagation();
    }).toJS;

    _tapFocusTouchCancelHandlerJs = ((web.Event _) {
      _pendingEmptyTouchTapFocus = false;
      _pendingEmptyTouchTapPoint = null;
    }).toJS;

    _tapFocusPointerUpHandlerJs = ((web.Event event) {
      if (!_pendingEmptyTouchTapFocus || !_isIOSWeb) return;
      final pointerEvent = event as web.PointerEvent;
      if (pointerEvent.pointerType.toLowerCase() == 'mouse') return;
      _completeEmptyTouchTapFocus(event: event);
      event.preventDefault();
      event.stopPropagation();
    }).toJS;

    _tapFocusPointerDownHandlerJs = ((web.Event event) {
      final pointerEvent = event as web.PointerEvent;
      if (pointerEvent.pointerType.toLowerCase() == 'mouse') {
        // Android WebView + DeX: keep native mouse; warm-up path untouched.
        if (_isAndroidWeb) return;
        // Desktop Flutter web: native mouse is DOM-first into the iframe, which
        // desynchronizes the bridge. Intercept cold/desynced taps only; in-editor
        // caret moves keep native behaviour when already focused.
        if (!_editorHasFocus || !_hasDomEditorFocus()) {
          _interceptTapFocus(event);
        }
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
      'touchend',
      _tapFocusTouchEndHandlerJs!,
      true.toJS,
    );
    editorDiv.addEventListener(
      'touchcancel',
      _tapFocusTouchCancelHandlerJs!,
      true.toJS,
    );
    editorDiv.addEventListener(
      'pointerdown',
      _tapFocusPointerDownHandlerJs!,
      true.toJS,
    );
    editorDiv.addEventListener(
      'pointerup',
      _tapFocusPointerUpHandlerJs!,
      true.toJS,
    );
  }

  /// Finishes an iOS empty-editor tap deferred from [touchstart] to [touchend].
  /// Must run focus before [preventDefault] so user activation is preserved.
  void _completeEmptyTouchTapFocus({web.Event? event}) {
    if (!_pendingEmptyTouchTapFocus) return;
    _pendingEmptyTouchTapFocus = false;

    final clientPoint =
        (event != null ? _extractClientPoint(event) : null) ??
        _pendingEmptyTouchTapPoint;
    _pendingEmptyTouchTapPoint = null;
    final tapIndex = clientPoint == null
        ? null
        : _resolveTapIndex(clientPoint.$1, clientPoint.$2);

    _traceFocus('empty_touch_tap_complete', {
      'eventType': event?.type ?? 'direct',
      'tapIndex': tapIndex,
    });
    _ignoreTapOutsideUntil = DateTime.now().add(
      _tapOutsideIgnoreAfterIntercept,
    );
    _focusEditorFromInterceptedTap(tapIndex);
  }

  void _interceptTapFocus(web.Event event) {
    final quill = _quill;
    final editorDiv = _editorDiv;
    if (quill == null || editorDiv == null) return;
    if (_pendingEmptyTouchTapFocus &&
        event is web.PointerEvent &&
        event.pointerType.toLowerCase() != 'mouse') {
      // iOS defers empty taps to touchend/pointerup; other platforms must not
      // stall here if touchstart already marked the gesture pending.
      if (_isIOSWeb) {
        return;
      }
      _completeEmptyTouchTapFocus(event: event);
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    // Leave the tap to native handling only when the editor is genuinely being
    // edited: it owns focus AND the keyboard is up (an in-place caret move).
    // After a system-button keyboard dismiss the editor keeps DOM focus while
    // the keyboard is down; a native tap on the already-focused contenteditable
    // does not reliably re-open the IME (it flashes open then closes), so that
    // case must fall through and re-open the keyboard via the warm-up path.
    if (_editorHasFocus && _hasDomEditorFocus() && _isKeyboardLikelyOpen()) {
      return;
    }
    if (_editorHasFocus && !_hasDomEditorFocus()) {
      _editorHasFocus = false;
      _onJsFocusChanged(hasFocus: false);
    }

    // Keep existing link-tap behaviour (dialog callback path) untouched.
    if (_findTappedAnchorFromEvent(event, editorDiv) != null) {
      return;
    }

    final clientPoint = _extractClientPoint(event);
    if (clientPoint == null) return;
    final tapIndex = _resolveTapIndex(clientPoint.$1, clientPoint.$2);
    _traceFocus('intercept_tap_focus', {
      'eventType': event.type,
      'tapIndex': tapIndex,
      'editorHasFocus': _editorHasFocus,
      'domHasFocus': _hasDomEditorFocus(),
    });

    // iOS Safari only: defer empty-editor focus from touchstart to touchend so
    // preventDefault does not cancel keyboard open. Every other platform (incl.
    // Android WebView and desktop web) must focus synchronously in this gesture.
    final isEmpty = _isEditorEffectivelyEmpty();
    if (event.type == 'touchstart' &&
        event is web.TouchEvent &&
        isEmpty &&
        _isIOSWeb) {
      _pendingEmptyTouchTapFocus = true;
      _pendingEmptyTouchTapPoint = clientPoint;
      _ignoreTapOutsideUntil = DateTime.now().add(
        _tapOutsideIgnoreAfterIntercept,
      );
      event.preventDefault();
      event.stopPropagation();
      return;
    }

    _pendingEmptyTouchTapFocus = false;
    _pendingEmptyTouchTapPoint = null;

    _ignoreTapOutsideUntil = DateTime.now().add(
      _tapOutsideIgnoreAfterIntercept,
    );
    // Focus before preventDefault so empty contenteditable still receives DOM
    // focus when the browser would otherwise rely on the default click path.
    _focusEditorFromInterceptedTap(tapIndex);
    event.preventDefault();
    event.stopPropagation();
  }

  bool _isEditorEffectivelyEmpty() {
    final quill = _quill;
    if (quill == null) return true;
    final length = quill.getLength();
    // Quill docs always include a terminal newline sentinel.
    return length <= 1;
  }

  bool _hasDomEditorFocus() {
    final doc = _iframe.contentDocument;
    final editor = _quillEditorElement();
    if (doc == null || editor == null) return false;
    final active = doc.activeElement;
    if (active == null) return false;
    if (identical(active, editor)) return true;
    return editor.contains(active);
  }

  double _readDomClientCoord(Object target, String property) {
    try {
      final value = (target as JSObject)[property];
      return switch (value) {
        JSNumber() => value.toDartDouble,
        _ => (value as num).toDouble(),
      };
    } catch (_) {
      // Bracket access can fail on some WebViews; dynamic read handles both
      // int-typed bindings and subpixel doubles from desktop HiDPI layouts.
      final dynamic jsTarget = target;
      final coord = property == 'clientX' ? jsTarget.clientX : jsTarget.clientY;
      return (coord as num).toDouble();
    }
  }

  web.Touch? _firstTouchFromEvent(web.TouchEvent event) {
    final changed = event.changedTouches;
    if (changed.length > 0) {
      final touch = changed.item(0);
      if (touch != null) return touch;
    }
    final active = event.touches;
    if (active.length > 0) {
      return active.item(0);
    }
    return null;
  }

  (double, double)? _extractClientPoint(web.Event event) {
    if (event is web.PointerEvent) {
      return (
        _readDomClientCoord(event, 'clientX'),
        _readDomClientCoord(event, 'clientY'),
      );
    }
    if (event is web.TouchEvent) {
      final touch = _firstTouchFromEvent(event);
      if (touch == null) return null;
      return (
        _readDomClientCoord(touch, 'clientX'),
        _readDomClientCoord(touch, 'clientY'),
      );
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
      try {
        final textLength = node.data.length;
        final localOffset = offset.clamp(0, textLength).toInt();
        return baseIndex + localOffset;
      } catch (_) {
        _traceFocus('resolve_tap_index_text_fallback', {
          'baseIndex': baseIndex,
          'offset': offset,
        });
        return baseIndex;
      }
    }
    return baseIndex;
  }

  void _focusEditorFromInterceptedTap(int? tapIndex) {
    final quill = _quill;
    if (quill == null) return;
    // User is intentionally focusing the editor; do not let a recent tap-outside
    // guard (e.g. after clicking subject) block this acquisition.
    _clearExplicitBlurGuard(reason: 'intercepted_tap');
    _traceFocus('focus_from_intercepted_tap', {'tapIndex': tapIndex});

    // On Android, open the keyboard via a hidden native input first and hand
    // focus to Quill only once the viewport resize has settled, so the cold
    // contenteditable focus never races the keyboard-driven resize.
    if (_shouldUseImeWarmupHandoff()) {
      _beginImeWarmupHandoff(tapIndex);
      return;
    }

    // Desktop: Flutter-first (same as Tab) avoids DOM-first ping-pong that
    // breaks subject re-focus. Mobile: DOM-first + acquisition guards IME.
    _didUserInteractWithSelection = true;
    if (!_isMobileWeb) {
      _focusEditorFlutterFirst(tapIndex);
      return;
    }

    _beginAcquisition(reason: 'intercepted_tap');
    _focusQuillFromTap(tapIndex);
  }

  /// Desktop tap path: request Flutter focus first, then sync into the iframe.
  void _focusEditorFlutterFirst(int? tapIndex) {
    _traceFocus('focus_flutter_first', {'tapIndex': tapIndex});
    final node = widget.focusNode;
    if (node != null && node.canRequestFocus) {
      node.requestFocus();
    }
    _syncDomFocusOwnership(force: true);
    // Empty editors often fail to show a caret when DOM focus is deferred to
    // the next frame; force Quill focus in the same user gesture.
    if (_isEditorEffectivelyEmpty() && _quill != null) {
      _quill!.focus();
      _quillEditorElement()?.focus();
      _editorHasFocus = true;
      _onJsFocusChanged(hasFocus: true);
      _applyTapSelectionAt(tapIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyTapSelectionAt(tapIndex);
    });
  }

  void _applyTapSelectionAt(int? tapIndex) {
    final quill = _quill;
    if (quill == null) return;

    _editorHasFocus = true;
    _refreshKeyboardHeightFromViewport();
    _scheduleKeyboardSettleRetries();

    final fallbackSelection = _getQuillSelection(focus: false);
    final resolvedTapIndex = tapIndex ?? fallbackSelection?.index ?? 0;

    void applySelection() {
      if (!mounted || _quill == null) return;
      if (!_hasDomEditorFocus()) {
        _quillEditorElement()?.focus();
      }
      final length = _quill!.getLength();
      final maxIndex = length > 0 ? length - 1 : 0;
      final clamped = resolvedTapIndex.clamp(0, maxIndex).toInt();
      _quill!.setSelection(clamped, 0);
    }

    applySelection();
    for (var i = 1; i <= 2; i++) {
      Future<void>.delayed(Duration(milliseconds: 16 * i), () {
        applySelection();
        _refreshKeyboardHeightFromViewport();
      });
    }
  }

  /// Focuses Quill and applies the tapped caret selection. Shared by the direct
  /// path and the post-warm-up handoff.
  void _focusQuillFromTap(int? tapIndex) {
    final quill = _quill;
    if (quill == null) return;

    quill.focus();
    // `quill.focus()` sets Quill's selection but the WebView can leave DOM
    // focus on `<body>` for a few frames; force it onto the editor element so
    // `_hasDomEditorFocus()` is true and the JS->Flutter sync does not steal.
    _quillEditorElement()?.focus();
    _editorHasFocus = true;
    _onJsFocusChanged(hasFocus: true);
    _applyTapSelectionAt(tapIndex);
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
        _isPasteInProgress = true;
        _cancelPendingNullSelectionFocusLoss();
        _editorHasFocus = true;

        final clipEvent = event as web.ClipboardEvent;
        final data = clipEvent.clipboardData;
        if (data == null) {
          _isPasteInProgress = false;
          return;
        }

        final plainText = data.getData('text/plain');
        final html = data.getData('text/html');
        final quillDeltaJson = data.getData(kQuillDeltaJsonClipboardMime);
        final plain = plainText.isNotEmpty ? plainText : null;
        final htmlContent = html.isNotEmpty ? html : null;
        final deltaJson = quillDeltaJson.isNotEmpty ? quillDeltaJson : null;

        final pasteDelta =
            _deltaFromClipboardJson(deltaJson) ??
            pasteInterceptor(plain, htmlContent, deltaJson);
        if (pasteDelta == null || pasteDelta.isEmpty) {
          _isPasteInProgress = false;
          return;
        }

        event.preventDefault();
        event.stopPropagation();

        // Read current selection without forcing focus first, so we don't
        // accidentally collapse a non-collapsed range before applying paste.
        var sel = _getQuillSelection();
        sel ??= _getQuillSelection(focus: true);
        final index =
            sel?.index ??
            ((_quill!.getLength() > 1) ? _quill!.getLength() - 1 : 0);
        final selectionLength = sel?.length ?? 0;

        final pasteOps = pasteDelta.toJson() as List;
        final combinedOps = <dynamic>[
          if (index > 0) {'retain': index},
          if (selectionLength > 0) {'delete': selectionLength},
          ...pasteOps,
        ];
        final combined = Delta.fromJson(combinedOps);
        _quill!.updateContents(_deltaToJs(combined), 'api'.toJS);

        final pasteLength = _deltaLength(pasteDelta);
        _quill!.setSelection(index + pasteLength, 0);

        // Re-assert focus after paste and clear the guard. The short
        // delay lets the browser finish processing the DOM mutation
        // before we re-sync Flutter's focus state.
        Future<void>.delayed(const Duration(milliseconds: 16), () {
          _isPasteInProgress = false;
          if (!mounted || _quill == null) return;
          _editorHasFocus = true;
          _onJsFocusChanged(hasFocus: true);
          _refreshKeyboardHeightFromViewport();
        });
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
          if (result.quillDeltaJson != null) {
            data.setData(kQuillDeltaJsonClipboardMime, result.quillDeltaJson!);
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
          if (result.quillDeltaJson != null) {
            data.setData(kQuillDeltaJsonClipboardMime, result.quillDeltaJson!);
          }
        }
        _quill!.deleteText(sel.index, sel.length);
        _quill!.setSelection(sel.index, 0);
      }).toJS;
      editorDiv.addEventListener('cut', _cutHandlerJs!, true.toJS);
    }
  }

  Delta? _deltaFromClipboardJson(String? quillDeltaJson) {
    if (quillDeltaJson == null || quillDeltaJson.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(quillDeltaJson);
      if (decoded is List) {
        final delta = Delta.fromJson(decoded);
        if (!delta.isEmpty) {
          return delta;
        }
      }
    } catch (_) {
      // Fall back to HTML/plain text when clipboard JSON is invalid.
    }
    return null;
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
      if (keyEvent.key != 'Escape' && keyEvent.key != 'Esc') return;
      event.preventDefault();
      event.stopPropagation();

      if (!_editorHasFocus) return;

      _iframe.blur();

      _blurEditorAndSyncFlutterFocus();

      final onEscape = widget.configuration.onEscapePressed;
      if (onEscape != null) {
        scheduleMicrotask(() {
          if (!mounted) return;
          onEscape();
        });
        return;
      }

      final node = widget.focusNode;
      if (node?.context == null) return;
      scheduleMicrotask(() {
        if (!mounted) return;
        node!.requestFocus();
        node.nextFocus();
      });
    }).toJS;

    // Use capture phase to handle escape before Quill/browser defaults.
    _editorDiv!.addEventListener('keydown', _escapeKeyHandlerJs, true.toJS);
  }

  // ------------------------------------------------------------------
  // Shift+Tab handling (optional host-provided previous focus target)
  // ------------------------------------------------------------------

  void _setupShiftTabKeyHandler() {
    _shiftTabKeyHandlerJs = ((web.Event event) {
      final keyEvent = event as web.KeyboardEvent;
      if (keyEvent.key != 'Tab' || !keyEvent.shiftKey) return;

      final onShiftTab = widget.configuration.onShiftTabPressed;
      if (onShiftTab == null) return;

      event.preventDefault();
      event.stopPropagation();

      if (!_editorHasFocus) return;

      _iframe.blur();

      _explicitBlurRequested = true;
      _blurEditorAndSyncFlutterFocus();

      scheduleMicrotask(() {
        if (!mounted) return;
        onShiftTab();
      });
    }).toJS;

    _editorDiv!.addEventListener('keydown', _shiftTabKeyHandlerJs, true.toJS);
  }

  // ------------------------------------------------------------------
  // Optional inner->outer scroll handoff
  // ------------------------------------------------------------------

  void _setupOuterScrollHandoff() {
    if (!widget.configuration.enableOuterScrollHandoff) {
      return;
    }
    final editorDiv = _editorDiv;
    if (editorDiv == null) return;

    _outerScrollWheelHandlerJs = ((web.Event event) {
      final wheelEvent = event as web.WheelEvent;
      final dy = wheelEvent.deltaY.toDouble();
      _tryHandoffOuterScroll(event: event, deltaY: dy, isTouch: false);
    }).toJS;

    _outerScrollTouchStartHandlerJs = ((web.Event event) {
      final touchEvent = event as web.TouchEvent;
      final touches = touchEvent.changedTouches;
      if (touches.length <= 0) return;
      final touch = touches.item(0);
      if (touch == null) return;
      _stopOuterFling();
      _resetTouchHandoffState();
      _touchGestureActive = true;
      final clientY = _readDomClientCoord(touch, 'clientY');
      _touchLastClientY = clientY;
      _recordVelocitySample(clientY);
      if (!_isEditorVerticallyScrollable()) {
        _touchScrollOwner = _TouchScrollOwner.outer;
      }
      _isSelectionGestureActive = _lastSelectionLength > 0;
    }).toJS;

    _outerScrollTouchMoveHandlerJs = ((web.Event event) {
      final touchEvent = event as web.TouchEvent;
      final touches = touchEvent.changedTouches;
      if (touches.length <= 0) return;
      final touch = touches.item(0);
      if (touch == null) return;

      if (_pendingEmptyTouchTapFocus) {
        final pendingPoint = _pendingEmptyTouchTapPoint;
        if (pendingPoint != null) {
          final dx =
              _readDomClientCoord(touch, 'clientX') - pendingPoint.$1;
          final dy =
              _readDomClientCoord(touch, 'clientY') - pendingPoint.$2;
          final distance = math.sqrt(dx * dx + dy * dy);
          if (distance <= _emptyTapFocusSlopPx) {
            // Keep this gesture in tap-focus mode; do not let tiny movement
            // leak into scroll handoff and cause focus-time wobble.
            event.preventDefault();
            event.stopPropagation();
            return;
          }
        }
        // User dragged beyond tap slop -> treat as scroll gesture.
        _pendingEmptyTouchTapFocus = false;
        _pendingEmptyTouchTapPoint = null;
      }

      final currentY = _readDomClientCoord(touch, 'clientY');
      final previousY = _touchLastClientY;
      _touchLastClientY = currentY;
      if (previousY == null) return;
      _recordVelocitySample(currentY);
      final dy = previousY - currentY;
      _touchGestureDistancePx += dy.abs();
      _tryHandoffOuterScroll(event: event, deltaY: dy, isTouch: true);
    }).toJS;

    _outerScrollTouchEndHandlerJs = ((web.Event _) {
      if (_shouldSuppressOuterHandoffDuringAcquisition()) {
        _resetTouchHandoffState();
        _touchGestureActive = false;
        _isSelectionGestureActive = false;
        return;
      }
      if (_pendingOuterTouchDelta.abs() >= _touchOuterEndFlushMinPx) {
        _flushQueuedOuterTouchDelta();
      }
      final wasOuter = _touchScrollOwner == _TouchScrollOwner.outer;
      final velocity = wasOuter ? _computeTouchVelocity() : 0.0;
      _resetTouchHandoffState();
      _touchGestureActive = false;
      _isSelectionGestureActive = false;
      if (wasOuter) {
        _startOuterFling(velocity);
      }
    }).toJS;

    _outerScrollTouchCancelHandlerJs = ((web.Event _) {
      if (_shouldSuppressOuterHandoffDuringAcquisition()) {
        _resetTouchHandoffState();
        _touchGestureActive = false;
        _isSelectionGestureActive = false;
        return;
      }
      if (_pendingOuterTouchDelta.abs() >= _touchOuterEndFlushMinPx) {
        _flushQueuedOuterTouchDelta();
      }
      _resetTouchHandoffState();
      _touchGestureActive = false;
      _isSelectionGestureActive = false;
    }).toJS;

    _outerScrollPointerDownHandlerJs = ((web.Event _) {
      _isSelectionGestureActive = _lastSelectionLength > 0;
    }).toJS;

    _outerScrollPointerUpHandlerJs = ((web.Event _) {
      _isSelectionGestureActive = false;
    }).toJS;

    _outerScrollPointerCancelHandlerJs = ((web.Event _) {
      _isSelectionGestureActive = false;
    }).toJS;

    _outerScrollCompositionStartHandlerJs = ((web.Event _) {
      _isImeComposing = true;
    }).toJS;

    _outerScrollCompositionEndHandlerJs = ((web.Event _) {
      _isImeComposing = false;
    }).toJS;

    editorDiv.addEventListener(
      'wheel',
      _outerScrollWheelHandlerJs!,
      _eventListenerOptions(passive: false),
    );
    editorDiv.addEventListener('touchstart', _outerScrollTouchStartHandlerJs!);
    editorDiv.addEventListener(
      'touchmove',
      _outerScrollTouchMoveHandlerJs!,
      _eventListenerOptions(passive: false),
    );
    editorDiv.addEventListener('touchend', _outerScrollTouchEndHandlerJs!);
    editorDiv.addEventListener(
      'touchcancel',
      _outerScrollTouchCancelHandlerJs!,
    );
    editorDiv.addEventListener(
      'pointerdown',
      _outerScrollPointerDownHandlerJs!,
    );
    editorDiv.addEventListener('pointerup', _outerScrollPointerUpHandlerJs!);
    editorDiv.addEventListener(
      'pointercancel',
      _outerScrollPointerCancelHandlerJs!,
    );
    editorDiv.addEventListener(
      'compositionstart',
      _outerScrollCompositionStartHandlerJs!,
    );
    editorDiv.addEventListener(
      'compositionend',
      _outerScrollCompositionEndHandlerJs!,
    );
  }

  JSObject _eventListenerOptions({
    required bool passive,
    bool capture = false,
  }) {
    return <String, dynamic>{'passive': passive, 'capture': capture}.jsify()
        as JSObject;
  }

  _ScrollTransfer _computeScrollTransfer(
    double deltaY, {
    double edgeEpsilon = 0.5,
  }) {
    if (deltaY.abs() <= 0.01) {
      return (innerConsumed: 0.0, outerRemainder: 0.0);
    }
    final editor = _quillEditorElement();
    if (editor == null) {
      return (innerConsumed: 0.0, outerRemainder: deltaY);
    }

    final maxScroll = math.max(
      0.0,
      editor.scrollHeight.toDouble() - editor.clientHeight.toDouble(),
    );
    if (maxScroll <= edgeEpsilon) {
      return (innerConsumed: 0.0, outerRemainder: deltaY);
    }

    final scrollTop = editor.scrollTop.toDouble().clamp(0.0, maxScroll);
    final downCapacity = math.max(0.0, maxScroll - scrollTop - edgeEpsilon);
    final upCapacity = math.max(0.0, scrollTop - edgeEpsilon);
    double innerConsumed = 0.0;
    if (deltaY > 0) {
      innerConsumed = math.min(deltaY, downCapacity);
    } else {
      innerConsumed = -math.min(-deltaY, upCapacity);
    }
    return (
      innerConsumed: innerConsumed,
      outerRemainder: deltaY - innerConsumed,
    );
  }

  bool _applyInnerScrollDelta(double deltaY) {
    if (deltaY.abs() <= 0.01) return false;
    final editor = _quillEditorElement();
    if (editor == null) return false;
    final maxScroll = math.max(
      0.0,
      editor.scrollHeight.toDouble() - editor.clientHeight.toDouble(),
    );
    if (maxScroll <= 0.5) return false;
    final current = editor.scrollTop.toDouble().clamp(0.0, maxScroll);
    final target = (current + deltaY).clamp(0.0, maxScroll).toDouble();
    if ((target - current).abs() <= 0.01) return false;
    editor.scrollTop = target;
    return true;
  }

  bool _isEditorVerticallyScrollable({double epsilon = 0.5}) {
    final editor = _quillEditorElement();
    if (editor == null) return false;
    final maxScroll = math.max(
      0.0,
      editor.scrollHeight.toDouble() - editor.clientHeight.toDouble(),
    );
    return maxScroll > epsilon;
  }

  double _filterOuterTouchDelta(double deltaY) {
    if (deltaY.abs() < _touchOuterDeltaMinPx) {
      return 0.0;
    }
    final direction = deltaY > 0 ? 1 : -1;
    if (_outerTouchDeltaDirection != 0 &&
        direction != _outerTouchDeltaDirection &&
        deltaY.abs() < _touchOuterDirectionFlipGuardPx) {
      return 0.0;
    }
    _outerTouchDeltaDirection = direction;
    return deltaY;
  }

  void _queueOuterTouchDelta(double deltaY) {
    if (deltaY.abs() <= 0.01) return;
    final incomingDirection = deltaY > 0 ? 1 : -1;
    final queuedDirection = _pendingOuterTouchDelta == 0
        ? 0
        : (_pendingOuterTouchDelta > 0 ? 1 : -1);
    if (queuedDirection != 0 &&
        incomingDirection != queuedDirection &&
        deltaY.abs() < _touchOuterPendingDropOnFlipPx) {
      _pendingOuterTouchDelta = 0.0;
      _cancelOuterFlushRaf();
    }
    _pendingOuterTouchDelta += deltaY;
    _scheduleOuterFlushRaf();
  }

  void _scheduleOuterFlushRaf() {
    if (_touchOuterFlushRafId != null) return;
    _touchOuterFlushRafId = web.window.requestAnimationFrame(
      ((JSAny _) {
        _touchOuterFlushRafId = null;
        _flushQueuedOuterTouchDelta();
      }).toJS,
    );
  }

  void _cancelOuterFlushRaf() {
    final rafId = _touchOuterFlushRafId;
    if (rafId != null) {
      web.window.cancelAnimationFrame(rafId);
      _touchOuterFlushRafId = null;
    }
  }

  void _flushQueuedOuterTouchDelta() {
    if (_pendingOuterTouchDelta.abs() <= 0.01) return;
    final delta = _pendingOuterTouchDelta;
    _pendingOuterTouchDelta = 0.0;
    _dispatchOuterScrollDelta(delta);
  }

  void _resetTouchHandoffState() {
    _touchLastClientY = null;
    _touchScrollOwner = _TouchScrollOwner.undecided;
    _touchGestureDistancePx = 0.0;
    _pendingOuterTouchDelta = 0.0;
    _outerTouchDeltaDirection = 0;
    _cancelOuterFlushRaf();
    _touchVelocitySamples.clear();
  }

  bool _dispatchOuterScrollDelta(double deltaY) {
    final callback = widget.configuration.onOuterScrollDelta;
    if (callback != null) {
      callback(deltaY);
      return true;
    }

    final scrollableState = Scrollable.maybeOf(context);
    final position = scrollableState?.position;
    if (position == null) return false;

    final target = (position.pixels + deltaY).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if ((target - position.pixels).abs() <= 0.5) {
      return false;
    }
    position.jumpTo(target);
    return true;
  }

  // ------------------------------------------------------------------
  // Touch velocity tracking & fling
  // ------------------------------------------------------------------

  void _recordVelocitySample(double clientY) {
    final now = web.window.performance.now();
    _touchVelocitySamples.add((now, clientY));
    if (_touchVelocitySamples.length > _maxVelocitySamples) {
      _touchVelocitySamples.removeAt(0);
    }
  }

  double _computeTouchVelocity() {
    if (_touchVelocitySamples.length < 2) return 0.0;
    final newest = _touchVelocitySamples.last;
    final oldest = _touchVelocitySamples.first;
    final dtMs = newest.$1 - oldest.$1;
    if (dtMs <= 0) return 0.0;
    final dtSeconds = dtMs / 1000.0;
    // Sign: (oldest.clientY - newest.clientY) is positive when the finger
    // moves upward, which corresponds to positive scroll-down delta — the
    // same convention used by _tryHandoffOuterScroll / _dispatchOuterScrollDelta.
    return (oldest.$2 - newest.$2) / dtSeconds;
  }

  void _startOuterFling(double velocityPxPerSec) {
    _stopOuterFling();
    if (velocityPxPerSec.abs() < _flingVelocityThreshold) return;

    _outerFlingSimulation = ClampingScrollSimulation(
      position: 0.0,
      velocity: velocityPxPerSec,
    );
    _outerFlingLastPosition = 0.0;
    _outerFlingTicker = createTicker(_onFlingTick);
    _outerFlingTicker!.start();
  }

  void _onFlingTick(Duration elapsed) {
    if (_shouldSuppressOuterHandoffDuringAcquisition()) {
      _stopOuterFling();
      return;
    }
    final simulation = _outerFlingSimulation;
    if (simulation == null) {
      _stopOuterFling();
      return;
    }

    final t = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    if (simulation.isDone(t)) {
      _stopOuterFling();
      return;
    }

    final currentPosition = simulation.x(t);
    final delta = currentPosition - _outerFlingLastPosition;
    _outerFlingLastPosition = currentPosition;

    if (delta.abs() < 0.5) {
      _stopOuterFling();
      return;
    }

    if (!_dispatchOuterScrollDelta(delta)) {
      _stopOuterFling();
    }
  }

  void _stopOuterFling() {
    _outerFlingTicker?.stop();
    _outerFlingTicker?.dispose();
    _outerFlingTicker = null;
    _outerFlingSimulation = null;
    _outerFlingLastPosition = 0.0;
  }

  void _tryHandoffOuterScroll({
    required web.Event event,
    required double deltaY,
    required bool isTouch,
  }) {
    if (!widget.configuration.enableOuterScrollHandoff) return;
    if (deltaY.abs() <= 0.01) return;
    if (_isImeComposing || _isSelectionGestureActive) return;
    if (_shouldSuppressOuterHandoffDuringAcquisition()) {
      if (isTouch) {
        _resetTouchHandoffState();
        _touchGestureActive = false;
      }
      return;
    }

    if (!isTouch) {
      final transfer = _computeScrollTransfer(deltaY);
      if (transfer.outerRemainder.abs() <= 0.01) return;

      final innerApplied = _applyInnerScrollDelta(transfer.innerConsumed);
      final outerHandled = _dispatchOuterScrollDelta(transfer.outerRemainder);
      if (!(innerApplied || outerHandled)) return;

      event.preventDefault();
      event.stopPropagation();
      return;
    }

    if (_touchScrollOwner == _TouchScrollOwner.undecided &&
        _touchGestureDistancePx < _touchHandoffDecisionThresholdPx) {
      if (!_isEditorVerticallyScrollable()) {
        _touchScrollOwner = _TouchScrollOwner.outer;
      } else {
        return;
      }
    }

    if (_touchScrollOwner == _TouchScrollOwner.undecided &&
        !_isEditorVerticallyScrollable()) {
      _touchScrollOwner = _TouchScrollOwner.outer;
    }

    if (_touchScrollOwner == _TouchScrollOwner.undecided &&
        _touchGestureDistancePx < _touchHandoffDecisionThresholdPx) {
      return;
    }

    // Single transfer computation used for both the owner decision and the
    // delta dispatch, eliminating disagreement between two epsilon values.
    final transfer = _computeScrollTransfer(
      deltaY,
      edgeEpsilon: _touchBoundaryHysteresisPx,
    );

    if (_touchScrollOwner == _TouchScrollOwner.undecided) {
      _touchScrollOwner = transfer.outerRemainder.abs() > 0.01
          ? _TouchScrollOwner.outer
          : _TouchScrollOwner.inner;
    } else if (_touchScrollOwner == _TouchScrollOwner.inner &&
        transfer.outerRemainder.abs() > 0.01) {
      // Inner-to-outer transition: once promoted, the owner stays outer for
      // the remainder of the gesture to avoid edge-bounce stutter.
      _touchScrollOwner = _TouchScrollOwner.outer;
    }
    // NOTE: outer-to-inner flip is intentionally omitted. Allowing mid-gesture
    // owner demotion caused visible stutter at scroll boundaries. A new
    // touchstart resets the decision cleanly.

    if (_touchScrollOwner == _TouchScrollOwner.inner) {
      return;
    }

    if (_touchScrollOwner == _TouchScrollOwner.outer) {
      // While outer owns this gesture, always prevent native page handling on
      // touchmove frames (including tiny filtered deltas) to avoid pull-to-
      // refresh/page takeover on fast swipes.
      event.preventDefault();
      event.stopPropagation();
    }

    final outerDelta = _filterOuterTouchDelta(transfer.outerRemainder);
    if (outerDelta.abs() <= 0.01) {
      return;
    }
    if (_isEditorVerticallyScrollable()) {
      _queueOuterTouchDelta(outerDelta);
    } else {
      // Non-scrollable content: 100% of delta goes through the manual pipeline.
      // Dispatch synchronously to avoid rAF batching jitter.
      _dispatchOuterScrollDelta(outerDelta);
    }
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
      _snapEditorScrollToLineBoundaryIfOverflowing();
    } catch (_) {
      // Best-effort only. If unsupported in runtime Quill build, ignore.
    }
  }

  void _snapEditorScrollToLineBoundaryIfOverflowing() {
    final editor = _quillEditorElement();
    if (editor == null) return;

    final clientHeight = editor.clientHeight.toDouble();
    final scrollHeight = editor.scrollHeight.toDouble();
    if (scrollHeight <= clientHeight + 0.5) {
      return;
    }

    final styles = web.window.getComputedStyle(editor);
    final lineHeight = _parseCssPx(styles.getPropertyValue('line-height'));
    if (lineHeight == null || lineHeight <= 0) {
      return;
    }

    final topPadding =
        _parseCssPx(styles.getPropertyValue('padding-top')) ?? 0.0;
    final current = editor.scrollTop.toDouble();
    final effective = math.max(0.0, current - topPadding);
    final snapped =
        (effective / lineHeight).ceilToDouble() * lineHeight + topPadding;
    final maxScroll = math.max(0.0, scrollHeight - clientHeight);
    final target = snapped.clamp(0.0, maxScroll);

    if ((target - current).abs() > 0.5) {
      editor.scrollTop = target;
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

  double _resolveAutoResizeHeight(
    double maxWidth,
    TextDirection textDirection,
  ) {
    final cfg = widget.configuration;
    final style = cfg.style;
    final fontSize = style?.fontSize ?? 16.0;
    final lineHeightMultiplier = style?.lineHeight ?? 1.5;
    final lineHeightPx = fontSize * lineHeightMultiplier;
    final contentWidth = math.max(
      0.0,
      maxWidth - cfg.autoResizeHorizontalPadding,
    );

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
    final explicitLineCount = text.isEmpty
        ? 1
        : '\n'.allMatches(text).length + 1;
    final visibleLineCount = math
        .max(wrappedLineCount, explicitLineCount)
        .clamp(cfg.minLines, cfg.maxLines);
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
    _traceFocus('tap_outside', {
      'editorHasFocus': _editorHasFocus,
      'focusPhase': _focusPhase.name,
      'ignoreActive': _ignoreTapOutsideUntil != null,
    });
    final ignoreUntil = _ignoreTapOutsideUntil;
    if (ignoreUntil != null && DateTime.now().isBefore(ignoreUntil)) {
      _traceFocus('tap_outside_ignored', {'reason': 'ignore_window_active'});
      return;
    }
    if (!_editorHasFocus || _quill == null) return;
    _explicitBlurRequested = true;
    _pendingJsToFlutterFocusSync = null;
    _suppressEditorRefocusUntil = DateTime.now().add(
      const Duration(milliseconds: 200),
    );
    _traceFocus('tap_outside_blur_triggered');
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
          final direction =
              Directionality.maybeOf(context) ?? TextDirection.ltr;
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

enum _FocusPhase { idle, acquiring, stable, blurring }
