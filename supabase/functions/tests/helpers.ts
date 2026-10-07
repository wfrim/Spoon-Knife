// Test doubles: a fetch that routes by URL, and a throwaway ES256 key in .p8 form.
export type Route = (req: Request, url: URL) => Response | Promise<Response>;

export function fakeFetch(routes: Record<string, Route>) {
  const calls: { url: URL; req: Request; body: string }[] = [];
  const fn = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const req = new Request(input, init);
    const url = new URL(req.url);
    const body = await req.clone().text();
    calls.push({ url, req, body });
    for (const [prefix, route] of Object.entries(routes)) {
      if (`${url.host}${url.pathname}`.startsWith(prefix)) return await route(req, url);
    }
    return new Response(JSON.stringify({ message: `no route for ${url}` }), { status: 599 });
  }) as typeof fetch;
  return { fn, calls };
}

export const ok = (body: unknown) => new Response(JSON.stringify(body), { status: 200 });

export async function testP8(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  const b64 = btoa(String.fromCharCode(...der)).replace(/(.{64})/g, "$1\n");
  return { pem: `-----BEGIN PRIVATE KEY-----\n${b64}\n-----END PRIVATE KEY-----\n`, publicKey: pair.publicKey };
}

export function decodePart(jwt: string, i: number) {
  const p = jwt.split(".")[i].replace(/-/g, "+").replace(/_/g, "/");
  return JSON.parse(atob(p + "=".repeat((4 - (p.length % 4)) % 4)));
}

export function fromB64url(s: string): Uint8Array<ArrayBuffer> {
  const p = s.replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(p + "=".repeat((4 - (p.length % 4)) % 4)), (c) => c.charCodeAt(0));
}

/** A JWT-shaped string with the given sub (unsigned; handlers only read it). */
export function userJwt(sub: string) {
  const b = (o: unknown) => btoa(JSON.stringify(o)).replace(/=+$/, "");
  return `${b({ alg: "HS256" })}.${b({ sub, role: "authenticated" })}.sig`;
}
