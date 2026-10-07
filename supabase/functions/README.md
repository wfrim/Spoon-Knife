# Edge Functions

| Function | Does |
|---|---|
| `place-call` | Starts a call (`start_call`), pushes VoIP to the phones that should ring, returns the caller's LiveKit room token. Nobody home → straight to voicemail. |
| `call-token` | LiveKit token for a call's room, for whoever the database says may be in it (answerer, roommates joining a call placed as the home). |

Tests: `deno task test` (no network; APNs, LiveKit and PostgREST are faked). CI runs them on every change here.

## Secrets (Supabase → Edge Functions → Secrets)

`SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are provided by Supabase.

| Name | Where it comes from |
|---|---|
| `APNS_KEY_ID`, `APNS_TEAM_ID` | Apple Developer → Keys → a key with Apple Push Notifications enabled |
| `APNS_PRIVATE_KEY` | The contents of that key's `AuthKey_XXXX.p8` |
| `APNS_BUNDLE_ID` | The app's bundle id (VoIP topic is `<bundle>.voip`) |
| `APNS_ENV` | `sandbox` for Xcode/TestFlight-dev builds, `production` for TestFlight/App Store |
| `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | LiveKit Cloud → project → Settings → Keys |

Deploy: `supabase functions deploy place-call call-token`.
Without APNs secrets, `place-call` still works but sends every home call straight to voicemail (and says so in `note`).
