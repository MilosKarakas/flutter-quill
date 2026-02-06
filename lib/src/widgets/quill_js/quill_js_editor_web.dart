// Web implementation of QuillJsEditorView using HtmlElementView + Quill.js.
// This file is only loaded on web via conditional export.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui' show Color;
import 'dart:ui_web' as ui_web;

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'quill_js_configurations.dart';

// ---------------------------------------------------------------------------
// JS interop bindings for Quill.js 2.0 (using Dart 3.3+ extension types)
// ---------------------------------------------------------------------------

/// Used to check whether the Quill.js global is available.
@JS('Quill')
external JSAny? get _quillJsGlobal;

/// Represents a Quill.js selection range `{index, length}`.
extension type _JsRange._(JSObject _) implements JSObject {
  external int get index;
  external int get length;
}

/// Zero-cost wrapper around a Quill.js 2.0 editor instance.
///
/// All methods are `external` and map directly to Quill.js API calls with
/// automatic Dart↔JS type conversion — no manual `callMethodVarArgs` needed.
@JS('Quill')
extension type _QuillJsInstance._(JSObject _) implements JSObject {
  external _QuillJsInstance(JSObject container, JSObject options);

  external void format(String name, JSAny? value);
  external void formatText(
      int index, int length, String name, JSAny? value);
  external JSObject? getFormat();
  external JSObject getContents();
  external void setContents(JSObject delta);
  external _JsRange? getSelection([bool focus]);
  external void on(String event, JSFunction handler);
  external void enable(bool enabled);
  external String getText(int index, int length);
  external int getLength();
  external void focus();
  external void blur();
  external void deleteText(int index, int length);
  external void insertText(int index, String text,
      [JSAny? formatName, JSAny? formatValue]);
  external void setSelection(int index, int length);
}

@JS('JSON.stringify')
external JSString _jsonStringify(JSAny? obj);

@JS('JSON.parse')
external JSAny _jsonParse(JSString json);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

typedef _QuillSelection = ({int index, int length});
typedef _LinkRange = ({int index, int length});

/// Converts a Flutter [Color] to a CSS `rgba(...)` string.
String _colorToCss(Color c) {
  final a = (c.alpha / 255).toStringAsFixed(3);
  return 'rgba(${c.red}, ${c.green}, ${c.blue}, $a)';
}

// ---------------------------------------------------------------------------
// Script / CSS loading
// ---------------------------------------------------------------------------

Completer<void>? _scriptLoadCompleter;
bool _customCssInjected = false;

bool _isQuillLoaded() => _quillJsGlobal.isDefinedAndNotNull;

Future<void> _ensureQuillJsLoaded(String jsUrl, String? cssUrl) async {
  if (_isQuillLoaded()) return;

  if (_scriptLoadCompleter != null) {
    await _scriptLoadCompleter!.future;
    return;
  }

  _scriptLoadCompleter = Completer<void>();

  // Load theme CSS
  if (cssUrl != null) {
    final link = web.document.createElement('link') as web.HTMLLinkElement
      ..rel = 'stylesheet'
      ..type = 'text/css'
      ..href = cssUrl;
    web.document.head?.append(link);
  }

  // Inject custom CSS overrides
  if (!_customCssInjected) {
    _customCssInjected = true;
    final style =
        web.document.createElement('style') as web.HTMLStyleElement;
    style.textContent = '''
.ql-container.ql-snow { border: none !important; font-size: 16px; }
.ql-editor { padding: 12px 16px; min-height: 100%; outline: none; }
.ql-editor.ql-blank::before { font-style: normal; color: rgba(0,0,0,0.38); }
.ql-editor a { cursor: pointer; color: #1a73e8; text-decoration: underline; }
''';
    web.document.head?.append(style);
  }

  // Load Quill.js script
  final script =
      web.document.createElement('script') as web.HTMLScriptElement
        ..src = jsUrl;

  script.addEventListener(
    'load',
    ((web.Event _) {
      _scriptLoadCompleter?.complete();
    }).toJS,
  );

  script.addEventListener(
    'error',
    ((web.Event _) {
      _scriptLoadCompleter
          ?.completeError('Failed to load Quill.js from $jsUrl');
      _scriptLoadCompleter = null; // allow retry
    }).toJS,
  );

  web.document.head?.append(script);
  await _scriptLoadCompleter!.future;
}

