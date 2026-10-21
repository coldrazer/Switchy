# The ultimate Switchy app — blueprint

A native Mac application built on this repository. The game stays the game; everything around it
becomes software.

This document is the plan, not the code. It says what the app is, what has to change in this
repository to make it possible, and in which order.

---

## 1. The problem with today

The repository builds a Mac app, but the *build* is the product:

- `build_app.py` is a 1,000-line script with seven flags, run from a terminal.
- It needs Xcode command line tools, Homebrew, `opus`, `libvpx` and Python 3.14 — five installs
  before anything works.
- It runs for twenty minutes with a terminal as its only progress display.
- The result is a `.app` that contains a 200-line launcher shim (`games/totk/app/launcher.m`) which
  does nothing but set environment variables and `execv` the game.

The pieces that make a good desktop application — a library, settings, mod management, progress,
diagnostics, updates — do not exist, because the build pipeline is a script rather than a service.

## 2. The shape of the thing

```
┌──────────────────────────────────────────────────────────┐
│  Switchy.app                 SwiftUI shell               │
│  Library · Setup · Settings · Mods · Diagnostics         │
│  Overlay: a separate AppKit/WebView process              │
└───────────────┬──────────────────────────────────────────┘
                │  XPC / Unix socket, JSON events both ways
┌───────────────▼──────────────────────────────────────────┐
│  com.macnativegames.agent        launchd, headless        │
│  job queue · state store · input detection · watcher     │
└───────────────┬──────────────────────────────────────────┘
                │  supervised subprocess, each step hash-checked
┌───────────────▼──────────────────────────────────────────┐
│  Toolchain                    ships inside the bundle     │
│  totk-native ×4 · totk_xlate · spirv-cross · Python       │
└───────────────┬──────────────────────────────────────────┘
                │  streaming reads
┌───────────────▼──────────────────────────────────────────┐
│  totk-native                     the game, its own process│
└──────────────────────────────────────────────────────────┘
```

**The app never hosts the game.** It prepares the environment and launches the game, the way a
platform does. The game keeps running as `totk-native` with the Switch's Horizon services answered
by the host and NVN replayed on Metal 4.

**The agent owns the state.** The app is a client. A build survives the app closing, because the
agent is a `LaunchAgent`, not a child process.

### Distribution

GitHub Releases, notarized, with a one-click updater. Not the Mac App Store: the app's job is to
build a copy of a game the user already owns, and a store reviewer has no way to evaluate that.
Releases are the honest distribution channel for a project like this.

---

## 3. The one refactor everything else depends on

**Today the native binary is compiled against the player's own data.** `build/romfs_config.h` and
`build/shared_fonts_config.h` are generated from the extracted game and the extracted fonts, so
`totk-native` cannot be shipped prebuilt — every player has to compile it. That is the single
reason the user needs a compiler.

The fix is to separate the facts about the data from the code that uses them.

### 3.1 What is a version constant, and what is a player's

| Fact | Source today | Whose is it? |
|---|---|---|
| RomFS image size | `romfs_config.h` | **Version.** `assets/expected-v*.json` already pins it. |
| RomFS image SHA-256 | `romfs_config.h` | **Version.** Same file, `romfs/sha256`. |
| `runtime-index.bin` SHA-256 | `romfs_config.h` | The build's own output, derived from the RomFS. |
| Six shared fonts: path, size, SHA-256 | `shared_fonts_config.h` | **Player.** Another firmware version's fonts are accepted and bound by their own bytes. |

The RomFS is the retail game's plaintext: identical for every genuine dump of a version. The
`expected-v*.json` files in this repository already say so, and `build_app.py` already checks the
player's extracted RomFS against them. So the runtime can compile the RomFS facts in from the
checked-in file instead of from the player's data, with no loss of meaning and no loss of strength.

Two things are genuinely per-player, and those move to a file the build writes next to the data it
describes.

### 3.2 The runtime manifest

A plain text file, `runtime-manifest.txt`, written into the RomFS directory:

```
format	1
romfs_index_sha256	<64 lowercase hex>
font	0	extracted/firmware/shared-fonts/0-standard.bfttf	<bytes>	<font bytes>	<64 hex>
font	1	…
```

