import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { Db } from "../_shared/postgrest.ts";
import { codeFrom, escapeHtml, makeHandler } from "../invite-page/handler.ts";
import { fakeFetch, ok } from "./helpers.ts";

const preview = {
  home_name: "The <Burrow>", handle: "theburrow", city: "Oakland", theme: "sticker-bubblegum",
  invited_by: "Maya", roommates: 3, is_full: false,
};

function handler(rows: unknown[]) {
  const db = fakeFetch({ "db.test/rest/v1/rpc/invite_preview": () => ok(rows) });
  const h = makeHandler({
    db: new Db("https://db.test", "anon-key", "service-key", db.fn),
    config: { publicBase: "https://apartmentline.app", appStoreId: "123", clipBundleId: "app.al.Clip" },
  });
  return { h, db };
}

Deno.test("renders a themed, unfurlable invite with the App Clip banner", async () => {
  const { h, db } = handler([preview]);
  const res = await h(new Request("https://fn/invite-page/j/burrow7k2q"));
  assertEquals(res.status, 200);
  const html = await res.text();
  assertStringIncludes(html, '<meta property="og:title" content="Join The &lt;Burrow&gt; on Apartment Line">');
  assertStringIncludes(html, "Maya invited you to The &lt;Burrow&gt; · Oakland. 3 people live there.");
  assertStringIncludes(html, 'app-clip-bundle-id=app.al.Clip, app-clip-display=card');
  assertStringIncludes(html, "background: #FFEFE3", "sticker-bubblegum page color");
  assertStringIncludes(html, 'href="https://apartmentline.app/j/burrow7k2q"');
  assert(!html.includes("<Burrow>"), "home names are escaped");

  // Looked up without an account.
  const call = db.calls[0];
  assertEquals(call.req.headers.get("authorization"), "Bearer anon-key");
  assertEquals(JSON.parse(call.body), { p_code: "burrow7k2q" });
});

Deno.test("expired, full and malformed links get a friendly page", async () => {
  const expired = await handler([]).h(new Request("https://fn/?code=abc123"));
  assertEquals(expired.status, 404);
  assertStringIncludes(await expired.text(), "This invite has expired");
  const full = await handler([{ ...preview, is_full: true }]).h(new Request("https://fn/?code=abc123"));
  assertEquals(full.status, 409);
  const bad = await handler([preview]).h(new Request("https://fn/?code=../../etc"));
  assertEquals(bad.status, 404);
});

Deno.test("helpers", () => {
  assertEquals(escapeHtml(`<a href="x">'&'</a>`), "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;");
  assertEquals(codeFrom(new URL("https://x/j/ABCdef12")), "ABCdef12");
  assertEquals(codeFrom(new URL("https://x/?code=a b")), null);
});
