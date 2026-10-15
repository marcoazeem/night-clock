# Night Clock

A bedside nightstand clock and smart-light dashboard (Flutter) for a
repurposed Galaxy Note 8, on a true-black AMOLED-friendly background. The
screen stays on via `wakelock_plus`. Under the clock sits a panel for your
TP-Link Tapo and Xiaomi Mi/Mijia bulbs and a Gree air conditioner, all on
one page and controlled straight over your home Wi-Fi. See
[Smart lights](#smart-lights) and [Air conditioner](#air-conditioner).

It turns whichever way the phone is standing. Either way the time is one
`HH:MM` line with a fading hairline and the date beneath it: upright it
spans the width above the lights; on its side it sits to their left. That matters on a wireless charger: lay the
phone on its side once it's full and it slips off the coil and stops
charging, without giving up the clock.

The clock's palette is white and red only: the time is white, the date is
red, and every digit "1" renders red. The light tiles are the one place
with more colour — each glows in its bulb's own shade when it's on.

## Gestures

- **Swipe up / down** — brighter / dimmer (two-stage, see Battery)
- **Long-press** — toggle 12/24-hour
- **Double-tap** — show/hide seconds

Seconds and AM/PM share a small row under the time. Settings persist
across launches. The whole display wanders within a ±20 × ±40 px region
(±40 × ±20 on its side — always wider along the panel's long axis),
jumping to a new spot every minute, so no pixel holds a static image —
AMOLED burn-in protection.

Every digit is drawn over its own unlit segments — a faint all-8s layer at
11% opacity — so the display reads like a real 7-segment panel rather than
floating glyphs.

## Smart lights

The dashboard controls bulbs **locally** — the phone talks to each bulb on
your Wi-Fi directly, with no cloud, hub, or vendor app involved.

- **TP-Link Tapo** bulbs (L510, L530, …) on current firmware (KLAP protocol)
- **Xiaomi Mi / Mijia** bulbs (miIO protocol — both newer MIoT and older
  Yeelight-made models; the app works out which on first use)

Each light gets a square frosted tile with a power button and — for
lights you mark dimmable — **1% / 25% / 50% / 100%** presets. The power
button lights up while the bulb is on, and so does the preset nearest its
brightness. **ALL OFF** in the header switches everything off. States refresh every 15 s.

The panel only appears when the app is built with a `lights.json`; without
one you get the plain clock.

### Setup

1. **Copy the template.** `lights.json` is gitignored, so your addresses
   and keys never end up in the repo:

   ```sh
   cp lights.example.json lights.json
   ```

2. **Give each bulb a fixed IP.** Add a DHCP reservation for each bulb in
   your router, or its address can change after a router reboot and the
   tile goes *Offline*.

3. **Tapo — `TAPO_HASH` and `TAPO_LIGHTS`.** Run:

   ```sh
   python3 tool/tapo_hash.py
   ```

   It asks for your Tapo account email and password and prints a 64-character
   hash; paste it as `TAPO_HASH`. The bulbs authenticate against this hash,
   so the app never stores your password. Find each bulb's IP in the Tapo app
   (device → ⚙ → Device Info) and list them as `Name=IP`:

   ```json
   "TAPO_LIGHTS": "Warm Light=192.168.1.20"
   ```

4. **Xiaomi — `MI_LIGHTS`.** Each Mi bulb has a secret 32-character token,
   fetched once from your Xiaomi account with
   [Xiaomi-cloud-tokens-extractor](https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor).
   On a Mac with Homebrew Python its one-line installer fails
   (`externally-managed-environment`), so run it in a virtualenv instead:

   ```sh
   mkdir -p ~/xiaomi-tokens && cd ~/xiaomi-tokens
   curl -L -o token_extractor.zip https://github.com/PiotrMachowski/Xiaomi-cloud-tokens-extractor/releases/latest/download/token_extractor.zip
   unzip token_extractor.zip && cd token_extractor
   python3 -m venv venv && venv/bin/pip install -r requirements.txt
   venv/bin/python token_extractor.py
   ```

   Log in (password or QR code), press Enter to search every server region,
   and copy the **IP** and **TOKEN** of each bulb as `Name=IP/token`:

   ```json
   "MI_LIGHTS": "White Light=192.168.1.30/0123456789abcdef0123456789abcdef"
   ```

5. **Choose which lights dim — `DIMMABLE_LIGHTS`.** A comma-separated list
   of names that should get the 1 / 25 / 50 / 100% presets;
   any light left out gets just the power button:

   ```json
   "DIMMABLE_LIGHTS": "Warm Light"
   ```

6. **Build with the file** (see [Build & install](#build--install)).

Several lights of one kind are comma-separated: `"Bed=…, Desk=…"`. A tile's
glow is read off its name — cool white if it contains "white" or "cool",
warm amber otherwise.

**Troubleshooting**

- *Every tile Offline* — the phone isn't on Wi-Fi. Airplane mode is fine,
  but Wi-Fi has to be switched back on.
- *One tile Offline* — check its IP still matches (fixed IP, step 2).
- *A light is missing entirely* — its `TAPO_HASH` or token isn't valid hex
  of the right length (a leftover placeholder, say); the app skips it
  rather than crash.

**Security:** the hash and tokens are compiled into the APK. Anyone with the
APK file and access to your Wi-Fi could switch your lights — but neither
gives access to your Tapo or Xiaomi account.

## Air conditioner

A **Gree** Wi-Fi AC (the kind the **Gree+** app controls) gets a frosted
tile under the lights, two to a row, with a power button and a dial for the
setpoint, 16–30 °C — drag around the dial or tap **−** / **+**, and the
change is sent once you stop. The tile shows the mode ("Cooling",
"Heating", …) and the room temperature when the unit reports one.

Setup needs only the AC's IP — no password or token. On first use the app
pairs with the unit over your network and the unit hands over its own key.

1. Make sure the AC works in the Gree+ app (that's what puts it on Wi-Fi).
2. Find its IP. Gree+ only shows the MAC (the AC → **⋯** → device info),
   so match that MAC against your router's list of connected devices. Give
   it a fixed IP in your router, as with the bulbs.
3. Add it to `lights.json`:

   ```json
   "GREE_AC": "Bedroom=192.168.1.40"
   ```

   Several ACs are comma-separated: `"Bedroom=…, Office=…"`.

Both older (AES-ECB) and newer (AES-GCM) Gree firmware are supported; the
app works out which on first use. Without `GREE_AC` there are no AC tiles.

## Font

One face: **DSEG7 Classic**, the 7-segment digital clock font (SIL OFL, by
Keshikan), in `fonts/` with its license. It covers digits and the colon
only, so the date and AM/PM deliberately fall back to the platform font.

## Battery

With seconds hidden the clock redraws about twice per minute (minute change +
burn-in drift), and the light panel polls the bulbs every 15 s. It runs no
background work at all — no services, no background permissions, and every
timer stops when the app isn't visible. So nearly all drain is the screen
itself being on.

The dimmer therefore drives the panel, not just the pixels. Swiping runs a
two-stage control:

- **Top 60% of the range** — sets the app window's own screen brightness,
  from the panel's hardware floor up to full. This is the part that saves
  power, and it needs no `WRITE_SETTINGS` permission; the system brightness
  you set elsewhere is left alone and restored when the app backgrounds.
- **Bottom 40%** — the panel is already at its floor, so this fades the
  pixels toward black (down to 12% opacity). It's the only way to go dimmer
  than the hardware allows, and on AMOLED darker pixels still draw less.

To stretch it further, keep the phone on its charger — a screen-on Note 8
pulls ~1.5–2.5 W, so a 5 W trickle charger will lose that race, and so will
a laptop USB port. Use an Adaptive Fast Charging brick; measured on-device,
a proper one pulls ~1.6 A.

To cut everything else on the phone, see **Bedside tips** below.

## Build & install

```sh
flutter build apk --release --split-per-abi --dart-define-from-file=lights.json
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Leave out `--dart-define-from-file=lights.json` to build the clock without
the lights panel.

Prebuilt APKs land in `build/app/outputs/flutter-apk/`; the Note 8 wants the
`arm64-v8a` one (`app-release.apk` is the universal fallback).

## Bedside tips

- Keep the phone on a charger; wakelock keeps the screen on indefinitely.
- The app rotates on its own (`fullSensor`), so the system auto-rotate
  toggle doesn't have to be on for it to follow the stand.
- Brightness is handled in-app now — just swipe. Turn off adaptive brightness
  (Settings → Display) so the system doesn't fight the app.
- Samsung "Edge panel" shows a handle on the left edge; disable it in
  Settings → Display → Edge screen for a fully black screen.

### Cutting background drain (Note 8, Android 9 / One UI 1.0)

The app itself does nothing in the background, so anything left is the rest
of the phone:

- **Airplane mode on.** A cellular radio hunting for signal in a nightstand
  corner is the single biggest drain. Turn Wi-Fi back on afterwards — the
  light controls need it.
- Bluetooth, NFC, Location, Mobile data, Hotspot — off.
- Settings → Accounts and backup → Accounts → **Auto sync data** off.
- Device care → Battery → ⋮ → Settings → turn on *Put unused apps to sleep*
  and *Auto disable unused apps*.
- **Add Night Clock to "Apps that won't be put to sleep"**, or Samsung's
  optimiser will kill it overnight. Also set it to *Not optimised* under
  Settings → Apps → ⋮ → Special access → Optimise battery usage.
- Play Store → Settings → Auto-update apps → *Don't auto-update*.
- Disable Bixby Home / Voice / Routines, and Always On Display (redundant
  with this app, and it lights pixels).
- Settings → Display → Screen mode → **Basic** draws less than Vivid.
- For a fully dedicated device: remove the Google account entirely, which
  stops most Play Services wakeups.