Tab-separated, matching the house style of `manifest.tsv` and `controls.txt`. It carries the index
digest and the six font rows. Nothing else.

**Where it lives matters.** The manifest goes in the RomFS directory — the one directory the
runtime already resolves — so it is found by code that already exists, and it is covered by the
app's code signature in the shipped product. The fonts themselves stay in the user's own directory
(the iPhone copies them into its Documents), and the manifest still pins their digests, so a
tampered font is still caught. The trust model is unchanged: trusted expectations in the signed
bundle, untrusted data outside it, checked against each other.

### 3.3 Files to change

| File | Change |
|---|---|
| `games/totk/runtime/runtime_manifest.h` | **New.** The manifest's shape and the reader's API. |
| `games/totk/runtime/runtime_manifest.c` | **New.** A strict line parser. No dependency on the rest of the runtime, so it compiles standalone in a test. |
| `games/totk/runtime/romfs.c` | `ROMFS_INDEX_SHA256` comes from the manifest. The image size and digest stay compiled in, now from `expected-v*.json`. |
| `games/totk/runtime/shared_font.c` | The six rows come from the manifest instead of the generated header. |
| `games/totk/scripts/prepare_romfs_backend.py` | Writes the header from `assets/expected-v*.json` instead of the player's `index.json`. Still builds `runtime-index.bin` from the player's data. |
| `games/totk/scripts/prepare_runtime_manifest.py` | **New.** Writes the manifest: the index digest and the font rows. |
| `games/totk/scripts/prepare_shared_fonts.py` | Folded into the new script; its font validation moves with it. |
| `games/totk/Makefile` | The four link lines gain `runtime/runtime_manifest.c`; the header dependencies become manifest dependencies. |
| `build_app.py` | Clones the manifest into the app next to `runtime-index.bin`. |
| `games/totk/ios/tools/build_ipa.py` | The manifest travels with the RomFS directory, which is already copied whole. |
| `tests/test_runtime_manifest.c` | **New.** The parser against synthetic manifests and malformed input. |
| `tests/test_runtime_manifest.py` | **New.** The generator and the parser agree. |

### 3.4 What this does not touch

- **`patch_nso.py` and the NSO rewriter.** Its output is pinned by `expected-v*.json`
  (`rewritten_sha256`), because those rewrites were verified site by site against the original in an
  emulator with negative controls. Changing the rewriter invalidates that verification; it is not a
  refactor target.
- **The game code itself.** The MitM-style rewrites are the port.
- **`totk_xlate`.** Pinned by `totk_xlate.sha256`; rebuilt with `publish_native.sh` and shipped
  prebuilt.

---

## 4. Phases

### Phase 1 — Make the toolchain prebuildable

The §3 refactor. Build `totk-native` for all four versions and ship them. Prebuild `spirv-cross`.
Embed Python with its wheels. The user needs no compiler, no Homebrew and no Xcode.

*Done when:* `totk-native` for v0/v112/v121/v143 builds from checked-in constants alone, and the
test suite is green.

> **Status: the manifest refactor is in.** `runtime/runtime_manifest.{h,c}` read the index digest and the font rows
> at start; `prepare_romfs_backend.py --header-only` writes `romfs_config.h` from `assets/expected-v*.json` alone (all
> four versions: `make romfs-headers`) and still refuses an extracted RomFS that does not match it;
> `prepare_runtime_manifest.py` writes the manifest into the RomFS directory; `build_app.py` clones it into the app and
> the iOS build requires it. `prepare_shared_fonts.py` is gone, its font validation folded into the new script.
> Checked without game data: 906 parser cases under `-fsanitize=undefined -fno-sanitize-recover=all`, the Python
> generator and the C parser agree on good and malformed input, and the production `romfs.c` + `shared_font.c`,
> started on a synthetic RomFS, stop on a tampered font, index, image or manifest (`tests/test_runtime_manifest.py`).
>
> **Still open:** `build/runtime_tables.h` is generated from the player's rewritten modules
> (`scripts/prepare_runtime.py`), so the binary is not yet prebuildable; §3.1 missed it. The tables derive from the
> game's code and cannot be checked in; they need the manifest's treatment (read at start, pinned by
> `rewritten_sha256`). Building all four versions and starting the game needs a Mac with game data.

