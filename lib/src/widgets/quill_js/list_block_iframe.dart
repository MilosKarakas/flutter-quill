/// The heading levels and Preformatted that a list item can carry, as
/// stored in the `list-block` line format.
const List<String> kListBlockHeadingValues = <String>[
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
];
const String kListBlockPreValue = 'pre';

/// The `list-block` values this editor allows: headings with `header`,
/// Preformatted with `code-block`, none without `list`.
List<String> listBlockValuesFor(List<String> formats) {
  if (!formats.contains('list')) return const <String>[];
  return <String>[
    if (formats.contains('header')) ...kListBlockHeadingValues,
    if (formats.contains('code-block')) kListBlockPreValue,
  ];
}

/// Font size of each `list-block` value relative to the list, matching the
/// editor's heading sizes; Preformatted keeps the list's size.
const Map<String, double> _listBlockScale = <String, double>{
  'h1': 2,
  'h2': 1.5,
  'h3': 1.17,
  'h4': 1,
  'h5': .83,
  'h6': .67,
  'pre': 1,
};

String _em(double value) {
  final fixed = value.toStringAsFixed(4);
  var trimmed = fixed.replaceFirst(RegExp(r'0+$'), '');
  if (trimmed.endsWith('.')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return '${trimmed}em';
}

/// CSS for list items that are also headings or Preformatted.
///
/// It reproduces how the TinyMCE editor renders `<li><h2>…</h2></li>`:
/// the text takes the heading's size and weight, while the bullet or number
/// keeps the list's size, weight, and [markerFontFamily], sits on the text's
/// baseline, and every item's text starts at the same indent as a plain
/// item's at that nesting level.
///
/// Quill sizes the item's padding and its marker in `em` of the item, so
/// both are divided by the item's scale, and the marker is put in the line
/// (it is absolutely positioned by default) so it shares the text baseline.
/// [markerFontFamily] is the editor's own font, so a Preformatted item's
/// number is not monospace.
String listBlockCss({required String markerFontFamily}) {
  final css = StringBuffer();
  const editor = '.ql-snow .ql-editor';
  css
    ..writeln('$editor li[data-list-block^="h"] { font-weight: bold; }')
    ..writeln('$editor li[data-list-block="pre"] { font-family: monospace; }')
    ..writeln(
      '$editor li[data-list-block] > .ql-ui { position: static; '
      'display: inline; font-weight: normal; font-style: normal; '
      'font-family: $markerFontFamily; }',
    );
  _listBlockScale.forEach((value, scale) {
    final item = '$editor li[data-list-block="$value"]';
    if (scale != 1) css.writeln('$item { font-size: ${_em(scale)}; }');
    css
      ..writeln('$item { padding-left: ${_em(1.5 / scale)}; }')
      ..writeln('$item > .ql-ui { font-size: ${_em(1 / scale)}; }');
    for (var indent = 1; indent <= 9; indent++) {
      final padding = _em((1.5 + 3 * indent) / scale);
      css
        ..writeln(
          '$item.ql-indent-$indent:not(.ql-direction-rtl) '
          '{ padding-left: $padding; }',
        )
        ..writeln(
          '$item.ql-indent-$indent.ql-direction-rtl.ql-align-right '
          '{ padding-right: $padding; }',
        );
    }
  });
  return css.toString();
}

/// JavaScript injected into the Quill iframe so a list item can also be a
/// heading or Preformatted, the way the TinyMCE editor writes
/// `<li><h2>…</h2></li>` and `<li><pre>…</pre></li>`.
///
/// A Quill line has one block type, so the style is a separate line format,
/// `list-block`, on a list item: `{"list": "bullet", "list-block": "h2"}`.
/// It mirrors TinyMCE:
/// - a heading or Preformatted chosen on a list item keeps the bullet;
/// - removing the bullet keeps the style, as a heading or code line;
/// - Enter at the end of a heading item starts a plain item, Enter in the
///   middle keeps the heading on both halves, and Enter at the start leaves
///   an empty plain item above;
/// - pasted `<li><hN>` and `<li><pre>` HTML keep both.
/// Adding a bullet to a heading line drops the heading, as TinyMCE does;
/// Quill already behaves that way.
String listBlockIframeScript() => r'''
function registerListBlock(Quill, values) {
  var Parchment = Quill.import('parchment');
  var ListItem = Quill.import('formats/list');
  if (!ListItem || ListItem.__listBlock) return;

  // Only list items take the format; on any other line it is ignored, so a
  // stray value in a delta never reaches the document.
  class ListBlockAttributor extends Parchment.Attributor {
    canAdd(node, value) {
      return node.tagName === 'LI' && super.canAdd(node, value);
    }
  }
  var listBlock = new ListBlockAttributor('list-block', 'data-list-block', {
    scope: Parchment.Scope.BLOCK,
    whitelist: values,
  });
  Quill.register(listBlock, true);

  class ListBlockItem extends ListItem {
    format(name, value) {
      if (name === 'list' && !value) {
        var style = this.domNode.getAttribute('data-list-block');
        if (style) {
          // Without the bullet, the item becomes that heading or code line.
          this.attributes.attribute(listBlock, false);
          if (style === 'pre') {
            this.replaceWith('code-block', true);
          } else {
            this.replaceWith('header', parseInt(style.slice(1), 10));
          }
          return;
        }
      }
      super.format(name, value);
    }
  }
  // The list container is already registered with Quill's own list item;
  // registering it again only logs an "Overwriting" warning.
  ListBlockItem.register = function () {};
  ListBlockItem.blotName = 'list';
  ListBlockItem.__listBlock = true;
  Quill.register(ListBlockItem, true);
}

// Puts `list` before `list-block` when a bullet is added, and `list-block`
// before `list` when one is removed. Quill applies a line's attributes in
// key order, and the style only fits on a list item, so otherwise the
// order a delta happens to list them in would decide whether the style
// survives (for example `{"list-block": "h2", "list": "bullet"}` from a
// converter, or the formats Quill copies when lines merge).
function orderListAttributes(attrs) {
  if (!attrs || !('list-block' in attrs) || !('list' in attrs)) return attrs;
  var first = attrs.list ? 'list' : 'list-block';
  var ordered = {};
  ordered[first] = attrs[first];
  Object.keys(attrs).forEach(function (key) {
    if (key !== first) ordered[key] = attrs[key];
  });
  return ordered;
}

function installListBlock(quill) {
  var Delta = quill.constructor.import('delta');
  var keyboard = quill.keyboard;

  function orderDelta(delta) {
    var ops = (delta && delta.ops) || [];
    var changed = false;
    var next = ops.map(function (op) {
      var attrs = orderListAttributes(op.attributes);
      if (attrs === op.attributes) return op;
      changed = true;
      return Object.assign({}, op, { attributes: attrs });
    });
    return changed ? new Delta(next) : delta;
  }
  // Every path that applies line attributes: updateContents and the
  // keyboard's merges (applyDelta), setContents (insertContents), and
  // format/formatLine and selection deletes (formatLine).
  var editor = quill.editor;
  var applyDelta = editor.applyDelta.bind(editor);
  editor.applyDelta = function (delta) {
    return applyDelta(orderDelta(delta));
  };
  var insertContents = editor.insertContents.bind(editor);
  editor.insertContents = function (index, delta) {
    return insertContents(index, orderDelta(delta));
  };
  var formatLine = editor.formatLine.bind(editor);
  editor.formatLine = function (index, length, formats) {
    var rest = Array.prototype.slice.call(arguments, 3);
    return formatLine.apply(null, [index, length, orderListAttributes(formats)].concat(rest));
  };

  function blockFormats(line) {
    var formats = Object.assign({}, line.formats());
    return formats;
  }

  // Enter at the end of a heading item: the new item is plain. A
  // Preformatted item continues as Preformatted (TinyMCE adds a line to
  // the same <pre>; a Quill list line cannot hold one, so the next item
  // keeps the style instead).
  var endEnter = {
    key: 'Enter',
    shiftKey: null,
    collapsed: true,
    format: ['list-block'],
    suffix: /^$/,
    empty: false,
    handler: function (range, context) {
      if (context.format['list-block'] === 'pre') return true;
      var found = quill.getLine(range.index);
      var line = found[0];
      var offset = found[1];
      var delta = new Delta()
        .retain(range.index)
        .insert('\n', blockFormats(line))
        .retain(line.length() - offset - 1)
        .retain(1, { 'list-block': null });
      quill.updateContents(delta, 'user');
      quill.setSelection(range.index + 1, 'silent');
      quill.scrollSelectionIntoView();
      return false;
    },
  };

  // Enter at the start of a non-empty styled item: an empty plain item
  // goes above, and the styled text stays styled.
  var startEnter = {
    key: 'Enter',
    shiftKey: null,
    collapsed: true,
    format: ['list-block'],
    prefix: /^$/,
    suffix: /./,
    handler: function (range) {
      var line = quill.getLine(range.index)[0];
      var formats = blockFormats(line);
      delete formats['list-block'];
      var delta = new Delta().retain(range.index).insert('\n', formats);
      quill.updateContents(delta, 'user');
      quill.setSelection(range.index + 1, 'silent');
      quill.scrollSelectionIntoView();
      return false;
    },
  };

  // Enter on an empty styled item leaves the list as a plain paragraph.
  // (Quill's own empty-item binding would remove only the bullet, and the
  // item would become an empty heading.)
  var emptyEnter = {
    key: 'Enter',
    shiftKey: null,
    collapsed: true,
    format: ['list-block'],
    empty: true,
    handler: function (range, context) {
      var formats = { 'list-block': null, list: false };
      if (context.format.indent) formats.indent = false;
      quill.formatLine(range.index, range.length, formats, 'user');
      return false;
    },
  };

  [emptyEnter, startEnter, endEnter].forEach(function (binding) {
    keyboard.addBinding(binding);
    // addBinding appends; these must run before Quill's own Enter handling.
    var list = keyboard.bindings['Enter'];
    list.unshift(list.pop());
  });

  // Delete at the end of a styled item: the merged item keeps this item's
  // style, as TinyMCE does. Quill would keep the next line's format.
  var endDelete = {
    key: 'Delete',
    collapsed: true,
    format: ['list-block'],
    suffix: /^$/,
    handler: function (range) {
      var line = quill.getLine(range.index)[0];
      // The line that follows in the document, which may be outside this
      // list (a paragraph, a heading, or a code line).
      var next = quill.getLine(range.index + 1)[0];
      if (!line || !next || next === line || !next.statics) return true;
      var name = next.statics.blotName;
      if (name === 'image' || name === 'video') return true;
      var keep = blockFormats(line);
      Object.keys(next.formats()).forEach(function (key) {
        if (!(key in keep)) keep[key] = null;
      });
      var delta = new Delta()
        .retain(range.index)
        .delete(1)
        .retain(next.length() - 1)
        .retain(1, keep);
      quill.updateContents(delta, 'user');
      quill.setSelection(range.index, 'silent');
      return false;
    },
  };
  keyboard.addBinding(endDelete);
  var deletes = keyboard.bindings['Delete'];
  deletes.unshift(deletes.pop());

  // Pasted <li><h2>…</h2></li> converts to a line with both list and
  // header, and Quill would keep only one of them. Quill adds `list` in its
  // matcher for the enclosing list, so this runs on the list element too,
  // after that one.
  if (quill.clipboard && quill.clipboard.addMatcher) {
    quill.clipboard.addMatcher('ol, ul', function (node, delta) {
      var ops = (delta.ops || []).map(function (op) {
        var attrs = op.attributes;
        if (!attrs || attrs.list == null) return op;
        var style = null;
        if (attrs.header != null) style = 'h' + attrs.header;
        else if (attrs['code-block'] != null && attrs['code-block'] !== false) style = 'pre';
        if (!style) return op;
        var next = Object.assign({}, attrs);
        delete next.header;
        delete next['code-block'];
        next['list-block'] = style;
        return Object.assign({}, op, { attributes: next });
      });
      return new Delta(ops);
    });
  }
}
''';
