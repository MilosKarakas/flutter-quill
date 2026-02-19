typedef QuillJsLinkRange = ({int index, int length});

/// Resolves the target link range for a tapped anchor.
///
/// Priority order:
/// 1) Range resolved from the tapped anchor node (if href matches).
/// 2) Range resolved from current selection (if href matches).
/// 3) Fallback href-based range search.
QuillJsLinkRange? resolveQuillJsTappedLinkRange({
  required String tappedHref,
  required QuillJsLinkRange? rangeFromAnchor,
  required String? hrefFromAnchorRange,
  required QuillJsLinkRange? rangeFromSelection,
  required String? hrefFromSelectionRange,
  required QuillJsLinkRange? rangeFromHrefFallback,
}) {
  if (rangeFromAnchor != null && hrefFromAnchorRange == tappedHref) {
    return rangeFromAnchor;
  }

  if (rangeFromSelection != null && hrefFromSelectionRange == tappedHref) {
    return rangeFromSelection;
  }

  return rangeFromHrefFallback;
}
