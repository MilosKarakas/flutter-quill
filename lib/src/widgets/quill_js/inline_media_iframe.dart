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

function isSameOriginSource(value) {
  if (typeof value !== 'string') return false;
  // A srcdoc document reports location.origin as "null"; window.origin
  // is the origin it inherited from the host page.
  var own = window.origin;
  if (!own || own === 'null') {
    try {
      own = window.parent.location.origin;
    } catch (_) {
      return false;
    }
  }
  try {
    return new URL(value.replace(/^\s+|\s+$/g, ''), window.location.href).origin === own;
  } catch (_) {
    return false;
  }
}

function applyEmbedDimensions(node, width, height) {
  var w = width != null && width !== '' ? String(width).replace(/px$/, '') : null;
  var h = height != null && height !== '' ? String(height).replace(/px$/, '') : null;
  if (w) {
    node.setAttribute('width', w);
    node.style.width = w + 'px';
    node.style.maxWidth = '100%';
  } else {
    node.removeAttribute('width');
    node.style.removeProperty('width');
    node.style.removeProperty('max-width');
  }
  if (h) {
    node.setAttribute('height', h);
    if (w) {
      node.style.height = 'auto';
      node.style.aspectRatio = w + ' / ' + h;
      node.style.removeProperty('object-fit');
    } else {
      // Height alone: keep that height and let the width follow the
      // intrinsic ratio. If the column is narrower, contain the picture
      // instead of stretching it.
      node.style.height = h + 'px';
      node.style.maxWidth = '100%';
      node.style.objectFit = 'contain';
      node.style.removeProperty('aspect-ratio');
    }
  } else {
    node.removeAttribute('height');
    node.style.removeProperty('height');
    node.style.removeProperty('aspect-ratio');
    node.style.removeProperty('object-fit');
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
    node.loading = 'lazy';
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
        editorContentMaxWidth(editor || node)
      );
    }
    node.addEventListener('load', onLoad);
    if (node.complete && node.naturalWidth) window.setTimeout(onLoad, 0);
  }

  function isSvgImageSource(value) {
    var s = String(value || '');
    var lower = s.toLowerCase();
    if (lower.indexOf('data:image/svg+xml') === 0) return true;
    var path = lower.split('#')[0].split('?')[0];
    return path.endsWith('.svg');
  }

  class CustomImageBlot extends BlockEmbed {
    static sanitize(url) {
      if (typeof url !== 'string') return ImageBlot.sanitize(url);
      var trimmed = url.replace(/^\s+|\s+$/g, '');
      if (trimmed.indexOf('blob:') === 0) return trimmed;
      if (trimmed.indexOf('data:') === 0) return trimmed;
      return ImageBlot.sanitize(trimmed);
    }

    static create(value) {
      var node = super.create(value);
      var str = typeof value === 'string' ? value : '';
      if (isSvgImageSource(str)) {
        node.setAttribute('data-src', str);
        node.setAttribute('src', '//:0');
      } else {
        node.setAttribute('src', CustomImageBlot.sanitize(str));
      }
      node.style.display = 'block';
      attachImageLoad(node);
      return node;
    }

    static value(node) {
      return node.getAttribute('data-src') || node.getAttribute('src') || '';
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
        var w = readSizeAttr(this.domNode, 'width');
        var h = readSizeAttr(this.domNode, 'height');
        if (name === 'width') w = value;
        else h = value;
        applyEmbedDimensions(this.domNode, w, h);
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
      node.setAttribute('loading', 'lazy');
      node.setAttribute('referrerpolicy', 'strict-origin-when-cross-origin');
      node.setAttribute(
        'allow',
        'autoplay; encrypted-media; picture-in-picture; fullscreen'
      );
      // allow-scripts with allow-same-origin is no sandbox for a page on the
      // editor's own origin, so such a page loses allow-same-origin.
      node.setAttribute(
        'sandbox',
        'allow-scripts' +
          (isSameOriginSource(value) ? '' : ' allow-same-origin') +
          ' allow-presentation allow-popups allow-popups-to-escape-sandbox'
      );
      node.classList.add('ql-video');
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
        var w = readSizeAttr(this.domNode, 'width');
        var h = readSizeAttr(this.domNode, 'height');
        if (name === 'width') w = value;
        else h = value;
        applyEmbedDimensions(this.domNode, w, h);
      } else {
        super.format(name, value);
      }
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

function editorContentMaxWidth(editorNode) {
  if (!editorNode) return contentWidthLimit(null);
  var style = editorNode.ownerDocument.defaultView.getComputedStyle(editorNode);
  var pl = parseFloat(style.paddingLeft) || 0;
  var pr = parseFloat(style.paddingRight) || 0;
  var w = editorNode.clientWidth - pl - pr;
  if (!w || w < 48) return contentWidthLimit(editorNode);
  if (w > 1600) w = 1600;
  return w;
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

// The text a clipboard HTML fragment would show, without images, markup,
// style sheets, comments, or whitespace.
function visibleHtmlText(html) {
  return String(html || '')
    .replace(/<!--[\s\S]*?-->/g, '')
    .replace(/<(style|script|head|title)\b[\s\S]*?<\/\1\s*>/gi, '')
    .replace(/<img\b[^>]*>/gi, '')
    .replace(/<[^>]+>/g, '')
    .replace(/&nbsp;|&#160;|&#xa0;/gi, '')
    .replace(/\s+/g, '');
}

function displaySizeForBitmap(nw, nh, cssWidth) {
  var layoutW = cssWidth > 48 ? cssWidth : 800;
  if (layoutW > 1600) layoutW = 1600;
  var displayScale = nw > layoutW ? layoutW / nw : 1;
  var displayW = Math.max(1, Math.round(nw * displayScale));
  var displayH = Math.max(1, Math.round(nh * displayScale));
  var pixelLimit = Math.min(1600, Math.max(displayW * 2, displayW));
  var pixelScale = nw > pixelLimit ? pixelLimit / nw : 1;
  return { displayW: displayW, displayH: displayH, pixelScale: pixelScale };
}

function bitmapFromFile(file) {
  if (typeof createImageBitmap === 'function') {
    return createImageBitmap(file).catch(function () {
      return bitmapFromFileViaImage(file);
    });
  }
  return bitmapFromFileViaImage(file);
}

function bitmapFromFileViaImage(file) {
  var url = URL.createObjectURL(file);
  return new Promise(function (resolve, reject) {
    var img = new Image();
    img.onload = function () {
      URL.revokeObjectURL(url);
      resolve(img);
    };
    img.onerror = function (err) {
      URL.revokeObjectURL(url);
      reject(err);
    };
    img.src = url;
  });
}

function readBlobAsDataUrl(blob) {
  return new Promise(function (resolve, reject) {
    var reader = new FileReader();
    reader.onload = function (ev) {
      resolve(ev.target.result);
    };
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
}

function canvasToBlobPromise(canvas, type, quality) {
  return new Promise(function (resolve, reject) {
    if (!canvas.toBlob) {
      reject(new Error('toBlob unavailable'));
      return;
    }
    canvas.toBlob(
      function (blob) {
        if (blob) resolve(blob);
        else reject(new Error('empty blob'));
      },
      type,
      quality
    );
  });
}

function encodeProcessedImage(source, file, cssWidth) {
  var nw = source.width || source.naturalWidth || 1;
  var nh = source.height || source.naturalHeight || 1;
  var sizes = displaySizeForBitmap(nw, nh, cssWidth);
  var mime = (file.type || '').toLowerCase();
  var fileSize = file.size || 0;
  var isJpeg = mime === 'image/jpeg' || mime === 'image/jpg';
  var isPngOrWebp = mime === 'image/png' || mime === 'image/webp';
  var keepOriginal = {
    blob: file,
    displayW: sizes.displayW,
    displayH: sizes.displayH,
  };
  if (sizes.pixelScale === 1 && (isJpeg || (isPngOrWebp && fileSize < 280000))) {
    return Promise.resolve(keepOriginal);
  }
  var owner = source.ownerDocument || document;
  var canvas = owner.createElement('canvas');
  canvas.width = Math.max(1, Math.round(nw * sizes.pixelScale));
  canvas.height = Math.max(1, Math.round(nh * sizes.pixelScale));
  var ctx = canvas.getContext('2d');
  if (!ctx) return Promise.resolve(keepOriginal);
  ctx.drawImage(source, 0, 0, canvas.width, canvas.height);

  function encodeJpeg() {
    // JPEG has no alpha; paint white behind transparent pixels.
    ctx.globalCompositeOperation = 'destination-over';
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.globalCompositeOperation = 'source-over';
    return canvasToBlobPromise(canvas, 'image/jpeg', 0.82);
  }

  var encoded = isJpeg
    ? encodeJpeg()
    : canvasToBlobPromise(canvas, 'image/webp', 0.85)
        .then(function (blob) {
          return blob.type === 'image/webp' ? blob : encodeJpeg();
        })
        .catch(encodeJpeg);
  return encoded.then(function (blob) {
    var smaller = blob.size < fileSize || sizes.pixelScale < 1;
    return {
      blob: smaller ? blob : file,
      displayW: sizes.displayW,
      displayH: sizes.displayH,
    };
  });
}

function processImageFile(file, cssWidth) {
  return bitmapFromFile(file).then(function (bitmap) {
    return encodeProcessedImage(bitmap, file, cssWidth).then(
      function (result) {
        if (bitmap.close) bitmap.close();
        // The blob: URL is made by the host page: one made here would be
        // revoked when this editor's iframe unloads, while the shared image
        // store keeps handing it to other editors.
        return readBlobAsDataUrl(result.blob).then(function (dataUrl) {
          return {
            blob: result.blob,
            dataUrl: dataUrl,
            width: result.displayW,
            height: result.displayH,
          };
        });
      },
      function (err) {
        if (bitmap.close) bitmap.close();
        throw err;
      }
    );
  });
}

function processScaledFiles(accepted, k, root, onDrop) {
  if (!onDrop || k >= accepted.length) return;
  function next() {
    processScaledFiles(accepted, k + 1, root, onDrop);
  }
  processImageFile(accepted[k], editorContentMaxWidth(root))
    .then(function (image) {
      onDrop(
        image.blob,
        image.dataUrl,
        image.width,
        image.height,
        root.clientWidth || image.width
      );
    })
    .catch(function () {})
    .then(next);
}

function dataUrlToBlob(dataUrl) {
  var comma = dataUrl.indexOf(',');
  var header = dataUrl.substring(0, comma);
  var mimeMatch = /^data:([^;,]+)/i.exec(header);
  var mime = mimeMatch ? mimeMatch[1] : 'application/octet-stream';
  var body = dataUrl.substring(comma + 1);
  var bytes;
  if (/;base64/i.test(header)) {
    var binary = atob(body.replace(/\s+/g, ''));
    bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  } else {
    bytes = new TextEncoder().encode(decodeURIComponent(body));
  }
  return new Blob([bytes], { type: mime });
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
      var index2 = indexFromPointNode(
        QuillGlobal,
        quill,
        range.startContainer,
        range.startOffset || 0
      );
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
    batchOpen: false,
    scrollFrame: 0,
    dragOverFrame: 0,
    dragOverPending: null,
  };

  var root = quill.root;
  var doc = root.ownerDocument;
  var win = doc.defaultView;

  var styleEl = doc.createElement('style');
  styleEl.textContent =
    '.ql-media-editing iframe.ql-video { pointer-events: none; }' +
    '.ql-media-selected { caret-color: transparent; }';
  doc.head.appendChild(styleEl);

  function editingLocked() {
    return !!options.readOnly || !!(quill.isEnabled && !quill.isEnabled());
  }

  function syncMediaEditingClass() {
    if (editingLocked()) root.classList.remove('ql-media-editing');
    else root.classList.add('ql-media-editing');
  }
  syncMediaEditingClass();

  window.__inlineMediaSetReadOnly = function (value) {
    options.readOnly = !!value;
    syncMediaEditingClass();
    if (editingLocked()) hideResizeOverlay();
  };

  // The native caret is not painted while another app (the file source) is
  // the active window, so a file drag shows its own drop indicator.
  var dropCaret = null;
  var fileDragActive = false;
  var dragLeaveTimer = 0;

  function showDropCaret(index) {
    var container = root.parentNode;
    if (!container) return;
    var bounds = quill.getBounds(index, 0);
    if (!bounds) return;
    if (!dropCaret) {
      dropCaret = doc.createElement('div');
      dropCaret.className = 'inline-media-drop-caret';
      dropCaret.style.position = 'absolute';
      dropCaret.style.pointerEvents = 'none';
      dropCaret.style.zIndex = '30';
      dropCaret.style.background = '#1a73e8';
      dropCaret.style.borderRadius = '1px';
      container.appendChild(dropCaret);
    }
    var containerRect = container.getBoundingClientRect();
    var embed = embedNodeAtIndex(index);
    var x;
    var y;
    if (embed) {
      var rect = embed.getBoundingClientRect();
      x = rect.left;
      y = rect.top - 3;
      dropCaret.style.width = rect.width + 'px';
      dropCaret.style.height = '2px';
    } else {
      x = containerRect.left + bounds.left - 1;
      y = containerRect.top + bounds.top;
      dropCaret.style.width = '2px';
      dropCaret.style.height = Math.max(bounds.height, 16) + 'px';
    }
    var left = x - containerRect.left;
    var top = y - containerRect.top;
    dropCaret.style.left = left + 'px';
    dropCaret.style.top = top + 'px';
    var placed = dropCaret.getBoundingClientRect();
    if (Math.abs(placed.left - x) > 0.5 || Math.abs(placed.top - y) > 0.5) {
      dropCaret.style.left = left + (x - placed.left) + 'px';
      dropCaret.style.top = top + (y - placed.top) + 'px';
    }
  }

  function endFileDrag() {
    fileDragActive = false;
    if (dragLeaveTimer) {
      win.clearTimeout(dragLeaveTimer);
      dragLeaveTimer = 0;
    }
    var state = window.__inlineMediaResize;
    if (state.dragOverFrame) {
      win.cancelAnimationFrame(state.dragOverFrame);
      state.dragOverFrame = 0;
    }
    state.dragOverPending = null;
    if (dropCaret && dropCaret.parentNode) dropCaret.parentNode.removeChild(dropCaret);
    dropCaret = null;
  }

  if (options.image || options.video) {
    root.addEventListener('dragover', function (e) {
      e.preventDefault();
      if (editingLocked()) return;
      var types = e.dataTransfer && e.dataTransfer.types;
      var hasFiles = false;
      if (types && types.length) {
        for (var ti = 0; ti < types.length; ti++) {
          if (types[ti] === 'Files') {
            hasFiles = true;
            break;
          }
        }
      }
      if (!hasFiles) return;
      if (dragLeaveTimer) {
        win.clearTimeout(dragLeaveTimer);
        dragLeaveTimer = 0;
      }
      fileDragActive = true;
      var state = window.__inlineMediaResize;
      state.dragOverPending = { x: e.clientX, y: e.clientY };
      if (state.dragOverFrame) return;
      state.dragOverFrame = win.requestAnimationFrame(function () {
        state.dragOverFrame = 0;
        var pending = state.dragOverPending;
        state.dragOverPending = null;
        if (!pending || !fileDragActive || editingLocked()) return;
        var idx = indexAtPoint(QuillGlobal, quill, pending.x, pending.y);
        quill.setSelection(idx, 0, 'silent');
        showDropCaret(idx);
      });
    });
    // dragleave also fires between child elements, often without a
    // relatedTarget; the next dragover cancels the pending hide.
    root.addEventListener('dragleave', function (e) {
      if (e.relatedTarget && root.contains(e.relatedTarget)) return;
      if (dragLeaveTimer) win.clearTimeout(dragLeaveTimer);
      dragLeaveTimer = win.setTimeout(function () {
        dragLeaveTimer = 0;
        endFileDrag();
      }, 100);
    });
    root.addEventListener('drop', endFileDrag, true);
    doc.addEventListener('dragend', endFileDrag);
  }

  if (options.image) {
    root.addEventListener('drop', function (e) {
      e.preventDefault();
      if (editingLocked() || !options.onImageDrop) return;
      processScaledFiles(imageFilesFromClipboard(e.dataTransfer), 0, root, options.onImageDrop);
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
      var html = '';
      try {
        html = data.getData('text/html') || '';
      } catch (err2) {
        html = '';
      }
      if (accepted.length) {
        // Office apps put a picture of the copied text next to the text, so
        // the file wins only when the HTML shows nothing but images. With no
        // HTML, a short single line is a file name (a Finder copy).
        var imageOnly = html
          ? !visibleHtmlText(html)
          : !(/[\r\n]/.test(rawPlain) || plain.length > 180);
        if (!imageOnly) return;
        e.preventDefault();
        e.stopPropagation();
        e.stopImmediatePropagation();
        processScaledFiles(accepted, 0, root, options.onImageDrop);
        return;
      }
      if (plain) return;
      if (!/src=["']data:image\/(?:png|jpe?g|webp);base64,/i.test(html)) return;
      if (visibleHtmlText(html)) return;
      var match = html.match(/src=["'](data:image\/(?:png|jpe?g|webp);base64,[^"']+)["']/i);
      if (!match) return;
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      var pastedBlob;
      try {
        pastedBlob = dataUrlToBlob(match[1]);
      } catch (err3) {
        return;
      }
      processScaledFiles([pastedBlob], 0, root, options.onImageDrop);
    }, true);

    // Runs after Quill's own copy handler has filled the clipboard. blob:
    // URLs only resolve in this page, so other apps must receive data URLs.
    function expandClipboardHtml(e) {
      if (!options.expandBlobUrl || !e.clipboardData) return;
      var html = '';
      try {
        html = e.clipboardData.getData('text/html') || '';
      } catch (err) {
        return;
      }
      if (html.indexOf('blob:') < 0) return;
      var expanded = html.replace(/(src=["'])(blob:[^"']+)(["'])/gi, function (all, open, url, close) {
        var data = options.expandBlobUrl(url);
        return data ? open + data + close : all;
      });
      if (expanded !== html) e.clipboardData.setData('text/html', expanded);
    }
    root.addEventListener('copy', expandClipboardHtml);
    root.addEventListener('cut', expandClipboardHtml);

    if (options.collapseDataUrl && quill.clipboard && quill.clipboard.addMatcher) {
      quill.clipboard.addMatcher('IMG', function (node, delta) {
        (delta.ops || []).forEach(function (op) {
          var image = op.insert && op.insert.image;
          if (typeof image === 'string' && /^data:image\//i.test(image)) {
            var collapsed = options.collapseDataUrl(image);
            if (collapsed) op.insert = Object.assign({}, op.insert, { image: collapsed });
          }
        });
        return delta;
      });
    }
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

  function finishDrag(commit) {
    var state = window.__inlineMediaResize;
    if (!state.drag) return;
    var d = state.drag;
    if (d.raf) {
      win.cancelAnimationFrame(d.raf);
      d.raf = 0;
    }
    // Restore the exact pre-drag attributes so batchEnd sees no net change;
    // the committed size arrives as one Dart-side change below.
    if (state.node) {
      applyEmbedDimensions(state.node, d.storedWidth, d.storedHeight);
    }
    if (state.batchOpen && quill.scroll && quill.scroll.batchEnd) {
      quill.scroll.batchEnd();
      state.batchOpen = false;
    }
    state.drag = null;
    var moved = d.dx !== 0 || d.dy !== 0;
    if (commit && moved && options.onResize) {
      // The size written is the one the preview showed, computed once here.
      var size = previewSize(
        d.originWidth,
        d.originHeight,
        d.dx,
        d.dy,
        d.corner,
        editorContentMaxWidth(root)
      );
      options.onResize(d.index, size.width, size.height);
    }
    if (state.node) positionResizeOverlay(d.index, state.node);
  }

  function hideResizeOverlay() {
    var state = window.__inlineMediaResize;
    if (state.drag) finishDrag(false);
    if (state.scrollFrame) {
      win.cancelAnimationFrame(state.scrollFrame);
      state.scrollFrame = 0;
    }
    if (state.dragOverFrame) {
      win.cancelAnimationFrame(state.dragOverFrame);
      state.dragOverFrame = 0;
    }
    if (state.overlay && state.overlay.parentNode) {
      state.overlay.parentNode.removeChild(state.overlay);
    }
    state.overlay = null;
    state.frame = null;
    state.handles = [];
    state.index = null;
    state.node = null;
    root.classList.remove('ql-media-selected');
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

  function previewSize(originWidth, originHeight, dx, dy, handle, maxW) {
    var size;
    if (dx === 0 && dy === 0) size = { width: originWidth, height: originHeight };
    else if (handle === 'n' || handle === 's') {
      size = { width: originWidth, height: resizedEdge(originHeight, dy) };
    } else if (handle === 'e' || handle === 'w') {
      size = { width: resizedEdge(originWidth, dx), height: originHeight };
    } else {
      var width = originWidth <= 0 ? 48 : originWidth;
      var height = originHeight <= 0 ? 48 : originHeight;
      var ratio = width / height;
      var widthDelta = dx / width;
      var heightDelta = dy / height;
      var scaleDelta =
        Math.abs(widthDelta) >= Math.abs(heightDelta) ? widthDelta : heightDelta;
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
      size = { width: Math.round(nextWidth), height: Math.round(nextHeight) };
    }
    if (maxW && size.width > maxW) {
      var r = size.width / size.height;
      size.width = Math.floor(maxW);
      size.height = Math.max(1, Math.round(size.width / r));
    }
    return size;
  }

  function applyPreviewSize(node, size) {
    applyEmbedDimensions(node, size.width, size.height);
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
    overlay.style.touchAction = 'none';

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
    frame.style.touchAction = 'none';
    overlay.appendChild(frame);
    state.overlay = overlay;
    state.frame = frame;
    root.classList.add('ql-media-selected');
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
      handle.style.touchAction = 'none';
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
          storedWidth: currentNode.getAttribute('width'),
          storedHeight: currentNode.getAttribute('height'),
          dx: 0,
          dy: 0,
          raf: 0,
        };
        if (quill.scroll && quill.scroll.batchStart) {
          quill.scroll.batchStart();
          state.batchOpen = true;
        }
        handle.setPointerCapture(e.pointerId);
      });
      handle.addEventListener('pointermove', function (e) {
        if (!state.drag || state.drag.corner !== corner || !state.node) return;
        var xSign = axisSign(corner, 'x');
        var ySign = axisSign(corner, 'y');
        state.drag.dx = xSign === 0 ? 0 : xSign * (e.clientX - state.drag.startX);
        state.drag.dy = ySign === 0 ? 0 : ySign * (e.clientY - state.drag.startY);
        if (state.drag.raf) return;
        state.drag.raf = win.requestAnimationFrame(function () {
          if (!state.drag || !state.node) return;
          state.drag.raf = 0;
          var maxW = editorContentMaxWidth(root);
          var size = previewSize(
            state.drag.originWidth,
            state.drag.originHeight,
            state.drag.dx,
            state.drag.dy,
            state.drag.corner,
            maxW
          );
          applyPreviewSize(state.node, size);
          positionResizeOverlay(state.drag.index, state.node);
        });
      });
      function endPointer(e) {
        if (!state.drag || state.drag.corner !== corner) return;
        finishDrag(true);
        try {
          handle.releasePointerCapture(e.pointerId);
        } catch (_) {}
      }
      handle.addEventListener('pointerup', endPointer);
      handle.addEventListener('pointercancel', endPointer);
      handle.addEventListener('lostpointercapture', endPointer);
      overlay.appendChild(handle);
      return handle;
    });

    var host = root.parentNode || root;
    var hostPosition = win.getComputedStyle(host).position;
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
    var hostStyle = win.getComputedStyle(host);
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
      state.overlay.style.left = left + shiftX + 'px';
      state.overlay.style.top = top + shiftY + 'px';
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
    if (!node) return null;
    var isImage = options.image && node.tagName === 'IMG';
    var isVideo = options.video && node.tagName === 'IFRAME';
    if (!isImage && !isVideo) return null;
    return { index: index, node: node };
  }

  // An embed is selected only by clicking it (showResizeOverlay). Any other
  // caret position, edit, or click deselects it.
  function selectionIsOnEmbed(range, index) {
    if (!range || index == null) return false;
    return range.index === index && (range.length === 0 || range.length === 1);
  }

  function changeEditsContent(delta) {
    var ops = (delta && delta.ops) || [];
    for (var i = 0; i < ops.length; i++) {
      if (ops[i].insert != null || ops[i].delete != null) return true;
    }
    return false;
  }

  function refreshSelectedEmbed() {
    var state = window.__inlineMediaResize;
    if (!state.overlay) return;
    if (editingLocked() || !state.node || !state.node.isConnected) {
      hideResizeOverlay();
      return;
    }
    var blot = QuillGlobal.find(state.node);
    if (!blot) {
      hideResizeOverlay();
      return;
    }
    state.index = quill.getIndex(blot);
    positionResizeOverlay(state.index, state.node);
  }

  function rootEmbed(node) {
    if (!node || node.parentNode !== root) return null;
    if (options.image && node.tagName === 'IMG') return node;
    if (options.video && node.tagName === 'IFRAME') return node;
    return null;
  }

  // A collapsed caret next to a block embed sits in the editor root, where
  // the browser paints it against the embed's edge. A caret before an embed
  // selects it; a caret after one moves to the start of the next line.
  function repairCaretAtEmbed(range) {
    if (!range || range.length !== 0) return false;
    var sel = doc.getSelection ? doc.getSelection() : null;
    if (!sel || !sel.anchorNode) return false;
    var anchor = sel.anchorNode;
    var before = null;
    var after = null;
    if (anchor === root) {
      before = rootEmbed(root.childNodes[sel.anchorOffset - 1]);
      after = rootEmbed(root.childNodes[sel.anchorOffset]);
    } else {
      after = rootEmbed(anchor);
    }
    var target = after || before;
    if (!target) return false;
    var blot = QuillGlobal.find(target);
    if (!blot) return false;
    var index = quill.getIndex(blot);
    // Keyboard moves from below (ArrowUp/ArrowLeft) select the embed so the
    // caret can travel past it; anything else continues on the next line.
    var fromBelow = !caretMovedByPointer && lastCaretIndex != null && lastCaretIndex > index;
    if (!after && target.nextSibling && !fromBelow) {
      hideResizeOverlay();
      quill.setSelection(index + 1, 0, 'silent');
      return true;
    }
    if (index !== range.index) quill.setSelection(index, 0, 'silent');
    var state = window.__inlineMediaResize;
    if (state.overlay && state.node === target) return true;
    showResizeOverlay(index, target);
    return true;
  }

  var lastCaretIndex = null;
  var caretMovedByPointer = false;
  var pointerIsDown = false;
  var caretRepairFrame = 0;

  // Quill emits no selection-change when a new native caret maps to the same
  // index, so the native selection itself is checked as well.
  function scheduleCaretRepair() {
    if (pointerIsDown || fileDragActive || caretRepairFrame) return;
    caretRepairFrame = win.requestAnimationFrame(function () {
      caretRepairFrame = 0;
      var state = window.__inlineMediaResize;
      if (pointerIsDown || fileDragActive || state.drag || editingLocked()) return;
      if (!quill.hasFocus || !quill.hasFocus()) return;
      var range = quill.getSelection();
      if (repairCaretAtEmbed(range)) {
        var current = quill.getSelection();
        if (current) lastCaretIndex = current.index;
      }
    });
  }
  doc.addEventListener('selectionchange', scheduleCaretRepair);
  function endPointer() {
    if (!pointerIsDown) return;
    pointerIsDown = false;
    scheduleCaretRepair();
  }
  doc.addEventListener('pointerup', endPointer, true);
  doc.addEventListener('pointercancel', endPointer, true);
  doc.addEventListener('mouseup', endPointer, true);
  win.addEventListener('blur', function () {
    pointerIsDown = false;
  });

  // editor-change also reports silent selection changes, which the host's
  // focus handling uses.
  quill.on('editor-change', function (eventName, first, second, source) {
    var state = window.__inlineMediaResize;
    if (state.drag) return;
    if (eventName === 'selection-change') {
      // A null range is a blur (for example the toolbar edit button); keep it.
      if (first == null) return;
      var repaired =
        source === 'user' && !fileDragActive && !editingLocked() && repairCaretAtEmbed(first);
      var current = repaired ? quill.getSelection() : first;
      lastCaretIndex = current ? current.index : first.index;
      if (repaired) return;
      if (state.overlay && !selectionIsOnEmbed(first, state.index)) hideResizeOverlay();
      return;
    }
    if (!state.overlay) return;
    if (eventName === 'text-change') {
      if (source === 'user' && changeEditsContent(first)) {
        hideResizeOverlay();
        return;
      }
      refreshSelectedEmbed();
    }
  });

  function repositionOverlaySoon() {
    var state = window.__inlineMediaResize;
    if (!state || !state.overlay || !state.node) return;
    if (state.scrollFrame) return;
    state.scrollFrame = win.requestAnimationFrame(function () {
      state.scrollFrame = 0;
      if (!state.overlay || !state.node || !state.node.isConnected) return;
      positionResizeOverlay(state.index, state.node);
    });
  }
  root.addEventListener('scroll', repositionOverlaySoon);
  if (root.parentNode) root.parentNode.addEventListener('scroll', repositionOverlaySoon);
  win.addEventListener('resize', repositionOverlaySoon);

  if (typeof ResizeObserver === 'function') {
    try {
      var ro = new ResizeObserver(function () {
        repositionOverlaySoon();
      });
      ro.observe(root);
    } catch (_) {}
  }

  root.addEventListener('mousedown', function (e) {
    if (editingLocked()) return;
    if (e.target && e.target.classList && e.target.classList.contains('inline-media-resize-handle')) return;
    var hit = embedFromEvent(e);
    if (!hit) return;
    e.preventDefault();
  }, true);

  root.addEventListener('pointerdown', function (e) {
    caretMovedByPointer = true;
    pointerIsDown = true;
    var state = window.__inlineMediaResize;
    if (!state.overlay || state.drag) return;
    if (e.target && e.target.classList && e.target.classList.contains('inline-media-resize-handle')) return;
    if (embedFromEvent(e)) return;
    hideResizeOverlay();
  }, true);

  root.addEventListener('click', function (e) {
    if (editingLocked()) return;
    if (e.target && e.target.classList && e.target.classList.contains('inline-media-resize-handle')) return;
    var hit = embedFromEvent(e);
    if (!hit) return;
    e.preventDefault();
    window.setTimeout(function () {
      if (quill.focus) quill.focus();
      quill.setSelection(hit.index, 0, 'user');
      showResizeOverlay(hit.index, hit.node);
    }, 0);
  });

  doc.addEventListener('keydown', function (e) {
    caretMovedByPointer = false;
    pointerIsDown = false;
    var state = window.__inlineMediaResize;
    if (state && state.drag && (e.key === 'Escape' || e.key === 'Esc')) {
      e.preventDefault();
      e.stopPropagation();
      finishDrag(false);
      return;
    }
    if (editingLocked() || e.isComposing) return;
    if (!state || !state.overlay || state.index == null || state.drag) return;
    if (e.metaKey || e.ctrlKey) return;
    var sel = quill.getSelection();
    if (!selectionIsOnEmbed(sel, state.index)) {
      hideResizeOverlay();
      return;
    }
    var index = state.index;
    if (e.key === 'Escape' || e.key === 'Esc') {
      e.preventDefault();
      e.stopPropagation();
      hideResizeOverlay();
      quill.setSelection(index + 1, 0, 'user');
      return;
    }
    if (e.key === 'Backspace' || e.key === 'Delete') {
      if (e.altKey) return;
      e.preventDefault();
      e.stopPropagation();
      hideResizeOverlay();
      quill.deleteText(index, 1, 'user');
      var length = quill.getLength();
      quill.setSelection(index >= length ? Math.max(0, length - 1) : index, 0, 'user');
      return;
    }
    var printable = e.key && e.key.length === 1;
    if (e.key !== 'Enter' && !printable) return;
    // Text typed at a block embed's index lands on a new line above it.
    // Continue below the embed instead, reusing an empty line there.
    hideResizeOverlay();
    var after = quill.getContents(index + 1, 1).ops[0];
    var nextLineEmpty = !!after && after.insert === '\n';
    if (!nextLineEmpty) quill.insertText(index + 1, '\n', 'user');
    quill.setSelection(index + 1, 0, 'user');
    if (e.key === 'Enter') {
      e.preventDefault();
      e.stopPropagation();
    }
  }, true);

  root.addEventListener('dblclick', function (e) {
    if (editingLocked()) return;
    var hit = embedFromEvent(e);
    if (!hit) return;
    quill.setSelection(hit.index, 1, 'user');
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
