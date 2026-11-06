// Shared harness code. It uses only the editor API that existed before the
// image, video, and block-style work, so main_baseline.dart can build it
// against an older checkout. main.dart adds the feature modes.
//
// Page hooks (called by ../driver):
//   hGet()                  controller.contents as Delta JSON
//   hSet(json)              controller.contents = Delta
//   hLog()                  onContentChanged/onBeforeTextChange counts and log
//   hFormat()               inline format state
//   hCall(name, argsJson)   controller methods (see the switch below)
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:web/web.dart' as web;

final controller = QuillJsEditorController();
int changes = 0;
int beforeCalls = 0;
String lastChange = '';
String lastBefore = '';
final List<String> log = <String>[];

List<LinkMatch> matcher(String text) {
  final re = RegExp(r'https?://[^\s]+');
  return [
    for (final m in re.allMatches(text))
      LinkMatch(start: m.start, end: m.end, url: m.group(0)!),
  ];
}

QuillJsEditorConfiguration defaultConfig({bool readOnly = false}) =>
    QuillJsEditorConfiguration(
      initialContent: Delta()..insert('Hello world\n'),
      readOnly: readOnly,
      linkMatcher: matcher,
      onContentChanged: (d) {
        changes++;
        lastChange = jsonEncode(d.toJson());
      },
      onBeforeTextChange: (change, old) {
        beforeCalls++;
        lastBefore = jsonEncode(change.toJson());
        return true;
      },
      onLinkCreate: ({existingUrl, selectedText}) async => null,
    );

void exposeCommon() {
  final w = web.window as JSObject;
  w['hGet'] = (() => jsonEncode(controller.contents.toJson()).toJS).toJS;
  w['hSet'] = ((JSString json) {
    controller.contents = Delta.fromJson(jsonDecode(json.toDart) as List);
  }).toJS;
  w['hLog'] = (() => jsonEncode({
        'changes': changes,
        'before': beforeCalls,
        'lastChange': lastChange,
        'lastBefore': lastBefore,
        'log': log,
      }).toJS).toJS;
  w['hFormat'] = (() {
    final s = controller.formatState;
    return jsonEncode({
      'bold': s.bold,
      'italic': s.italic,
      'underline': s.underline,
      'list': s.list,
      'link': s.link,
    }).toJS;
  }).toJS;
  w['hCall'] = ((JSString name, JSString argsJson) {
    final args = jsonDecode(argsJson.toDart) as List;
    switch (name.toDart) {
      case 'toggleBold':
        controller.toggleBold();
      case 'toggleItalic':
        controller.toggleItalic();
      case 'toggleUnderline':
        controller.toggleUnderline();
      case 'toggleOrderedList':
        controller.toggleOrderedList();
      case 'toggleBulletList':
        controller.toggleBulletList();
      case 'setSelection':
        controller.setSelection(args[0] as int, args[1] as int);
      case 'insertText':
        controller.insertText(args[0] as int, args[1] as String);
      case 'replaceText':
        controller.replaceText(
            args[0] as int, args[1] as int, args[2] as String);
      case 'insertTextAtCursor':
        controller.insertTextAtCursor(args[0] as String);
      case 'clear':
        controller.clear();
      case 'focus':
        controller.focus();
      default:
        return extraCall(name.toDart, args)?.toJS;
    }
    return null;
  }).toJS;
}

String? Function(String name, List args) extraCall = (_, __) => 'unknown';

class HarnessApp extends StatelessWidget {
  const HarnessApp({super.key, required this.config, this.extra});

  final QuillJsEditorConfiguration config;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            QuillToolbar.basic(quillJsController: controller),
            SizedBox(
              width: 700,
              height: double.parse(Uri.base.queryParameters['h'] ?? '400'),
              child: QuillJsEditorView(
                controller: controller,
                configuration: config,
              ),
            ),
            if (extra != null) extra!,
          ],
        ),
      ),
    );
  }
}
