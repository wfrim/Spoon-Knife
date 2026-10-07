# apartmentline.app (invite links)

Invite links are `https://apartmentline.app/j/<code>`. The domain needs to serve two things:

1. **`/.well-known/apple-app-site-association`** (this folder), as `application/json`, no redirect.
   Replace `TEAMID` and the bundle id with yours. It tells iOS that `/j/*` opens the app, and that
   the App Clip belongs to this domain.
2. **`/j/<code>`** → the `invite-page` Edge Function (`.../functions/v1/invite-page?code=<code>`),
   which renders the link preview (Open Graph tags for iMessage) and the App Clip banner, in the
   home's own theme.

Any static host with a rewrite works (Cloudflare Pages, Vercel, Netlify). Example `_redirects` for
Cloudflare Pages / Netlify:

```
/j/:code  https://<project-ref>.supabase.co/functions/v1/invite-page?code=:code  200
```

Then, in App Store Connect → the app → App Clip → Advanced App Clip Experiences, add
`https://apartmentline.app/j/` as a prefix URL so every invite opens the App Clip card.
