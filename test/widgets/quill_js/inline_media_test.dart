import 'package:flutter_quill/src/widgets/quill_js/inline_media.dart';
import 'package:flutter_quill/src/widgets/quill_js/quill_js_configurations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isSupportedDroppedImage', () {
    test('accepts jpeg, webp, and png', () {
      expect(isSupportedDroppedImage(mimeType: 'image/jpeg'), isTrue);
      expect(isSupportedDroppedImage(mimeType: 'image/png'), isTrue);
      expect(isSupportedDroppedImage(mimeType: 'image/webp'), isTrue);
      expect(isSupportedDroppedImage(name: 'photo.JPEG'), isTrue);
    });

    test('rejects svg, video, and an empty drop', () {
      expect(isSupportedDroppedImage(mimeType: 'image/svg+xml', name: 'icon.svg'), isFalse);
      expect(isSupportedDroppedImage(mimeType: 'video/mp4', name: 'clip.mp4'), isFalse);
      expect(isSupportedDroppedImage(), isFalse);
    });
  });

  group('isHttpVideoSource', () {
    test('accepts http and https only', () {
      expect(isHttpVideoSource('https://www.youtube.com/embed/abc'), isTrue);
      expect(isHttpVideoSource(' http://cdn.example/a.mp4 '), isTrue);
      expect(isHttpVideoSource('ftp://cdn.example/a.mp4'), isFalse);
      expect(isHttpVideoSource('www.youtube.com/watch?v=abc'), isFalse);
    });
  });

  group('containsSvgSource', () {
    test('matches svg mime prefix and .svg path suffix only', () {
      expect(containsSvgSource('https://cdn.example/icon.SVG'), isTrue);
      expect(containsSvgSource('https://cdn.example/a.png'), isFalse);
      expect(containsSvgSource('https://cdn.example/svg/foo.png'), isFalse);
      expect(containsSvgSource('data:image/svg+xml;base64,PHN2Zw'), isTrue);
    });
  });

  group('normalizeVideoEmbedUrl', () {
    test('maps YouTube watch and youtu.be links with start time', () {
      expect(
        normalizeVideoEmbedUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=90'),
        'https://www.youtube.com/embed/dQw4w9WgXcQ?start=90',
      );
      expect(
        normalizeVideoEmbedUrl('https://youtu.be/dQw4w9WgXcQ?t=1m30s'),
        'https://www.youtube.com/embed/dQw4w9WgXcQ?start=90',
      );
      expect(
        normalizeVideoEmbedUrl('https://youtube.com/shorts/dQw4w9WgXcQ'),
        'https://www.youtube.com/embed/dQw4w9WgXcQ',
      );
    });

    test('maps Vimeo and Loom share URLs', () {
      expect(
        normalizeVideoEmbedUrl('https://vimeo.com/123456789'),
        'https://player.vimeo.com/video/123456789',
      );
      expect(
        normalizeVideoEmbedUrl('https://www.loom.com/share/abc123'),
        'https://www.loom.com/embed/abc123',
      );
    });

    test('keeps an already-embedded Loom URL', () {
      expect(
        normalizeVideoEmbedUrl('https://www.loom.com/embed/abc123'),
        'https://www.loom.com/embed/abc123',
      );
      expect(
        normalizeVideoEmbedUrl('https://loom.com/embed/abc123?sid=x'),
        'https://www.loom.com/embed/abc123',
      );
      expect(normalizeVideoEmbedUrl('https://www.loom.com/looms'), isNull);
    });

    test('keeps the privacy hash of an unlisted Vimeo video', () {
      expect(
        normalizeVideoEmbedUrl('https://vimeo.com/123456/abcdef1234'),
        'https://player.vimeo.com/video/123456?h=abcdef1234',
      );
      expect(
        normalizeVideoEmbedUrl('https://vimeo.com/123456?h=abc'),
        'https://player.vimeo.com/video/123456?h=abc',
      );
      // A hash can be all digits; the first number is still the id.
      expect(
        normalizeVideoEmbedUrl('https://vimeo.com/123456789/0123456789'),
        'https://player.vimeo.com/video/123456789?h=0123456789',
      );
    });

    test('takes the video id, not the album id, from Vimeo paths', () {
      expect(
        normalizeVideoEmbedUrl('https://vimeo.com/showcase/111/video/222'),
        'https://player.vimeo.com/video/222',
      );
      expect(
        normalizeVideoEmbedUrl('https://vimeo.com/channels/staffpicks/333'),
        'https://player.vimeo.com/video/333',
      );
      expect(
        normalizeVideoEmbedUrl('https://vimeo.com/groups/name/videos/444'),
        'https://player.vimeo.com/video/444',
      );
    });

    test('an unchanged Loom embed passes the edit decision', () {
      final decision = MediaEditDecision.fromResult(
        kind: MediaEditKind.video,
        result: const QuillJsMediaValue(
          source: 'https://www.loom.com/embed/abc123',
          alt: 'Demo',
        ),
      );
      expect(decision.apply, isTrue);
      expect(decision.value!.source, 'https://www.loom.com/embed/abc123');
    });

    test('rejects non-http schemes', () {
      expect(normalizeVideoEmbedUrl('javascript:alert(1)'), isNull);
      expect(normalizeVideoEmbedUrl('ftp://example.com/v'), isNull);
    });
  });

  group('mediaAttributes', () {
    test('omits an empty alt and non-positive sizes', () {
      expect(mediaAttributes(alt: '  ', width: 0, height: null), isNull);
      expect(
        mediaAttributes(alt: ' Diagram ', width: 240, height: 180),
        {'alt': 'Diagram', 'width': '240', 'height': '180'},
      );
    });
  });

  group('resizeFromCorner', () {
    test('grows from the axis that changed more and keeps the ratio', () {
      expect(
        resizeFromCorner(
          originWidth: 200,
          originHeight: 100,
          dx: 100,
          dy: 0,
          handle: 'se',
        ),
        const EmbedSize(300, 150),
      );
      expect(
        resizeFromCorner(
          originWidth: 200,
          originHeight: 100,
          dx: 0,
          dy: 50,
          handle: 'se',
        ),
        const EmbedSize(300, 150),
      );
    });

    test('floors a shrinking drag at 48 and keeps a zero drag', () {
      expect(
        resizeFromCorner(
          originWidth: 200,
          originHeight: 100,
          dx: -180,
          dy: 0,
          handle: 'se',
        ),
        const EmbedSize(96, 48),
      );
      expect(
        resizeFromCorner(originWidth: 30, originHeight: 20, dx: 0, dy: 0),
        const EmbedSize(30, 20),
      );
    });

    test('clamps width to maxWidth while keeping ratio', () {
      expect(
        resizeFromCorner(
          originWidth: 800,
          originHeight: 400,
          dx: 200,
          dy: 0,
          handle: 'se',
          maxWidth: 500,
        ),
        const EmbedSize(500, 250),
      );
    });

    test('edge handles change only that axis', () {
      expect(
        resizeFromCorner(
          originWidth: 200,
          originHeight: 100,
          dx: 0,
          dy: 50,
          handle: 's',
        ),
        const EmbedSize(200, 150),
      );
      expect(
        resizeFromCorner(
          originWidth: 200,
          originHeight: 100,
          dx: 0,
          dy: -80,
          handle: 's',
        ),
        const EmbedSize(200, 48),
      );
      expect(
        resizeFromCorner(
          originWidth: 30,
          originHeight: 100,
          dx: 0,
          dy: -80,
          handle: 's',
        ),
        const EmbedSize(30, 48),
      );
    });
  });

  group('resolveFormEmbedSize', () {
    test('floors a new side, derives a new video, and keeps both typed sides', () {
      expect(
        resolveFormEmbedSize(
          isVideo: false,
          widthChanged: true,
          heightChanged: false,
          width: 20,
          height: null,
          initialWidth: null,
          initialHeight: null,
        ),
        (width: 48, height: null),
      );
      expect(
        resolveFormEmbedSize(
          isVideo: true,
          widthChanged: true,
          heightChanged: false,
          width: 800,
          height: null,
          initialWidth: null,
          initialHeight: null,
        ),
        (width: 800, height: 450),
      );
      expect(
        resolveFormEmbedSize(
          isVideo: true,
          widthChanged: true,
          heightChanged: false,
          width: 20,
          height: null,
          initialWidth: null,
          initialHeight: null,
        ),
        (width: 85, height: 48),
      );
      expect(
        resolveFormEmbedSize(
          isVideo: false,
          widthChanged: true,
          heightChanged: true,
          width: 300,
          height: 80,
          initialWidth: 200,
          initialHeight: 100,
        ),
        (width: 300, height: 80),
      );
      expect(
        resolveFormEmbedSize(
          isVideo: false,
          widthChanged: false,
          heightChanged: false,
          width: 20,
          height: 10,
          initialWidth: 20,
          initialHeight: 10,
        ),
        (width: 20, height: 10),
      );
    });
  });

  group('changeDimension', () {
    test('updates the other side from the ratio and floors at 48', () {
      expect(
        changeDimension(width: 200, height: 100, editWidth: true, editedValue: 300),
        const EmbedSize(300, 150),
      );
      expect(
        changeDimension(width: 200, height: 100, editWidth: true, editedValue: 20),
        const EmbedSize(96, 48),
      );
    });
  });

  group('fitToContentWidth', () {
    test('scales a wide image down and leaves a narrow one', () {
      expect(fitToContentWidth(const EmbedSize(800, 400), 400), const EmbedSize(400, 200));
      expect(fitToContentWidth(const EmbedSize(100, 50), 400), const EmbedSize(100, 50));
    });
  });

  group('resolveLoadedSize', () {
    test('keeps both sides, including values below 48', () {
      expect(
        resolveLoadedSize(width: 20, height: 10, isVideo: false),
        const EmbedSize(20, 10),
      );
    });

    test('derives the missing side and defaults video to 560 by 315', () {
      expect(
        resolveLoadedSize(width: 100, height: null, isVideo: false, intrinsicRatio: 2),
        const EmbedSize(100, 50),
      );
      expect(resolveLoadedSize(width: null, height: null, isVideo: true), defaultVideoSize);
      expect(defaultVideoSize, const EmbedSize(560, 315));
    });
  });

  group('resolveImageLoadSize', () {
    test('uses natural size when both sides are missing', () {
      expect(
        resolveImageLoadSize(naturalWidth: 800, naturalHeight: 400),
        const EmbedSize(800, 400),
      );
    });

    test('does not return a size that would be written as 0', () {
      final size = resolveImageLoadSize(naturalWidth: 0, naturalHeight: 0);
      expect(size, isNull);
    });

    test('keeps both stored sides, including values below 48', () {
      expect(
        resolveImageLoadSize(width: 20, height: 10, naturalWidth: 800, naturalHeight: 400),
        const EmbedSize(20, 10),
      );
    });

    test('derives the missing side from the natural ratio', () {
      expect(
        resolveImageLoadSize(width: 100, naturalWidth: 800, naturalHeight: 400),
        const EmbedSize(100, 50),
      );
    });
  });
}
