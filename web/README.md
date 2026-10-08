# homephone.app (invite links)

Invite links are `https://homephone.app/j/<code>`. The domain needs to serve two things:

1. **`/.well-known/apple-app-site-association`** (this folder), as `application/json`, no redirect.
   Replace `TEAMID` and the bundle id with yours. It tells iOS that `/j/*` opens the app, and that
   the App Clip belongs to this domain.
2. **`/j/<code>`**: `functions/j/[code].ts`, a Cloudflare Pages Function that runs the tested
   handler in `supabase/functions/invite-page/handler.ts`. It renders the link preview (Open Graph
   tags for iMessage) and the App Clip banner, in the home's own theme. Supabase can't host it:
   it serves HTML from its own domain as plain text.

It also hosts the **browser test phone** at `/test-phone/` (see docs/SETUP.md).

Hosting: Cloudflare Pages, root directory `web`, env vars `SUPABASE_URL` and `SUPABASE_ANON_KEY`.

Then, in App Store Connect → the app → App Clip → Advanced App Clip Experiences, add
`https://homephone.app/j/` as a prefix URL so every invite opens the App Clip card.
