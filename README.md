# Glide: a mouse driver for the MX Master 3S on macOS

A menu bar app that makes the scroll wheel feel smooth and predictable on macOS, and covers the usual driver settings for Logitech mice: wheel mode, DPI, buttons, gestures and battery.

## Install

```bash
./build.sh
```

This builds `Glide.app`, signs it with your Apple Development certificate, installs it to `~/Applications` and starts it. On first launch macOS asks for two permissions in System Settings > Privacy & Security:

- **Accessibility**: smooth scrolling and button remapping.
- **Input Monitoring**: talking to the mouse itself (DPI, wheel mode, battery, gesture button).

Glide picks both up within a second; no restart needed. Because the app is signed with your certificate, the permissions survive rebuilds.

## What it does

| Pane | Settings |
|---|---|
| **Scrolling** | Smooth scrolling (each click glides instead of jumping), distance per click, smoothness, acceleration (off = every click the same distance, like a Windows wheel), reverse direction for the mouse only, thumb wheel (sideways, tabs, zoom or volume), Shift + wheel sideways, a test area. |
| **Scroll Wheel** | The wheel's physical feel, stored in the mouse: **Ratchet** (always clicks, like a normal wheel), **SmartShift** (frees itself on fast flicks, with adjustable sensitivity) or **Free-spin**. |
| **Buttons** | Middle, back, forward, the gesture button (click plus hold-and-move up/down/left/right) and the button behind the wheel. Actions: Mission Control, App Exposé, desktops, media keys, copy/paste, tabs, any keyboard shortcut, cycle DPI, switch wheel mode and more. |
| **Pointer** | DPI from 200 to 8000 (stored in the mouse), DPI presets, pointer acceleration off for this mouse only. |
| **General** | On/off, open at login, battery in the menu bar, permissions, mouse details, log. |

The menu bar icon shows the battery level, and lets you switch smooth scrolling, wheel mode and DPI without opening the window.

Glide leaves the wheel alone in games: each wheel event there is one step (the next hotbar slot), so a glide would skip several. It detects apps in a games category, Steam, Unity and Minecraft (Java), and you can add any other app under Scrolling > Exceptions. ⌘, ⌥ and ⌃ + scroll are also passed through untouched, so zoom shortcuts keep working.

## How it works

- **Smooth scrolling**: an event tap catches wheel events from mice (trackpads and the Magic Mouse are left alone), and plays each click out as pixel scroll events in step with the display refresh. Each click glides towards its target with an ease-out curve; a click in the other direction turns around at once. The physics live in `Sources/GlideCore/ScrollPhysics.swift`.
- **Counting real clicks**: macOS accelerates wheel events before anything sees them. Glide also reads the mouse's raw HID report and pairs each event with the report behind it, so every physical click counts exactly once.
- **Mouse settings**: Logitech's HID++ 2.0 protocol over Bluetooth (`HIDPP.swift`, `LogitechMouse.swift`): SmartShift (0x2110), DPI (0x2201), battery (0x1004), button diversion for the gesture and top buttons (0x1B04). The mouse forgets some of these when it powers off, so Glide applies them again whenever it reconnects or the Mac wakes. Settings you never touch are never written.
- Settings are saved in `~/Library/Application Support/Glide/settings.json`; the log is at `~/Library/Logs/Glide.log`.

## Checks

```bash
swift run glide-sim                      # scroll physics: distances, timing, reversal
.build/release/Glide --probe             # read the mouse over HID++ and print what it reports
.build/release/Glide --selftest          # event tap end to end (quit the Glide app first)
.build/release/Glide --snapshot <dir>    # render each settings pane to PNG
```

`--selftest` posts synthetic wheel clicks through the real tap and display link. A second tap at the end of the chain records and swallows everything while it runs, so nothing reaches the apps on screen. It needs the terminal to have Accessibility permission.

## Layout

| Path | What |
|---|---|
| `Sources/GlideCore/ScrollPhysics.swift` | Scroll glide physics (pure, tested by `glide-sim`) |
| `Sources/Glide/EventEngine.swift` | Event tap: wheel handling, click pairing, button remapping |
| `Sources/Glide/ScrollOutput.swift` | Frame-synced output of scroll events (CVDisplayLink) |
| `Sources/Glide/HIDPP.swift`, `LogitechMouse.swift` | HID++ transport and mouse features |
| `Sources/Glide/Driver.swift` | Driver thread, HID manager, gestures, applying settings |
| `Sources/Glide/Actions.swift` | What buttons can do |
| `Sources/Glide/AppModel.swift`, `Views/` | Settings window and menu bar |
| `build.sh`, `Resources/Info.plist`, `Scripts/make-icon.swift` | Packaging |

Glide talks HID++ to Logitech mice connected directly over Bluetooth. Mice on a Unifying or Bolt receiver still get smooth scrolling and button remapping, but not the in-mouse settings.

## License

MIT, see [LICENSE](LICENSE). Glide is an independent project and is not affiliated with or endorsed by Logitech. Logitech, MX Master and SmartShift are trademarks of Logitech.
