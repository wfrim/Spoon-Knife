import { DbError } from "./postgrest.ts";

export const cors = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
};

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...cors } });
}

export function bearer(req: Request): string | null {
  const h = req.headers.get("authorization") ?? "";
  return h.toLowerCase().startsWith("bearer ") ? h.slice(7) : null;
}

/** Maps database errors to HTTP: permission → 403, missing → 404, bad input → 400. */
export function errorResponse(e: unknown): Response {
  if (e instanceof DbError) {
    const status = e.code === "42501" ? 403 : e.code === "P0002" ? 404 : e.code?.startsWith("22") ? 400 : 502;
    return json({ error: e.message, code: e.code, hint: e.hint }, status);
  }
  console.error(e);
  return json({ error: "internal error" }, 500);
}
