// GET /invite-page?code=<code>  (served at https://<domain>/j/<code> through the web proxy)
//
// What a roommate sees when they tap an invite link before having the app:
// - Open Graph tags, so iMessage/WhatsApp unfurl it as "Join The Burrow".
// - A page drawn in the home's own theme, with the App Clip banner, so on
//   iPhone it opens the App Clip card ("Join The Burrow · Open").
// - A plain fallback when the code is wrong, expired or the home is full.
import { Db } from "../_shared/postgrest.ts";

export interface InviteConfig {
  appStoreId?: string; // numeric App Store id, once the app is listed
  clipBundleId?: string; // e.g. app.homephone.Clip
  publicBase: string; // e.g. https://homephone.app
}

interface Preview {
  home_name: string;
  handle: string;
  city: string | null;
  theme: string;
  invited_by: string | null;
  roommates: number;
  is_full: boolean;
}

/** Page colors per theme family + scheme; mirrors the app's design tokens. */
const PAGE: Record<string, { bg: string; card: string; ink: string; accent: string; accentInk: string; font: string; border: string }> = {
  "simple-cobalt": { bg: "#F6F7FB", card: "#FFFFFF", ink: "#14172B", accent: "#1D4ED8", accentInk: "#FFFFFF", font: "system-ui", border: "1px solid #E4E6EC" },
  "simple-ember": { bg: "#F6F7FB", card: "#FFFFFF", ink: "#14172B", accent: "#C2410C", accentInk: "#FFFFFF", font: "system-ui", border: "1px solid #E4E6EC" },
  "simple-forest": { bg: "#F6F7FB", card: "#FFFFFF", ink: "#14172B", accent: "#166534", accentInk: "#FFFFFF", font: "system-ui", border: "1px solid #E4E6EC" },
  "simple-plum": { bg: "#F6F7FB", card: "#FFFFFF", ink: "#14172B", accent: "#7E22CE", accentInk: "#FFFFFF", font: "system-ui", border: "1px solid #E4E6EC" },
  "sticker-bubblegum": { bg: "#FFEFE3", card: "#FFFFFF", ink: "#2B2140", accent: "#7BE0A3", accentInk: "#2B2140", font: "ui-rounded, system-ui", border: "2.5px solid #2B2140" },
  "sticker-pool": { bg: "#E3F6F5", card: "#FFFFFF", ink: "#12343B", accent: "#6EE7B7", accentInk: "#12343B", font: "ui-rounded, system-ui", border: "2.5px solid #12343B" },
  "sticker-night": { bg: "#241A3D", card: "#FFFFFF", ink: "#0F0A1C", accent: "#7BE0A3", accentInk: "#0F0A1C", font: "ui-rounded, system-ui", border: "2.5px solid #0F0A1C" },
  "rotary-mustard": { bg: "#F4E7CC", card: "#FBF3E1", ink: "#3A2213", accent: "#4A2C1A", accentInk: "#F4E7CC", font: "Georgia, serif", border: "1.5px solid #4A2C1A" },
  "rotary-avocado": { bg: "#EEF0DD", card: "#F7F8EC", ink: "#26301A", accent: "#2F3A1A", accentInk: "#EEF0DD", font: "Georgia, serif", border: "1.5px solid #2F3A1A" },
  "rotary-rust": { bg: "#F7E4D7", card: "#FCF1EA", ink: "#3B1F14", accent: "#3B1F14", accentInk: "#F7E4D7", font: "Georgia, serif", border: "1.5px solid #3B1F14" },
  "rotary-bakelite": { bg: "#EFE6D2", card: "#F8F2E6", ink: "#1F1C1A", accent: "#1F1C1A", accentInk: "#EFE6D2", font: "Georgia, serif", border: "1.5px solid #1F1C1A" },
};

export function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

export function codeFrom(url: URL): string | null {
  const raw = url.searchParams.get("code") ?? url.pathname.split("/").filter(Boolean).pop() ?? "";
  return /^[a-z0-9]{6,32}$/i.test(raw) ? raw : null;
}

