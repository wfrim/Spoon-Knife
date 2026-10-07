// Cloudflare Pages Function: https://<your domain>/j/<code> → the themed invite page.
// Supabase won't serve HTML from its own domain (it rewrites it to plain text),
// so the page renders here, on your web host, from the same handler the tests cover.
import { Db } from "../../../supabase/functions/_shared/postgrest.ts";
import { makeHandler } from "../../../supabase/functions/invite-page/handler.ts";

interface Env {
  SUPABASE_URL: string;
  SUPABASE_ANON_KEY: string;
  APP_STORE_ID?: string;
  APP_CLIP_BUNDLE_ID?: string;
}

export const onRequestGet = async ({ request, env }: { request: Request; env: Env }) => {
  const handler = makeHandler({
    // Only the public invite preview is read, so the anon key is all this needs.
    db: new Db(env.SUPABASE_URL, env.SUPABASE_ANON_KEY, env.SUPABASE_ANON_KEY),
    config: {
      publicBase: new URL(request.url).origin,
      appStoreId: env.APP_STORE_ID,
      clipBundleId: env.APP_CLIP_BUNDLE_ID,
    },
  });
  return await handler(request);
};
