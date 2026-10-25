# Proofdeck

*[日本語版はこちら](README.ja.md)*

A macOS viewer for `.pptx` files that reloads the deck whenever another app
rewrites it.

If you have Claude (or any tool) generate a deck, look at the result, give
feedback and let it regenerate the file, PowerPoint is the wrong place to
look: it keeps showing the version it opened. This viewer watches the file,
redraws within about a second of each save, and stays on the slide you were
looking at.

> Development happens in a private Azure DevOps repository; this GitHub
> repository is a published mirror, updated when there is something worth
> publishing. Issues and discussion here are read — pull requests are applied
> by hand upstream, so please open an issue first for anything substantial.

## Features

- Reloads on every save, whether the file is overwritten in place or replaced
  through a temporary file. Half-written files are never read.
- Keeps your place: the same slide number after a reload, the last slide if
  that one disappeared.
- A left pane with numbered thumbnails (hidden slides dimmed and struck
  through), one slide at a time on the right, speaker notes underneath.
- Marks the slides that changed in the last update, and flips between the
  previous and current version of the slide you are on with ⌘B.
- A memo pane next to the notes: write feedback per slide, then copy it all
  with ⌥⌘C as "Slide 12 «title»: …" — ready to paste back into Claude.
- Search across slide text and notes, copy a slide as a 4K PNG, export the
  deck to PDF or PNGs, run a full-screen slide show that keeps updating.
- Remembers window position, size and current slide per file, and reopens
  the files you had open when you quit.
- An MCP server for Claude: it can see the slide you are on, render slides
  with this renderer, measure overflowing text, read and resolve your memos,
  move the viewer, and hold redraws while it is still writing the file.
- Renders in-process with a JavaScript renderer inside WKWebView. No
  PowerPoint, no external converter, and no network access at all.

Requires macOS 14 or later. Apple Silicon and Intel.

## What it does and does not do

