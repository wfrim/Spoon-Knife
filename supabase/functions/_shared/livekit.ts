// LiveKit access tokens (HS256 JWT with a "video" grant), no SDK needed.
import { signHS256 } from "./jwt.ts";

export interface LiveKitConfig {
  url: string; // wss://<project>.livekit.cloud
  apiKey: string;
  apiSecret: string;
}

export function liveKitConfigFromEnv(env: (k: string) => string | undefined): LiveKitConfig | null {
  const url = env("LIVEKIT_URL"), apiKey = env("LIVEKIT_API_KEY"), apiSecret = env("LIVEKIT_API_SECRET");
  return url && apiKey && apiSecret ? { url, apiKey, apiSecret } : null;
}

/** A short-lived token to join one room as one person, audio only. */
export async function roomToken(
  config: LiveKitConfig,
  opts: { room: string; identity: string; name?: string; ttlSeconds?: number; now?: number },
): Promise<string> {
  const now = Math.floor((opts.now ?? Date.now()) / 1000);
  return await signHS256(config.apiSecret, {
    iss: config.apiKey,
    sub: opts.identity,
    name: opts.name,
    nbf: now,
    exp: now + (opts.ttlSeconds ?? 2 * 60 * 60),
    video: {
      room: opts.room,
      roomJoin: true,
      canPublish: true,
      canSubscribe: true,
      canPublishData: true,
      canPublishSources: ["microphone"],
    },
  });
}
