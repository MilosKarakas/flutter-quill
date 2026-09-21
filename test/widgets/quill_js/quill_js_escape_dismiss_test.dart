import 'package:flutter_quill/src/widgets/quill_js/quill_js_escape_dismiss.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('applyQuillJsEscapeDismiss', () {
    test(
      'marks explicit dismiss then blurs when there is no host callback',
      () async {
        final calls = <String>[];

        applyQuillJsEscapeDismiss(
          markExplicitDismiss: () => calls.add('mark'),
          blurEditor: () => calls.add('blur'),
        );

        expect(calls, ['mark', 'blur']);
        await Future<void>.delayed(Duration.zero);
        expect(calls, ['mark', 'blur']);
      },
    );

    test('invokes the host callback once on a microtask after blur', () async {
      final calls = <String>[];

      applyQuillJsEscapeDismiss(
        markExplicitDismiss: () => calls.add('mark'),
        blurEditor: () => calls.add('blur'),
        onEscapePressed: () => calls.add('host'),
      );

      expect(calls, ['mark', 'blur']);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['mark', 'blur', 'host']);
    });
  });
}
