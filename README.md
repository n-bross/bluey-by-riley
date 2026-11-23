# Bluey

Bluey is a little blueberry focus friend. Keep your iPhone sideways under your Mac monitor: his eyes follow your mouse, and his matching blue cursor appears when he has something to point out. Same character, animation, British personality, speech bubbles and cartoon chirp. No spoken voice output and no glow.

## Start focusing

1. Run Bluey on your Mac and iPhone on the same local network.
2. On Mac, choose **Pair iPhone (QR)…** from Bluey's menu. On iPhone choose **Pair Mac**, then scan the code. Treat this code as a private pairing credential.
3. Add your OpenAI API key through **OpenAI Key…** in the Mac menu. It stays in `~/Library/Application Support/Googly/keys.json`, with private file permissions. It never goes to the phone or into this repository.
4. Grant **Screen Recording** on Mac. If macOS requests it, quit and reopen Bluey after granting access. **Microphone** on iPhone enables voice; **Camera** is used only for QR pairing; **Local Network** lets the phone find the Mac. Accessibility is optional for the existing explicitly requested computer-control tools, and isn't needed for focus classification.
5. Hold Bluey's face and describe the task, optionally giving a duration: “I'm making a Codex video for 30 minutes.” Release to start. The microphone captures while held and buffers the beginning in memory while the voice connection starts. Only held audio is sent; no spoken audio output is played. The default is 30 minutes, with a 1–240 minute range. You can also tap **Focus**, type a task, and start there.

The task appears at the phone's top left, with a large white countdown at bottom right on both devices. Small pause/resume, end and Focus icons sit at the phone's bottom left, alongside the listening status icon. Hold Bluey's face to speak. Controls are also available in the Mac menu and through voice. **⌃⌥S** pauses focus and stops computer control. Pause, end, expiry, Mac lock/sleep, phone backgrounding or disconnect stops monitoring. Reconnection and unlocking never resume it automatically. A missing heartbeat is detected within five seconds; outstanding results are discarded.

**Developer Mode:** turn it on at the top of **Focus** on the phone or in Bluey's Mac menu. The countdown runs **4× faster**, and the Mac checks the screen every **10 real seconds**. Repeated majority off-task choices nudge after two or three checks (about **20–30 real seconds**, plus request time); cooldown is 30 real seconds. **Test a nudge** checks the Mac bubble and phone chirp immediately without taking a screenshot. Changes take effect immediately on both devices, including during a session. Test sessions are labelled in history with their real active time, and the setting is remembered on the Mac. A fresh installation defaults to normal speed. Turning it off restores the real-time clock, 30-second checks and two-to-four-minute evidence span. Pause, lock and disconnect still stop capture normally.

## The Bluey app: chat, todos, notes, pomodoro, stats

The same app runs on iPhone, Mac and in the browser. Tabs: **Chat**, **Todos**, **Notizen**, **Pomodoro**, **Statistik**, and **Gesicht** (his face).

- **iPhone:** opens on the tabs. **Gesicht** switches to the familiar sideways face, synced with the Mac. The grid button goes back. Waking him (double tap, or ⌥Space on the Mac) brings the face up. Todos, notes and the pomodoro also work offline and sync once the Mac is reachable.
- **Mac:** **Bluey öffnen…** (⌃⌥O) in the menu opens a window with a sidebar. While it is open, Bluey has a Dock icon. `--window` opens it at launch.
- **Web:** **Web-App öffnen** in the menu opens `http://127.0.0.1:4777` with a private token link. It is reachable only from this Mac. The token is stored as a cookie and kept in `~/Library/Application Support/Googly/web-token`.
- **Chat:** OpenAI Responses with streaming. Attach images, PDFs and text files (up to 10 MB). Pick a model from the models available to your key. **Web** turns on web search. The key stays on the Mac; phone and browser ask the Mac to chat for them.
- **Pomodoro:** focus and break phases, linkable to a todo. With **Bluey schaut mit**, every focus phase also starts a Bluey focus session with screen checks.
- **Sync:** the Mac holds the source copy (`~/Library/Application Support/Googly/workspace.json`, attachments next to it). Every item carries `updatedAt`, and the newest version wins. Deletions sync as tombstones.

