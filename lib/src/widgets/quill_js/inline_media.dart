import 'quill_js_configurations.dart';

enum MediaEditKind { image, video }

class MediaEditDecision {
  const MediaEditDecision._({this.value, required this.apply});

  final QuillJsMediaValue? value;
  final bool apply;

  static MediaEditDecision fromResult({
    required MediaEditKind kind,
    required QuillJsMediaValue? result,
  }) {
    if (result == null) return const MediaEditDecision._(apply: false);
    if (containsSvgSource(result.source)) return const MediaEditDecision._(apply: false);
    if (kind == MediaEditKind.video && !isHttpVideoSource(result.source)) {
      return const MediaEditDecision._(apply: false);
    }
    return MediaEditDecision._(apply: true, value: result);
  }
}

class EmbedSize {
  const EmbedSize(this.width, this.height);

  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is EmbedSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'EmbedSize($width, $height)';
}

const EmbedSize defaultVideoSize = EmbedSize(560, 315);
const int minEmbedSide = 48;

const Set<String> _allowedImageMimeTypes = {
  'image/jpeg',
  'image/jpg',
  'image/png',
  'image/webp',
};

bool isSupportedDroppedImage({String? mimeType, String? name}) {
  final mime = mimeType?.toLowerCase();
  if (mime == 'image/svg+xml') return false;
  if (mime != null && _allowedImageMimeTypes.contains(mime)) return true;
  final lower = name?.toLowerCase() ?? '';
  return lower.endsWith('.jpg') ||
      lower.endsWith('.jpeg') ||
      lower.endsWith('.png') ||
      lower.endsWith('.webp');
}

bool isHttpVideoSource(String source) {
  final uri = Uri.tryParse(source.trim());
  if (uri == null || !uri.hasScheme) return false;
  return uri.scheme == 'http' || uri.scheme == 'https';
}

bool containsSvgSource(String source) {
  final lower = source.toLowerCase();
  return lower.contains('.svg') || lower.contains('image/svg');
}

Map<String, dynamic>? mediaAttributes({String? alt, int? width, int? height}) {
  final attributes = <String, dynamic>{};
  final trimmed = alt?.trim() ?? '';
  if (trimmed.isNotEmpty) attributes['alt'] = trimmed;
  if (width != null && width > 0) attributes['width'] = width.toString();
  if (height != null && height > 0) attributes['height'] = height.toString();
  if (attributes.isEmpty) return null;
  return attributes;
}

EmbedSize resizeFromCorner({
  required int originWidth,
  required int originHeight,
  required double dx,
  required double dy,
  String? handle,
  int minSide = minEmbedSide,
}) {
  if (dx == 0 && dy == 0) return EmbedSize(originWidth, originHeight);
  if (handle == 'n' || handle == 's') {
    return EmbedSize(originWidth, _resizedEdge(originHeight, dy, minSide));
  }
  if (handle == 'e' || handle == 'w') {
    return EmbedSize(_resizedEdge(originWidth, dx, minSide), originHeight);
  }
  final width = originWidth <= 0 ? minSide : originWidth;
  final height = originHeight <= 0 ? minSide : originHeight;
  final ratio = width / height;
  final widthDelta = dx / width;
  final heightDelta = dy / height;
  final scaleDelta = widthDelta.abs() >= heightDelta.abs() ? widthDelta : heightDelta;
  return _floorSize(width * (1 + scaleDelta), ratio, minSide);
}

