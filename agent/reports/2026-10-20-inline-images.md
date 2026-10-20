# Inline images — herdr-d1f

STATUS: COMPLETE

## Implementation and decisions

- New `Sources/editxr/Services/Images.swift` owns block discovery, portable SHA-256, PNG IHDR dimensions (no pixel decoding), Mermaid work/cache, and terminal image IDs. `KittyGraphics.swift` owns capability detection, 4096-byte base64 chunks, placement/deletion escapes, and terminal cell pixels.
- `InlineImages.enabled` is evaluated at launch: `--no-images`, JSON `images: false`, or missing terminal markers disable the feature. Accept Kitty/WezTerm/Ghostty markers and `TERM=xterm-kitty`; deliberately do not query stdin, avoiding interference with the editor's input/probing machinery. Unknown terminals retain today's rendering.
- PNGs resolve relative to the document directory; absolute paths, percent-encoded paths, and angle-bracket paths work. Only standalone image lines and fenced Mermaid blocks are replaced. URLs and images inside ordinary code fences stay text. Backtick and tilde Mermaid fences require a matching closing fence.
- Cursor anywhere from opening through closing fence reveals the entire original fence. Cursor on a PNG line reveals that line. Raw view, diff/review, selection, syntax-highlighted code files, and modal/palette overlays disable image layout.
- Mermaid runs on a serial DispatchQueue; stdin is written concurrently with stdout reading to avoid pipe deadlock. Main-queue completion schedules a redraw, even if the user moved to another tab (the new frame decides which results are relevant). Exit 2 is silent; other failures show a bounded one-line toast. Failed keys are not retried each frame. A 15-second soft process termination bounds normal helper failures.
- Helper invocation: `$EDITXR_MERMAID_PNG mermaid-png --theme dark|light --scale N`, otherwise `/usr/bin/env mini-md-ide ...`. Source goes on stdin, PNG on stdout. Default scale is 2, configurable integer 1–4 via `imageScale`.
- Cache name is SHA-256 of UTF-8 `theme + NUL + scale + NUL + fence body`, lowercase hex. Cache directory is `$XDG_CACHE_HOME/editxr/mermaid`, default `~/.cache/editxr/mermaid`. Writes are atomic; invalid cached PNG headers trigger regeneration. Cache IO failure is nonfatal (memory result remains usable).
- `imageMaxRows` defaults to 12 (clamped 1–100). Size fits content width, content height and max rows while preserving pixel aspect, rounded to cell boundaries. `TIOCGWINSZ` supplies pixel/cell dimensions; missing dimensions fall back to 8×16. Local files are limited to 32 MiB, cached by path/mtime/size, then content hash; first read/hash is synchronous, later frames only stat the file.

## Layout hook and graphics lifetime

`EditorApp.prepareImages` runs **before** `state.adjustScroll` in `renderEditor`. It builds a source-line row-count map: the opening line owns N image rows, remaining fence lines own zero. `EditorState.visualRowCount`, cursor visual position, total row count, viewport scrolling, and mouse row→source mapping use this map. Clicking any image row lands on its source opening line, immediately revealing editable text. Arrow movement continues to navigate source; there are no artificial editable image rows.

`renderNormalModeWrapped` consumes the same map, reserves blank rows, skips covered fence lines, and collects placements only when the whole image rectangle is visible. With wrap off, this same image-aware traversal keeps text to one row and preserves horizontal scrolling/caret rendering. The normal no-image path remains unchanged.

Placement coordinates include top bar/tab strip, sidebar, separator and gutter. Full redraw emits `a=d,d=a` first, retaining transmitted pixels; then paints text and visible placements within the existing synchronized-update frame. Each service ID is transmitted once (`a=t,f=100`, base64 chunks, `m=1/0`) and reused by `a=p`. `C=1` prevents placements moving the cursor. Quit deletes image data with `d=A`. Resize recomputes dimensions and visibility at the next frame without retransmitting data.

## Verification

### Builds and diagnostics

