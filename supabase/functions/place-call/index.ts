import { Apns, apnsConfigFromEnv } from "../_shared/apns.ts";
import { liveKitConfigFromEnv } from "../_shared/livekit.ts";
import { Db } from "../_shared/postgrest.ts";
import { makeHandler } from "./handler.ts";

const env = (k: string) => Deno.env.get(k);
const apnsConfig = apnsConfigFromEnv(env);

Deno.serve(makeHandler({
  db: new Db(env("SUPABASE_URL")!, env("SUPABASE_ANON_KEY")!, env("SUPABASE_SERVICE_ROLE_KEY")!),
  apns: apnsConfig ? new Apns(apnsConfig) : null,
  livekit: liveKitConfigFromEnv(env),
}));
