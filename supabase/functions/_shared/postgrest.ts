// Tiny PostgREST client. Calls made "as the user" forward their JWT so the
// database's own checks (auth.uid(), RLS) apply; "as service" is for fan-out.

export class DbError extends Error {
  constructor(public status: number, public code: string | undefined, message: string, public hint?: string) {
    super(message);
  }
}

export class Db {
  constructor(
    private url: string,
    private anonKey: string,
    private serviceKey: string,
    private fetcher: typeof fetch = fetch,
  ) {}

  private async request<T>(path: string, init: RequestInit, jwt: string | null): Promise<T> {
    const res = await this.fetcher(`${this.url}/rest/v1/${path}`, {
      ...init,
      headers: {
        apikey: jwt ? this.anonKey : this.serviceKey,
        authorization: `Bearer ${jwt ?? this.serviceKey}`,
        "content-type": "application/json",
        ...(init.headers ?? {}),
      },
    });
    const text = await res.text();
    const body = text ? JSON.parse(text) : null;
    if (!res.ok) throw new DbError(res.status, body?.code, body?.message ?? text, body?.hint);
    return body as T;
  }

  rpc<T>(name: string, params: Record<string, unknown>, jwt: string | null): Promise<T> {
    return this.request<T>(`rpc/${name}`, { method: "POST", body: JSON.stringify(params) }, jwt);
  }

  /** PATCH with a PostgREST filter, as the service role. */
  patch(table: string, filter: string, values: Record<string, unknown>): Promise<unknown> {
    return this.request(`${table}?${filter}`, {
      method: "PATCH",
      body: JSON.stringify(values),
      headers: { prefer: "return=minimal" },
    }, null);
  }

  /** GET rows: as the user (RLS applies) or, with jwt = null, as the service role. */
  select<T>(path: string, jwt: string | null): Promise<T> {
    return this.request<T>(path, { method: "GET" }, jwt);
  }
}