- macOS release: `DEVELOPER_DIR=/Library/Developer/CommandLineTools swift build -c release` — successful, final build after the image-line reveal fix 16.73 seconds. Executable: `.build/release/editxr`.
- Final binary: **1,368,344 bytes**; baseline before implementation: **1,289,016 bytes**; delta **+79,328 bytes (+6.15%)**. SHA-256: `5be7f4bbbb05ca42be85a65a239c8c840e3fa002c4cc549d1dc493ca637386c7`.
- The baseline build itself succeeded; its chained BSD `stat -f %z` failed because this machine resolves GNU stat. Size was then measured with Python before the feature rebuild.
- Active SourceKit diagnostics on all six changed Swift files: no new diagnostics; one pre-existing unused `uri` warning in `EditorApp.swift`. `git diff --check` clean.
- Linux compilation succeeded in Docker (`swift:6.3.2`, x86_64 Linux). Final combined affected tests pass (34), with zero failures in 3.197 seconds. The macOS release binary has been rebuilt after the image-line reveal correction below.

### Tests

Tests were written before implementing the APIs. The initial Docker `--filter Images` run failed to compile on the absent image APIs/row mapping, establishing the red baseline.

Commands (from this worktree):

```sh
RCI_HOST=forge rci 'docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/src -w /src swift:6.3.2 swift test --scratch-path /tmp/editxr-images-build --filter "Images|RenderTests|CursorScrollTests|MouseTests" > /tmp/images-verified.log 2>&1; result=$?; tail -50 /tmp/images-verified.log; exit $result'
RCI_HOST=forge rci 'docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/src -w /src swift:6.3.2 swift test --scratch-path /tmp/editxr-images-mouse --filter MouseTests > /tmp/images-mouse.log 2>&1; result=$?; tail -12 /tmp/images-mouse.log; exit $result'
```

**Affected tests pass (34 tests, 4 test classes): ImagesTests 9, RenderTests 11, CursorScrollTests 2, MouseTests 12. Zero failures; final test execution 3.197 seconds.** Standalone MouseTests also passed (12 tests). The preceding runs executed Images (9), RenderTests (11), CursorScrollTests (2). Only the image-line reveal assertion failed. Initially corrected the assertion to strip ANSI using `RenderTests.plain`; the repeated failure then exposed the real rendering issue: the existing Markdown parser sees the `[alt](path)` portion as a link starting at column 1, so a cursor on the leading `!` did not reveal the link source. The image-enabled render path now explicitly marks that source line raw in both wrapped and unwrapped modes. Unsupported/disabled terminals keep their previous markup behavior. This is the third verification attempt for this particular reveal obstacle; no assertion was weakened. Also added a regression assertion for horizontal scrolling with wrap off. The last combined filter additionally includes `MouseTests`.

The first affected-run attempt failed before compilation: Docker's root-owned `.build` artifacts made rci's rsync deletion fail. Repaired ownership of that remote scratch directory; subsequent Docker invocations run as the remote UID/GID with ephemeral `/tmp` scratch paths. No repository state was reset. No full test suite was run. The known unrelated LinkWrapTests failure was not selected.

Coverage includes fence/cursor exclusion, code-fence and URL exclusion, known SHA-256 cache key, capability markers, chunking and placement escapes, transmit-once reuse, height contribution/opt-out/raw view, image mouse mapping and scrolling (wrap on/off), unwrapped horizontal caret visibility, aspect fit, asynchronous stub output/disk cache and silent unsupported fallback.

### PTY

The supplied `agent/ptyprobe.py` was used with `TERM=xterm-kitty`, the stub helper, and `agent/fixtures/sample.md`; a second run passed `--no-images`. `agent/verify-inline-images.py` asserts the captures:

- Fully rendered Mermaid starts at **terminal row 6, column 2**, matching source line 5 after the one-row top bar and four preceding content rows.
- The local PNG starts at **row 21, column 2** after the 12-row Mermaid picture and three intervening text/blank rows.
- Both rectangles occupy 12 rows; each ID is transmitted once, chunks never exceed 4096 base64 bytes, and every full frame deletes old placements before repainting.
- The opt-out capture contains no `ESC_G` commands.

Initial captures `/tmp/editxr-images.pty` and `/tmp/editxr-no-images.pty` passed these assertions. The first combined wrapper timed out at 40 seconds because the supplied probe waits up to 30 seconds **per process** (the attempted Ctrl+Q event did not exit it). The second probes used an 80-second combined budget, but saved cursor history started inside the fence. Inspection showed the supplied probe replays overlapping OSC query matches and can inject a fragment such as `:1e1e/1e1e/1e1e` into the buffer before scripted movement; on a fence line that invalidates the fence. This is a probe/input artifact, not a saved fixture change. The third/final probe uses fresh temporary copies of both fixtures (no saved cursor history), the original `[[0.5, ""]]` script, and an 80-second budget. Captures are `/tmp/editxr-images-isolated.pty` and `/tmp/editxr-no-images-isolated.pty`. Final completion: **passed**, exit 0; both probes completed in 30.06 seconds each. Verifier output: `PTY assertions pass: placements at rows 6 and 21, column 2; 12 rows each; two single transmissions; opt-out emits no graphics`.