// ---------------------------------------------------------------------------
// QuillJsEditorView — the web widget
// ---------------------------------------------------------------------------

/// Embeds a Quill.js 2.0 rich-text editor inside an [HtmlElementView].
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

  const QuillJsEditorView({
    super.key,
    required this.configuration,
    required this.controller,
    this.focusNode,
    this.autoFocus = false,
    this.loadingBuilder,
  });

  @override
  State<QuillJsEditorView> createState() => _QuillJsEditorViewState();
}

class _QuillJsEditorViewState extends State<QuillJsEditorView> {
  static int _nextId = 0;

  late final String _viewType;
  late final web.HTMLDivElement _containerDiv;
  late final web.HTMLDivElement _editorDiv;

  _QuillJsInstance? _quill;

  _LoadState _loadState = _LoadState.loading;
  String? _errorMessage;

  // Event listener references for cleanup
  JSFunction? _tabKeyHandlerJs;
  JSFunction? _linkClickHandlerJs;
  JSFunction? _scrollBoundaryHandlerJs;
  JSFunction? _editorFocusFixJs;
  JSFunction? _editorBlurFixJs;
  JSFunction? _viewportResizeHandlerJs;

  // Injected <style> element ID for ::selection styling (cleaned up on dispose)
  String? _selectionStyleId;

  // Focus bridging state
  bool _isSyncingFocus = false;

  // The full viewport height (no keyboard). Captured once at init.
  double _fullViewportHeight = 0;

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  @override
  void initState() {
    super.initState();

    _viewType = 'quill-js-editor-${_nextId++}';

    // Build the container DOM structure:
    //   _containerDiv (platform view root)
    //     └── _editorDiv (Quill.js target)
    _containerDiv = web.document.createElement('div') as web.HTMLDivElement
      ..style.setProperty('width', '100%')
      ..style.setProperty('height', '100%')
      ..style.setProperty('overflow', 'auto');

    _editorDiv = web.document.createElement('div') as web.HTMLDivElement;
    _containerDiv.append(_editorDiv);

    // Register platform view factory
    ui_web.platformViewRegistry.registerViewFactory(
      _viewType,
      (int viewId, {Object? params}) => _containerDiv,
    );

    // Begin async initialisation
    _initializeAsync();
  }

