import { Db } from "../_shared/postgrest.ts";
import { makeHandler } from "./handler.ts";

const env = (k: string) => Deno.env.get(k);

Deno.serve(makeHandler({
  db: new Db(env("SUPABASE_URL")!, env("SUPABASE_ANON_KEY")!, env("SUPABASE_SERVICE_ROLE_KEY")!),
  config: {
    publicBase: env("INVITE_PUBLIC_BASE") ?? "https://apartmentline.app",
    appStoreId: env("APP_STORE_ID"),
    clipBundleId: env("APP_CLIP_BUNDLE_ID"),
  },
}));