Shared SwiftUI screens live in `App/` (compiled into both apps), the data model in `Shared/Workspace.swift`, and the web app in `Web/index.html`.

For development next to a running Bluey: `swift run GooglyMac --workspace-preview` opens only the window and the web app (port 4787) with throwaway data.

## Settings, shortcuts and look

**Settings…** (⌘, in Bluey's menu) has everything in one window: *General* (notch, floating Keramik avatar, pointer style and size, computer control, phone position), *Shortcuts*, *Focus* (Pomodoro presets, times, cycle preview, auto-start, Developer Mode), *Hermes* (connection, risky-step approvals, ActivityWatch) and *Account* (OpenAI key, personality). The menu itself only keeps what you use day to day.

| Shortcut | Default |
|---|---|
| Talk to Bluey (hold) | ⌃⌥Space |
| Type to Bluey | ⌃⌥B |
| Hide / show Bluey | ⌃⌥H |
| Start / stop listening | ⌃⌥W |
| Stop him (emergency brake) | ⌃⌥S |
| Point where my mouse is | ⌃⌥P |
| Eyes follow my mouse | ⌃⌥F |
| Stop pointing | ⌃⌥D |

Every shortcut can be changed or turned off in *Settings ▸ Shortcuts*: click it and press the new combination (Esc cancels, ⌫ turns it off). A combination already used by another Bluey action moves over; one macOS refuses gets a warning. **Hide** makes him disappear everywhere (notch, pointer, avatar window); focus and Pomodoro keep running, and their announcements still show briefly.

**Look:** Bluey uses the Keramik design: the Keramik avatar on the phone and in the optional floating window, a small Keramik face in the notch, and the **Keramik drone** pointer: when he points, the drone hovers above the target, lights it with a cone and frames it in cyan, with his bubble above the drone. The original blueberry pointer is still available in *Settings ▸ General*.

## Without the laptop: chats, todos and notes on the phone

The phone app has a second side in T3 Code's mobile design (dark/light palette, DM Sans and layout ported from `pingdotgg/t3code` `apps/mobile`, MIT): **Threads** (all your Hermes conversations, new chats with live streaming, tool steps and approval cards), **Todos** (overdue / today / upcoming / no date, quick add, swipe for today/tomorrow/delete), **Notes** (Raycast-style: first line is the title, pinned first, saves as you type) and a **Browser** (browse yourself, or ask Hermes about the page / give it a browsing job). Open it from the pairing screen (*Use without Mac*), Bluey's app screen, or the drawer; it runs in portrait, Bluey's face stays landscape.

It talks to **Bluey Hub** (`hub/bluey_hub.py`, Python stdlib only), a small service next to Hermes on an always-on machine:

- stores notes (`~/bluey-hub/notes/*.md`) and todos (`todos.json`), and passes chats through to Hermes' API server (Hermes' key never leaves that machine);
- runs on `127.0.0.1` behind `tailscale serve`, so it's reachable only in your tailnet, and your Tailscale login is the authentication (`tailnet_logins` in `~/bluey-hub/config.json`; a bearer key works too);
- the `bluey-hub` command and the `bluey-hub` Hermes skill (`hub/SKILL.md`) let Hermes read and change the same notes and todos, so "add a todo…", "what's on my list?" or "note this down" work in any chat.

On the Mac, **⌃⌥N** opens floating **Quick Notes** (the same notes), and *Settings ▸ Hermes ▸ Bluey Hub* holds the hub address; a paired phone receives it automatically when it connects (or with *Send to iPhone*). The phone needs the Tailscale app on.

