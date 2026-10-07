import { assertEquals } from "jsr:@std/assert@1";
import { Db } from "../_shared/postgrest.ts";
import { makeHandler, subject } from "../call-token/handler.ts";
import { decodePart, fakeFetch, ok, userJwt } from "./helpers.ts";

function handlerWith(room: string | null) {
  const db = fakeFetch({ "db.test/rest/v1/rpc/call_room": () => ok(room) });
  return makeHandler({
    db: new Db("https://db.test", "anon", "service", db.fn),
    livekit: { url: "wss://lk.test", apiKey: "key", apiSecret: "secret" },
  });
}

const post = (body: unknown, jwt = userJwt("mo")) =>
  new Request("http://fn/call-token", { method: "POST", headers: { authorization: `Bearer ${jwt}` }, body: JSON.stringify(body) });

Deno.test("participants get a token for the call's room", async () => {
  const res = await handlerWith("room-9")(post({ call_id: "c" }));
  assertEquals(res.status, 200);
  const { token, room, url } = await res.json();
  assertEquals([room, url], ["room-9", "wss://lk.test"]);
  const claims = decodePart(token, 1);
  assertEquals([claims.sub, claims.iss, claims.video.room, claims.video.roomJoin], ["mo", "key", "room-9", true]);
  assertEquals(claims.video.canPublishSources, ["microphone"]);
});

Deno.test("everyone else is refused", async () => {
  assertEquals((await handlerWith(null)(post({ call_id: "c" }))).status, 403);
});

Deno.test("subject reads the JWT sub", () => {
  assertEquals(subject(userJwt("abc")), "abc");
  assertEquals(subject("garbage"), null);
});