Reproduction of the final isolated run:

```sh
probe=$(mktemp -d /tmp/editxr-images-probe.XXXXXX)
cp agent/fixtures/sample.md agent/fixtures/sample.png "$probe/"
python3 agent/ptyprobe.py /tmp/editxr-images-isolated.pty '[[0.5,""]]' env TERM=xterm-kitty EDITXR_MERMAID_PNG=agent/stub-mermaid-png.sh .build/release/editxr "$probe/sample.md"
python3 agent/ptyprobe.py /tmp/editxr-no-images-isolated.pty '[[0.5,""]]' env TERM=xterm-kitty EDITXR_MERMAID_PNG=agent/stub-mermaid-png.sh .build/release/editxr --no-images "$probe/sample.md"
python3 agent/verify-inline-images.py /tmp/editxr-images-isolated.pty /tmp/editxr-no-images-isolated.pty
```

### Actual WezTerm

Launched the built editor in a **new, dedicated WezTerm window** with the full-path stub override. WezTerm version: `20240203-110809-5046fc22`.

Screenshots were captured and inspected, not inferred from terminal text:

- [`screenshots/wezterm-inline.png`](screenshots/wezterm-inline.png): Mermaid PNG below “Some text before.” and above “Text between.”
- [`screenshots/wezterm-raw.png`](screenshots/wezterm-raw.png): Ctrl+R removes the picture and restores fence/image source.
- [`screenshots/wezterm-scrolled.png`](screenshots/wezterm-scrolled.png): moving down reveals the local PNG above the visible caret and “Text after.”; the previous Mermaid placement is gone.
- [`screenshots/wezterm-cursor-in-fence.png`](screenshots/wezterm-cursor-in-fence.png): moving back into the Mermaid body removes that picture and restores editable code-block styling/caret.

Exited only the test pane after inspection. No document edits were saved. The provided PNG/sample document were retained as fixtures.

## Honest scrolling assessment and open issues

- Fully visible images render and move correctly in the inspected WezTerm frames. Expanded row counts participate in scroll bounds and mouse mapping; existing cursor/table scroll regressions are covered by the affected tests.
- **Partial images are intentionally not placed**, at either top or bottom. Their rows remain reserved and therefore look blank until the complete rectangle fits. There is no pixel cropping/smooth image scroll. This is the brief's simplest clipping option.
- Moving into/out of a fence changes its rendered height; the existing cursor-follow logic can visibly re-anchor the viewport. It keeps source editable, but is not a stable visual-anchor/smooth-scroll implementation.
- Real helper integration is unverified because `mini-md-ide` is being built separately. Verified its contract using the provided fixed-PNG stub. The stub picture is intentionally identical to the local fixture, not a rasterization of each test source.
- No additional Kitty query fallback, Sixel/iTerm protocol, HTTP fetching, reference-style images, inline paragraph images, image titles, or animated formats. PNG dimensions are inspected, but actual PNG decoding/validation belongs to the terminal.
- Capability markers are heuristics; nested multiplexers or terminals advertising markers but not forwarding graphics can leave blank reserved rectangles. Unknown terminals without markers remain text-only.
- Only the tested WezTerm build was visually verified. Physical interactive resize, other terminal implementations, and Windows were not independently exercised; Linux compilation is checked by Docker tests. Windows Mermaid helper invocation deliberately falls back with a status message.
- Local first-read IO is synchronous (bounded size); a slow/network filesystem can stall that first load. Session image data/IDs and Mermaid disk cache do not yet have an LRU/size eviction policy. Failed Mermaid keys retry only after source/theme/scale changes or restart. A malicious helper that ignores SIGTERM or retains stdout in descendants can outlive the soft timeout.
- Existing raw-text versus collapsed-markup wrapping discrepancies outside image blocks are not redesigned here.

No commits, pushes, or state-changing git commands were run. LLM/OAuth and `AIFeature` were not modified.
