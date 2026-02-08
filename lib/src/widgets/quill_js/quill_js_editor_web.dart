// Web implementation of QuillJsEditorView using an iframe-based HtmlElementView
// + Quill.js. The iframe provides natural scroll/keyboard/focus isolation,
// preventing the browser from scrolling the parent Flutter page when the
// keyboard opens or when the user drags inside the editor.
//
// This file is only loaded on web via conditional export.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui' show Color;
import 'dart:ui_web' as ui_web;

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

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
  late final web.HTMLIFrameElement _iframe;

  /// Reference to the Quill.js editor div inside the iframe (`#editor`).
  /// Set after the iframe loads and Quill is initialised.
  web.HTMLElement? _editorDiv;

  _QuillJsInstance? _quill;

  _LoadState _loadState = _LoadState.loading;
  String? _errorMessage;

  // Event listener references for cleanup
  JSFunction? _tabKeyHandlerJs;
  JSFunction? _linkClickHandlerJs;
  JSFunction? _iframeLoadHandlerJs;

  // Focus bridging state
  bool _isSyncingFocus = false;

  // ------------------------------------------------------------------
  // Lifecycle
  // ------------------------------------------------------------------

  @override
  void initState() {
    super.initState();

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

    // Remove iframe load listener
    if (_iframeLoadHandlerJs != null) {
      _iframe.removeEventListener('load', _iframeLoadHandlerJs);
    }

    // Remove DOM event listeners inside the iframe
    if (_editorDiv != null) {
      if (_tabKeyHandlerJs != null) {
        _editorDiv!.removeEventListener('keydown', _tabKeyHandlerJs, true.toJS);
      }
      if (_linkClickHandlerJs != null) {
        _editorDiv!.removeEventListener('click', _linkClickHandlerJs);
      }
    }

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
    final style = config.style;

    // --- Build dynamic <style> block for QuillJsEditorStyle ---
    final dynamicCss = StringBuffer();

    if (style != null) {
      final editorCss = StringBuffer();
      if (style.fontFamily != null) {
        editorCss.write('font-family: ${style.fontFamily};');
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
        editorCss
            .write('accent-color: ${_colorToCss(style.selectionHandleColor!)};');
      }
      if (editorCss.isNotEmpty) {
        dynamicCss.writeln('.ql-editor { $editorCss }');
      }

      // Pseudo-element styles
      if (style.selectionColor != null) {
        final c = _colorToCss(style.selectionColor!);
        dynamicCss.writeln('.ql-editor::selection { background-color: $c; }');
        dynamicCss.writeln('.ql-editor *::selection { background-color: $c; }');
      }
      if (style.placeholderColor != null) {
        final c = _colorToCss(style.placeholderColor!);
        dynamicCss.writeln(
            '.ql-editor.ql-blank::before { color: $c !important; }');
      }
      if (style.linkColor != null) {
        final c = _colorToCss(style.linkColor!);
        dynamicCss.writeln('.ql-editor a { color: $c !important; }');
      }
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
.ql-editor { padding: 12px 16px; min-height: 100%; outline: none; }
.ql-editor.ql-blank::before { font-style: normal; color: rgba(0,0,0,0.38); }
.ql-editor a { cursor: pointer; color: #1a73e8; text-decoration: underline; }
$dynamicCss
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
      _editorDiv =
          contentDoc.querySelector('#editor') as web.HTMLElement?;
      if (_editorDiv == null) {
        throw StateError('Could not find #editor inside iframe');
      }

      // Check that Quill.js loaded successfully inside the iframe
      final quillGlobal =
          (contentWindow as JSObject)['Quill'];
      if (!quillGlobal.isDefinedAndNotNull) {
        throw StateError(
            'Quill.js did not load inside iframe. Check quillJsUrl.');
      }

      _setupQuill(contentWindow as JSObject);

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

  void _setupQuill(JSObject iframeWindow) {
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

    // Obtain the Quill constructor from the iframe's window and create
    // the editor instance inside the iframe's document.
    final quillConstructor = iframeWindow['Quill'] as JSFunction;
    final jsQuill = quillConstructor.callAsConstructor<JSObject>(
        _editorDiv!, options);
    _quill = jsQuill as _QuillJsInstance;

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

  /// Flutter FocusNode changed -> sync to JS editor.
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
    final editorDiv = _editorDiv!;

    _linkClickHandlerJs = ((web.Event event) {
      var target = (event as web.MouseEvent).target as web.Element?;

      // Walk up the DOM to find an <a> element
      while (target != null && target != editorDiv) {
        if (target.tagName.toLowerCase() == 'a') {
          event.preventDefault();
          event.stopPropagation();

          final anchor = target as web.HTMLAnchorElement;
          // Use getAttribute to get the raw href as stored by Quill.js,
          // NOT anchor.href which resolves relative to the page origin.
          final href = anchor.getAttribute('href') ?? anchor.href;
          final text = anchor.textContent ?? '';

          _handleLinkTapped(href, text);
          return;
        }
        target = target.parentElement;
      }
    }).toJS;

    editorDiv.addEventListener('click', _linkClickHandlerJs);
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
        // Scroll the Quill editor container inside the iframe to the bottom.
        final qlContainer =
            _iframe.contentDocument?.querySelector('.ql-container');
        if (qlContainer != null) {
          (qlContainer as web.HTMLElement).scrollTop =
              qlContainer.scrollHeight;
        }
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
