# Wally for macOS

Looping video wallpaper for the macOS desktop.

Wally draws a video in a desktop-level window — beneath the desktop icons, above
the macOS wallpaper — and is controlled from a menu bar item.

> Part of the Wally family, alongside [`wally`](https://github.com/i5dr0id/wally)
> for GNOME/Linux. The installed app and its menu bar item are named
> **LiveWallpaper**.

## Why it exists

macOS plays an Aerial **desktop** wallpaper once on login/unlock, then holds the
last frame. The lock screen and screen saver loop forever; the desktop does not,
and there is no setting for it. That is the "live on the lock screen, frozen after
login" behaviour. This app supplies the looping desktop layer.

## Layout

| File | Purpose |
|---|---|
| `main.swift` | The whole app — ~640 lines, no dependencies |
| `Info.plist` | Bundle metadata (`LSUIElement` = no Dock tile) |
| `build.sh` | Compile → bundle → sign → install → reload agent (this Mac) |
| `package.sh` | Universal arm64+x86_64 build → zip in `dist/` (other Macs) |
| `dmg.sh` | Same contents as a compressed `.dmg` disk image |
| `install.sh` / `uninstall.sh` | Shipped inside the zip and the dmg |

Installed to `~/Applications/LiveWallpaper.app`, kept running by
`~/Library/LaunchAgents/local.LiveWallpaper.plist`.

## Build

    ./build.sh          # this Mac
    ./package.sh        # universal zip in dist/ for another Mac

`KeepAlive` is set to restart only on a *crash* (`SuccessfulExit: false`), so
**Quit** in the menu genuinely quits instead of being relaunched by launchd.

## Menu

- **Pause / Resume** — manual, ⌘P
- **Desktop Wallpaper** — pick from the library folder, or choose any file
- **Screen Saver & Lock Screen** — pick a video for the Aerial slot (see below)
- **Fill Mode** — Fill / Fit / Stretch
- **Dim** — 0–60% black overlay, for icon legibility over a bright video
- **Pause on Battery**, **Pause in Low Power Mode**, **Pause When Desktop Covered**
- **Launch at Login**, **Start Playing at Launch**

The second line of the menu always says *why* playback stopped
("Paused — on battery"), so a pause is never mysterious.

## Screen saver and lock screen

These are separate from the desktop: the desktop is this app, the screen saver and
lock screen are macOS's Aerial slot. You can point them at different videos.

On macOS 26/27 the Aerial manifest lives inside the **SIP-protected** extension
bundle (`WallpaperAerialsExtension.appex/Contents/Resources/entries.json`), so a
genuinely custom asset cannot be registered — the widely documented
"edit `entries.json`" trick from Sonoma/Sequoia silently falls back to
"Golden Gate Sunset". The workaround here keeps a real Apple asset ID
(`4C108785…`, "Tahoe Day") and swaps the video file underneath it:

- Apple's original is preserved as `<id>.mov.apple-original`
- The replacement gets `chflags uchg` so `idleassetsd` cannot re-download over it
- `Index.plist` / `Index_v2.plist` are backed up once as `*.livewallpaper-backup`

System Settings will still *label* it with the original Aerial's name (on this Mac,
"Tahoe Day"). That is cosmetic — the name comes from the read-only manifest.

## Power

Measured on an M2 Pro playing 4K HEVC, as CPU-seconds consumed over 45 s windows:

| State | CPU (of one core) |
|---|---|
| Playing | 2.62% |
| Paused because the desktop is covered | 0.96% |
| **Saving while covered** | **64%** |

`ps` measures against a single core, so 2.62% is about 0.2% of a 12-core M2 Pro —
video is decoded by dedicated HEVC hardware, not the CPU.

**The occlusion pause is the only optimization with real weight.** The rest is
tidiness: the dim layer is only created when dim > 0, fill-mode and dim changes
apply in place instead of rebuilding the players, and stall-buffering is off since
the file is local.

A 5 s timer re-checks state, so a missed notification self-corrects instead of
leaving a frozen frame — which would look exactly like the bug this app fixes.

### Measured and rejected

Setting `preferredMaximumResolution` to the display size, so a 4K file would not
decode ~⅓ more pixels than the screen shows. A/B tested over alternating 45 s
samples: **2.61% with vs 2.62% without** — the variance within each variant was
larger than the difference between them. It is documented for streaming and is a
no-op for local files, so it was removed rather than kept as an optimization that
only looks like one.

## Settings

Stored in the `local.LiveWallpaper` defaults domain; the menu writes them all.

    defaults read local.LiveWallpaper

## Installing on another Mac

    ./package.sh        # dist/LiveWallpaper-<version>.zip
    ./dmg.sh            # dist/LiveWallpaper-<version>.dmg

Copy either across, open it, then run `./install.sh` from inside.

The disk image also has an `Applications` shortcut, so the app can just be dragged
across instead. That path hits Gatekeeper: the app is signed **ad-hoc**, not with a
paid Apple Developer ID, so the first launch is blocked and has to be approved once
in *System Settings › Privacy & Security › Open Anyway*. `install.sh` avoids that by
clearing the quarantine flag and re-signing locally, which is why it is the
recommended route. Notarising it properly would need a $99/year Developer ID.

A dragged copy is self-sufficient: **Launch at Login** writes its own launch agent
pointing at wherever the app ended up, and a single-instance guard stops a second
copy from stacking another video layer on the desktop.

The binary is universal (Apple Silicon + Intel, macOS 13+). `install.sh` clears the
quarantine flag that copying between Macs attaches and re-signs locally — without
that, the ad-hoc signature trips Gatekeeper and the app is killed on launch. It
writes the launch agent with the correct `$HOME` and starts it.

On a fresh Mac the default video won't exist; the menu says *"No video — choose one
below"* and nothing is drawn over the wallpaper until you pick one.

The Aerial asset ID is **read from the wallpaper store, not hardcoded**, because IDs
differ between Macs and macOS versions — whichever Aerial that Mac has selected is
the one swapped underneath. If none is set up, the menu says so instead of silently
doing nothing.

## Uninstall

    launchctl bootout gui/$(id -u)/local.LiveWallpaper
    rm -rf ~/Applications/LiveWallpaper.app ~/Library/LaunchAgents/local.LiveWallpaper.plist
    defaults delete local.LiveWallpaper

Use **Restore Apple's Aerial** first if you want the stock screen saver back.
The desktop then falls back to the macOS Aerial wallpaper.
