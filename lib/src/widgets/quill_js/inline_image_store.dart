import 'package:dart_quill_delta/dart_quill_delta.dart';

/// Maps `blob:` image URLs used inside the editor to persisted `data:` URLs.
///
/// Shared across every [QuillJsEditor] instance on the page. Call [retain] /
/// [release] per editor so blob URLs are revoked when the last editor goes away.
class InlineImageStore {
  InlineImageStore._();

  static final InlineImageStore instance = InlineImageStore._();

  /// Creates a `blob:` URL from a `data:` URL. Override in tests or via
  /// [configureInlineImageStoreForBrowser].
  static BlobUrlCreator blobUrlCreator = _unsupportedBlobUrlCreator;

  /// Revokes a `blob:` URL when the last editor [release]s. Set on web only.
  static void Function(String blobUrl)? revokeBlobUrl;

  final Map<String, String> _blobToData = {};
  final Map<String, String> _dataToBlob = {};
  int _refCount = 0;

  void retain() {
    _refCount++;
  }

  void release() {
    _refCount--;
    if (_refCount <= 0) {
      _revokeAll();
      _refCount = 0;
    }
  }

  String blobUrlFor(String dataUrl) =>
      adopt(dataUrl, () => blobUrlCreator(dataUrl));

  /// Returns the `blob:` URL already mapped to [dataUrl], or registers the
  /// one [createBlobUrl] makes.
  ///
  /// The URL must be created in the host page, not in an editor iframe. The
  /// browser revokes a `blob:` URL when the document that created it
  /// unloads, and this store outlives any single editor.
  String adopt(String dataUrl, String Function() createBlobUrl) {
    final existing = _dataToBlob[dataUrl];
    if (existing != null) return existing;
    final blobUrl = createBlobUrl();
    register(blobUrl, dataUrl);
    return blobUrl;
  }

  void register(String blobUrl, String dataUrl) {
    _blobToData[blobUrl] = dataUrl;
    _dataToBlob[dataUrl] = blobUrl;
  }

  String? dataUrlFor(String blobUrl) => _blobToData[blobUrl];

  Delta expand(Delta delta) => _mapImageUrls(delta, (url) {
        if (!isBlobImageUrl(url)) return null;
        return dataUrlFor(url) ?? url;
      });

  Delta collapse(Delta delta) => _mapImageUrls(delta, (url) {
        if (!isDataImageUrl(url)) return null;
        return blobUrlFor(url);
      });

  static bool isBlobImageUrl(String url) => url.startsWith('blob:');

  static bool isDataImageUrl(String url) {
    final lower = url.toLowerCase();
    return lower.startsWith('data:image/');
  }

  /// Returns [delta] itself when no image URL changes, so editors without
  /// images pay no copy and observe the exact Delta Quill produced.
  static Delta _mapImageUrls(
    Delta delta,
    String? Function(String url) mapUrl,
  ) {
    final ops = delta.toList();
    var changes = false;
    for (final op in ops) {
      if (!op.isInsert || op.data is! Map) continue;
      final image = (op.data as Map)['image'];
      if (image is! String) continue;
      final mapped = mapUrl(image);
      if (mapped != null && mapped != image) {
        changes = true;
        break;
      }
    }
    if (!changes) return delta;
    final out = Delta();
    for (final op in ops) {
      if (op.isInsert && op.data is Map) {
        final data = Map<String, dynamic>.from(op.data as Map);
        final image = data['image'];
        if (image is String) {
          final mapped = mapUrl(image);
          if (mapped != null && mapped != image) {
            data['image'] = mapped;
            out.insert(data, op.attributes);
            continue;
          }
        }
      }
      if (op.isRetain) {
        out.retain(op.length!, op.attributes);
      } else if (op.isInsert) {
        out.insert(op.data, op.attributes);
      } else if (op.isDelete) {
        out.delete(op.length!);
      }
    }
    return out;
  }

  void _revokeAll() {
    final revoke = revokeBlobUrl;
    if (revoke != null) {
      for (final blobUrl in _blobToData.keys) {
        revoke(blobUrl);
      }
    }
    _blobToData.clear();
    _dataToBlob.clear();
  }
}

typedef BlobUrlCreator = String Function(String dataUrl);

String _unsupportedBlobUrlCreator(String dataUrl) {
  throw UnsupportedError(
    'InlineImageStore.blobUrlCreator is not configured. '
    'Call configureInlineImageStoreForBrowser() on web.',
  );
}

/// Document index of the last `\n` strictly before [cursorIndex], counting embeds.
int? lastNewlineIndexBefore(Delta contents, int cursorIndex) {
  var offset = 0;
  int? lastNewline;
  for (final op in contents.toList()) {
    if (!op.isInsert) continue;
    final data = op.data;
    if (data is String) {
      for (var i = 0; i < data.length; i++) {
        final pos = offset + i;
        if (pos >= cursorIndex) return lastNewline;
        if (data.codeUnitAt(i) == 0x0A) lastNewline = pos;
      }
      offset += data.length;
    } else {
      if (offset >= cursorIndex) return lastNewline;
      offset += 1;
    }
  }
  return lastNewline;
}
