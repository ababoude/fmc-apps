# Shortcuts companion (iPhone)

The watch has no network. This small iOS app sits next to Nothing X on the same phone, keeps a BLE link to the watch
and runs what a tap asks for: a `shortcuts://run-shortcut?name=…` URL, or a plain HTTP POST to your own webhook.

Watch side: `../src/` (Rust, tap → `h1N` + row index). Protocol: `../src/model.rs` and "The `h1` messages" below.

## Why an app and not a Shortcut

A Shortcut on its own cannot see the watch: the watch's messages go over the watch's BLE channel, encrypted with the
pairing secret, not to the Shortcuts app. So the phone needs a small central that speaks that channel — this app — and
it is *this app* that runs the Shortcut (`shortcuts://`) or the webhook (`URLSession`).

## Build

Three ways, pick one.

### GitHub Actions, no Mac and no Xcode (works from the iPhone)

`.github/workflows/companion.yml` builds the `.ipa` on a GitHub-hosted `macos-15` runner. Start it from the
**Actions → Companion → Run workflow** button — the GitHub iOS app can do that — then open the run and download the
`Shortcuts-x.y.z` artifact.

- No secrets set: the `.ipa` is **unsigned** and carries no provisioning profile. Install it with an on-device signer
  (Sideloadly, AltStore, ESign) and a free Apple ID. It cannot be opened directly in Xcode in that form.
- `IOS_TEAM_ID`, `IOS_CERTIFICATE_P12`, `IOS_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE` set: the `.ipa` is
  signed; the workflow reads the profile's real name/UUID and the app's bundle id (`fmc.shortcuts.ShortcutsWatch`) so
  the profile must cover that id. The `.p12` and `.mobileprovision` are secrets, base64-encoded
  (`base64 -i cert.p12 | pbcopy`).
- The same workflow runs on a push that touches `apps/webhook/companion/`; it also runs `swift test` first, so a build
  that breaks the wire format fails before it packages.

### On a Mac, with Xcode

`brew install xcodegen`, then `cd companion && xcodegen generate && open ShortcutsWatch.xcodeproj` (there is no
`.xcodeproj` in git; `project.yml` is the source of truth). Signing & Capabilities: pick your team;
**Background Modes → Uses Bluetooth LE accessories** (`bluetooth-central`) is already in `Info.plist`. Run on a real
phone: the simulator has no Bluetooth.

### Without a Mac: `ios/`, built by xtool

[xtool](https://xtool.sh) turns the same `Sources/` into an `.ipa` on Linux or Windows. `ios/` is a tiny SwiftPM
package (`Package.swift`, `xtool.yml`, `Info.plist`, `AppIcon.png`) whose `Sources` is a symlink to `../Sources` and
whose icon is a symlink into the asset catalog, so neither the code nor the icon is duplicated:

```sh
xtool sdk install ~/Downloads/Xcode_27.xip   # once: a Darwin SDK cannot be downloaded prebuilt
cd companion/ios
xtool dev build --ipa --sign                 # or --ipa, unsigned; needs `xtool auth` for --sign
```

`xtool dev build --ipa` alone fails with `Error: Operation unsupported / Now generating the Darwin SDK` when no Darwin
SDK is installed: the SDK is generated from an Xcode `.xip`, never fetched. Then `xtool auth login` (API key if you
pay for a developer account, password otherwise) so `--sign` can provision the app for your phone.

No App Store, no network beyond the Shortcut or the webhook URL you configure yourself.

## Tests

`Sources/Wire.swift` holds the whole wire format — framing, AES, CRC32, `h1`, and the send queue — with no
CoreBluetooth in it, so it builds and runs on Linux:

```sh
swift test     # AES vs FIPS-197/NIST, CRC32 vs zlib, framing, h1, Outbox ordering
```

`Sources/WatchLink.swift` is the CoreBluetooth half and needs a phone and a watch.

## Use

1. Install the watch app (`apps/webhook`) and open it once. It shows `Open iPhone app`.
2. Open this app: it connects on its own (asking iOS for the peripheral Nothing X already holds), reads the pairing
   secret over the shell (`AT GETSECRET`) and keeps the link open while the app is in the foreground.
3. In the phone app, set a row: **Name** (what the watch shows, ≤ 23 bytes) and **Action**:
   - **Shortcut**: the Shortcut's name, exactly as in the Shortcuts app.
   - **Webhook**: a URL; the app POSTs `{"row": 3, "source": "watch"}` to it.
4. The rows go to the watch as soon as it is connected. Tap a row on the watch: the phone runs it and acks, and the
   watch shows `Sent to iPhone` (or `Shortcut failed`).

## One message at a time

The watch's inbox holds **four** messages (`fw/wp2-core/src/chan.rs`, `DEPTH = 4`), while a six-row list is eight
(`h1L` + 6×`h1S` + `h1E`). Writing them in a burst silently drops rows, so `Outbox` writes one message and waits for
the watch's `0xB0A5` reply before the next. Status `5` (busy), `8` (full) and `9` (paused) requeue the same message;
a hard refusal (`7`, no app open) drops the rest and is shown on the phone. A 3 s watchdog resends a message whose
reply never arrived, so a lost notification cannot stall the list.

## The `h1` messages

Watch → phone, 3–4 B:

| Message | Meaning |
|---|---|
| `h1R` | send me the list (on start, on resume, and every 4 s until one arrives) |
| `h1N` + `row` | run row `row` (0-based) |

Phone → watch, ≤ 128 B each:

| Message | Meaning |
|---|---|
| `h1L` + `count` | list begins, `count` rows follow |
| `h1S` + `row` + name | row `row` is `name` (UTF-8, ≤ 23 B, cut on a char boundary) |
| `h1E` + `count` | list complete |
| `h1A` + `row` + `status` | ran (`0`) or failed (non-zero) |

Anything not starting with `h1` is ignored, on both sides. Names are the only text that crosses: keep them generic
(`Garage`, `Lights`), never personal data — anyone in BLE range can read the channel (see `AGENTS.md`).

## Bluetooth link

The watch takes one central, and on the phone that is the system's link that Nothing X holds. So this app does not
connect from scratch: it asks iOS for the already-connected peripheral
(`retrieveConnectedPeripherals(withServices:)`), and only scans if there is none.

The channel is the stub's own (`docs/abi-1.4.md` in cmf-watch-sdk): the 16-byte pairing secret read with
`AT GETSECRET` is the AES key, so the stock Nothing X session is untouched.

- Commands: write `0000FFF2-…`, notify `0000FFF1-…`
- Shell: write `77D4FF01-…`, notify `77D4FF02-…`
- Frame: `F5 ‖ len:u16be ‖ c1:u16be ‖ 00 01 ‖ 00 01 ‖ c2:u16be ‖ body`,
  `body = AES-128-CBC(K, IV, PKCS7(plain ‖ crc32le(plain)))`, IV `5051…665A`
- Send: `MSG` (`0x90A5`) with `slot ‖ data`, expect `0x90A5 | 0xA000`
- Receive: `EVENT` (`0xB0A6`), body decrypts to `seq ‖ slot ‖ data`. Registered with one `PING` (`0x90A7`, `00`)
  so the watch pushes messages instead of being polled.

Requires the patched firmware (`fw-wp2.bin` from 2026-11-13 or later) and App Loader from the same date.