export function renderInvite(p: Preview, code: string, cfg: InviteConfig): string {
  const t = PAGE[p.theme] ?? PAGE["simple-cobalt"];
  const home = escapeHtml(p.home_name);
  const who = p.invited_by ? escapeHtml(p.invited_by) : "Your roommate";
  const others = p.roommates === 1 ? "1 person lives there" : `${p.roommates} people live there`;
  const where = p.city ? ` · ${escapeHtml(p.city)}` : "";
  const link = `${cfg.publicBase}/j/${encodeURIComponent(code)}`;
  const banner = cfg.appStoreId
    ? `<meta name="apple-itunes-app" content="app-id=${cfg.appStoreId}${cfg.clipBundleId ? `, app-clip-bundle-id=${cfg.clipBundleId}, app-clip-display=card` : ""}, app-argument=${link}">`
    : "";
  const description = `${who} invited you to ${home}${where}. ${others}. When you're home, calls to ${home} ring your phone.`;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Join ${home} on Home Phone</title>
<meta property="og:type" content="website">
<meta property="og:title" content="Join ${home} on Home Phone">
<meta property="og:description" content="${description}">
<meta property="og:url" content="${link}">
${banner}
<style>
  :root { color-scheme: light; }
  body { margin: 0; min-height: 100vh; background: ${t.bg}; font-family: ${t.font}; color: ${t.ink};
         display: flex; align-items: center; justify-content: center; padding: 24px; box-sizing: border-box; }
  .card { width: 100%; max-width: 380px; background: ${t.card}; border: ${t.border}; border-radius: 24px; padding: 28px 24px; box-sizing: border-box; }
  .kicker { font-size: 15px; opacity: .75; margin: 0; }
  h1 { font-size: 40px; line-height: 1; margin: 8px 0 12px; letter-spacing: -.02em; }
  p { font-size: 17px; line-height: 1.45; margin: 0 0 22px; }
  a.cta { display: block; text-align: center; padding: 16px; border-radius: 16px; background: ${t.accent}; color: ${t.accentInk};
          border: ${t.border}; font-weight: 700; font-size: 18px; text-decoration: none; }
  .small { font-size: 13px; opacity: .7; margin: 14px 0 0; text-align: center; }
</style>
</head>
<body>
<main class="card">
  <p class="kicker">${who} invited you to</p>
  <h1>${home}</h1>
  <p>${others}${where}. When you're home, calls to ${home} ring your phone. When nobody picks up, callers leave a message.</p>
  <a class="cta" href="${link}">Join ${home}</a>
  <p class="small">Opens in Home Phone, or right here with the App Clip, no download needed.</p>
</main>
</body>
</html>`;
}

function fallback(title: string, body: string, status: number): Response {
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title><style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
font-family:system-ui;background:#FFF8F1;color:#14172B;padding:24px;box-sizing:border-box}main{max-width:360px}</style></head>
<body><main><h1>${escapeHtml(title)}</h1><p>${escapeHtml(body)}</p></main></body></html>`;
  return new Response(html, { status, headers: { "content-type": "text/html; charset=utf-8" } });
}

export function makeHandler({ db, config }: { db: Db; config: InviteConfig }) {
  return async (req: Request): Promise<Response> => {
    const code = codeFrom(new URL(req.url));
    if (!code) return fallback("That link looks broken", "Ask your roommate to send the invite again.", 404);
    try {
      // Anonymous: the preview is public by design (no account yet).
      const rows = await db.rpc<Preview[]>("invite_preview", { p_code: code }, "anon");
      const p = rows[0];
      if (!p) return fallback("This invite has expired", "Invites last 7 days. Ask your roommate for a new one.", 404);
      if (p.is_full) return fallback(`${p.home_name} is full`, "A home can have up to 8 people.", 409);
      return new Response(renderInvite(p, code, config), {
        headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=60" },
      });
    } catch (e) {
      console.error(e);
      return fallback("Something went wrong", "Try the link again in a minute.", 502);
    }
  };
}
