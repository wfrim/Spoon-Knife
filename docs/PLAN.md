# Apartment Line — iOS Proof of Concept Plan

Oct 6, 2026 · @Will Frimel

## Summary

The concept is buildable. Who is home comes from a geofence around each apartment, recorded ahead of time, because iOS can't run a location or Wi-Fi check at the moment a call arrives.

**The idea.** Each apartment has a profile with a fun name. Calling it rings every roommate who is home; the first to pick up takes the call and the others can join. If nobody answers, the caller leaves a message for the whole apartment. It behaves like a shared landline that lives in everyone's pocket only while they're home.

**What the proof of concept (POC) must prove**, in order of risk:

1. Presence: the server knows within a few minutes which roommates are home, from a home geofence, without them opening the app.
2. Ringing: calling an apartment shows the native call screen on every home phone; the first pickup stops the others ringing.
3. Ongoing call: the other home roommates see a "call in progress" card and can join.
4. Messages: a caller who gets no answer leaves a voice message for the whole apartment.
5. Setup: creating an apartment profile and inviting roommates takes under two minutes.

**Recommended approach.** A native SwiftUI app using CallKit and VoIP push for ringing, a Live Activity for the ongoing-call card, LiveKit for voice, and Supabase for profiles, presence and messages. Presence is a geofence around each apartment (decided Oct 6) with a manual Home/Away override.

## How it works

Five flows cover the POC: create the apartment, join it, call it, leave it a message, and get back to someone you missed.

**1. Create the apartment profile (first roommate)**

1. Sign in with Apple.
2. Create the apartment: a fun name ("The Burrow"), a unique handle (@theburrow), a photo or emoji, and a short status line.
3. Set home: use current location or drop a pin; the app draws the geofence (default 200 m, adjustable 100–500 m).
4. Invite roommates with a link or QR code.

**2. Join (each roommate)**

1. Open the invite, sign in, set a display name and photo.
2. Grant Location (Always) and Notifications; optionally share a phone number for text-backs.
3. From then on presence is automatic: entering the geofence marks you home, leaving marks you away. A widget or in-app switch overrides it.

**3. Call an apartment**

1. Search the apartment's name or handle, or tap it in Favorites. Its profile shows who's home ("2 of 4 home").
2. Tap Call; the server rings every member currently home.
3. Each home phone shows the native call screen: "The Burrow — Alex calling".
4. The first roommate to pick up is connected; every other phone stops ringing at once.
5. The other home roommates get a Lock Screen card, "On a call: Maya with Alex", with a Join button. Joining adds them to the call; the card disappears when the call ends.
6. No pickup within 30 seconds, or nobody home: the caller is offered "Leave a message for The Burrow".

**4. Leave a message for the apartment**

1. The caller records a voice message (up to 60 seconds) or types a short note.
2. It lands in the apartment's shared Messages inbox, every member gets a notification, and the inbox shows who has listened.
3. Any roommate can reply or call back from the message.

**5. Missed a call: three ways back (stretch)**

The missed-call notification and the Recents entry offer three actions: call the person directly (rings only their phone), call their apartment, or text them through iMessage.

## Technical challenges and blockers

Two items are true blockers that force a design change (B1, B2); the rest are solvable with known patterns.

### B1 — Blocker: the app can't check Wi-Fi at the moment a call comes in

The intuitive design — call arrives, each phone checks "am I on the home Wi-Fi?", only matching phones ring — does not work on iPhone.

