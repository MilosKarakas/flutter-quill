# Quill JS browser checks

`QuillJsEditorView` runs Quill inside an iframe, and most of the image, video,
and block-style behaviour lives in JavaScript injected into that iframe. The
package's `flutter test` suite runs on the Dart VM and cannot load it, and
Flutter's test bindings do not mount platform views. These checks build a small
web app around the editor and drive it in a real Chrome with Playwright.

## Run

Requirements: Flutter, Node.js, Python 3, and Google Chrome.

```bash
cd tool/quill_js_browser_checks
./run.sh                      # feature checks
./run.sh --baseline 3695039   # also compare regular editing with a git ref
./run.sh --debug              # feature checks on a debug (DDC) build
```

Run `--debug` as well as the default. `flutter run` and the apps that host
the editor during development use the debug compiler, which type-checks JS
interop values (for example arrays from the editor iframe) that a profile or
release build accepts, so a bug can show up only there. A check fails when
the page logs a Flutter exception while it runs.

Set `CHROME` if Chrome is not at the macOS default path. The first run installs
`playwright-core` into `driver/node_modules`; it uses the installed Chrome and
downloads no browser. Results go to `results/` (git-ignored).

## What is checked

`driver/features.js` covers the support-article features: inserting and editing
images and videos from the dialog (including in the middle of a line), drop and
paste, the paste rule for Office text, blob URL lifetime across editors, resize,
keyboard handling on a selected embed, undo, copy, the heading menu state and
commands, Preformatted stored as `code-block: true`, video URL normalization,
and the video sandbox.

`driver/regression.js` runs everyday editing on the default editor (typing,
shortcuts, controller calls, list indent, paste, auto-linking, undo and redo,
copy and cut, read-only, `setContents`, drop) and records the document and the
callbacks. With `--baseline <ref>`, the same scenarios run against that ref and
`driver/diff.py` reports any difference. The expected ones:

- `readOnly`: a paste event no longer inserts text into a read-only editor.
- With all new formats enabled, `pasteImageFileOnly`, `setContentsWithEmbeds`,
  and `dropImageFile` differ because images are allowed there.

`3695039` is the last commit before the image, video, and block-style work.
The baseline build uses `app/lib/main_baseline.dart`, which only touches API
that existed then.

## Harness

`app/` is a Flutter web app with page hooks the driver calls (`hGet`, `hSet`,
`hCall`, `hLog`, ...); the top of `app/lib/common.dart` and `app/lib/main.dart`
lists them and the query parameters. To try something by hand, build it with
`flutter build web --profile -t lib/main.dart`, serve `build/web`, and open
`/?mode=full`.

Known timing behaviour, present in the baseline too: setting the selection
from code within about 50 ms of a click can be undone by the editor's delayed
click-to-focus handling. The driver waits after its clicks for that reason.
