import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/src/widgets/quill_js/inline_media.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const image = QuillJsMediaValue(source: 'https://cdn.example/a.png', alt: 'A', width: 20, height: 10);

  test('a cancelled edit is not applied', () {
    final decision = MediaEditDecision.fromResult(kind: MediaEditKind.image, result: null);
    expect(decision.apply, isFalse);
  });

  test('svg and a non-http video are not applied', () {
    expect(
      MediaEditDecision.fromResult(
        kind: MediaEditKind.image,
        result: const QuillJsMediaValue(source: 'https://cdn.example/a.svg'),
      ).apply,
      isFalse,
    );
    expect(
      MediaEditDecision.fromResult(
        kind: MediaEditKind.video,
        result: const QuillJsMediaValue(source: 'javascript:alert(1)'),
      ).apply,
      isFalse,
    );
  });

  test('a valid result keeps a size below 48', () {
    final decision = MediaEditDecision.fromResult(kind: MediaEditKind.image, result: image);
    expect(decision.apply, isTrue);
    expect(decision.value!.width, 20);
    expect(mediaAttributes(alt: image.alt, width: image.width, height: image.height)!['width'], '20');
  });
}