  @override
  void didUpdateWidget(QuillJsEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.configuration.readOnly != oldWidget.configuration.readOnly) {
      _quill?.enable(!widget.configuration.readOnly);
    }
  }

  @override
  void dispose() {
    _teardownFocusBridge();
    _detachController();

    // Remove DOM event listeners
    if (_tabKeyHandlerJs != null) {
      _editorDiv.removeEventListener('keydown', _tabKeyHandlerJs, true.toJS);
    }
    if (_linkClickHandlerJs != null) {
      _editorDiv.removeEventListener('click', _linkClickHandlerJs);
    }
    if (_scrollBoundaryHandlerJs != null) {
      _containerDiv.removeEventListener('wheel', _scrollBoundaryHandlerJs);
    }

    // Remove scroll / viewport fix listeners
    final qlEditor =
        _editorDiv.querySelector('.ql-editor') as web.HTMLElement?;
    final target = qlEditor ?? _editorDiv;
    if (_editorFocusFixJs != null) {
      target.removeEventListener('focus', _editorFocusFixJs, true.toJS);
    }
    if (_editorBlurFixJs != null) {
      target.removeEventListener('blur', _editorBlurFixJs, true.toJS);
    }
    // Restore overflow in case the editor is disposed while focused.
    (web.document.documentElement as web.HTMLElement?)
        ?.style.setProperty('overflow', _savedHtmlOverflow ?? '');
    web.document.body?.style
        .setProperty('overflow', _savedBodyOverflow ?? '');

    // Remove Visual Viewport listener
    if (_viewportResizeHandlerJs != null) {
      web.window.visualViewport
          ?.removeEventListener('resize', _viewportResizeHandlerJs);
    }
    // Reset keyboard height so consumers don't keep stale padding.
    widget.controller.keyboardHeight.value = 0;

    // Remove injected selection style
    if (_selectionStyleId != null) {
      web.document.getElementById(_selectionStyleId!)?.remove();
    }

    super.dispose();
  }

  // ------------------------------------------------------------------
  // Initialisation
  // ------------------------------------------------------------------

  Future<void> _initializeAsync() async {
    try {
      await _ensureQuillJsLoaded(
        widget.configuration.quillJsUrl,
        widget.configuration.quillCssUrl,
      );

      if (!mounted) return;

      // Ensure the container has been laid out in the DOM
      final completer = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        completer.complete();
      });
      await completer.future;
      if (!mounted) return;

      _setupQuill();

      setState(() => _loadState = _LoadState.ready);

      // Auto-focus after the build pass so the HtmlElementView is visible.
      if (widget.autoFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || _quill == null) return;
          _quill!.focus();
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

  void _setupQuill() {
    final config = widget.configuration;

    final options = <String, dynamic>{
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
    }.jsify() as JSObject;

    _quill = _QuillJsInstance(_editorDiv, options);

    // Set initial content
    if (config.initialContent != null) {
      _quill!.setContents(_deltaToJs(config.initialContent!));
    }

    _setupEventListeners();
    _setupLinkClickHandler();

    if (config.preventOrphanListNesting) {
      _setupTabKeyHandler();
    }

    _attachController();
    _setupFocusBridge();
    _applyEditorStyle();
    _setupScrollAndViewportFixes();
  }

  // ------------------------------------------------------------------
  // Focus bridging (Flutter FocusNode <-> JS editor focus)
  // ------------------------------------------------------------------

  void _setupFocusBridge() {
    widget.focusNode?.addListener(_onFlutterFocusChanged);
  }

  void _teardownFocusBridge() {
    widget.focusNode?.removeListener(_onFlutterFocusChanged);
  }

  /// Flutter FocusNode changed → sync to JS editor.
  void _onFlutterFocusChanged() {
    if (_isSyncingFocus || _quill == null) return;
    _isSyncingFocus = true;
    try {
      final node = widget.focusNode!;
      if (node.hasFocus) {
        _quill!.focus();
      } else {
        _quill!.blur();
      }
    } finally {
      _isSyncingFocus = false;
    }
  }

  /// JS editor focus changed → sync to Flutter FocusNode.
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
  // Scroll & viewport fixes for PlatformView on mobile web
  // ------------------------------------------------------------------

  // Saved original overflow values so we can restore them on blur.
  String? _savedHtmlOverflow;
  String? _savedBodyOverflow;

  /// Sets up mitigations for PlatformView scroll / viewport issues:
  ///
  /// 1. **Scroll containment** – `overscroll-behavior: contain` prevents
  ///    scroll-chaining from the editor's own scrollable area to the browser
  ///    page, which otherwise moves the whole page on touch-drag.
  ///
  /// 2. **touch-action: none** – prevents the browser from interpreting touch
  ///    gestures on the editor container as page-level pan/scroll. The Quill.js
  ///    contenteditable still handles its own selection / scrolling internally.
  ///
  /// 3. **Wheel boundary passthrough** – on desktop, lets wheel events
  ///    propagate to the Flutter scroll view when the editor is at its scroll
  ///    boundary (top / bottom).
  ///
  /// 4. **Page-scroll lock while focused** – on focus, `<html>` and `<body>`
  ///    get `overflow: hidden` to prevent the browser from scrolling the page
  ///    when the keyboard opens (which would move the app bar off-screen).
  ///    On blur the original overflow is restored.
  ///
  /// 5. **Visual Viewport keyboard detection** – listens to the browser's
  ///    `visualViewport.onresize` to detect the virtual keyboard height
  ///    (since `MediaQuery.viewInsets.bottom` is always 0 on Flutter Web).
  ///    The detected height is written to
  ///    `widget.controller.keyboardHeight` so the host layout can react.
  void _setupScrollAndViewportFixes() {
    // --- CSS containment ---
    _containerDiv.style.setProperty('overscroll-behavior', 'contain');
    _containerDiv.style.setProperty('touch-action', 'none');

    // --- Wheel events (desktop) ---
    _scrollBoundaryHandlerJs = ((web.Event event) {
      final wheelEvt = event as web.WheelEvent;
      final el = _containerDiv;
      final atTop = el.scrollTop <= 0 && wheelEvt.deltaY < 0;
      final atBottom =
          el.scrollTop + el.clientHeight >= el.scrollHeight - 1 &&
              wheelEvt.deltaY > 0;
      if (atTop || atBottom) {
        // At boundary — let it propagate to Flutter
        return;
      }
    }).toJS;
    _containerDiv.addEventListener('wheel', _scrollBoundaryHandlerJs);

    // --- Page-scroll lock via overflow: hidden ---
    _editorFocusFixJs = ((web.Event _) {
      final html =
          web.document.documentElement as web.HTMLElement?;
      final body = web.document.body;
      // Save current overflow values so we can restore them later.
      _savedHtmlOverflow =
          html?.style.getPropertyValue('overflow') ?? '';
      _savedBodyOverflow =
          body?.style.getPropertyValue('overflow') ?? '';
      html?.style.setProperty('overflow', 'hidden');
      body?.style.setProperty('overflow', 'hidden');
      // Reset any scroll the browser may have already applied.
      html?.scrollTop = 0;
      body?.scrollTop = 0;
    }).toJS;

    _editorBlurFixJs = ((web.Event _) {
      // Restore original overflow.
      final html =
          web.document.documentElement as web.HTMLElement?;
      html?.style.setProperty('overflow', _savedHtmlOverflow ?? '');
      web.document.body?.style
          .setProperty('overflow', _savedBodyOverflow ?? '');
    }).toJS;

    // The Quill.js `.ql-editor` contenteditable is inside _editorDiv.
    final qlEditor =
        _editorDiv.querySelector('.ql-editor') as web.HTMLElement?;
    final target = qlEditor ?? _editorDiv;
    target.addEventListener('focus', _editorFocusFixJs, true.toJS);
    target.addEventListener('blur', _editorBlurFixJs, true.toJS);

    // --- Visual Viewport keyboard height detection ---
    // On mobile web, MediaQuery.viewInsets.bottom is always 0.
    // The Visual Viewport API reports the actual visible area; when the
    // keyboard opens, visualViewport.height shrinks while
    // window.innerHeight stays the same.  The difference is the
    // keyboard height.
    _fullViewportHeight = web.window.innerHeight.toDouble();
    final vv = web.window.visualViewport;
    if (vv != null) {
      _viewportResizeHandlerJs = ((web.Event _) {
        final currentHeight = vv.height;
        final kb = _fullViewportHeight - currentHeight;
        // Ignore small differences (< 50px) caused by browser chrome
        // toggling (e.g. address bar hide/show).
        final keyboardHeight = kb > 50 ? kb : 0.0;
        widget.controller.keyboardHeight.value = keyboardHeight;
      }).toJS;
      vv.addEventListener('resize', _viewportResizeHandlerJs);
    }
  }

  // ------------------------------------------------------------------
  // Editor visual styling
  // ------------------------------------------------------------------

  void _applyEditorStyle() {
    final style = widget.configuration.style;
    if (style == null) return;

    // Quill.js creates a `.ql-editor` contenteditable div inside _editorDiv.
    final editorEl =
        _editorDiv.querySelector('.ql-editor') as web.HTMLElement?;
    if (editorEl == null) return;

    final css = editorEl.style;

    if (style.fontFamily != null) {
      css.setProperty('font-family', style.fontFamily!);
    }
    if (style.fontSize != null) {
      css.setProperty('font-size', '${style.fontSize}px');
    }
    if (style.lineHeight != null) {
      css.setProperty('line-height', '${style.lineHeight}');
    }
    if (style.letterSpacing != null) {
      css.setProperty('letter-spacing', '${style.letterSpacing}px');
    }
    if (style.color != null) {
      css.setProperty('color', _colorToCss(style.color!));
    }
    if (style.caretColor != null) {
      css.setProperty('caret-color', _colorToCss(style.caretColor!));
    }
    if (style.selectionHandleColor != null) {
      // accent-color influences selection handles on Chrome/Android.
      css.setProperty('accent-color', _colorToCss(style.selectionHandleColor!));
    }

    // Pseudo-element styles (::selection, ::before, links) require a <style>
    // tag — they can't be set via inline styles.
    _injectPseudoStyles(style);
  }

  /// Injects a scoped `<style>` element for pseudo-element rules (selection
  /// highlight, placeholder text, link color), uniquely scoped via a class
  /// on `_editorDiv`.
  void _injectPseudoStyles(QuillJsEditorStyle style) {
    if (style.selectionColor == null &&
        style.placeholderColor == null &&
        style.linkColor == null) {
      return;
    }

    final className = _viewType; // already unique per instance
    _editorDiv.classList.add(className);

    final id = 'sel-style-$_viewType';
    _selectionStyleId = id;

    final buf = StringBuffer();

    if (style.selectionColor != null) {
      final c = _colorToCss(style.selectionColor!);
      buf.writeln('.$className .ql-editor::selection { background-color: $c; }');
      buf.writeln('.$className .ql-editor *::selection { background-color: $c; }');
    }

    if (style.placeholderColor != null) {
      final c = _colorToCss(style.placeholderColor!);
      buf.writeln('.$className .ql-editor.ql-blank::before { color: $c !important; }');
    }

    if (style.linkColor != null) {
      final c = _colorToCss(style.linkColor!);
      buf.writeln('.$className .ql-editor a { color: $c !important; }');
    }

    final styleEl =
        web.document.createElement('style') as web.HTMLStyleElement;
    styleEl.id = id;
    styleEl.textContent = buf.toString();
    web.document.head?.append(styleEl);
  }

  // ------------------------------------------------------------------
  // Quill.js event listeners
  // ------------------------------------------------------------------

  void _setupEventListeners() {
    // text-change: (delta, oldDelta, source) => void
    _quill!.on(
      'text-change',
      ((JSAny? delta, JSAny? oldDelta, JSAny? source) {
        final src = (source as JSString?)?.toDart;
        if (src == 'user') {
          _onTextChanged();
        }
      }).toJS,
    );

    // selection-change: (range, oldRange, source) => void
    _quill!.on(
      'selection-change',
      ((JSAny? range, JSAny? oldRange, JSAny? source) {
        _onSelectionChanged(range as JSObject?);
      }).toJS,
    );
  }

  void _onTextChanged() {
    final delta = _getContentsDelta();
    widget.configuration.onContentChanged?.call(delta);
  }

  void _onSelectionChanged(JSObject? range) {
    // range == null means the editor lost focus
    if (range == null) {
      _onJsFocusChanged(hasFocus: false);
      return;
    }

    // range != null means the editor has focus
    _onJsFocusChanged(hasFocus: true);

    final format = _getFormat();
    final state = QuillJsFormatState(
      bold: format['bold'] == true,
      italic: format['italic'] == true,
      underline: format['underline'] == true,
      list: format['list'] is String ? format['list'] as String : null,
      link: format['link'] is String ? format['link'] as String : null,
    );

    widget.controller.updateFormatState(state);
  }

  // ------------------------------------------------------------------
  // Link click interception
  // ------------------------------------------------------------------

  void _setupLinkClickHandler() {
    _linkClickHandlerJs = ((web.Event event) {
      var target = (event as web.MouseEvent).target as web.Element?;

      // Walk up the DOM to find an <a> element
      while (target != null && target != _editorDiv) {
        if (target.tagName.toLowerCase() == 'a') {
          event.preventDefault();
          event.stopPropagation();

          final anchor = target as web.HTMLAnchorElement;
          // Use getAttribute to get the raw href as stored by Quill.js,
          // NOT anchor.href which resolves relative to the page origin
          // (e.g. "example.com" → "http://localhost:8080/example.com").
          final href = anchor.getAttribute('href') ?? anchor.href;
          final text = anchor.textContent ?? '';

          _handleLinkTapped(href, text);
          return;
        }
        target = target.parentElement;
      }
    }).toJS;

    _editorDiv.addEventListener('click', _linkClickHandlerJs);
  }

  Future<void> _handleLinkTapped(String href, String text) async {
    final callback = widget.configuration.onLinkTapped;
    if (callback == null) return;

    // Small delay so Quill processes the click and updates selection
    await Future.delayed(const Duration(milliseconds: 50));
    if (!mounted || _quill == null) return;

    final sel = _getQuillSelection();
    if (sel == null) return;

    final linkRange = _findLinkRange(sel.index);
    if (linkRange == null) return;

    final linkText = _quill!.getText(linkRange.index, linkRange.length);
    final result = await callback(href, linkText);
    if (!mounted || _quill == null) return;

    if (result == null) {
      // Remove the link
      _quill!.formatText(
          linkRange.index, linkRange.length, 'link', false.toJS);
    } else {
      if (result.text != null && result.text != linkText) {
        // Replace text and set new link
        _quill!.deleteText(linkRange.index, linkRange.length);
        _quill!.insertText(
            linkRange.index, result.text!, 'link'.toJS, result.url.toJS);
      } else {
        // Update URL only
        _quill!.formatText(
            linkRange.index, linkRange.length, 'link', result.url.toJS);
      }
    }
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
    _editorDiv.addEventListener('keydown', _tabKeyHandlerJs, true.toJS);
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
    final delta = _getContentsDelta();

    int offset = 0;
    int? prevLineIndent;
    bool prevLineIsList = false;

    for (final op in delta.toList()) {
      final opData = op.data;
      final opLen = opData is String ? opData.length : 1;

      // Stop once we've passed the cursor
      if (offset + opLen > sel.index) break;

      if (opData is String && opData.contains('\n')) {
        if (opData == '\n') {
          // Standalone newline — block-attributed
          final attrs = op.attributes ?? {};
          prevLineIsList = attrs.containsKey('list');
          prevLineIndent =
              prevLineIsList ? ((attrs['indent'] as num?)?.toInt() ?? 0) : null;
        } else {
          // Embedded newline (plain text, no block attributes)
          prevLineIsList = false;
          prevLineIndent = null;
        }
      }

      offset += opLen;
    }

    if (!prevLineIsList) return false;
    return (prevLineIndent ?? -1) >= currentIndent;
  }

  // ------------------------------------------------------------------
  // Controller attachment
  // ------------------------------------------------------------------

  void _attachController() {
    widget.controller.attachCallbacks(
      toggleBold: () {
        final fmt = _getFormat();
        _quill!.format('bold', (!(fmt['bold'] == true)).toJS);
        _syncFormatState();
      },
      toggleItalic: () {
        final fmt = _getFormat();
        _quill!.format('italic', (!(fmt['italic'] == true)).toJS);
        _syncFormatState();
      },
      toggleUnderline: () {
        final fmt = _getFormat();
        _quill!.format('underline', (!(fmt['underline'] == true)).toJS);
        _syncFormatState();
      },
      toggleOrderedList: () {
        final fmt = _getFormat();
        if (fmt['list'] == 'ordered') {
          _quill!.format('list', false.toJS);
        } else {
          _quill!.format('list', 'ordered'.toJS);
        }
        _syncFormatState();
      },
      toggleBulletList: () {
        final fmt = _getFormat();
        if (fmt['list'] == 'bullet') {
          _quill!.format('list', false.toJS);
        } else {
          _quill!.format('list', 'bullet'.toJS);
        }
        _syncFormatState();
      },
      requestLink: () => _handleRequestLink(),
      getContents: () => _getContentsDelta(),
      setContents: (Delta delta) {
        _quill!.setContents(_deltaToJs(delta));
      },
      scrollToEnd: () {
        final length = _quill!.getLength();
        if (length > 0) {
          _quill!.setSelection(length - 1, 0);
        }
        // Scroll the HTML container to the bottom
        _containerDiv.scrollTop = _containerDiv.scrollHeight;
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
    final state = QuillJsFormatState(
      bold: format['bold'] == true,
      italic: format['italic'] == true,
      underline: format['underline'] == true,
      list: format['list'] is String ? format['list'] as String : null,
      link: format['link'] is String ? format['link'] as String : null,
    );
    widget.controller.updateFormatState(state);
  }

  // ------------------------------------------------------------------
  // Link create / edit
  // ------------------------------------------------------------------

  Future<void> _handleRequestLink() async {
    final format = _getFormat();
    final linkUrl = format['link'];

    if (linkUrl is String && linkUrl.isNotEmpty) {
      await _handleLinkEdit(linkUrl);
    } else {
      await _handleLinkCreate();
    }
  }

  Future<void> _handleLinkCreate() async {
    final callback = widget.configuration.onLinkCreate;
    if (callback == null) return;

    final sel = _getQuillSelection(focus: true);
    String? selectedText;
    if (sel != null && sel.length > 0) {
      selectedText = _quill!.getText(sel.index, sel.length);
    }

    final result = await callback(selectedText);
    if (result == null || !mounted || _quill == null) return;

    if (sel != null && sel.length > 0) {
      if (result.text != null && result.text != selectedText) {
        _quill!.deleteText(sel.index, sel.length);
        _quill!.insertText(
            sel.index, result.text!, 'link'.toJS, result.url.toJS);
      } else {
        _quill!.formatText(sel.index, sel.length, 'link', result.url.toJS);
      }
    } else {
      final insertIdx = sel?.index ?? (_quill!.getLength() - 1);
      final text = result.text ?? result.url;
      _quill!.insertText(insertIdx, text, 'link'.toJS, result.url.toJS);
    }
  }

  Future<void> _handleLinkEdit(String currentUrl) async {
    final callback = widget.configuration.onLinkTapped;
    if (callback == null) return;

    final sel = _getQuillSelection(focus: true);
    if (sel == null) return;

    final linkRange = _findLinkRange(sel.index);
    if (linkRange == null) return;

    final linkText = _quill!.getText(linkRange.index, linkRange.length);
    final result = await callback(currentUrl, linkText);
    if (!mounted || _quill == null) return;

    if (result == null) {
      _quill!.formatText(
          linkRange.index, linkRange.length, 'link', false.toJS);
    } else {
      if (result.text != null && result.text != linkText) {
        _quill!.deleteText(linkRange.index, linkRange.length);
        _quill!.insertText(
            linkRange.index, result.text!, 'link'.toJS, result.url.toJS);
      } else {
        _quill!.formatText(
            linkRange.index, linkRange.length, 'link', result.url.toJS);
      }
    }
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
      final jsonStr = _jsonStringify(formatObj).toDart;
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

  // ------------------------------------------------------------------
  // Delta conversion
  // ------------------------------------------------------------------

  static JSObject _deltaToJs(Delta delta) {
    final json = jsonEncode({'ops': delta.toJson()});
    return _jsonParse(json.toJS) as JSObject;
  }

  static Delta _jsToDelta(JSObject jsDelta) {
    final jsonStr = _jsonStringify(jsDelta).toDart;
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    return Delta.fromJson(map['ops'] as List);
  }

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Stack(
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
  }
}

enum _LoadState { loading, ready, error }
