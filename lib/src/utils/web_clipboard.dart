// Conditional export for web clipboard functionality
// Uses package:web on web, stub implementation elsewhere

export 'web_clipboard_stub.dart'
    if (dart.library.js_interop) 'web_clipboard_web.dart';
