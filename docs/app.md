# Switchy.app and its agent

The app is a client; the agent owns the state (docs/ultimate-app-blueprint.md §2). A build keeps going when the app
quits, because the agent is a per-user LaunchAgent, not a child of the app.

```
Switchy.app  (apps/Switchy, SwiftUI)      game menu · Setup · Library · Builds · Mods · Settings · Diagnostics
        │  Unix socket, newline-delimited JSON (mng_agent/protocol.py)
com.macnativegames.agent  (mng_agent, Python 3.9+)       job queue · state store · detection · mods · watcher
        │  supervised subprocess (mng_agent/runner.py), JSON events
build_app.py  step graph                                 the same build as the command line, step by step
```

## Install

On the Mac with the checkout (macOS 26, Apple silicon; the build itself still needs what build_app.py lists):

```sh
python3 -m mng_agent install          # LaunchAgent: starts now and at every login
cd apps/Switchy && ./make_app.sh          # -> apps/Switchy/build/Switchy.app
cd apps/Switchy && ./make_dmg.sh          # -> apps/Switchy/build/Switchy-<version>.dmg
```

The app can also install the agent itself (the orange "Off" pill, or the card it shows when the agent is not running).
Remove it with `python3 -m mng_agent uninstall`.

## Use

On first run a checklist checks the source, the agent and the build tools, and can download the source into
`~/Library/Application Support/Switchy/Source`. Click the avatar for **Profile** (a local name, handle and line about
you). **Settings** has the paths with validation, reset/import/export, the agent's controls (reveal log, reinstall,
restart, remove), an update check and free disk space.

Drop the game file (XCI or NSP), an optional update and your `prod.keys` on the window, or choose **Add a game**. The
Setup Assistant shows what it found (by content, not by file name), builds in the background, and offers **Play now**
when it is done. The game menu shows each built app as a tile over its own art (the icon the build extracts from your
dump); arrows or a controller's d-pad move, Return or A plays, Space or Y/Menu opens the game card.

Everything also works from a terminal, without the app:

```sh
python3 -m mng_agent build ~/Games/totk.xci --update ~/Games/totk-1.4.3.nsp --wait
python3 -m mng_agent status | jobs | log <id> -f | cancel <id>
python3 -m mng_agent library | launch | rebuild <app>
python3 -m mng_agent mods-add ~/Mods/my-mod v143 | mods | mods-disable <id>
python3 -m mng_agent settings game.operation_mode=handheld auto_rebuild=true
python3 -m mng_agent diagnostics --export ~/Desktop/report.zip
```

## What each part guarantees

- **Builds** run one at a time. A build the agent was running when it stopped (restart, crash, logout) resumes on the
  next start; steps that finished and whose outputs later steps check again are skipped, the rest run again and skip
  their own finished work by hash, as build_app.py always has. Cancel stops the whole process group.
- **The output** is replaced whole at the end of a build, so the agent refuses an output path that exists and is not an
  app this project built.
- **Keys** are found next to the game, in `~/.switch` or in Ryujinx's folder; only the names a keys file defines are
  checked, its values are never read out, logged or put in a diagnostics archive.
- **Mods**: the runtime reads one folder per version (`mods/<version>`, one `manifest.tsv`). The agent keeps each mod
  whole in `mod-library/` and composes the enabled ones into that folder with a manifest checked against your built
  app's game data. Two enabled mods that change the same file are refused, as the game would refuse them at start. A
  hand-made `mods/<version>` is never touched until you import it.
- **Game settings** are checked the way the runtime checks them and passed to the game as `TOTK_*` variables at launch.
- **The watcher** marks an app when its game files change or it goes missing; with automatic rebuilds on, it rebuilds
  once per change (a failing rebuild is not retried every pass).

## Testing

```sh
python3 -m unittest discover -s tests          # includes tests/test_agent.py and tests/test_runtime_manifest.py
cd apps/Switchy && swift test           # MNGCore against the real agent (also runs on Linux)
```

The menu has a development fixture for checking the carousel: **Settings → Developer → Show 10 mock games** adds
ten local tiles with their covers (they are not apps, cannot be launched and never reach the agent), so the glide can
be exercised without building a game. The previous/next buttons beside the page dots, the arrow keys and a controller
all drive the same `move()` and the same spring.

The fixture ships no cover art: each mock tile shows its title on the menu's normal placeholder, so the carousel can be
tested without any image files in the repository.

The agent tests run the real runner subprocess over build_app's real step graph with harmless steps
(`tests/agent_fake_pipeline.py`); no game data, keys or macOS needed. The SwiftUI views compile only on macOS.

## Not done yet

- **A fully prebuilt `totk-native`** (blueprint Phase 1): the RomFS and font facts are out of the binary
  (`runtime-manifest.txt`), but `build/runtime_tables.h` is still generated from the player's rewritten modules by
  `scripts/prepare_runtime.py`. Those tables are derived from the game's code, so they cannot be checked in; they need
  the same treatment as the manifest (read at start, pinned by the version's `rewritten_sha256`).
- **Embedded Python and toolchain, notarized releases, an updater** (Phases 1 and 4).
- **Streaming RomFS** (Phase 3) and **iOS Setup** (Phase 5).