- The only way to receive a call while the app is closed is a VoIP push, and Apple requires every VoIP push to immediately show a call screen. On iOS 13 and later, [the system terminates the app if it doesn't, and repeated failures stop VoIP push delivery entirely](https://developer.apple.com/tutorials/data/documentation/pushkit/pkpushtype/voip.md). So a phone can't receive the call, check Wi-Fi, and quietly decline.
- Silent background pushes are throttled and can be delayed for minutes or dropped, so they can't be used for a real-time "are you home?" poll.

**Alternative (recommended):** decide *before* the call. The server keeps a presence roster per apartment that phones update in the background, and pushes only go to phones marked home. Ringing becomes a server decision, which is reliable.

### B2 — Blocker: iOS won't notify an app when the phone joins a Wi-Fi network

There is no background "Wi-Fi changed" event for ordinary apps. Reading the network name is possible with [Apple's `NEHotspotNetwork.fetchCurrent`](<https://developer.apple.com/tutorials/data/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:).md>), but only while the app is running, and only with [the Access Wi-Fi Information capability plus the user's location permission](https://developer.apple.com/forums/thread/748672).

**Alternatives, combined into a layered presence engine:**

| Signal | How it fires | Latency | Reliability | User setup |
| --- | --- | --- | --- | --- |
| Home geofence (Core Location region monitoring) | iOS wakes the app on entering/leaving a ~100 m circle around home | ~1–3 min | High for arrive/leave; can't tell Wi-Fi from "outside the door" | Location: Always |
| Wi-Fi check on wake | Every time the app runs (geofence wake, app open, background refresh), read SSID/BSSID and report | Rides on other wakes | Exact when it runs | Same permission |
| Shortcuts automation "When joining home Wi-Fi" | The Shortcuts app runs the app's intent the moment Wi-Fi joins; [current iOS lets Wi-Fi automations run without asking](https://support.apple.com/guide/shortcuts/apd602971e63/ios) | Seconds | Highest — this is the true Wi-Fi signal | One-time, ~30 s guided setup |
| Manual toggle | Home / Away switch in the app and a Lock Screen widget | Instant | Depends on the user | None |
| Heartbeat expiry | Server marks "home" stale if no report in N hours | — | Safety net | None |

**Decision (Oct 6): the geofence is the presence signal.** Strict Wi-Fi isn't required, which also covers apartments where different rooms use different networks. The Wi-Fi check and Shortcuts automation are dropped from the POC; the manual Home/Away override and heartbeat expiry stay.

### B3 — Hard but solvable: geofence accuracy

Geofences fire on crossing a circle, typically one to a few minutes late, and small circles are unreliable (roughly 100 m is a sensible floor, approximate). In a dense block, the café downstairs or a neighbor's place counts as home. Mitigations: a radius slider at setup, the manual Away override, "near home" wording on status dots, and counting false rings during the pilot.

### B4 — Hard but solvable: ringing several phones and connecting the ones that answer

Apple handles the ringing (CallKit) but not the audio. A group voice room from a hosted media service solves it: each answering phone joins a room named after the call. Options: LiveKit (open source, Swift SDK, generous free tier), Twilio Video/Voice, or Agora. LiveKit is the recommended default.

### B5 — Hard but solvable: first pickup stops the rest, and the call stays visible

When the first roommate answers, the server marks the call answered (one atomic database update, so two simultaneous pickups can't both win) and signals the other ringing phones over the realtime connection each opens while ringing. Each ends its call screen with CallKit's "answered elsewhere" reason, so it shows as handled, not missed.

The lasting "call in progress" notice is a Live Activity (ActivityKit): the server starts it on the other home phones by push, updates who's on, and ends it with the call. Its Join button opens the app, which joins the voice room as a normal CallKit call. Push-started Live Activities need iOS 17.2 or later, which sets the POC's minimum iOS. Fallback if a phone can't show it: a standard notification "Maya is on a call with Alex — tap to join".

### B6 — Straightforward: apartment messages

Record with AVFoundation (AAC, a 60-second message is well under 1 MB), upload to Supabase Storage, store a row per message, and send a standard push to every member. The work is mainly UI: the shared inbox, playback, and "heard by" markers.

### B7 — Stretch, with limits: getting back to a missed caller through iMessage

An app can't send iMessages on its own or read conversations. It can open a pre-filled Messages compose sheet (MessageUI) addressed to the caller; the roommate taps Send. That needs the caller's phone number, so number sharing is opt-in per person. "Call them directly" reuses the call pipeline with one target and no presence check; "call their apartment" is a normal apartment call. An iMessage app extension (calling an apartment from inside Messages) is a later option.

### Other constraints worth knowing up front

- **Physical iPhones only.** VoIP push and the native call screen don't work in the Simulator; you need at least 2–3 real iPhones, ideally 4.
- **Paid Apple Developer account ($99/yr)** for push certificates, the Wi-Fi capability, and TestFlight.
- **"Always" location is a big permission ask** and draws App Store review scrutiny; the POC can ship via TestFlight and defer this. Explain the reason clearly on the permission screen.
- **CallKit is disabled for apps on the China App Store**; irrelevant for the POC.
- **Callers must have the app** in the POC. A real phone number per apartment (via Twilio) that bridges to the same room is a later phase.
- **Privacy:** roommates see each other's home/away status. Make this explicit at join time and give each person a "don't ring me" switch.

## Recommended architecture

A native SwiftUI app, a small backend that owns the home roster, Apple's push service for ringing, and LiveKit for audio.

```
 iPhone (each roommate)                      Backend (Supabase)                 External
┌──────────────────────────┐   presence   ┌───────────────────────────┐
│ CLMonitor home geofence  │─────────────▶│ devices / presence roster │
│ Manual Home/Away switch  │              │ (Postgres + RLS)          │
├──────────────────────────┤              ├───────────────────────────┤    VoIP / LA push
│ CallKit + PushKit        │◀─────────────│ Call fan-out (Edge Fn)    │──▶ APNs
│ ActivityKit Live Activity│              │ reads roster → home only  │
├──────────────────────────┤  room token  ├───────────────────────────┤
│ LiveKit Swift SDK        │◀────────────▶│ Token minting             │──▶ LiveKit Cloud
└──────────────────────────┘              └───────────────────────────┘
```

Phones report home/away continuously; when someone dials, the call service reads the roster and pushes only to home phones, and everyone who answers meets the caller in one voice room.

**Stack choices**

- **iOS app:** Swift + SwiftUI, iOS 17.2+. Frameworks: CallKit (native call UI), PushKit (VoIP push), Core Location `CLMonitor` (home geofence), ActivityKit (ongoing-call Live Activity), AVFoundation (voice messages), MessageUI (text-back), WidgetKit (Home/Away widget), LiveKit Swift SDK.
- **Backend:** Supabase — Postgres, auth, realtime (live roster and the "answered elsewhere" signal), Storage (voice messages) — plus TypeScript Edge Functions for call fan-out and APNs sending.
- **Push:** APNs with token-based auth (.p8 key): VoIP pushes to ring, Live Activity pushes for the ongoing-call card, standard pushes for messages and missed calls.
- **Media:** LiveKit Cloud; the server mints a room token per participant, including late joiners. Room name = call id.

## Data model and API sketch

Seven tables and about a dozen endpoints are enough for the POC.

| Table | Key fields | Notes |
| --- | --- | --- |
| users | id, apple_sub, display_name, photo_url, phone | Phone is optional, opt-in, used only for text-backs |
| apartments | id, handle, name, photo_url, status_line, home_lat, home_lng, radius_m | Handle unique (@theburrow); this is the apartment's profile |
| memberships | user_id, apartment_id, role, ring_enabled | ring_enabled = personal "don't ring me" |
| devices | id, user_id, voip_token, apns_token, activity_start_token, presence, presence_source, presence_at | One row per iPhone; source = geofence or manual |
| calls | id, apartment_id, target_user_id, caller_id, room_name, state, answered_by, participants, started_at, ended_at | target_user_id set for direct person calls; state = ringing / active / ended / missed |
| messages | id, apartment_id, sender_id, audio_url, duration_s, text, created_at | Shared apartment inbox |
| message_listens | message_id, user_id, listened_at | Drives "heard by" |

**Endpoints**

- `POST /auth/apple` — exchange Apple identity token for a session
- `POST /apartments`, `PATCH /apartments/:id`, `GET /apartments/search?q=` — create, edit and find apartment profiles
- `POST /apartments/:id/invites`, `POST /invites/:code/accept`
- `PUT /devices/:id/tokens` — VoIP, standard push and Live Activity push-to-start tokens
- `POST /presence` — `{state: home|away, source: geofence|manual}`
- `POST /calls` — `{apartment_id}` or `{user_id}` → rings home members (or the one person), returns the caller's room token
- `POST /calls/:id/answer` — first answer wins; others get "answered elsewhere" and the ongoing-call Live Activity
- `POST /calls/:id/join` — late joiner's room token; updates the Live Activity
- `POST /calls/:id/end` — ends the call and every Live Activity for it
- `POST /apartments/:id/messages`, `GET /apartments/:id/messages`, `POST /messages/:id/listened`

**Addressing decision (Oct 6):** apartments are reached by name or handle through search and Favorites, not by number.

## UI/UX

The app is a social phone: four tabs plus an apartment profile page, built in SwiftUI with standard iOS components so calling feels like the Phone app.

| Screen | What's on it | Design notes |
| --- | --- | --- |
| Calls (default tab) | Search bar for apartment names and handles; Favorites as profile cards with photo and "2 of 4 home" | Replaces a keypad; seeing who's home comes before calling |
| Apartment profile | Photo, fun name, handle, status line, members with Home/Away dots; big Call and Leave a message buttons | What a caller sees; the place the apartment's personality lives |
| Messages | The apartment's shared inbox: voice and text messages, playback, who has heard each one, reply | Badge on the tab for unheard messages |
| Recents | Calls in and out; missed calls carry the three ways back (call person, call apartment, text) | Same actions as the missed-call notification |
| My Apartment | Edit profile, geofence map with radius slider, roommates, Home/Away override, "don't ring me", invite | Status dots say "near home" rather than claiming certainty |

**Calls use the native iPhone call UI** via CallKit: they ring on the Lock Screen, show in system Recents, and work with AirPods and CarPlay. While a roommate is on a call, the others see a Live Activity on the Lock Screen and Dynamic Island showing who's talking, with a Join button. Inside the app, an active-call banner sits above every tab.

**Onboarding** is one decision per screen: sign in → create or join an apartment → profile (name, handle, photo) → set home on a map → permissions, each with a one-line reason ("Location lets your apartment ring you when you're home").

**Extras that fit the concept cheaply:** a Lock Screen widget toggling Home/Away, and a Home Screen widget showing who's home.

## Phased build plan

Build the riskiest piece first: Phase 0 proves geofence presence on real phones before any calling code exists. Each phase ends with a gate; don't start the next until it passes.

### Phase 0 — Geofence presence spike (week 1)

- [x] Bare SwiftUI app with Location (Always) and a `CLMonitor` home geofence
- [x] Manual Home/Away switch
- [x] Log every presence event (time, source, state) to a backend table

**Gate:** over 3 days on 2+ phones, home/away matches reality at least 95% of the time within 5 minutes; record any false "home" from nearby spots.

### Phase 1 — Apartment profiles (week 2)

- [ ] Supabase project, Sign in with Apple, tables from the data model *(tables, RLS, create/invite/accept/roster RPCs done; Sign in with Apple pending)*
- [ ] Create and edit apartment profile (name, handle, photo, status line, home pin + radius)
- [ ] Search by name/handle, Favorites, invite link, live roster on My Apartment

**Gate:** four test accounts in one apartment; a fifth account finds it by search and sees an accurate "N of 4 home".

### Phase 2 — Ringing with first pickup (week 3)

- [ ] PushKit VoIP registration; APNs sending from an Edge Function
- [ ] CallKit provider reports every VoIP push as an incoming call before any network work
- [ ] `/calls` rings home members only; atomic first answer; others end with "answered elsewhere" *(`ring_targets` and atomic `answer_call` done in SQL)*

**Gate:** a call rings every home phone (locked, app closed) within 3 seconds, 20 times out of 20; the others stop within 2 seconds of the first pickup.

### Phase 3 — Voice and the ongoing-call card (week 4)

- [ ] LiveKit Cloud; server mints room tokens; audio session through CallKit
- [ ] Live Activity started by push on the other home phones, updated as people join, ended with the call
- [ ] Join flow for late joiners

**Gate:** caller and first roommate talk for 10 minutes on Wi-Fi and cellular; a third roommate joins from the Lock Screen card.

### Phase 4 — Messages for the apartment (week 5)

- [ ] "Leave a message" after 30 seconds unanswered or when nobody is home
- [ ] Record, upload, shared inbox, playback, "heard by", push to all members

**Gate:** a message left after an unanswered call reaches every member and plays on each phone.

### Phase 5 — Polish and pilot (weeks 6–7)

- [ ] Onboarding, permission fix-it banners, Home/Away widget, Recents
- [ ] TestFlight to one real apartment for two weeks; count missed rings, false rings, messages left

**Gate:** pilot roommates want to keep using it; false rings under 1 in 20 calls.

### Stretch — Missed-call ways back

- [ ] Direct person-to-person calls (one target, no presence check)
- [ ] Missed-call notification actions: call person, call apartment, text
- [ ] Text-back through a pre-filled iMessage compose sheet, using opt-in phone numbers

### Later (not in POC)

A real phone number per apartment via Twilio so anyone can call from a normal phone; an iMessage app extension; Android.

## Testing, prerequisites, costs, open decisions

The POC needs a Mac with Xcode, a paid Apple Developer account, and 3–4 real iPhones; running costs stay near zero on free tiers.

**Prerequisites**

- Mac with current Xcode; iPhones on a recent iOS (target iOS 17.2+ for push-started Live Activities)
- Apple Developer Program membership ($99/yr) — needed for VoIP push, Wi-Fi capability, TestFlight
- Accounts: Supabase or Firebase (free tier), LiveKit Cloud (free tier covers POC usage)
- A real apartment to test at, plus spots just outside the geofence and just inside it (café downstairs) for the edge cases

**Test matrix** (run each on every phone)

| Scenario | Expected |
| --- | --- |
| Arrive home, app closed | Marked home within 5 min |
| Leave home | Marked away within 5 min |
| In the café downstairs (inside the geofence) | Shows home — log as a false positive |
| Phone locked, app force-quit, apartment called | Native call screen rings |
| First roommate answers | Others stop ringing within 2 s and get the ongoing-call card |
| Another roommate taps Join | Joins the call; card updates for everyone |
| No answer in 30 s, or nobody home | Caller offered a message; it reaches every member |
| Low Power Mode on | Note any delay in presence or Live Activity |

**Decisions (Oct 6) and what's still open**

1. Group call or first-to-answer? Decided: first to pick up stops the ringing; the others see an ongoing-call card and can join.
2. Presence: decided — geofence, not strict Wi-Fi, which also handles apartments with several networks.
3. For the POC, anyone can call an apartment; permissions (connecting apartments) come later. Original question: who can call an apartment: anyone with the app and the number, or only approved contacts? Open dialing invites spam.
4. Addressing: decided — a profile with a fun name and handle, no numbers.
5. Setup: decided — one roommate creates the profile and invites the rest; zero setup isn't required.

## Product decisions (Oct 7)

Design reference: the "Apartment Line App Design" canvas (App flows + Profile explorations pages).

### Apartment styles

**Decision:** each apartment picks a style for its "phone"; the rest of the app stays in one base style. Launch with three styles: **Simple** (the current design, default), **Sticker Book** and **Retro Rotary**. Any roommate can change the apartment's style.

Where a style shows:

| Surface | Styled? | Notes |
| --- | --- | --- |
| Apartment profile, outgoing "Calling…" screen, leave-a-message screen, the apartment's own Messages/answering machine | Fully | These are the apartment's "phone" |
| Ongoing-call Live Activity (Lock Screen card, Dynamic Island) | Colors, fonts, small art | Live Activities are SwiftUI widgets: no custom animation, tap opens the app |
| Incoming call screen | No | Drawn by Apple (CallKit). We control the caller text ("The Burrow — Alex"), the app icon and the ringtone, so each style can bring its own ring (e.g. an old bell for Rotary) |
| Standard notifications (missed call, new message, join invites) | No | Base style; text and app icon only |
| Tabs, search, Recents, settings | No | Base style |

**Built to extend.** A style is data plus optional views, never a fork of a screen:

- *Tokens*: colors, typography, corner radii, borders/shadows, motion, ringtone.
- *Slots*: named pieces of the apartment screens (profile hero, roster, call button, calling screen, recorder, answering machine). Simple implements every slot; another style overrides only the slots it wants (Rotary overrides the roster and call button with the dial) and inherits the rest.
- *Registry*: styles are registered by id. Apartments store `style_id` plus `style_options` (e.g. accent color). An id the installed app doesn't know falls back to Simple, so new styles can ship without breaking older builds. A server-side `styles` list can gate which styles are offered.
- *Rotary ring animation*: tapping Ring spins the dial and lets it click back; home roommates' holes pulse while ringing; the answerer's hole lights up.

### Home status and availability

Two separate settings per person, replacing Automatic/Home/Away + "Don't ring me":

1. **Ring me?**: *Available* (ring me when I'm home), *Snooze* (1 hour / until tomorrow), *Off* (never ring me).
2. **Show my status?**: whether roommates (and, per the apartment's setting, visitors) see that you're home.

Rules:

- Hiding your status never stops you being rung. The server still uses your location privately to decide ringing; it just isn't displayed.
- Unknown status is never shown as "unknown". Someone who hasn't shared status appears by name only, with no indicator.
- No "since 6:12 PM" times anywhere.
- Counts only include people who share status ("2 home", not "2 of 3 home"), so a hidden or unknown roommate isn't implied to be away.
- Replace the green dot (reads as "online/available") with a clearer "home" treatment; to be designed.
- **Apartment setting — what visitors see:** names of who's home / just a count / nothing. Default: just a count.
- A roommate who never grants location can opt in to **"Ring me for every call"** (decided Oct 7); otherwise they're never rung.
- Status shows only positively (a "home" badge); "away" is never displayed.

### Calling as an apartment (backlog)

When calling, choose **Call as yourself** (default) or **Call as The Burrow**. Calling as the apartment gives your home roommates a "Maya is calling Casa Noodle — join" card; their phones do not ring. The receiving side sees "The Burrow is calling (Maya)". Uses the ongoing-call Live Activity, with a time-sensitive notification as the fallback. The voice room already supports many participants; new work is `calls.from_apartment_id`, join cards on the caller's side, and the incoming label. After Phase 3.

### Answering machine and weekly recap (backlog)

- Messages tab becomes the apartment's answering machine: "You have 5 new messages", one Play that plays them back to back on speaker. Each is introduced aloud ("Alex, Tuesday 6:02 PM") by on-device speech. Skip, replay and save controls.
- Weekly recap: a Sunday notification ("This week at The Burrow: 5 messages, 12 calls — play them all") that opens the answering machine. A shareable recap card is a later follow-up.

### Schema changes these imply (not built yet)

- `apartments.style_id`, `apartments.style_options`, `apartments.visitor_presence` (`names` | `count` | `none`)
- `memberships.ring_mode` (`available` | `snoozed` | `off`) + `snoozed_until`, replacing `ring_enabled`; `memberships.share_status`; `memberships.ring_always` (no-location opt-in)
- `apartment_roster()` respects `share_status` and `visitor_presence`; drop `presence_at` from its output
- `calls.from_apartment_id`
- `message_listens` already supports the answering machine's "new" count

## Product decisions (Oct 8): v2 prototype

Design reference: canvas pages "v2 · Onboarding", "v2 · App", "v2 · Calling (by theme)".

**Language.** The product says "home" ("One line for you and your roommates"). Admins are **Keyholders**: whoever creates a home is one, and Keyholders can hand keys to others. Keyholders approve join requests, edit the home's style and greeting, and remove roommates.

**Where styles show.** A home is a place; the app is the hallway. Inside a home (yours or one you're calling) you see that home's style and colors; everywhere else (Recents, Phone, You, onboarding, settings) is the plain house style. Your own Voicemail and Home tabs wear your home's style. The tab bar is always house style.

**Themes and color schemes.** Two layers: a theme (Simple, Sticker Book, Retro Rotary) and a curated, contrast-checked color scheme per theme with a default (Simple: Cobalt*, Ember, Forest, Plum; Sticker: Bubblegum*, Pool, Night; Rotary: Mustard*, Avocado, Rust, Bakelite). Picked in onboarding with a live preview of the home's profile; any roommate can change it later.

**Tabs.** Voicemail · Recents · **Phone** (centre: the contact book: favorites, all homes, people, search and add) · *Your home* · You (personal profile and settings).

**Onboarding.**
1. Sign up with phone number (SMS code). Sign in with Apple is offered, but Apple doesn't share phone numbers, so Apple users are still asked for one.
2. Name and photo, then a "how it works" screen that sets up the location ask.
3. Create or join. Pending invites for your number are shown first ("Sam invited you to The Burrow").
4. Create: name → style + colors → home area ("where can The Burrow ring you?") → location permission (Always) → invite roommates (contacts, number, link).
5. Join: accept an invite, enter a code, or look a home up and **ask to join** (a Keyholder approves).
6. Location denied: explain plainly that the home can't ring you, and keep a red fix-it banner in the app until it's on.

**Calling.**
- Ring for 30 s (about 6 rings; a home setting can change it), then voicemail starts automatically: the home's greeting (recorded by a roommate), a beep, recording up to 60 s.
- After recording: play back, re-record, delete, or send. Hanging up sends, like a real answering machine.
- Mute and Speaker on every call screen. No keypad, no FaceTime.
- No text notes: voicemail only.
- Copy: "Calling rings the roommates who are home" (no count, no names).

**Moving out.** You → "Move out of <home>" → confirm (stop ringing; voicemails stay with the home; if you're the last Keyholder you must pass the keys) → create a new home, join one, or use an invite.

**Schema additions implied:** `apartments.style_id/style_options` (theme + scheme), `apartments.ring_seconds`, `apartments.greeting_url`, `memberships.role` gains `keyholder`, `join_requests` table, phone-number auth (Supabase phone OTP).

### Oct 8 (later) — revisions

- **The whole app wears your home's theme.** Every tab, setting and the tab bar use your home's style and colors. Only another home's screens (its profile, calling it, leaving it a voicemail) look different. Onboarding uses Simple until you have a home. *(Supersedes "the app is the hallway" above.)*
- **Greeting is optional at setup** (last step of creating a home; skip plays a default "You've reached The Burrow…"). Editable any time in home settings. When a roommate moves in, the home tab prompts everyone to re-record it together.
- **Call from: Just me / <your home>.** A two-option picker sits above the Call button on every home profile, with a line saying what the other side will see and who on your side can join; the button label follows ("Call" / "Call as The Burrow").
- **Neighborhood replaces the contact book** (centre tab). Homes can ask to be **neighbors**; the other home accepts. It shows incoming neighbor requests, **Favorites (private to your household)**, your Neighbors list, and search with "Be neighbors?".
  - Open question: should only neighbors be able to ring you (others go straight to voicemail or a request)? This would answer the spam concern from decision 3.
- **Home settings are their own screens** (style & colors, home area, invite, greeting), not the onboarding flow.
- Schema implied: `neighbors (home_a, home_b, status, requested_by)`, `favorites (home_id, favorite_home_id)`, `calls.from_apartment_id` (already planned).

## Who can reach whom (Oct 8)

Three circles: **people** (individuals), **homes** (households), and **the public**.

- **Neighbors** are homes connected to yours. The Neighborhood tab is the contact book, with a **Homes** view and a **People** view (your roommates, plus the people in neighbor homes).
- **Neighbors happen automatically through contacts.** If anyone in home A has the phone number of anyone in home B (either direction), A and B become neighbors, with no request. Each neighbor row says why ("Alex is in your contacts", "Dee is in Sam's contacts").
  - Contacts access is asked for in onboarding ("Find your people"), right after the how-it-works screen. It also surfaces homes your roommates already created.
- **Everyone else** can find a home by name or handle and **ask to be neighbors**; anyone in that home can accept.
- **Defaults, changeable in settings:**
  - Who can ring a home: **Neighbors** (default) / Anyone / Nobody. Non-neighbors go straight to voicemail and can ask to be neighbors. Keyholders set this.
  - Who can call *you* directly: **Contacts** (default) / Neighbors / Nobody.
- **Favorites** are a private, per-home subset of neighbors.
- **Blocking:** homes can block homes and people can block people. The blocked party isn't told, can't ring or call, and their calls don't reach voicemail. Unblock from "Who can reach you & blocking".
- Supersedes decision 3 (anyone can call any apartment) and the request-only neighbor model from earlier today.
- **Schema implied:**
  - `contact_hashes` (user → hashed phone numbers, matched server-side; raw contact lists never stored)
  - `neighbors` (home_a, home_b, source: contacts|request, status)
  - `favorites` (home_id → home_id)
  - `blocks` (blocker home/user → blocked home/user)
  - `apartments.who_can_ring`
  - `users.who_can_call`

### Oct 8 (later) — onboarding polish and neighbor controls

- **Onboarding palette "Pop"** (house style before you have a home), replacing the burnt orange:
  - primary cobalt #3B5BFD
  - sunny yellow #FFD43B
  - pink #E23C7A
  - mint #0E9F6E
  - warm white ground #FFF8F1
  - ink #14172B
- **Fixed button footer** on every onboarding step: primary button 56 pt, then a reserved 44 pt slot (secondary link, short note, or empty), 28 pt from the bottom. The primary is always in the same spot.
- **Home step:** address search with suggestions plus "use my location" on the map. A note under the button says location permission comes next.
- **Neighbors:**
  - Contact links count both ways (confirmed).
  - New contact-made neighbors are highlighted (NEW badge, banner) until seen.
  - Any home can **Remove** a neighbor. A removed home is never re-added from contacts, but can still ask.
- **Keyholders:**
  - The creator is a Keyholder, and a home can have any number of them.
  - Any roommate can accept a neighbor request.
  - Keyholders choose who can ring the home (Neighbors / Anyone / Nobody).

### Oct 9 — themed onboarding, roommates, cities

- **Style step previews live.** `Pick your home's style` starts on **Simple · Cobalt**. Picking a theme or color re-skins the whole screen (background, type, cards, buttons), not a thumbnail.
- **After "Use this style", onboarding wears the chosen theme.** Home area, Location, Roommates, Invite and Greeting all render from the same theme tokens the app uses. Everything before that (welcome, phone, about you, contacts, name) stays in the house "Pop" style, because you don't have a home yet.
- **Theme tokens** (one set per theme × color scheme; screens never hard-code colors). Every screen reads the same names, so a new theme is a new token set, not new screens:

  | Group | Tokens |
  |---|---|
  | Page | bg, text, muted |
  | Type | font, head, headStyle, headWeight |
  | Cards | cardBg, cardText, cardMuted, cardBorder, cardRadius, cardShadow |
  | Inputs | inBorder, inRadius |
  | Buttons | btnBg, btnFg, btnBorder, btnRadius, btnShadow |
  | Accents | accent, accentFg, soft, strong |
  | Chips | chip on / off |
  | Map | mapRing, mapFill, pin |
  | Avatars | avatars[3] |
  | Flourish | tilt (Sticker stickers sit crooked) |

- **New step: "How many roommates do you have?"** (step 5 of 6). It uses a stepper from 1 to 7 (8 people per home), with an "It's just me for now" link. The answer sets how many open spots the Invite step shows ("1 of 2 invited").
- **Invite is search, not a list.** The flow is "Search your contacts", "Add a number" or "Share link". No contacts are shown until you type, and we only look up names you search for. The same pattern applies in Home → Invite.
- **Greeting example** uses whatever the home is called: "Hi, you've reached {Home}! We can't get to the phone right now. Leave a message and we'll call you back."
- **Geofence default is 200 m** (slider 100–500, step 25, "recommended" at 200). Indoor GPS drifts 30–65 m, so 100 m missed people on the couch. 150 m is the floor we suggest.
- **City on every home:**
  - It's filled in from the address you pick or your current location (reverse geocode → locality) and can be edited.
  - It's shown on the home profile and in Neighborhood ("Casa Noodle · New York"), including people's rows ("Alex · Casa Noodle · New York").
  - The address itself is never shown.
  - Schema: `apartments.city`, plus `create_apartment(p_city)`.
- **Favorites are capped at 3 per home.** Favoriting a 4th asks you to unfavorite one first.
- **Move out** wears the home's theme while you're still a member. Once you've moved out you have no home, so the "where to next?" screen drops back to the house style.

#### Address search and auto-locate (Apple APIs, no key needed)

| Need | API | Notes |
|---|---|---|
| Type-ahead suggestions | `MKLocalSearchCompleter` (`resultTypes = .address`, `region` = around the user) | Returns title/subtitle only. Debounced; free, rate-limited per device. |
| Turn a suggestion into a coordinate | `MKLocalSearch(request: .init(completion:))` | Gives `MKMapItem` → `placemark.coordinate`, `locality` (city), `administrativeArea`. |
| "Use my location" | `CLLocationManager.requestLocation()` (or `CLLocationUpdate.liveUpdates()` first value) | Needs **When In Use** only; Always is asked on the next step for the geofence. |
| Coordinate → address + city | `CLGeocoder.reverseGeocodeLocation` (iOS 26: `MKReverseGeocodingRequest`) | One request at a time; cache. City = `locality` (fall back to `subLocality` / `administrativeArea`). |
| Map + circle | SwiftUI `Map` with `MapCircle`, `Annotation` | Already in `HomeSetupView`. |

- **Info.plist:** `NSLocationWhenInUseUsageDescription`, plus `NSLocationAlwaysAndWhenInUseUsageDescription`. No MapKit entitlement or API key is required.
- **Storage:** we store `home_lat`, `home_lng`, `radius_m` and `city`. We don't store the street address; it's only used to place the pin.
