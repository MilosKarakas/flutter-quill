import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter_quill/src/utils/delta.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('sliceDeltaForCopy', () {
    final bulletList = Delta()
      ..insert('a')
      ..insert('\n', {'list': 'bullet'})
      ..insert('v')
      ..insert('\n', {'list': 'bullet'});

    test('keeps list format of last line when its newline is not selected', () {
      final result = sliceDeltaForCopy(bulletList, 0, 3);

      expect(
        result.toJson(),
        (Delta()
              ..insert('a')
              ..insert('\n', {'list': 'bullet'})
              ..insert('v')
              ..insert('\n', {'list': 'bullet'}))
            .toJson(),
      );
    });

    test('keeps ordered list format of last line', () {
      final ordered = Delta()
        ..insert('a')
        ..insert('\n', {'list': 'ordered'})
        ..insert('v')
        ..insert('\n', {'list': 'ordered'});

      final result = sliceDeltaForCopy(ordered, 0, 3);

      expect(
        result.toJson(),
        (Delta()
              ..insert('a')
              ..insert('\n', {'list': 'ordered'})
              ..insert('v')
              ..insert('\n', {'list': 'ordered'}))
            .toJson(),
      );
    });

    test('does not duplicate newline when it is already selected', () {
      final result = sliceDeltaForCopy(bulletList, 0, 4);

      expect(result.toJson(), bulletList.toJson());
    });

    test('does not add block format to a selection within a single line', () {
      final result = sliceDeltaForCopy(bulletList, 2, 3);

      expect(result.toJson(), (Delta()..insert('v')).toJson());
    });

    test('does not add newline when last line has no block format', () {
      final doc = Delta()
        ..insert('a')
        ..insert('\n', {'list': 'bullet'})
        ..insert('v\n');

      final result = sliceDeltaForCopy(doc, 0, 3);

      expect(
        result.toJson(),
        (Delta()
              ..insert('a')
              ..insert('\n', {'list': 'bullet'})
              ..insert('v'))
            .toJson(),
      );
    });

    test('keeps only block attributes from the last line newline', () {
      final doc = Delta()
        ..insert('a\n')
        ..insert('v')
        ..insert('\n', {'header': 1, 'bold': true});

      final result = sliceDeltaForCopy(doc, 0, 3);

      expect(
        result.toJson(),
        (Delta()
              ..insert('a\nv')
              ..insert('\n', {'header': 1}))
            .toJson(),
      );
    });

    test(
      'uses the line containing the selection end when it ends mid-line',
      () {
        final doc = Delta()
          ..insert('a\n')
          ..insert('vwx')
          ..insert('\n', {'blockquote': true});

        final result = sliceDeltaForCopy(doc, 0, 4);

        expect(
          result.toJson(),
          (Delta()
                ..insert('a\nvw')
                ..insert('\n', {'blockquote': true}))
              .toJson(),
        );
      },
    );
  });
}
