import { assert, assertEquals } from "jsr:@std/assert@1";
import { Apns } from "../_shared/apns.ts";
import { Db } from "../_shared/postgrest.ts";
import { makeHandler } from "../place-call/handler.ts";
import { decodePart, fakeFetch, ok, testP8, userJwt } from "./helpers.ts";

const SB = "db.test";
const call = {
  id: "call-1", apartment_id: "apt-1", target_user_id: null, caller_id: "kim", as_home: null,
  room_name: "room-1", state: "ringing", ring_until: "2026-10-09T12:00:30Z",
};
const livekit = { url: "wss://lk.test", apiKey: "key", apiSecret: "secret" };

async function setup(opts: { targets: string[]; startError?: Response; webTestPhones?: boolean }) {
  const { pem } = await testP8();
  const db = fakeFetch({
    [`${SB}/rest/v1/rpc/start_call`]: () => opts.startError ?? ok(call),
    [`${SB}/rest/v1/rpc/call_fanout`]: () => ok(opts.targets.map((t, i) => ({ user_id: `u${i}`, device_id: `d${i}`, voip_token: t }))),
    [`${SB}/rest/v1/rpc/ring_out`]: () => ok({ ...call, state: "voicemail" }),
    [`${SB}/rest/v1/users`]: () => ok([{ display_name: "Kim" }]),
    [`${SB}/rest/v1/apartments`]: () => ok([{ name: "The Burrow" }]),
    [`${SB}/rest/v1/devices`]: () => new Response(null, { status: 204 }),
  });
  const push = fakeFetch({
    "api.sandbox.push.apple.com/3/device/live": () => new Response(null, { status: 200 }),
    "api.sandbox.push.apple.com/3/device/dead": () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 }),
  });
  const handler = makeHandler({
    db: new Db(`https://${SB}`, "anon", "service", db.fn),
    apns: new Apns({ keyId: "K", teamId: "T", privateKey: pem, bundleId: "app.test", production: false }, push.fn),
    livekit,
    webTestPhones: opts.webTestPhones,
  });
  const send = (body: unknown, jwt: string | null = userJwt("kim")) =>
    handler(new Request("http://fn/place-call", {
      method: "POST",
      headers: jwt ? { authorization: `Bearer ${jwt}` } : {},
      body: JSON.stringify(body),
    }));
  return { db, push, send };
}

Deno.test("rings the phones that are home and hands the caller a room token", async () => {
  const { db, push, send } = await setup({ targets: ["live", "dead"] });
  const res = await send({ apartment_id: "apt-1" });
  assertEquals(res.status, 200);
  const out = await res.json();
  assertEquals(out.rang, 1);
  assertEquals(out.call.state, "ringing");
  assertEquals(decodePart(out.room.token, 1).video.room, "room-1");
  assertEquals(decodePart(out.room.token, 1).sub, "kim");

  // start_call runs as the caller (their JWT); fan-out as the service role.
  const start = db.calls.find((c) => c.url.pathname.endsWith("start_call"))!;
  assert(start.req.headers.get("authorization")!.includes(userJwt("kim")));
  assertEquals(JSON.parse(start.body), { p_apartment_id: "apt-1", p_target_user_id: null, p_as_home: null });
  const fan = db.calls.find((c) => c.url.pathname.endsWith("call_fanout"))!;
  assertEquals(fan.req.headers.get("authorization"), "Bearer service");

  // What the ringing phone shows.
  assertEquals(JSON.parse(push.calls[0].body), {
    call_id: "call-1", kind: "home", caller_name: "Kim", caller_person: "Kim", home_name: "The Burrow",
    ring_until: "2026-10-09T12:00:30Z",
  });
  // The dead token is cleared.
  const cleanup = db.calls.find((c) => c.url.pathname.endsWith("/devices"))!;
  assertEquals(cleanup.req.method, "PATCH");
  assertEquals(decodeURIComponent(cleanup.url.search), '?voip_token=in.("dead")');
  assert(!db.calls.some((c) => c.url.pathname.endsWith("ring_out")), "a rung call keeps ringing");
});

Deno.test("nobody home: straight to voicemail, no room", async () => {
  const { db, push, send } = await setup({ targets: [] });
  const out = await (await send({ apartment_id: "apt-1" })).json();
  assertEquals([out.rang, out.call.state, out.room], [0, "voicemail", null]);
  assertEquals(push.calls.length, 0);
  const ringOut = db.calls.find((c) => c.url.pathname.endsWith("ring_out"))!;
  assertEquals(JSON.parse(ringOut.body), { p_call_id: "call-1", p_nobody_home: true });
});

Deno.test("database refusals become 403 with the hint for the app", async () => {
  const { send } = await setup({
    targets: [],
    startError: new Response(JSON.stringify({
      code: "42501", message: "this home only takes calls from neighbors", hint: "ask_to_be_neighbors",
    }), { status: 403 }),
  });
  const res = await send({ apartment_id: "apt-1" });
  assertEquals(res.status, 403);
  assertEquals((await res.json()).hint, "ask_to_be_neighbors");
});

Deno.test("requires a signed-in caller and a JSON body", async () => {
  const { send } = await setup({ targets: [] });
  assertEquals((await send({ apartment_id: "apt-1" }, null)).status, 401);
});

Deno.test("browser test phones count as rung without a push, only when enabled", async () => {
  const on = await setup({ targets: ["web:abc", "live"], webTestPhones: true });
  const out = await (await on.send({ apartment_id: "apt-1" })).json();
  assertEquals([out.rang, out.call.state], [2, "ringing"]);
  assertEquals(on.push.calls.map((c) => c.url.pathname), ["/3/device/live"], "no APNs push to a web token");

  const off = await setup({ targets: ["web:abc"] });
  const out2 = await (await off.send({ apartment_id: "apt-1" })).json();
  assertEquals([out2.rang, out2.call.state], [0, "voicemail"], "disabled: a web token is nobody");
});
