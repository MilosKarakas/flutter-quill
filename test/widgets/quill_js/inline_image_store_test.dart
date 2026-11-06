import 'package:dart_quill_delta/dart_quill_delta.dart';
import 'package:flutter_quill/src/widgets/quill_js/inline_image_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    InlineImageStore.instance.release();
    InlineImageStore.instance.release();
    InlineImageStore.blobUrlCreator = (data) => 'blob:test-${data.hashCode}';
  });

  tearDown(() {
    InlineImageStore.instance.release();
  });

  test('collapse and expand round-trip image ops', () {
    InlineImageStore.instance.retain();
    const dataUrl = 'data:image/png;base64,abcd';
    final input = Delta()
      ..insert('hello')
      ..insert({'image': dataUrl}, {'width': '100'});
    final collapsed = InlineImageStore.instance.collapse(input);
    final imageOp = collapsed.toList()[1];
    expect((imageOp.data as Map)['image'], startsWith('blob:'));
    final expanded = InlineImageStore.instance.expand(collapsed);
    expect((expanded.toList()[1].data as Map)['image'], dataUrl);
    InlineImageStore.instance.release();
  });

  test('dedupes identical data URLs', () {
    InlineImageStore.instance.retain();
    const dataUrl = 'data:image/jpeg;base64,xyz';
    final a = InlineImageStore.instance.blobUrlFor(dataUrl);
    final b = InlineImageStore.instance.blobUrlFor(dataUrl);
    expect(a, b);
    InlineImageStore.instance.release();
  });

  test('a Delta without a URL to change is returned as the same object', () {
    InlineImageStore.instance.retain();
    final text = Delta()
      ..insert('hello', {'bold': true})
      ..insert('\n');
    expect(identical(InlineImageStore.instance.expand(text), text), isTrue);
    expect(identical(InlineImageStore.instance.collapse(text), text), isTrue);
    final remote = Delta()
      ..insert({'image': 'https://x.example/a.png'})
      ..insert('\n');
    expect(identical(InlineImageStore.instance.expand(remote), remote), isTrue);
    expect(identical(InlineImageStore.instance.collapse(remote), remote), isTrue);
    final unknownBlob = Delta()..insert({'image': 'blob:unknown'});
    expect(
      identical(InlineImageStore.instance.expand(unknownBlob), unknownBlob),
      isTrue,
    );
    InlineImageStore.instance.release();
  });

  test('adopt registers a caller-made URL once and reuses it', () {
    InlineImageStore.instance.retain();
    const dataUrl = 'data:image/png;base64,adopt';
    var created = 0;
    final first = InlineImageStore.instance.adopt(dataUrl, () {
      created++;
      return 'blob:host-made';
    });
    final second = InlineImageStore.instance.adopt(dataUrl, () {
      created++;
      return 'blob:other';
    });
    expect(first, 'blob:host-made');
    expect(second, 'blob:host-made');
    expect(created, 1);
    expect(InlineImageStore.instance.dataUrlFor('blob:host-made'), dataUrl);
    expect(InlineImageStore.instance.blobUrlFor(dataUrl), 'blob:host-made');
    InlineImageStore.instance.release();
  });

  test('lastNewlineIndexBefore counts embeds', () {
    final delta = Delta()
      ..insert('a\n')
      ..insert({'image': 'blob:x'})
      ..insert('\nb');
    expect(lastNewlineIndexBefore(delta, 4), 3);
    expect(lastNewlineIndexBefore(delta, 2), 1);
    expect(lastNewlineIndexBefore(delta, 0), isNull);
  });
}