| | |
| --- | --- |
| Display a `.pptx` faithfully | Mostly. Text, shapes, fills, images, tables, hidden slides and notes render; the renderer is [pptx-vanilla-viewer](https://github.com/ChristopherVR/ooxml) with a few local fixes (see below) |
| Match PowerPoint pixel for pixel | **No.** Line breaks follow CoreText's glyph metrics, so a title that only just fits in PowerPoint may wrap here or the other way round. Animations and transitions are not shown |
| Edit | **No.** It is a viewer. Edit the file with whatever wrote it and watch it update |
| Quick Look (space bar in Finder) | **Ships, but not active by default.** A preview extension is bundled and registered, yet macOS keeps using its built-in Office previewer while PowerPoint is the default app for `.pptx`. Not verified with this app set as the default |
| Work offline | Yes. The page that draws the slides is served from inside the app over a private URL scheme, and http/https are blocked at the WebKit level |

## Install

Download the zip from [Releases](../../releases), unpack it, and move
`Proofdeck.app` to `~/Applications` — or build it yourself (below).

The release build is ad-hoc signed and not notarized, so macOS blocks the
first launch. To allow it, open **System Settings → Privacy & Security**,
scroll down to Security, and press **Open Anyway** next to the message about
Proofdeck.

Open a deck with **File → Open…**, from the Finder's *Open With* menu, or

```bash
open -a Proofdeck path/to/deck.pptx
```

| | |
| --- | --- |
| Open / recent files | ⌘O / File menu |
| Reload | ⌘R |
| Zoom in / out / fit | ⌘+ / ⌘- / ⌘0 |
| Move between slides | ← → PageUp PageDown Space, or click the thumbnail |
| Toggle notes and memo | ⌥⌘N |
| Previous version of this slide | ⌘B |
| Find / next / previous | ⌘F / ⌘G / ⇧⌘G |
| Copy slide as image | ⌘C in the sidebar, ⇧⌘C anywhere |
| Copy all memos | ⌥⌘C |
| Export PDF / PNG | ⌘E / File → Export |
| Slide show | ⇧⌘↩, Esc to leave |
| Help | ⌘? |

## Claude (MCP)

The app bundles an MCP server. Register it once with Claude Code — from the
app menu, **Proofdeck → Claude Code と連携する…**, or by hand:

```bash
claude mcp add proofdeck --scope user -- ~/Applications/Proofdeck.app/Contents/MacOS/proofdeck-mcp
```

| Tool | What it does |
| --- | --- |
| `list_open_decks` | Open decks with slide count, current slide, slides changed in the last update, memo count |
| `open_deck` | Open a `.pptx` in the viewer |
| `get_current_slide` | The slide the user is looking at: number, title, text, notes, memo — so "this slide" needs no number |
| `get_slides` | Number, title, text, notes, hidden, changed, memo for a range of slides |
| `render_slide` | The slide as an image, drawn by the same renderer the user sees |
| `check_layout` | Measures the rendered slide: text overflowing its box, text off the slide, text overlapping text (in inches) |
| `get_changes` | Slides changed by the last rewrite, with added and removed lines |
| `get_memos` / `resolve_memo` | Read the user's per-slide feedback; mark it done (the sidebar shows a green check) |
| `goto_slide` | Move the viewer to a slide |
| `set_generating` | Before writing the file `on: true`, after `on: false`: the viewer shows a banner and redraws once at the end |

The server talks to the running app over a Unix socket in
`~/Library/Application Support/Proofdeck/` that only your user can
open, and starts the app in the background if it is not running. Nothing
listens on the network.

An ad-hoc signature changes with every build, so after updating a release
macOS treats it as a new app and asks again for access to protected folders
such as the Desktop. A build of your own signed with an Apple Development
identity (below) keeps those grants.

## Build

```bash
./build.sh install
```

This installs the renderer's npm dependencies, applies the local patches,
bundles the page with esbuild, generates the Xcode project from `project.yml`
with XcodeGen, builds the app and its Quick Look extension, copies
`Proofdeck.app` to `~/Applications` and registers the extension.
Requires Xcode, Node.js and `brew install xcodegen`.

Signing uses whichever Apple Development identity is in your keychain
(override with `DEVELOPMENT_TEAM=…`); with no identity at all the build is
signed ad-hoc. `Proofdeck.xcodeproj` is generated from `project.yml` and is
not committed — run `scripts/bootstrap.sh` after adding a source file, and
`scripts/ci.sh` for the same checks CI runs. [SPEC.md](SPEC.md) covers the
architecture (in Japanese).

`swift build` still works for quick debug runs of the app alone.

The built `.app` lives in `.build/` on purpose: a copy in the project folder
would show up in Spotlight next to the installed one.

## How it works

| | |
| --- | --- |
| Watching | `stat` every 0.25 s plus a kqueue on the parent folder, so both in-place writes and atomic replaces are caught. A change is accepted only once the ZIP's end-of-central-directory record is present |
| Rendering | pptx-vanilla-viewer (Apache-2.0, built on ooxml-core / ooxml-ui) in a WKWebView, loaded over a `ppv://` scheme handler. The deck bytes are handed to the page the same way |
| Thumbnails | A second, hidden WKWebView renders the same deck and is snapshotted slide by slide; only changed slides are redone, and the view is torn down when idle |
| Notes | Read straight from the `notesSlide*.xml` parts, so a notes-only save updates the notes without redrawing |
| Changed slides | Each slide is fingerprinted by the CRCs of its XML and relationships, so insertions and deletions don't mark everything as changed. The previous version stays on disk for ⌘B |
| Export | The hidden view is enlarged and snapshotted per slide; the PDF embeds JPEGs at 2560 px, the PNGs are 3840 px |

Patches to the renderer live in `web/patches/patches.mjs` and are reapplied
on every build: text colour alpha, hanging punctuation (the library's
zero-width trick hid Japanese commas in WebKit), and repeated `a:pPr`
elements as written by pptxgenjs, and the five-point star preset, whose
guides differed from the OOXML definition. They are meant to go upstream.

## Why it exists

Writing slides with an AI and iterating on them turns the viewer into the
feedback loop. PowerPoint will not reload a file it has open; Quick Look drops
text inside shapes; the Office-derived converters are large and copyleft. This
is the small, open piece that was missing.

## License

MIT — see [LICENSE](LICENSE). The app icon and the name (Proofdeck) are the
author's own work and are not part of that grant; please use your own if you
fork this.

Proofdeck is an independent project, not affiliated with or endorsed by
Microsoft. PowerPoint is a trademark of Microsoft Corporation; the name is
used only to say what files this software opens.
