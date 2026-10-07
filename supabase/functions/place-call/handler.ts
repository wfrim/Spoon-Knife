// POST /place-call { apartment_id } | { user_id }, optional { as_home }
//
// 1. start_call() as the caller: the database decides whether this call may happen.
// 2. call_fanout() as service: VoIP tokens of the phones to ring.
// 3. One VoIP push per phone. Each phone shows CallKit immediately, then polls
//    the call row and stops ringing when it's answered elsewhere or rings out.
// 4. The caller gets a LiveKit token right away and waits in the room, so an
//    answer connects without another round trip.
// Nobody to ring (or every push failed) → ring_out(): voicemail for homes.
import { Apns } from "../_shared/apns.ts";
import { bearer, errorResponse, json } from "../_shared/http.ts";
import { type LiveKitConfig, roomToken } from "../_shared/livekit.ts";
import { Db } from "../_shared/postgrest.ts";

interface Call {
  id: string;
  apartment_id: string | null;
  target_user_id: string | null;
  caller_id: string;
  as_home: string | null;
  room_name: string;
  state: string;
  ring_until: string;
}

export interface Deps {
  db: Db;
  apns: Apns | null;
  livekit: LiveKitConfig | null;
}

export function makeHandler({ db, apns, livekit }: Deps) {
  return async (req: Request): Promise<Response> => {
    if (req.method === "OPTIONS") return json({});
    if (req.method !== "POST") return json({ error: "POST only" }, 405);
    const jwt = bearer(req);
    if (!jwt) return json({ error: "sign in first" }, 401);

    let body: { apartment_id?: string; user_id?: string; as_home?: string };
    try {
      body = await req.json();
    } catch {
      return json({ error: "expected a JSON body" }, 400);
    }

    try {
      const call = await db.rpc<Call>("start_call", {
        p_apartment_id: body.apartment_id ?? null,
        p_target_user_id: body.user_id ?? null,
        p_as_home: body.as_home ?? null,
      }, jwt);

      const targets = await db.rpc<{ user_id: string; device_id: string; voip_token: string }[]>(
        "call_fanout", { p_call_id: call.id }, null);

      let rang = 0;
      let pushNote: string | undefined;
      if (targets.length && apns) {
        const payload = await describe(db, call);
        const results = await apns.sendVoip(targets.map((t) => t.voip_token), payload);
        rang = results.filter((r) => r.ok).length;
        const dead = results.filter((r) => r.unregistered).map((r) => r.token);
        if (dead.length) {
          await db.patch("devices", `voip_token=in.(${dead.map((t) => `"${t}"`).join(",")})`, { voip_token: null })
            .catch((e) => console.error("token cleanup failed", e));
        }
      } else if (targets.length) {
        pushNote = "APNs is not configured";
      }

      let state = call;
      if (rang === 0) {
        // Nobody home (or no phone reachable): settle now instead of ringing for 30 s.
        state = await db.rpc<Call>("ring_out", { p_call_id: call.id, p_nobody_home: true }, jwt);
      }

      const room = livekit && (state.state === "ringing" || state.state === "active")
        ? { url: livekit.url, token: await roomToken(livekit, { room: call.room_name, identity: call.caller_id }) }
        : null;

      return json({ call: state, rang, room, note: pushNote });
    } catch (e) {
      return errorResponse(e);
    }
  };
}

/** What the ringing phone shows: "Kim calling The Burrow", or "Hilltop calling". */
async function describe(db: Db, call: Call): Promise<Record<string, unknown>> {
  const one = async <T>(path: string) => ((await db.select<T[]>(path, null))[0] ?? null);
  const [caller, home, asHome] = await Promise.all([
    one<{ display_name: string }>(`users?id=eq.${call.caller_id}&select=display_name`),
    call.apartment_id ? one<{ name: string }>(`apartments?id=eq.${call.apartment_id}&select=name`) : null,
    call.as_home ? one<{ name: string }>(`apartments?id=eq.${call.as_home}&select=name`) : null,
  ]);
  return {
    call_id: call.id,
    kind: call.apartment_id ? "home" : "direct",
    caller_name: asHome?.name ?? caller?.display_name ?? "Someone",
    caller_person: caller?.display_name ?? null,
    home_name: home?.name ?? null,
    ring_until: call.ring_until,
  };
}
