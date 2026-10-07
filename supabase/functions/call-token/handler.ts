// POST /call-token { call_id } → a LiveKit token for the call's room, if the
// database says this person may be in it (caller, answerer, or a roommate who
// joined a call placed as the home).
import { bearer, errorResponse, json } from "../_shared/http.ts";
import { type LiveKitConfig, roomToken } from "../_shared/livekit.ts";
import { Db } from "../_shared/postgrest.ts";

/** The JWT's "sub". PostgREST has already verified the token by the time we use it. */
export function subject(jwt: string): string | null {
  try {
    const part = jwt.split(".")[1].replace(/-/g, "+").replace(/_/g, "/");
    return JSON.parse(atob(part + "=".repeat((4 - (part.length % 4)) % 4))).sub ?? null;
  } catch {
    return null;
  }
}

export function makeHandler({ db, livekit }: { db: Db; livekit: LiveKitConfig | null }) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return json({});
    const jwt = bearer(req);
    if (!jwt) return json({ error: "sign in first" }, 401);
    if (!livekit) return json({ error: "LiveKit is not configured" }, 503);
    try {
      const { call_id } = await req.json();
      const room = await db.rpc<string | null>("call_room", { p_call_id: call_id }, jwt);
      if (!room) return json({ error: "not on this call" }, 403);
      const identity = subject(jwt);
      if (!identity) return json({ error: "bad token" }, 401);
      return json({ url: livekit.url, room, token: await roomToken(livekit, { room, identity }) });
    } catch (e) {
      return errorResponse(e);
    }
  };
}
