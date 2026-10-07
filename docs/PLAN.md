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
3. Set home: use current location or drop a pin; the app draws the geofence (default 100 m, adjustable).
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
