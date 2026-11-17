Six rows on your wrist that each run a Shortcut on your iPhone. Tap one — the phone in your pocket runs the Shortcut, or POSTs to your own server.

The watch has no network and no Swift runtime: it is a tiny Rust app that sends four bytes over Bluetooth. It only tells the phone which row you touched, so your Shortcut names and webhook URLs never leave the iPhone.

## Requirements

The [patched firmware](/firmware), the [App Loader](/firmware), and the iPhone companion (source in `apps/webhook/companion`, sideload it with Xcode — a free Apple ID is enough). Open the app from the **Apps** row at the end of the watch's app list.

The companion builds without a Mac: the repository's **Actions → Companion** workflow makes the `.ipa` on a GitHub runner, and you download it from the run. See `apps/webhook/companion/README.md`.

## Setting it up

1. Install the companion on your iPhone and open it once, so it can ask for Bluetooth. It finds the watch and reads the pairing secret by itself; Nothing X can stay connected.
2. Open **Shortcuts** on the watch; the phone sends it your six row names.
3. In the phone app, give each row either a **Shortcut** name (it runs `shortcuts://run-shortcut?name=…`) or an `https://` **webhook** URL that gets a `POST` with `{"row": n, "source": "watch"}`.
4. Tap a row on the watch: the phone runs it and the watch shows `Sent to iPhone`, or `Shortcut failed`.

Rows you have not set up still appear on the watch, reading `Set up on iPhone`, so an unfinished list is obvious instead of silently failing.

## Good to know

- Only the row names cross the Bluetooth link; keep them generic (`Garage`, `Lights`), never personal data.
- The list is pushed **one message at a time** and acknowledged by the watch, because its inbox holds four messages and a six-row list is eight. That is why rows arrive reliably instead of half-disappearing.
- After a factory reset the stored pairing secret stops working; the app re-reads it on its own.
- The phone app must be open (foreground, or backgrounded with Bluetooth on) for a tap to do anything. The watch shows `No phone` when the link is down.
