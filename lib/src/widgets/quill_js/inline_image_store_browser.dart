import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'inline_image_store.dart';

/// Wires [InlineImageStore] to `URL.createObjectURL` / `revokeObjectURL`.
void configureInlineImageStoreForBrowser() {
  InlineImageStore.blobUrlCreator = _webBlobUrlCreator;
  InlineImageStore.revokeBlobUrl = (url) {
    // Only URLs this store created are revoked; a data: URL kept as its own
    // placeholder needs nothing.
    if (url.startsWith('blob:')) web.URL.revokeObjectURL(url);
  };
}

/// Creates a `blob:` URL holding the bytes of [dataUrl].
///
/// Both base64 and percent-encoded data URLs are decoded. A data URL that
/// cannot be parsed is returned unchanged and stays usable as the source.
String _webBlobUrlCreator(String dataUrl) {
  final UriData data;
  try {
    data = UriData.parse(dataUrl.replaceAll(RegExp(r'\s'), ''));
  } on FormatException {
    return dataUrl;
  }
  final mime = data.mimeType.isEmpty ? 'application/octet-stream' : data.mimeType;
  final blob = web.Blob(
    [data.contentAsBytes().toJS].toJS,
    web.BlobPropertyBag(type: mime),
  );
  return web.URL.createObjectURL(blob);
}
