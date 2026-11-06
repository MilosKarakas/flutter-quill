// Feature harness. Query parameters:
//   mode=default|full|two   default editor, all new formats, or two editors
//   formats=a,b,...         overrides the format list in full mode
//   readOnly=1, h=<px>      read-only editor, editor height
//   styles=superuser        bold/italic sized like the superuser editor
// Extra page hooks: hFormat2(), hGetB(), hSetB(json), and window.hNextMedia
// (JSON the image/video dialog returns; source "SAME" keeps the current one).
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:web/web.dart' as web;

import 'common.dart';

const fullFormats = <String>[
  ...QuillJsEditorConfiguration.defaultFormats,
  'header',
  'code-block',
  'image',
  'video',
];

final controllerB = QuillJsEditorController();
final showFirst = ValueNotifier<bool>(true);

Future<QuillJsMediaValue?> scriptedDialog(String kind, QuillJsMediaValue? current) async {
  log.add(jsonEncode({
    'dialog': kind,
    'current': current == null
        ? null
        : {
            'source': current.source.startsWith('blob:') ? 'blob:*' : current.source,
            'alt': current.alt,
            'width': current.width,
            'height': current.height,
            'embedded': current.embedded,
          },
  }));
  final next = (web.window as JSObject)['hNextMedia'];
  if (next == null || next.isUndefinedOrNull) return null;
  final m = jsonDecode((next as JSString).toDart) as Map<String, dynamic>;
  var source = m['source'] as String;
  if (source == 'SAME' && current != null) source = current.source;
  return QuillJsMediaValue(
    source: source,
    alt: m['alt'] as String?,
    width: m['width'] as int?,
    height: m['height'] as int?,
  );
}

QuillJsEditorConfiguration fullConfig({bool readOnly = false, Delta? initial}) =>
    QuillJsEditorConfiguration(
      initialContent: initial ?? (Delta()..insert('Hello world\n')),
      readOnly: readOnly,
      formats: Uri.base.queryParameters['formats']?.split(',') ?? fullFormats,
      // The superuser editor sizes bold and italic text explicitly.
      styles: Uri.base.queryParameters['styles'] == 'superuser'
          ? const DefaultStyles(
              bold: TextStyle(
                fontSize: 16,
                height: 1.5,
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
              italic: TextStyle(
                fontSize: 16,
                height: 1.5,
                color: Colors.black,
                fontStyle: FontStyle.italic,
              ),
            )
          : null,
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
      onImageCreate: (c) => scriptedDialog('image', c),
      onVideoCreate: (c) => scriptedDialog('video', c),
    );

void main() {
  exposeCommon();
  final q = Uri.base.queryParameters;
  final mode = q['mode'] ?? 'default';
  final readOnly = q['readOnly'] == '1';
  final w = web.window as JSObject;
  w['hFormat2'] = (() {
    final s = controller.formatState;
    return jsonEncode({'blockStyle': s.blockStyle.name, 'mixed': s.blockStyleMixed}).toJS;
  }).toJS;
  w['hGetB'] = (() => jsonEncode(controllerB.contents.toJson()).toJS).toJS;
  w['hSetB'] = ((JSString json) {
    controllerB.contents = Delta.fromJson(jsonDecode(json.toDart) as List);
  }).toJS;
  extraCall = (name, args) {
    switch (name) {
      case 'applyBlockStyle':
        return controller
            .applyBlockStyle(BlockStyleChoice.values.byName(args[0] as String))
            .toString();
      case 'requestImageEmbed':
        controller.requestImageEmbed();
        return null;
      case 'requestVideoEmbed':
        controller.requestVideoEmbed();
        return null;
      case 'removeFirst':
        showFirst.value = false;
        return null;
    }
    return 'unknown';
  };
  if (mode == 'default') {
    runApp(HarnessApp(config: defaultConfig(readOnly: readOnly)));
    return;
  }
  if (mode == 'full') {
    runApp(FullApp(config: fullConfig(readOnly: readOnly)));
    return;
  }
  runApp(const TwoApp());
}

class FullApp extends StatelessWidget {
  const FullApp({super.key, required this.config});
  final QuillJsEditorConfiguration config;

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: Column(children: [
            QuillToolbar.basic(
              quillJsController: controller,
              enabledFormats: Uri.base.queryParameters['formats']?.split(',') ?? fullFormats,
              showImage: true,
              showVideo: true,
            ),
            SizedBox(
              width: 700,
              height: 500,
              child: QuillJsEditorView(controller: controller, configuration: config),
            ),
          ]),
        ),
      );
}

class TwoApp extends StatelessWidget {
  const TwoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          body: Column(children: [
            ValueListenableBuilder<bool>(
              valueListenable: showFirst,
              builder: (context, show, _) => SizedBox(
                width: 700,
                height: 300,
                child: show
                    ? QuillJsEditorView(controller: controller, configuration: fullConfig())
                    : const SizedBox(),
              ),
            ),
            SizedBox(
              width: 700,
              height: 300,
              child: QuillJsEditorView(
                controller: controllerB,
                configuration: fullConfig(initial: Delta()..insert('Second\n')),
              ),
            ),
          ]),
        ),
      );
}
