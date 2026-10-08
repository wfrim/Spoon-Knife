# Setup: from zero to a real call on one iPhone

Every step happens in a browser. **Secrets only go into GitHub secrets, Supabase or Cloudflare, never into chat or the repo.**

GitHub secrets live at: repo → **Settings → Secrets and variables → Actions → New repository secret**.

---

## 1. Supabase (~15 min)

1. **Create the project**
   - At supabase.com, choose **New project** and name it `apartment-line`.
   - Generate a strong database password and save it in your password manager.
   - Pick the region closest to you. The Free plan is fine.
2. **Turn on anonymous sign-ins.** Go to **Authentication → Sign In / Providers** and turn on **Allow anonymous sign-ins**. The test app uses them until phone sign-in exists.
3. **Turn on `pg_cron` before step 4.** Go to **Database → Extensions** and enable `pg_cron`. Otherwise the 30-second ring-out backstop isn't scheduled.
4. **Add GitHub secrets:**

   | Secret | Where |
   |---|---|
   | `SUPABASE_PROJECT_REF` | **Project Settings → General**: the project ID (the `xxxx` in `https://xxxx.supabase.co`) |
   | `SUPABASE_DB_PASSWORD` | The password from step 1 |
   | `SUPABASE_ACCESS_TOKEN` | Your avatar (top right) → **Account → Access Tokens** → generate one called `github-deploy` |
   | `SUPABASE_URL` | **Project Settings → API Keys**: the Project URL |
   | `SUPABASE_ANON_KEY` | **Project Settings → API Keys → Legacy API keys** tab: the `anon` `public` key (not the newer "publishable" key) |

   The **service_role** key never leaves Supabase. Server functions receive it automatically.
5. **Deploy.** Go to repo → **Actions → Deploy Supabase → Run workflow**. It runs the tests, applies every database migration and deploys the server functions.
   - After that, it runs again on its own whenever the database or the functions change.
   - It also creates the voicemail storage bucket and the private contact-matching key.

## 2. LiveKit Cloud (~5 min)

1. At cloud.livekit.io, create a new project, e.g. `apartment-line`.
2. Go to **Settings → Keys** and create an API key.
3. Note three values: the **WebSocket URL** (`wss://….livekit.cloud`), the **API key** and the **API secret**. They go into Supabase in step 4.

## 3. Apple (~20 min)

At developer.apple.com → **Certificates, Identifiers & Profiles**:

1. **App ID**
   - Go to **Identifiers → + → App IDs → App**.
   - Use the explicit bundle ID `app.homephone.<yourname>`.
   - Turn on **Push Notifications** and **Associated Domains**.
2. **App Clip ID**
   - Go to **Identifiers → + → App IDs → App Clip**.
   - Choose the app above as its parent. The bundle ID is `<the app's bundle ID>.Clip`.
3. **Push key**
   - Go to **Keys → +** and turn on **Apple Push Notifications service (APNs)**.
   - Download the `.p8` file. Apple only lets you download it once, so keep it safe.
   - Note its **Key ID**.
   - Find your **Team ID** under **Membership details**.

Then at appstoreconnect.apple.com:

4. **App record**
   - Go to **Apps → + → New App** (iOS) and pick the bundle ID from step 1.
   - The name can be changed later.
5. **CI key**
   - Go to **Users and Access → Integrations → App Store Connect API → Team Keys → +**.
   - Name it `GitHub CI` with **Admin** access; that's needed for automatic signing.
   - Download the `.p8` and note its **Key ID** and the **Issuer ID** shown above the list.
6. **Add GitHub secrets:**

   | Secret | Value |
   |---|---|
   | `APPLE_TEAM_ID` | Team ID |
   | `APP_BUNDLE_ID` | e.g. `app.homephone.yourname` |
   | `ASC_KEY_ID` | The CI key's Key ID |
   | `ASC_ISSUER_ID` | The Issuer ID |
   | `ASC_KEY_P8` | The CI key's `.p8` file contents, including the BEGIN/END lines |

7. **First build.** Go to repo → **Actions → TestFlight → Run workflow**.
   - About 15 minutes later the build shows up in App Store Connect → **TestFlight**.
   - Add yourself as an internal tester, then install it with the TestFlight app on your iPhone.

## 4. Supabase Edge Function secrets

In Supabase → **Edge Functions → Secrets**, add:

| Name | Value |
|---|---|
| `APNS_KEY_ID` | The push key's Key ID (step 3.3) |
| `APNS_TEAM_ID` | Team ID |
| `APNS_PRIVATE_KEY` | The push key's `.p8` contents |
| `APNS_BUNDLE_ID` | The app's bundle ID |
| `APNS_ENV` | `production` (TestFlight builds use Apple's production push service) |
| `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` | From step 2 |
| `WEB_TEST_PHONES` | `on` while you test with the browser test phone. Remove it later. |

## 5. Cloudflare Pages: test phone and invite links (~10 min)

1. At dash.cloudflare.com, go to **Workers & Pages → Create → Pages → Connect to Git**.
2. Pick this repo and the `apartment-line` branch.
3. Set the build up like this:
   - Framework preset **None**
   - Build command: empty
   - Root directory: `web`
   - Build output directory: `/`
4. Under **Settings → Environment variables**, add `SUPABASE_URL` and `SUPABASE_ANON_KEY`, then redeploy.
5. You get `https://<name>.pages.dev`. The test phone is at `/test-phone/`, and invite links work at `/j/<code>`.
6. Later, attach your own domain and update `web/.well-known/apple-app-site-association` and `ios/project.yml` (`homephone.app` is a placeholder).

---

## Testing calls with one iPhone

The browser test phone is a second roommate.

1. **iPhone setup.** Open the TestFlight app on your phone.
   - Allow location (**Always**) and set your tester name.
   - Tap **Set Home** under Manual override, so you count as home right away.
   - Allow notifications if asked.
2. **Browser setup.** Open `https://<name>.pages.dev/test-phone/` on your laptop.
   - Paste the Project URL and anon key, and enter a name.
   - Tap **Sign in**, then **Create a test home**. Note the invite code.
3. **Join from the iPhone.** Under **Calls (preview)**, enter the invite code and tap **Join**.
4. **iPhone → browser.** Type the test home's handle (shown in the browser, e.g. `testab12c`) and tap **Call**.
   - The browser rings. Answer and talk.
   - Use headphones on one side, or you'll get echo.
5. **Browser → iPhone.** In the browser, tap **Call the home**. The iPhone rings with the system call screen, even when it's locked. Answer.
6. **Voicemail.**
   - Call from the iPhone and ignore the browser.
   - After 30 s you hear the beep. Speak, then hang up.
   - In Supabase, the **messages** table and the **voicemails** bucket should have it.

**What one phone can't test yet:** two phones racing to answer the same call (first answer wins), and contact-based neighbors.
