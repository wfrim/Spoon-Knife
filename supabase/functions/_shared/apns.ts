// VoIP pushes over APNs (token auth). One provider JWT is reused for 50 minutes;
// Apple rejects tokens older than an hour and throttles ones refreshed too often.
import { importP8, signES256 } from "./jwt.ts";

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  privateKey: string; // contents of AuthKey_XXXX.p8
  bundleId: string; // app bundle id; VoIP topic is "<bundleId>.voip"
  production: boolean;
}

export interface PushResult {
  token: string;
  ok: boolean;
  status: number;
  reason?: string;
  /** The token is dead (app deleted / token rotated); stop sending to it. */
  unregistered: boolean;
}

export function apnsConfigFromEnv(env: (k: string) => string | undefined): ApnsConfig | null {
  const keyId = env("APNS_KEY_ID"), teamId = env("APNS_TEAM_ID"), privateKey = env("APNS_PRIVATE_KEY");
  const bundleId = env("APNS_BUNDLE_ID");
  if (!keyId || !teamId || !privateKey || !bundleId) return null;
  return { keyId, teamId, privateKey, bundleId, production: env("APNS_ENV") === "production" };
}

export class Apns {
  private jwt?: { value: string; at: number };
  private key?: CryptoKey;

  constructor(private config: ApnsConfig, private fetcher: typeof fetch = fetch, private now = () => Date.now()) {}

  async providerToken(): Promise<string> {
    if (this.jwt && this.now() - this.jwt.at < 50 * 60 * 1000) return this.jwt.value;
    this.key ??= await importP8(this.config.privateKey);
    const iat = Math.floor(this.now() / 1000);
    const value = await signES256(this.key, { kid: this.config.keyId }, { iss: this.config.teamId, iat });
    this.jwt = { value, at: this.now() };
    return value;
  }

  /** Sends one VoIP push per token, in parallel. Never throws for a single bad token. */
  async sendVoip(tokens: string[], payload: Record<string, unknown>): Promise<PushResult[]> {
    const host = this.config.production ? "api.push.apple.com" : "api.sandbox.push.apple.com";
    const auth = `bearer ${await this.providerToken()}`;
    const body = JSON.stringify(payload);
    return await Promise.all(tokens.map(async (token): Promise<PushResult> => {
      try {
        const res = await this.fetcher(`https://${host}/3/device/${token}`, {
          method: "POST",
          headers: {
            authorization: auth,
            "apns-topic": `${this.config.bundleId}.voip`,
            "apns-push-type": "voip",
            "apns-priority": "10",
            // A ring that can't be delivered now is useless later.
            "apns-expiration": "0",
          },
          body,
        });
        const reason = res.ok ? undefined : (await res.json().catch(() => ({}))).reason;
        return {
          token, ok: res.ok, status: res.status, reason,
          unregistered: res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered",
        };
      } catch (e) {
        return { token, ok: false, status: 0, reason: String(e), unregistered: false };
      }
    }));
  }
}