/// Form sizes. An unchanged pair is kept, including a side below 48.
/// One edited side follows the current ratio, or 16:9 for a new video.
/// Both edited sides are kept and each is raised to 48.
({int? width, int? height}) resolveFormEmbedSize({
  required bool isVideo,
  required bool widthChanged,
  required bool heightChanged,
  int? width,
  int? height,
  int? initialWidth,
  int? initialHeight,
}) {
  if (!widthChanged && !heightChanged) {
    return (width: width, height: height);
  }

  final initialReady = initialWidth != null &&
      initialWidth > 0 &&
      initialHeight != null &&
      initialHeight > 0;
  if (widthChanged && heightChanged && width != null && height != null) {
    return (width: _atLeastMin(width), height: _atLeastMin(height));
  }
  if (initialReady && widthChanged && !heightChanged && width != null) {
    final size = changeDimension(
      width: initialWidth,
      height: initialHeight,
      editWidth: true,
      editedValue: width,
    );
    return (width: size.width, height: size.height);
  }
  if (initialReady && heightChanged && !widthChanged && height != null) {
    final size = changeDimension(
      width: initialWidth,
      height: initialHeight,
      editWidth: false,
      editedValue: height,
    );
    return (width: size.width, height: size.height);
  }
  if (width != null && height == null) {
    if (!isVideo) return (width: _atLeastMin(width), height: null);
    final size = changeDimension(
      width: defaultVideoSize.width,
      height: defaultVideoSize.height,
      editWidth: true,
      editedValue: width,
    );
    return (width: size.width, height: size.height);
  }
  if (height != null && width == null) {
    if (!isVideo) return (width: null, height: _atLeastMin(height));
    final size = changeDimension(
      width: defaultVideoSize.width,
      height: defaultVideoSize.height,
      editWidth: false,
      editedValue: height,
    );
    return (width: size.width, height: size.height);
  }
  return (
    width: widthChanged && width != null ? _atLeastMin(width) : width,
    height: heightChanged && height != null ? _atLeastMin(height) : height,
  );
}

EmbedSize changeDimension({
  required int width,
  required int height,
  required bool editWidth,
  required int editedValue,
  int minSide = minEmbedSide,
}) {
  final ratio = width / height;
  final nextWidth = editWidth ? editedValue.toDouble() : editedValue * ratio;
  return _floorSize(nextWidth, ratio, minSide);
}

EmbedSize fitToContentWidth(EmbedSize intrinsic, double contentWidth) {
  if (intrinsic.width <= 0 || intrinsic.height <= 0) return intrinsic;
  if (contentWidth <= 0 || intrinsic.width <= contentWidth) return intrinsic;
  final ratio = intrinsic.width / intrinsic.height;
  final width = contentWidth.floor();
  final height = (width / ratio).round();
  return EmbedSize(width, height < 1 ? 1 : height);
}

EmbedSize resolveLoadedSize({
  int? width,
  int? height,
  required bool isVideo,
  double? intrinsicRatio,
}) {
  if (width != null && width > 0 && height != null && height > 0) {
    return EmbedSize(width, height);
  }
  final ratio = (intrinsicRatio != null && intrinsicRatio > 0)
      ? intrinsicRatio
      : (isVideo ? defaultVideoSize.width / defaultVideoSize.height : null);
  if (width != null && width > 0 && ratio != null) {
    return EmbedSize(width, (width / ratio).round());
  }
  if (height != null && height > 0 && ratio != null) {
    return EmbedSize((height * ratio).round(), height);
  }
  if (isVideo) return defaultVideoSize;
  return const EmbedSize(0, 0);
}

EmbedSize? resolveImageLoadSize({
  int? width,
  int? height,
  required int naturalWidth,
  required int naturalHeight,
}) {
  final storedWidth = (width != null && width > 0) ? width : null;
  final storedHeight = (height != null && height > 0) ? height : null;
  final hasNatural = naturalWidth > 0 && naturalHeight > 0;
  if (storedWidth != null && storedHeight != null) {
    return EmbedSize(storedWidth, storedHeight);
  }
  if (storedWidth != null && hasNatural) {
    final derivedHeight = (storedWidth * naturalHeight / naturalWidth).round();
    if (derivedHeight <= 0) return null;
    return EmbedSize(storedWidth, derivedHeight);
  }
  if (storedHeight != null && hasNatural) {
    final derivedWidth = (storedHeight * naturalWidth / naturalHeight).round();
    if (derivedWidth <= 0) return null;
    return EmbedSize(derivedWidth, storedHeight);
  }
  if (storedWidth == null && storedHeight == null && hasNatural) {
    return EmbedSize(naturalWidth, naturalHeight);
  }
  return null;
}

int _atLeastMin(int value, [int minSide = minEmbedSide]) =>
    value < minSide ? minSide : value;

int _resizedEdge(int origin, double delta, int minSide) {
  final next = origin + delta;
  if (next < minSide) return minSide;
  return next.round();
}

EmbedSize _floorSize(double nextWidth, double ratio, int minSide) {
  var width = nextWidth;
  var height = width / ratio;
  if (width < minSide || height < minSide) {
    if (ratio >= 1) {
      height = minSide.toDouble();
      width = height * ratio;
    } else {
      width = minSide.toDouble();
      height = width / ratio;
    }
  }
  return EmbedSize(width.round(), height.round());
}
