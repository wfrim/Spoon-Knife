// Minimal JWT signing with WebCrypto: ES256 for APNs, HS256 for LiveKit.
// No dependencies, so it runs the same in Supabase Edge Functions and `deno test`.

const enc = new TextEncoder();

export function base64url(input: Uint8Array | string): string {
  const bytes = typeof input === "string" ? enc.encode(input) : input;
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function signingInput(header: object, claims: object): string {
  return `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(claims))}`;
}

/** Imports an Apple .p8 key (PKCS#8 PEM) for ES256 signing. */
export async function importP8(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
}

export async function signES256(key: CryptoKey, header: object, claims: object): Promise<string> {
  const input = signingInput({ alg: "ES256", ...header }, claims);
  // WebCrypto returns the raw r||s signature JOSE expects.
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(input));
  return `${input}.${base64url(new Uint8Array(sig))}`;
}

export async function signHS256(secret: string, claims: object): Promise<string> {
  const key = await crypto.subtle.importKey("raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const input = signingInput({ alg: "HS256", typ: "JWT" }, claims);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(input));
  return `${input}.${base64url(new Uint8Array(sig))}`;
}
