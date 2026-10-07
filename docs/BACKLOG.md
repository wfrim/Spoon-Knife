# Backlog

What's next, roughly in order. **You** = needs you (an account, a device, a decision). Everything else can be built in a cloud session.

Last updated Oct 9, 2026.

## Now: to make a real call between two phones

1. **Accounts and keys (You)**
   - Apple Developer account ($99/yr).
   - A Supabase project: turn on anonymous sign-ins and the `pg_cron` extension, then run `supabase db push`.
   - A LiveKit Cloud project.
   - Put the secrets into Supabase Edge Function Secrets; the list is in `supabase/functions/README.md`.
2. **Signed builds to TestFlight from CI.**
   - Add a CI job that signs the app using your Apple account's credentials, stored as GitHub secrets.
   - Bump the build number automatically, then upload to TestFlight.
   - You won't need a Mac.
3. **Device test pass (You + iPhone × 2):**
   - Ring, answer, answered-elsewhere, ring-out to voicemail, leave a message, blocked caller, call as the home.
   - Fix whatever the simulator couldn't show us.
4. **CallKit + LiveKit audio session.**
   - Hand LiveKit the audio session that CallKit activates (`provider(_:didActivate:)`), rather than letting LiveKit configure its own.
   - Check speaker/mute from the system call screen.
5. **Play the home's greeting before the beep.**
   - Record and upload the greeting to Storage, using `apartments.greeting_url`, which already exists.
   - The caller's phone downloads it and plays it before recording.
6. **Live call updates instead of polling.**
   - The phone currently checks the call's status every 2 s.
   - Switch to Supabase Realtime on the `calls` row (with RLS), and keep polling only as a fallback.

## App (turn the designs into SwiftUI)

7. **Theme system in SwiftUI.**
   - Port `tools/theme.js` (one token set per theme and color scheme) to a Swift `Theme` environment value.
   - Every screen reads tokens, like the canvas.
8. **Screens, in order:**
   - Onboarding: welcome, phone, about you, contacts, choose path, then the create flow (name, style, home area, location, roommates, invite, greeting).
   - The five tabs.
   - Home settings, Keyholders, Move out.
   - The calling screens.
9. **Phone sign-in.**
   - Replace anonymous auth with phone OTP plus Sign in with Apple.
   - Phone OTP fills `users.phone_hash`, which turns on contact matching.
10. **Contacts sync.**
    - Read contacts (with permission), normalize numbers to E.164 with a library such as PhoneNumberKit, then call `sync_contacts`.
    - Re-sync on app open at most daily (the server allows 10 a day).
11. **Address search.**
    - `MKLocalSearchCompleter` for type-ahead, `MKLocalSearch` to resolve, reverse geocoding for the city.
    - The designs are on the canvas, and the plan has the API notes.
12. **Live Activity / Lock Screen card in the home's theme.**
    - Apple's incoming-call screen can't be themed; the Lock Screen card can.
13. **App Clip → full app handoff.**
    - Share the anonymous session through an App Group, so joining in the clip carries over when the full app is installed.

## Backend

14. **Neighbor graph for the app.**
    - Endpoints for the Neighborhood tab: requests inbox, search homes by name/@handle with paging, and People (the members of neighbor homes).
    - Index `apartments(lower(handle))`.
15. **Who can ring = Keyholders' setting in the UI.**
    - The database enforces it already.
    - Show "Only neighbors can ring Casa Noodle — ask to be neighbors" using the `ask_to_be_neighbors` hint the server returns.
16. **Push notifications (non-VoIP)** for: new voicemail, neighbor request, someone moved in, "Theo wants to move in", and Keyholder changes.
17. **Move-in requests** (designed: "Theo wants to move in").
    - Table and functions alongside invites; Keyholders approve.
18. **Presence log retention.**
    - Partition `presence_events` by month, or delete rows older than 90 days with a cron job, once the Phase 0 pilot is over.
19. **Rate limits** on `place-call` (per caller per minute) and `request_neighbor` (per home per day) to stop ring-spam.
20. **Observability.**
    - A call funnel table: placed → rang → answered/voicemail/missed, with time-to-ring.
    - Track the time from tapping Call to the first phone ringing.
21. **RLS performance pass.**
    - Wrap `is_member()` in `(select …)` in the init policies, and add `devices(user_id)` and `memberships(user_id)` indexes.
    - Use `EXPLAIN` on the roster for a home with 8 people and many devices.

## Design

22. **Simple + Rotary for the remaining screens:**
    - home settings (style, area, invite, greeting, privacy, Keyholders, move out)
    - incoming/ongoing call
    - Lock Screen card
23. **Dark mode** for Simple; Night already exists for Sticker.
24. **Empty states:**
    - nobody home
    - no neighbors yet
    - first voicemail
    - first call
    - a home that's just you
25. **Accessibility pass:**
    - Dynamic Type at XXL
    - VoiceOver labels on tilted stickers and the rotary dial
    - Reduce Motion for the bobbing tiles and ringing dial
    - contrast checks on every theme
26. **Shareable home card** (sticker image with @handle) for Instagram stories.
27. **Weekly recap** ("The Burrow got 6 calls; Sam answered 4").

## Mechanics to decide (You)

28. **Living in two homes** (college + parents): which home's theme the app wears, and which home Recents and Voicemail show.
29. **Guests / sublets**: a membership that expires on a date.
30. **Quiet hours per home**, and "only ring if 2+ are home".
31. **Knock**: an "anyone home?" ping instead of a call.
32. **House-wide call**: ring every roommate wherever they are.
33. **Voicemail claim**: "Lee is calling them back", so three people don't all call back.
34. **A real phone number per home**, so people without the app can call (Twilio). This is the biggest growth lever, but it costs money per number and per minute.

## Cleanup

35. **Archive the v1 canvas pages** (flows, explore, styles, settings).
36. **Rename and detach the repo from Spoon-Knife (You).**
37. **Split `docs/PLAN.md`** into a short current spec plus a decisions log.
38. **Retire the Phase 0 test screen** once onboarding exists; keep the spot-check button for the pilot.
39. **Sign the CI-built Xcode project** only in the TestFlight job; the simulator job stays unsigned.