### Phase 2 — The agent

Turn `build_app.py` from a script into importable steps with a declared job graph. Add a state
store, a `LaunchAgent`, structured progress events and resumable builds.

The resume logic is already there: `source_matches`, `exefs_matches` and the
`sha256(image) == h` pattern all skip completed work whose output still matches. It needs a state
store and a job graph, not a new idea.

> **Status: in** (`mng_agent`, `docs/app.md`). `build_app.py` is a declared step graph (`STEPS`, `run_pipeline`); the
> agent runs it as a supervised subprocess with JSON events, keeps jobs/library/mods/settings in a state store, resumes
> an interrupted build, and serves the app over a Unix socket. `python3 -m mng_agent` does everything from a terminal.

### Phase 3 — Streaming RomFS

Stop extracting 17 GB. Read pages out of the encrypted container through a page cache; build the
RomFS index from the directory tree alone.

The 20-second whole-image SHA-256 goes away — each block is verified as it is read. Disk cost drops
from 34 GB beyond the game the user already owns to 0.4 GB.

This is the phase that makes the app feel like a product rather than a build script.

### Phase 4 — The app

SwiftUI shell. Setup Assistant (Welcome → Detection → Background build → Ready), Library, Settings,
Mods, Diagnostics, the AppKit overlay. GitHub Releases, notarized, with an updater.

> **Status: the app is in** (`apps/Switchy`): the console-style game menu, Setup Assistant, Library, Builds,
> Mods, Settings, Diagnostics, controller navigation. Not yet: the overlay process, notarized releases, the updater.

### Phase 5 — Continuity

Watch for new game versions and rebuild. Pull the shared shader list upstream and re-seed. Port the
Setup flow to the iOS path, where the Mac-side agent already has a precedent in
`shader_contrib_watch.py`.

---

## 5. The user's journey

**Today:** install five tools, learn seven flags, watch a terminal for twenty minutes, move the app
and recompile its shaders, re-run the build when an update lands, hand-write a `manifest.tsv` for
each mod, hand-edit `controls.txt`, and rebuild when the shared shader list grows.

**With the app:** drag the game onto the icon. The app finds the keys, identifies the version by
content hash, builds in the background, and tells you when it is ready. After that it is quiet: it
rebuilds when the game changes, re-seeds when the shader list grows, and keeps the mods you
installed.

**The one decision the user makes:** point at their copy of the game. Everything else is the app's
problem, and stays invisible until it isn't.

**What stays deliberately manual:** the game file, the keys, shader contributions (reviewed before
they leave), updates (requested, not forced), and mods (yours to install, yours to remove by
deleting a folder).

---

## 6. Risks

- **Prebuilt binaries mean a release process.** Signing, notarization, per-OS-version slices. This
  is the cost of removing the compiler from the user's life, and it is worth it.
- **The game cannot be redistributed.** The app is licensed for personal, noncommercial use; the built output contains the game.
  Releases distribute the tool, never the result. A user who builds gets a copy for their own use.
- **macOS 26+ is a real ceiling.** The Metal 4 requirement and the guest-memory layout below 2^39
  both need the new OS. Widening it means a Vulkan or Metal 3 path in the NVN layer — a much larger
  project than this one.
- **Phase 3 is the hard one.** Streaming changes the read path of every file the game opens. It
  must land after the manifest work, and it needs real playtesting, not just a green test suite.
- **Upstream drift.** This repository moves fast. Every phase needs a rebase against upstream, and
  the hash pins mean conflicts are resolved by re-deriving the expected values, never by relaxing
  them.

---

## 7. Acceptance criteria for Phase 1

1. `totk-native` builds for v0, v112, v121 and v143 with no player data in the compile inputs.
2. `build/romfs_config.h` is derived from `assets/expected-v*.json`, and the build still fails when
   the player's RomFS does not match it.
3. The runtime manifest is written by the build, travels with the app, and is found on macOS and on
   iOS.
4. A font file that does not match its manifest digest still stops the game, and a RomFS image that
   does not match its pinned digest still stops the game.
5. `python -m unittest discover -s tests` is green, including the new manifest tests.
6. The native parsers still pass under `-fsanitize=undefined -fno-sanitize-recover=all`.