Setup on the server (as the Hermes user): copy `hub/` there, enable Hermes' API server (`API_SERVER_ENABLED=true`, a key, `127.0.0.1:8642`), run `bluey_hub.py serve --port 8766` as a user service, `tailscale serve --bg --https=8790 http://127.0.0.1:8766`, add your Tailscale login to `tailnet_logins`, and copy `hub/SKILL.md` to `~/.hermes/skills/personal/bluey-hub/`.

## Journal: what did I do?

Like Reclaim's time tracking, Bluey keeps a journal of every day in `~/Documents/Bluey Journal/YYYY-MM-DD.md` (today's file is refreshed every 10 minutes): real active time, focus sessions with their on-task share, a timeline of work blocks (`09:12–09:47 **Xcode** (35m) — window titles`), away periods, what you asked Hermes, and app totals. Short glances (under 45 s) don't break a block.

- **Ask Bluey:** “what did I do today?”, “what did I do yesterday afternoon?”, “how long did I work on the report on Monday?” He answers from the journal in a sentence or two.
- **Hermes knows it too:** each day goes to Hermes once (today's from 18:00, adjustable; days the Mac was off follow the next time Bluey runs), in its own session `bluey-journal-YYYY-MM-DD`, without popping up anywhere. The `bluey` Hermes skill points Hermes at the journal folder, so it can answer questions about any day or week on its own. Hermes' small permanent memory only gets a line when a lasting pattern shows up.
- **Reliable active time:** ActivityWatch's AFK watcher on macOS can miss sleep and lock (one “active” event across a night). Bluey therefore records presence itself every 30 seconds (real idle time and lock state, nothing during sleep) in a `bluey-presence_<Mac>` bucket and uses it wherever it exists. Older days without it get a warning on blocks that look like idle time (hours in one unchanged window), which aren't counted as active.
- **Settings ▸ Journal:** on/off, send to Hermes and from what time, *Send today now*, *Open Folder*. Window titles are included; they stay between Bluey, the journal files and your Hermes.
- `swift run GooglyMac --journal [today|yesterday|monday|YYYY-MM-DD]` prints a day's journal without sending anything.

## Pomodoro

Focus runs in a Pomodoro rhythm (on by default): **25 minutes focus → 5-minute break**, and after **4 rounds a 15-minute break**. When a round's time is up, Bluey sends you on your break (bubble, chirp on the Mac and phone, the notch drops open, and a green break countdown replaces the timer). No screen checks happen during a break, and lock, sleep or the phone going to the background don't pause it: being away is the point. When the break is over he calls you back and asks whether you're ready for the next round; say “go” or tap Focus, and it continues the same task. Ending a round early gives no break; you can always **take a break now** or **skip** one.

Change it however you like:
- **Voice or typing:** “50 minutes focus and 10 minutes break”, “longer breaks”, “Pomodoro off”, “start the next round automatically”.
- **Notch:** the timer button opens on/off, presets, ± for focus, break, long break and rounds, and *Auto next round*.
- **Phone:** the Pomodoro card in Focus sessions (presets, steppers, auto-start switches).
- **Mac menu:** *Pomodoro* has presets (25/5, 50/10, 90/20, 15/5), *Custom Times…*, auto-start switches, *Take a Break Now* and *Skip Break*.

Settings are saved on the Mac and apply from the next round or break. Without a duration, a new focus session uses the Pomodoro length; a named duration (“for 40 minutes”) still wins. With Pomodoro off, sessions simply end, as before (default 30 minutes). Developer Mode runs breaks at 4× too.

## Without the phone: Bluey in the notch

On a MacBook with a notch, Bluey also lives right in it, so the phone is optional (**Bluey in the Notch** in the menu, on by default). His little face peeks out to the left of the notch with his eyes on your mouse; the right side shows the focus countdown, a listening meter, a spinner while he or Hermes works, or a yellow badge when Hermes waits for you. Hover over him and the notch drops open: his latest reply, a field to type to him (“what's on my calendar?”, “tell Hermes…”, or a task to focus on), a mic button, focus controls and Hermes approval cards. **⌃⌥B** opens it straight into the text field; it stays open while you type and closes with Esc or a click elsewhere. If another app already lives in the notch (a “Dynamic Island” like Vorssaint), Bluey sits beside it instead of covering it, and his right-hand wing only appears for a timer, a break, Hermes waiting or while you talk.

- **Talk:** with no phone connected, **hold ⌃⌥Space** (the talk shortcut) and speak, let go and he answers (with a phone connected, it wakes the phone instead). Voice runs on the Mac with the same Realtime session and tools as on the phone; captions appear as his usual bubbles, hanging from the notch. Typing never turns the mic on; the mic starts the first time you talk, and it turns off again after three idle minutes.
- **Focus:** the Mac keeps focus sessions alive on its own, so they start, run and nudge without the phone (nudges chirp on the Mac). With a phone connected everything works as before; without one, his cursor's home moves from above the phone to just under the notch.
- On Macs without a notch he sits in the middle of the menu bar instead. Demo switches for screenshots: `GOOGLY_DEMO_NOTCH_OPEN=1` keeps the panel open, `GOOGLY_DEMO_NOTCH_ASK="…"` types a question after launch, `GOOGLY_DEMO_POMODORO=1` starts a break with the timer settings open.

## Hermes gateway

Bluey is also a gateway to [Hermes Agent](https://hermes-agent.nousresearch.com) running on the same Mac. Hold Bluey's face and say “tell Hermes…” (or just ask for something Hermes does: send a message, check the calendar, add a to-do, use the browser or the computer), or open the **✦** button on the phone (also **Hermes** in Bluey's app screen) and type. Hermes does the work with its own tools; Bluey hands it the request, follows the run, and shows the answer as a bubble and in the phone's Hermes chat. Quick answers come back straight away; longer jobs report back when they're done. The Mac menu has **Hermes ▸ Ask Hermes…** and the recent requests.

- **Setup:** enable Hermes' API server (`hermes config set API_SERVER_ENABLED true`, `hermes config set API_SERVER_KEY <secret>`, then `hermes gateway restart`) and enter the URL and key in **Hermes ▸ Connect…**. The key stays in `~/Library/Application Support/Googly/hermes.json` (mode 600) and never goes to the phone. Bluey talks to `/v1/runs` on `127.0.0.1:8642`.
- **Risky steps:** pick **Ask me**, **Always deny** or **Always allow** on the phone's Hermes screen or in **Hermes ▸ Risky Steps**. In *Ask me*, a yellow card appears on the phone (the ✦ button turns yellow) and in the Mac menu; when he's awake he also asks you out loud and takes your answer. Hermes' own approval policy runs first: in its default `smart` mode it settles clearly safe or clearly dangerous commands itself, and only uncertain ones reach Bluey. Questions from Hermes always come to you.
- **Context:** each request carries the current focus task, recent focus sessions and today's ActivityWatch summary. Requests share one Hermes conversation per day (`bluey-YYYY-MM-DD`). A `bluey` Hermes skill (in `~/.hermes/skills/personal/bluey`) tells Hermes where the to-dos, focus history and ActivityWatch data live.
- **Live probe:** `swift run GooglyMac --hermes-test ["request"]` checks ActivityWatch and sends one real request (approvals are denied in the probe).

## ActivityWatch

With [ActivityWatch](https://activitywatch.net) running on the Mac (`localhost:5600`), Bluey tracks **real active time**: only time with keyboard or mouse use (ActivityWatch's not-AFK time) counts, and app and window time is measured inside it. The phone's Hermes screen shows today's active and away time and top apps; ask Bluey “what did I do today?” for a summary (see Journal). Each focus session records the active time and top apps for its time window (shown under the session's timeline), and focus sessions are written to a `bluey-focus_<Mac name>` bucket, so they appear on ActivityWatch's own timeline next to everything else. Everything stays on the Mac.

## Screen sharing and privacy

During a running focus session the Mac captures its **main display every 30 seconds** (every **10 real seconds in Developer Mode**), excluding Bluey's own windows, and sends a reduced JPEG to OpenAI with the declared task, active elapsed time, idle duration and up to eight recent check results. Real active time is distinguished from the accelerated test clock. If a nudge becomes due, a separate Responses request receives a fresh image and OCR target labels to prepare a short bubble and optional pointer target. No automatic clicking, app closing, website blocking or Codex delegation occurs in the monitoring path.

Bluey keeps screenshots in memory and does not save them by default. Local focus history stores the task, timings, classifications, model probability/confidence estimates and nudge markers, not images or OCR text. Mac history is `~/Library/Application Support/Googly/focus-history.json`; a copy is retained on the phone. OpenAI's processing and retention follow your API account's data controls; “not saved by Bluey” is not a promise of zero retention by OpenAI. Pause before opening anything you don't want shared.

The phone gets short-lived Realtime client secrets, never the Mac's long-lived key. Bonjour discovery still uses `_googly._tcp`, but connections now authenticate using a QR-shared 256-bit secret, a fresh challenge and HMAC. Direction-specific HKDF keys protect ordered AES-GCM records against eavesdropping, tampering and replay. Unpaired clients cannot request screenshots, tools or Realtime secrets. The phone stores its pairing credential in its device-only Keychain. The Mac stores its pairing credential in a private support file. Older builds using plaintext pairing must be updated on both devices.

## How nudges work

The [Decisions API](https://developers.openai.com/api/docs/guides/decisions) is called at `POST /v1/decisions` using `gpt-6-luna` and a **choice** question named `activity`: `on_task`, `off_task`, or `uncertain`. The app parses `choice`, the per-choice `probabilities`, and separate `confidence`. It does not expect explanations or coordinates.

Related tutorials, focused research, reading and waiting for a build can support the specific task. General social-feed browsing does not become on-task merely because an AI or Codex keyword appears. Social media research can still be on-task when it directly serves the declared task. The classifier receives bounded OCR text and the frontmost app name alongside the image, so small screen text remains readable. None of that text is stored. A still mouse is never proof of distraction. Screenshot text is untrusted evidence, never instructions.

- Only consecutive off-task choices with P(off_task) at least 0.5 accumulate evidence. The separate API confidence score is displayed for inspection; it does not veto an off-task probability a second time.
- In normal mode, mean P(off_task) at 0.95 or above requires an evidence span of **120 seconds**. From 0.5 to 0.95 the span falls gradually from **240 to 120 seconds**. For example 0.65 requires about 200 seconds, reached at the next 30-second check. Developer Mode uses a 40-to-80 focus-second span, so two or three ten-real-second checks can trigger a nudge.
- On-task, uncertain, failed, malformed, stale (>20 real seconds), out-of-order or missing checks reset the evidence run. A missing check means a gap over 1.5 observation intervals (45 focus-clock seconds normally, 60 in Developer Mode). Pause/end reset it too. Changing Developer Mode discards pending results and starts fresh evidence.
- A nudge resets the run and has a 120-second cooldown. Model estimates are not calibrated certainty; these are conservative initial product thresholds, not measured accuracy guarantees.
- Responses (`gpt-5.5`, structured output, `store: false`, eight-second wording timeout) writes one gentle sentence. A failed extra capture or wording request falls back to “Are you sure you're on task right now?” It can select only an existing OCR line, with an exact matching quote. The app re-reads its position and checks the foreground app before pointing. Ambiguous or changed targets get a bubble alone. The same nudge text also appears briefly on the phone, alongside its chirp.

Sessions show a rectangular timeline on iPhone: green on-task samples, peach off-task samples, grey unknown/unavailable/unchecked time. The main face screen also shows the latest **On task**, **Off task** or uncertain status. Tap the timeline or **On task**, **Off task**, or **Unknown** to inspect individual checks, their category probabilities and separate overall decision confidence. Older checks may have only the Off task probability; missing values are labelled, never inferred. Failed or stale checks have no valid confidence estimate. The timeline represents periodic observations rather than an exact time audit. Paused time is excluded.

## Build and run

Keep existing internal names and bundle IDs (`GooglyMac`, `GooglyEyes`, `co.visionairy.googly.*`). Renaming them resets permissions and pairing.

Mac (SwiftPM, macOS 14+):

```sh
./scripts/build-mac.sh
pkill -x GooglyMac
open build/Bluey.app --args --pair
```

The script signs with an available Apple Development certificate and stages signing outside iCloud-managed Documents. The app remains a menu bar app.

Phone (Xcode, iOS 17+):

```sh
xcodegen generate
xcodebuild -project GooglyEyes.xcodeproj -scheme GooglyEyes \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/BlueyFocusDerivedData build
xcrun devicectl list devices
xcrun devicectl device install app --device <your-device-id> \
  /tmp/BlueyFocusDerivedData/Build/Products/Debug-iphoneos/Bluey.app
xcrun devicectl device process launch --device <your-device-id> \
  --terminate-existing co.visionairy.googly.phone
```

Set your own development team in `project.yml` when building on another Mac. Build outside Documents to avoid iCloud extended attributes breaking signing.

## Tests

Deterministic fixtures, no real API calls:

```sh
swift test --scratch-path /tmp/bluey-focus-swift
```

Tests cover timing, resets, cooldowns, stale/invalid answers, pause/resume/expiry, synchronization payloads, permission failure, disconnect/lock, cancellation and encrypted loopback pairing. A separate opt-in live probe calls the production API code with **synthetic images**, never your desktop:

```sh
swift run GooglyMac --focus-api-test
```

With a separate signed Bluey app already running, `build/Bluey.app/Contents/MacOS/GooglyMac --focus-link-test` exercises real Bonjour discovery, authenticated encryption, a 30-second desktop capture/Decisions check and synchronized pause/resume/end. It creates a labelled integration-test entry in history and skips an existing active user session. `--focus-screen-test` makes one real desktop capture/Decisions request without saving an image. These probes share your screen with OpenAI; do not run them while displaying private content.

`build/Bluey.app/Contents/MacOS/GooglyMac --focus-developer-test` checks the same live path at 4× clock speed and the ten-real-second cadence, then restores the previous Developer Mode setting. It also skips an existing active session.

`build/Bluey.app/Contents/MacOS/GooglyMac --focus-nudge-test` sends the same immediate test notification as the phone's **Test a nudge** button. It requires Developer Mode and secure pairing, captures no screen, and leaves focus sessions unchanged. Automatic nudge delivery, fallback failures and cancellation also have fixture-based coordinator tests.

Latest local verification: **22 deterministic tests passed**, both signed targets built, and the updated apps were installed and opened on Mac and a physical iPhone 16 Pro. QR pairing and voice-to-task were verified on the phone. Live integration checked the scheduled Decisions request, 4× clock, pause/resume/end and synchronized history. A real Mac test bubble was visually checked, and the phone confirmed receiving the nudge notification.

Live API tests using **synthetic screenshots and OCR** classified an unrelated Twitter feed as off-task and directly relevant Twitter research as on-task. Automatic nudge delivery, capture/wording failures and cancellation were covered by injected fixture tests. These are separate from the physical notification test. Real off-task browsing with the latest classifier, audible chirp loudness and pointer targeting still need a manual device run; the synthetic examples are not an accuracy benchmark.

## Existing capabilities

The existing manual pointing, voice context, research cards, Codex controller and session history remain available. The focus path does not start the old continuous meeting-audio recorder by default. Realtime output remains text only, with bubbles and chirps. The long-lived key stays on the Mac.

## Layout

- `Shared/`: pairing transport, palette, focus state and deterministic nudge policy.
- `Mac/`: menu bar app, screenshot classifier, nudge generator, timer and existing tools.
- `iOS/`: face, voice input, QR pairing, synchronized controls and focus timelines.
- `Tests/`: deterministic logic, lifecycle and secure transport tests.

## License

Public domain under [the Unlicense](LICENSE). Do whatever you want with it.
