// Conditional export: uses the web implementation when dart:js_interop is
// available, otherwise falls back to a stub that shows a "web only" message.

export 'quill_js_editor_stub.dart'
    if (dart.library.js_interop) 'quill_js_editor_web.dart';
