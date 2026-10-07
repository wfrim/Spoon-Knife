import { assert, assertEquals } from "jsr:@std/assert@1";
import { importP8, signES256, signHS256 } from "../_shared/jwt.ts";
import { decodePart, fromB64url, testP8 } from "./helpers.ts";

const enc = new TextEncoder();

Deno.test("ES256 tokens verify against the key's public half", async () => {
  const { pem, publicKey } = await testP8();
  const jwt = await signES256(await importP8(pem), { kid: "ABC123" }, { iss: "TEAM", iat: 1 });
  const [h, c, s] = jwt.split(".");
  assertEquals(decodePart(jwt, 0), { alg: "ES256", kid: "ABC123" });
  assertEquals(decodePart(jwt, 1), { iss: "TEAM", iat: 1 });
  assertEquals(fromB64url(s).length, 64, "raw r||s signature");
  assert(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, fromB64url(s), enc.encode(`${h}.${c}`)));
});

Deno.test("HS256 tokens verify with the shared secret", async () => {
  const jwt = await signHS256("secret", { sub: "u1" });
  const [h, c, s] = jwt.split(".");
  const key = await crypto.subtle.importKey("raw", enc.encode("secret"), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  assert(await crypto.subtle.verify("HMAC", key, fromB64url(s), enc.encode(`${h}.${c}`)));
  assertEquals(decodePart(jwt, 0).typ, "JWT");
});
