import { assert, assertEquals } from "jsr:@std/assert@1";
import { Apns } from "../_shared/apns.ts";
import { decodePart, fakeFetch, testP8 } from "./helpers.ts";

Deno.test("sends VoIP pushes with the right headers and flags dead tokens", async () => {
  const { pem } = await testP8();
  const { fn, calls } = fakeFetch({
    "api.sandbox.push.apple.com/3/device/good": () => new Response(null, { status: 200 }),
    "api.sandbox.push.apple.com/3/device/gone": () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 }),
    "api.sandbox.push.apple.com/3/device/bad": () => new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 }),
  });
  let now = 1_000_000;
  const apns = new Apns({ keyId: "KID", teamId: "TEAM", privateKey: pem, bundleId: "app.test", production: false }, fn, () => now);

  const results = await apns.sendVoip(["good", "gone", "bad"], { call_id: "c1" });
  assertEquals(results.map((r) => [r.token, r.ok, r.unregistered]), [["good", true, false], ["gone", false, true], ["bad", false, true]]);

  const h = calls[0].req.headers;
  assertEquals(h.get("apns-topic"), "app.test.voip");
  assertEquals(h.get("apns-push-type"), "voip");
  assertEquals(h.get("apns-priority"), "10");
  assertEquals(h.get("apns-expiration"), "0");
  assertEquals(JSON.parse(calls[0].body), { call_id: "c1" });
  const jwt = h.get("authorization")!.slice("bearer ".length);
  assertEquals(decodePart(jwt, 0).kid, "KID");
  assertEquals(decodePart(jwt, 1).iss, "TEAM");

  // The provider token is reused for 50 minutes, then refreshed.
  const first = await apns.providerToken();
  now += 49 * 60 * 1000;
  assertEquals(await apns.providerToken(), first);
  now += 2 * 60 * 1000;
  assert((await apns.providerToken()) !== first);
});

Deno.test("production uses the production host; network errors don't throw", async () => {
  const { pem } = await testP8();
  const { fn, calls } = fakeFetch({ "api.push.apple.com": () => { throw new Error("offline"); } });
  const apns = new Apns({ keyId: "K", teamId: "T", privateKey: pem, bundleId: "b", production: true }, fn);
  const [r] = await apns.sendVoip(["t"], {});
  assertEquals(calls[0].url.host, "api.push.apple.com");
  assertEquals([r.ok, r.unregistered, r.status], [false, false, 0]);
});
