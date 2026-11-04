bool inlineMediaInstallsFor(List<String> formats) =>
    formats.contains('image') || formats.contains('video');

/// JavaScript injected into the Quill iframe for custom image/video blots,
/// drag-and-drop, and corner resize handles.
String inlineMediaIframeScript() => r'''
function isHttpVideoSource(value) {
  if (typeof value !== 'string') return false;
  var raw = value.replace(/^\s+|\s+$/g, '');
  if (!raw) return false;
  var match = /^([A-Za-z][A-Za-z0-9+.\-]*):/.exec(raw);
  if (!match) return false;
  var scheme = match[1].toLowerCase();
  return scheme === 'http' || scheme === 'https';
}

function writeEmbedSide(node, name, value) {
  if (value) {
    var px = String(value).replace(/px$/, '');
    node.setAttribute(name, px);
    node.style.setProperty(name, px + 'px');
  } else {
    node.removeAttribute(name);
    node.style.removeProperty(name);
  }
}

function registerInlineMedia(Quill) {
  var ImageBlot = Quill.import('formats/image');
  var VideoBlot = Quill.import('formats/video');
  var BlockEmbed = Quill.import('blots/block/embed');

  function readSizeAttr(node, name) {
    var v = node.getAttribute(name);
    if (v == null || v === '') return undefined;
    return v;
  }

  function attachImageLoad(node) {
    if (node.__inlineMediaLoadAttached) return;
    node.__inlineMediaLoadAttached = true;
    node.decoding = 'async';
    function onLoad() {
      if (node.__inlineMediaLoadHandled) return;
      var opts = window.__inlineMediaOptions;
      var quill = window.__inlineMediaQuill;
      if (!opts || !opts.image || !quill) return;
      if (opts.readOnly || (quill.isEnabled && !quill.isEnabled())) return;
      var blot = Quill.find(node);
      if (!blot) return;
      node.__inlineMediaLoadHandled = true;
      var w = node.getAttribute('width');
      var h = node.getAttribute('height');
      if (w && h && parseInt(w, 10) > 0 && parseInt(h, 10) > 0) return;
      if (!opts.onImageLoad) return;
      var editor = node.closest ? node.closest('.ql-editor') : null;
      opts.onImageLoad(
        quill.getIndex(blot),
        node.naturalWidth,
        node.naturalHeight,
        (editor && editor.clientWidth) || 0
      );
    }
    node.addEventListener('load', onLoad);
    if (node.complete && node.naturalWidth) window.setTimeout(onLoad, 0);
  }

  function isSvgImageSource(value) {
    var lower = String(value || '').toLowerCase();
    return lower.indexOf('.svg') >= 0 || lower.indexOf('image/svg') >= 0;
  }

  class CustomImageBlot extends BlockEmbed {
    static create(value) {
      var node = super.create(value);
      if (typeof value === 'string') {
        node.setAttribute('src', isSvgImageSource(value) ? '//:0' : ImageBlot.sanitize(value));
      }
      node.style.display = 'block';
      attachImageLoad(node);
      return node;
    }

    static value(node) {
      return node.getAttribute('src');
    }

    static formats(node) {
      var formats = {};
      var alt = node.getAttribute('alt');
      if (alt != null) formats.alt = alt;
      var width = readSizeAttr(node, 'width');
      if (width !== undefined) formats.width = width;
      var height = readSizeAttr(node, 'height');
      if (height !== undefined) formats.height = height;
      return formats;
    }

    format(name, value) {
      if (name === 'alt') {
        if (value) this.domNode.setAttribute('alt', value);
        else this.domNode.removeAttribute('alt');
      } else if (name === 'width' || name === 'height') {
        writeEmbedSide(this.domNode, name, value);
      } else {
        super.format(name, value);
      }
    }
  }
  CustomImageBlot.blotName = 'image';
  CustomImageBlot.tagName = 'IMG';
  Quill.register(CustomImageBlot, true);

  class CustomVideoBlot extends VideoBlot {
    static create(value) {
      var node = super.create(value);
      node.setAttribute('frameborder', '0');
      node.setAttribute('allowfullscreen', 'true');
      node.style.pointerEvents = 'none';
      node.style.border = '0';
      node.style.display = 'block';
      if (isHttpVideoSource(value)) node.setAttribute('src', value);
      return node;
    }

    static formats(node) {
      var formats = {};
      var alt = node.getAttribute('title');
      if (alt != null) formats.alt = alt;
      var width = readSizeAttr(node, 'width');
      if (width !== undefined) formats.width = width;
      var height = readSizeAttr(node, 'height');
      if (height !== undefined) formats.height = height;
      return formats;
    }

    format(name, value) {
      if (name === 'alt') {
        if (value) this.domNode.setAttribute('title', value);
        else this.domNode.removeAttribute('title');
      } else if (name === 'width' || name === 'height') {
        writeEmbedSide(this.domNode, name, value);
      } else {
        super.format(name, value);
      }
      this.domNode.style.pointerEvents = 'none';
      this.domNode.style.border = '0';
      this.domNode.style.display = 'block';
    }
  }
  CustomVideoBlot.blotName = 'video';
  CustomVideoBlot.tagName = 'IFRAME';
  Quill.register(CustomVideoBlot, true);
}

function isSupportedDroppedImageFile(file) {
  if (!file) return false;
  var mime = (file.type || '').toLowerCase();
  if (mime === 'image/svg+xml') return false;
  if (
    mime === 'image/jpeg' ||
    mime === 'image/jpg' ||
    mime === 'image/png' ||
    mime === 'image/webp'
  ) {
    return true;
  }
  var name = (file.name || '').toLowerCase();
  return (
    name.endsWith('.jpg') ||
    name.endsWith('.jpeg') ||
    name.endsWith('.png') ||
    name.endsWith('.webp')
  );
}

function contentWidthLimit(node) {
  var editor = node && node.closest ? node.closest('.ql-editor') : null;
  var width = editor && editor.clientWidth ? editor.clientWidth : 0;
  if (!width || width < 48) width = 800;
  if (width > 1600) width = 1600;
  return width;
}

function imageFilesFromClipboard(data) {
  var accepted = [];
  if (!data) return accepted;
  var list = data.files;
  var i;
  if (list && list.length) {
    for (i = 0; i < list.length; i++) {
      if (isSupportedDroppedImageFile(list[i])) accepted.push(list[i]);
    }
  }
  if (accepted.length) return accepted;
  var items = data.items;
  if (!items) return accepted;
  for (i = 0; i < items.length; i++) {
    var item = items[i];
    if (!item || item.kind !== 'file' || !item.getAsFile) continue;
    var file = item.getAsFile();
    if (isSupportedDroppedImageFile(file)) accepted.push(file);
  }
  return accepted;
}

function scaledBitmap(img, cssWidth) {
  var nw = img.naturalWidth || 1;
  var nh = img.naturalHeight || 1;
  var layoutW = cssWidth > 48 ? cssWidth : 800;
  if (layoutW > 1600) layoutW = 1600;
  var displayScale = nw > layoutW ? layoutW / nw : 1;
  var displayW = Math.max(1, Math.round(nw * displayScale));
  var displayH = Math.max(1, Math.round(nh * displayScale));
  var pixelLimit = Math.min(1600, Math.max(displayW * 2, displayW));
  var pixelScale = nw > pixelLimit ? pixelLimit / nw : 1;
  var src = '';
  if (img.getAttribute) src = img.getAttribute('src') || '';
  if (!src) src = img.src || '';
  var isData = src.indexOf('data:') === 0;
  var payload = isData ? src.length : 0;
  var alreadyJpeg = src.indexOf('data:image/jpeg') === 0 || src.indexOf('data:image/jpg') === 0;
  if (!isData || (pixelScale === 1 && (payload < 280000 || alreadyJpeg))) {
    return { url: src, width: displayW, height: displayH, changed: false };
  }
  var owner = img.ownerDocument || document;
  var canvas = owner.createElement('canvas');
  canvas.width = Math.max(1, Math.round(nw * pixelScale));
  canvas.height = Math.max(1, Math.round(nh * pixelScale));
  var ctx = canvas.getContext('2d');
  if (!ctx) return { url: src, width: displayW, height: displayH, changed: false };
  try {
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    var url = canvas.toDataURL('image/jpeg', 0.82);
    if (!url || (pixelScale === 1 && url.length >= src.length)) {
      return { url: src, width: displayW, height: displayH, changed: false };
    }
    return { url: url, width: displayW, height: displayH, changed: true };
  } catch (err) {
    return { url: src, width: displayW, height: displayH, changed: false };
  }
}

function indexFromPointNode(QuillGlobal, quill, node, offset) {
  if (!node) return null;
  if (node.nodeType === 3) {
    var textBlot = QuillGlobal.find(node, true);
    if (!textBlot) return null;
    return quill.getIndex(textBlot) + offset;
  }
  var blot = QuillGlobal.find(node, true);
  if (!blot) return null;
  if (offset === 0) return quill.getIndex(blot);
  var child = node.childNodes && node.childNodes[offset];
  if (child) {
    var childBlot = QuillGlobal.find(child, true);
    if (childBlot) return quill.getIndex(childBlot);
  }
  return quill.getIndex(blot) + (blot.length ? blot.length() : 0);
}

function indexAtPoint(QuillGlobal, quill, x, y) {
  var doc = quill.root.ownerDocument;
  if (doc.caretPositionFromPoint) {
    var pos = doc.caretPositionFromPoint(x, y);
    if (pos && pos.offsetNode) {
      var index = indexFromPointNode(QuillGlobal, quill, pos.offsetNode, pos.offset || 0);
      if (index != null) return index;
    }
  }
  if (doc.caretRangeFromPoint) {
    var range = doc.caretRangeFromPoint(x, y);
    if (range) {
      var index2 = indexFromPointNode(QuillGlobal, quill, range.startContainer, range.startOffset || 0);
      if (index2 != null) return index2;
    }
  }
  return Math.max(0, quill.getLength() - 1);
}

function installInlineMedia(quill, options) {
  var QuillGlobal = quill.constructor;
  window.__inlineMediaOptions = options;
  window.__inlineMediaQuill = quill;
  window.__inlineMediaResize = {
    overlay: null,
    frame: null,
    handles: [],
    drag: null,
    index: null,
    node: null,
  };

  var root = quill.root;
  var doc = root.ownerDocument;

  function editingLocked() {
    return !!options.readOnly || !!(quill.isEnabled && !quill.isEnabled());
  }

  window.__inlineMediaSetReadOnly = function (value) {
    options.readOnly = !!value;
    if (editingLocked()) hideResizeOverlay();
  };

  if (options.image || options.video) {
    root.addEventListener('dragover', function (e) {
      e.preventDefault();
      if (editingLocked()) return;
      var idx = indexAtPoint(QuillGlobal, quill, e.clientX, e.clientY);
      quill.setSelection(idx, 0, 'silent');
    });
  }

  function readScaledFiles(accepted, k) {
    if (!options.onImageDrop || k >= accepted.length) return;
    var reader = new FileReader();
    reader.onerror = function () {
      readScaledFiles(accepted, k + 1);
    };
    reader.onload = function (ev) {
      var img = new Image();
      img.onload = function () {
        var scaled = scaledBitmap(img, contentWidthLimit(root));
        options.onImageDrop(
          scaled.url,
          scaled.width,
          scaled.height,
          root.clientWidth || scaled.width
        );
        readScaledFiles(accepted, k + 1);
      };
      img.onerror = function () {
        readScaledFiles(accepted, k + 1);
      };
      img.src = ev.target.result;
    };
    reader.readAsDataURL(accepted[k]);
  }

  if (options.image) {
    root.addEventListener('drop', function (e) {
      e.preventDefault();
      if (editingLocked() || !options.onImageDrop) return;
      readScaledFiles(imageFilesFromClipboard(e.dataTransfer), 0);
    });
    doc.addEventListener('paste', function (e) {
      if (editingLocked() || !options.onImageDrop) return;
      if (e.target !== root && !root.contains(e.target)) return;
      var data = e.clipboardData;
      if (!data) return;
      var accepted = imageFilesFromClipboard(data);
      var rawPlain = '';
      try {
        rawPlain = data.getData('text/plain') || '';
      } catch (err) {
        rawPlain = '';
      }
      var plain = rawPlain.replace(/\s+/g, '');
      var plainIsDocument = /[\r\n]/.test(rawPlain) || plain.length > 180;
      if (accepted.length && !plainIsDocument) {
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        readScaledFiles(accepted, 0);
        return;
      }
      if (accepted.length || plain) return;
      var html = '';
      try {
        html = data.getData('text/html') || '';
      } catch (err2) {
        html = '';
      }
      if (!/src=["']data:image\/(?:png|jpe?g|webp);base64,/i.test(html)) return;
      var stripped = html
        .replace(/<img\b[^>]*>/gi, '')
        .replace(/<[^>]+>/g, '')
        .replace(/&nbsp;|&#160;/gi, '')
        .replace(/\s+/g, '');
      if (stripped) return;
      var match = html.match(/src=["'](data:image\/(?:png|jpe?g|webp);base64,[^"']+)["']/i);
      if (!match) return;
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      var pasted = new Image();
      pasted.onload = function () {
        var scaled = scaledBitmap(pasted, contentWidthLimit(root));
        options.onImageDrop(
          scaled.url,
          scaled.width,
          scaled.height,
          root.clientWidth || scaled.width
        );
      };
      pasted.src = match[1];
    }, true);
  }

  function embedNodeAtIndex(index) {
    var leaf = quill.getLeaf(index);
    if (!leaf || !leaf[0]) return null;
    var blot = leaf[0];
    if (!blot.domNode) return null;
    var node = blot.domNode;
    if (node.tagName === 'IMG' || node.tagName === 'IFRAME') return node;
    return null;
  }

  function hideResizeOverlay() {
    var state = window.__inlineMediaResize;
    if (state.overlay && state.overlay.parentNode) {
      state.overlay.parentNode.removeChild(state.overlay);
    }
    state.overlay = null;
    state.frame = null;
    state.handles = [];
    state.drag = null;
    state.index = null;
    state.node = null;
  }

  function axisSign(corner, axis) {
    if (axis === 'x') {
      if (corner.indexOf('e') >= 0) return 1;
      if (corner.indexOf('w') >= 0) return -1;
      return 0;
    }
    if (corner.indexOf('s') >= 0) return 1;
    if (corner.indexOf('n') >= 0) return -1;
    return 0;
  }

  function resizedEdge(origin, delta) {
    var next = origin + delta;
    if (next < 48) return 48;
    return Math.round(next);
  }

  function previewSize(originWidth, originHeight, dx, dy, handle) {
    if (dx === 0 && dy === 0) return { width: originWidth, height: originHeight };
    if (handle === 'n' || handle === 's') {
      return { width: originWidth, height: resizedEdge(originHeight, dy) };
    }
    if (handle === 'e' || handle === 'w') {
      return { width: resizedEdge(originWidth, dx), height: originHeight };
    }
    var width = originWidth <= 0 ? 48 : originWidth;
    var height = originHeight <= 0 ? 48 : originHeight;
    var ratio = width / height;
    var widthDelta = dx / width;
    var heightDelta = dy / height;
    var scaleDelta = Math.abs(widthDelta) >= Math.abs(heightDelta) ? widthDelta : heightDelta;
    var nextWidth = width * (1 + scaleDelta);
    var nextHeight = nextWidth / ratio;
    if (nextWidth < 48 || nextHeight < 48) {
      if (ratio >= 1) {
        nextHeight = 48;
        nextWidth = nextHeight * ratio;
      } else {
        nextWidth = 48;
        nextHeight = nextWidth / ratio;
      }
    }
    return { width: Math.round(nextWidth), height: Math.round(nextHeight) };
  }

  function applyPreviewSize(node, size, commit) {
    node.style.width = size.width + 'px';
    node.style.height = size.height + 'px';
    if (!commit) return;
    node.setAttribute('width', String(size.width));
    node.setAttribute('height', String(size.height));
  }

  function handleCursor(corner) {
    if (corner === 'n' || corner === 's') return 'ns-resize';
    if (corner === 'e' || corner === 'w') return 'ew-resize';
    if (corner === 'nw' || corner === 'se') return 'nwse-resize';
    return 'nesw-resize';
  }

  function showResizeOverlay(index, node) {
    hideResizeOverlay();
    var state = window.__inlineMediaResize;
    var overlay = doc.createElement('div');
    overlay.className = 'inline-media-resize-overlay';
    overlay.style.position = 'absolute';
    overlay.style.pointerEvents = 'none';
    overlay.style.zIndex = '20';
    overlay.style.boxSizing = 'border-box';

    var frame = doc.createElement('div');
    frame.className = 'inline-media-resize-frame';
    frame.style.position = 'absolute';
    frame.style.left = '0';
    frame.style.top = '0';
    frame.style.right = '0';
    frame.style.bottom = '0';
    frame.style.border = '2px solid #1a73e8';
    frame.style.boxShadow = '0 0 0 1px #fff';
    frame.style.boxSizing = 'border-box';
    frame.style.pointerEvents = 'none';
    overlay.appendChild(frame);
    state.overlay = overlay;
    state.frame = frame;
    state.index = index;
    state.node = node;

    var corners = ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'];
    state.handles = corners.map(function (corner) {
      var handle = doc.createElement('div');
      handle.className = 'inline-media-resize-handle';
      handle.dataset.corner = corner;
      handle.style.position = 'absolute';
      handle.style.width = '10px';
      handle.style.height = '10px';
      handle.style.background = '#1a73e8';
      handle.style.border = '2px solid #fff';
      handle.style.borderRadius = '2px';
      handle.style.boxSizing = 'border-box';
      handle.style.pointerEvents = 'auto';
      handle.style.cursor = handleCursor(corner);
      handle.addEventListener('pointerdown', function (e) {
        if (editingLocked()) return;
        e.preventDefault();
        e.stopPropagation();
        var currentIndex = state.index;
        var currentNode = state.node;
        if (currentIndex == null || !currentNode) return;
        var originWidth =
          parseInt(currentNode.getAttribute('width'), 10) ||
          currentNode.clientWidth ||
          1;
        var originHeight =
          parseInt(currentNode.getAttribute('height'), 10) ||
          currentNode.clientHeight ||
          1;
        state.drag = {
          index: currentIndex,
          corner: corner,
          startX: e.clientX,
          startY: e.clientY,
          originWidth: originWidth,
          originHeight: originHeight,
          dx: 0,
          dy: 0,
        };
        if (quill.scroll && quill.scroll.batchStart) quill.scroll.batchStart();
        handle.setPointerCapture(e.pointerId);
      });
      handle.addEventListener('pointermove', function (e) {
        if (!state.drag || state.drag.corner !== corner || !state.node) return;
        var xSign = axisSign(corner, 'x');
        var ySign = axisSign(corner, 'y');
        state.drag.dx = xSign === 0 ? 0 : xSign * (e.clientX - state.drag.startX);
        state.drag.dy = ySign === 0 ? 0 : ySign * (e.clientY - state.drag.startY);
        if (state.drag.raf) return;
        state.drag.raf = doc.defaultView.requestAnimationFrame(function () {
          if (!state.drag || !state.node) return;
          state.drag.raf = 0;
          var size = previewSize(
            state.drag.originWidth,
            state.drag.originHeight,
            state.drag.dx,
            state.drag.dy,
            state.drag.corner
          );
          applyPreviewSize(state.node, size, false);
          positionResizeOverlay(state.drag.index, state.node);
        });
      });
      handle.addEventListener('pointerup', function (e) {
        if (!state.drag) return;
        var d = state.drag;
        if (d.raf) {
          doc.defaultView.cancelAnimationFrame(d.raf);
          d.raf = 0;
        }
        if (state.node) {
          applyPreviewSize(state.node, previewSize(d.originWidth, d.originHeight, d.dx, d.dy, d.corner), true);
        }
        if (quill.scroll && quill.scroll.batchEnd) quill.scroll.batchEnd();
        state.drag = null;
        if (options.onResize) {
          options.onResize(d.index, d.originWidth, d.originHeight, d.dx, d.dy, d.corner);
        }
        try {
          handle.releasePointerCapture(e.pointerId);
        } catch (_) {}
        positionResizeOverlay(d.index, state.node);
      });
      overlay.appendChild(handle);
      return handle;
    });

    var host = root.parentNode || root;
    var hostPosition = doc.defaultView.getComputedStyle(host).position;
    if (hostPosition === 'static') host.style.position = 'relative';
    host.appendChild(overlay);
    positionResizeOverlay(index, node);
  }

  function positionResizeOverlay(index, node) {
    var state = window.__inlineMediaResize;
    if (!state.overlay || !state.frame || !node) return;
    var host = state.overlay.parentNode || root.parentNode || root;
    var hostRect = host.getBoundingClientRect();
    var rect = node.getBoundingClientRect();
    var hostStyle = doc.defaultView.getComputedStyle(host);
    var borderTop = parseFloat(hostStyle.borderTopWidth) || 0;
    var borderLeft = parseFloat(hostStyle.borderLeftWidth) || 0;
    var top = rect.top - hostRect.top - borderTop + (host.scrollTop || 0);
    var left = rect.left - hostRect.left - borderLeft + (host.scrollLeft || 0);
    state.overlay.style.left = left + 'px';
    state.overlay.style.top = top + 'px';
    state.overlay.style.width = rect.width + 'px';
    state.overlay.style.height = rect.height + 'px';
    var placed = state.overlay.getBoundingClientRect();
    var shiftX = rect.left - placed.left;
    var shiftY = rect.top - placed.top;
    if (Math.abs(shiftX) > 0.5 || Math.abs(shiftY) > 0.5) {
      state.overlay.style.left = (left + shiftX) + 'px';
      state.overlay.style.top = (top + shiftY) + 'px';
    }
    state.handles.forEach(function (handle) {
      var c = handle.dataset.corner;
      handle.style.top = '';
      handle.style.bottom = '';
      handle.style.left = '';
      handle.style.right = '';
      handle.style.marginLeft = '';
      handle.style.marginTop = '';
      if (c.indexOf('n') >= 0) handle.style.top = '-5px';
      else if (c.indexOf('s') >= 0) handle.style.bottom = '-5px';
      else {
        handle.style.top = '50%';
        handle.style.marginTop = '-5px';
      }
      if (c.indexOf('w') >= 0) handle.style.left = '-5px';
      else if (c.indexOf('e') >= 0) handle.style.right = '-5px';
      else {
        handle.style.left = '50%';
        handle.style.marginLeft = '-5px';
      }
    });
  }

  function embedNodeAtClientPoint(x, y) {
    var nodes = root.querySelectorAll('img, iframe');
    for (var i = nodes.length - 1; i >= 0; i--) {
      var rect = nodes[i].getBoundingClientRect();
      if (x >= rect.left && x <= rect.right && y >= rect.top && y <= rect.bottom) {
        return nodes[i];
      }
    }
    return null;
  }

  function embedFromEvent(e) {
    var node = null;
    var index = null;
    var target = e.target;
    if (target && (target.tagName === 'IMG' || target.tagName === 'IFRAME')) {
      var blot = QuillGlobal.find(target);
      if (blot) {
        node = target;
        index = quill.getIndex(blot);
      }
    }
    if (!node) {
      node = embedNodeAtClientPoint(e.clientX, e.clientY);
      if (node) {
        var hitBlot = QuillGlobal.find(node);
        if (hitBlot) index = quill.getIndex(hitBlot);
        else node = null;
      }
    }
    if (!node) {
      index = indexAtPoint(QuillGlobal, quill, e.clientX, e.clientY);
      node = embedNodeAtIndex(index);
    }
    if (!node) return null;
    var isImage = options.image && node.tagName === 'IMG';
    var isVideo = options.video && node.tagName === 'IFRAME';
    if (!isImage && !isVideo) return null;
    return { index: index, node: node };
  }

  function selectionTouches(sel, index) {
    if (!sel || index == null) return false;
    if (sel.index === index) return true;
    if (sel.length === 0 && sel.index === index + 1) return true;
    return sel.index < index + 1 && sel.index + sel.length > index;
  }

  function updateResizeOverlay() {
    if (editingLocked()) {
      hideResizeOverlay();
      return;
    }
    var state = window.__inlineMediaResize;
    if (state.drag && state.node) {
      positionResizeOverlay(state.index, state.node);
      return;
    }
    var sel = quill.getSelection();
    var index = sel ? sel.index : null;
    var node = null;
    if (sel && sel.length === 1) node = embedNodeAtIndex(sel.index);
    if (!node && state.node && selectionTouches(sel, state.index)) {
      index = state.index;
      node = state.node;
    }
    if (!node && sel && sel.length === 0) {
      node = embedNodeAtIndex(sel.index) || embedNodeAtIndex(Math.max(0, sel.index - 1));
      if (node) index = node === embedNodeAtIndex(sel.index) ? sel.index : sel.index - 1;
    }
    if (!node) {
      hideResizeOverlay();
      return;
    }
    var isImage = options.image && node.tagName === 'IMG';
    var isVideo = options.video && node.tagName === 'IFRAME';
    if (!isImage && !isVideo) {
      hideResizeOverlay();
      return;
    }
    if (state.overlay && (state.index !== index || state.node !== node)) {
      hideResizeOverlay();
    }
    if (!window.__inlineMediaResize.overlay) {
      showResizeOverlay(index, node);
    } else {
      positionResizeOverlay(index, node);
    }
  }

  window.__inlineMediaApplyAttributes = function (index, alt, width, height) {
    var leaf = quill.getLeaf(index);
    if (!leaf || !leaf[0]) return;
    var blot = leaf[0];
    if (!blot || !blot.format) return;
    if (alt != null && alt !== '') blot.format('alt', alt);
    if (width != null && width !== '') blot.format('width', width);
    if (height != null && height !== '') blot.format('height', height);
  };

  quill.on('selection-change', function () {
    updateResizeOverlay();
  });
  quill.on('text-change', function () {
    var state = window.__inlineMediaResize;
    if (state && state.node && state.node.isConnected && !state.drag) {
      var blot = QuillGlobal.find(state.node);
      if (blot) state.index = quill.getIndex(blot);
    }
    updateResizeOverlay();
  });

  function repositionOverlaySoon() {
    var state = window.__inlineMediaResize;
    if (!state || !state.overlay || !state.node) return;
    if (state.scrollFrame) return;
    state.scrollFrame = doc.defaultView.requestAnimationFrame(function () {
      state.scrollFrame = 0;
      if (!state.overlay || !state.node || !state.node.isConnected) return;
      positionResizeOverlay(state.index, state.node);
    });
  }
  root.addEventListener('scroll', repositionOverlaySoon);
  if (root.parentNode) root.parentNode.addEventListener('scroll', repositionOverlaySoon);

  root.addEventListener('mousedown', function (e) {
    if (e.target && e.target.classList && e.target.classList.contains('inline-media-resize-handle')) return;
    var hit = embedFromEvent(e);
    if (!hit) return;
    e.preventDefault();
  }, true);

  root.addEventListener('click', function (e) {
    if (editingLocked()) return;
    if (e.target && e.target.classList && e.target.classList.contains('inline-media-resize-handle')) return;
    var hit = embedFromEvent(e);
    if (!hit) return;
    e.preventDefault();
    window.setTimeout(function () {
      if (quill.focus) quill.focus();
      quill.setSelection(hit.index, 0, 'silent');
      showResizeOverlay(hit.index, hit.node);
    }, 0);
  });

  root.addEventListener('keydown', function (e) {
    if (editingLocked()) return;
    if (e.key !== 'Backspace' && e.key !== 'Delete') return;
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    var state = window.__inlineMediaResize;
    if (!state || !state.overlay || state.index == null || state.drag) return;
    var sel = quill.getSelection();
    if (!sel) return;
    var collapsed = sel.length === 0;
    var exactEmbed = sel.length === 1 && sel.index === state.index;
    if (!collapsed && !exactEmbed) return;
    var onEmbed = collapsed && sel.index === state.index;
    var backspaceAfter = collapsed && sel.index === state.index + 1 && e.key === 'Backspace';
    if (!exactEmbed && !onEmbed && !backspaceAfter) return;
    e.preventDefault();
    e.stopPropagation();
    var index = state.index;
    hideResizeOverlay();
    quill.deleteText(index, 1, 'user');
    var length = quill.getLength();
    var next = index >= length ? Math.max(0, length - 1) : index;
    quill.setSelection(next, 0, 'silent');
  }, true);

  root.addEventListener('dblclick', function (e) {
    if (editingLocked()) return;
    var hit = embedFromEvent(e);
    if (!hit) return;
    quill.setSelection(hit.index, 1, 'silent');
    if (hit.node.tagName === 'IMG' && options.image && options.onImageDoubleClick) {
      options.onImageDoubleClick();
      return;
    }
    if (hit.node.tagName === 'IFRAME' && options.video && options.onVideoDoubleClick) {
      options.onVideoDoubleClick();
    }
  });
}
''';
