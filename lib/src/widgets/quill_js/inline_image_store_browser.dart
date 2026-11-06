import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'inline_image_store.dart';

/// Wires [InlineImageStore] to `URL.createObjectURL` / `revokeObjectURL`.
void configureInlineImageStoreForBrowser() {
  InlineImageStore.blobUrlCreator = _webBlobUrlCreator;
  InlineImageStore.revokeBlobUrl = (url) => web.URL.revokeObjectURL(url);
}

String _webBlobUrlCreator(String dataUrl) {
  final match = RegExp(
    r'^data:([^;,]+)?(?:;charset=[^;,]+)?;base64,(.*)$',
    caseSensitive: false,
  ).firstMatch(dataUrl);
  if (match == null) {
    return dataUrl;
  }
  final mime = match.group(1) ?? 'application/octet-stream';
  final Uint8List bytes;
  try {
    bytes = base64Decode(match.group(2)!.replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    return dataUrl;
  }
  final blob = web.Blob(
    [bytes.toJS].toJS,
    web.BlobPropertyBag(type: mime),
  );
  return web.URL.createObjectURL(blob);
}
