# Home Phone

A shared landline for an apartment that lives in everyone's pocket, but only rings the roommates who are home.

Each apartment has a profile with a fun name and handle (@theburrow). Calling it rings every roommate who's home. The first to pick up takes the call, and the others see an ongoing-call card and can join. If nobody answers, the caller leaves a message for the whole apartment.

The full proof-of-concept plan, including blockers, architecture, data model and phased build, is in **[docs/PLAN.md](docs/PLAN.md)**.

## Status

| Phase | What | State |
| --- | --- | --- |
| 0 | Geofence presence spike | **Built, ready to test on phones** |
| 1 | Apartment profiles | Schema, RLS and RPCs done; Sign in with Apple and UI pending |
| 2 | Ringing with first pickup | `ring_targets` and atomic `answer_call` done in SQL; CallKit/PushKit pending |
| 3–5 | Voice, Live Activity, messages, pilot | Not started (`messages` tables exist) |

## Repository layout

```
docs/PLAN.md                      The plan (source of truth for decisions)
ios/                              SwiftUI app (iOS 17.2+), generated with XcodeGen
  project.yml
  Config/Secrets.example.xcconfig
  HomePhone/
    App/        entry point, background heartbeat
    Presence/   CLMonitor home geofence, offline report queue, permissions
    Backend/    small Supabase REST client (anonymous auth for Phase 0)
    Views/      Phase 0 screen, set-home map
supabase/
  migrations/   schema, row-level security, RPCs
  tests/        SQL behaviour tests (+ stubs for plain Postgres)
  reports/      phase0_gate.sql: the Phase 0 pass/fail query
scripts/test-db.sh                Runs the migrations and tests on a throwaway Postgres
```

## How presence works

iOS can't check "am I home?" when a call arrives (plan B1/B2), so the server keeps a roster ahead of time:

- **Geofence.** `CLMonitor` watches a circle (default 100 m) around home. iOS relaunches the app in the background on each crossing, and it reports `home` or `away` with the time it saw the crossing.
- **Offline queue.** Reports are written to disk first and sent in order, so a crossing seen with no signal still arrives later with its original timestamp. The server ignores anything older than what it already has.
- **Manual override.** Set Home or Set Away holds until the next real crossing.
- **Heartbeat expiry.** Presence nobody has confirmed in 24 h reads as `unknown`, and unknown phones never ring. Background App Refresh and opening the app re-confirm the geofence state so people who stay home don't expire.
- Every report is logged in `presence_events`. Spot checks ("I'm home" / "I'm away") go in `presence_checks` as ground truth.

## Setup

### Backend (Supabase)

1. Create a Supabase project (free tier).
2. Authentication → Providers: enable **Anonymous sign-ins** (Phase 0 only; Sign in with Apple replaces it in Phase 1).
3. Apply the schema, either with `supabase link --project-ref <ref> && supabase db push` or by pasting `supabase/migrations/*.sql` into the SQL editor.

### iOS app

Needs a Mac with Xcode, a paid Apple Developer account and real iPhones.

```sh
brew install xcodegen
cd ios
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # fill in URL, anon key, bundle id, team
xcodegen
open HomePhone.xcodeproj
```

Run on each test phone, set the location permission to **Always** with Precise Location on, then tap **Home** and set the circle.

### Database tests

```sh
scripts/test-db.sh                                  # throwaway local cluster (needs initdb/pg_ctl)
DATABASE_URL=postgres://… scripts/test-db.sh        # or an existing empty database
```

CI runs the same thing on every change under `supabase/`.

## Running the Phase 0 gate

**Gate:** over 3 days on 2+ phones, home/away matches reality at least 95% of the time within 5 minutes, with any false "home" from nearby spots recorded.

1. Install on 2+ phones, give each tester a name in the app, set home, and grant Always location.
2. Live normally for 3 days. A few times a day, especially just after arriving or leaving and in spots near home (the café downstairs, a neighbour's), tap **I'm home** or **I'm away** and add a note.
3. Run `supabase/reports/phase0_gate.sql` in the SQL editor. It scores each spot check against the geofence's latest report received within 5 minutes, per phone and overall, and lists false-home cases.

Also run the test matrix in the plan: arrive and leave with the app closed, Low Power Mode, and phone off overnight.
