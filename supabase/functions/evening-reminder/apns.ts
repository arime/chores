// Everything about talking to Apple that does not need a network: kept apart
// from index.ts so it can be tested with `deno test` and nothing else.

export type Environment = "development" | "production";

/** One row of evening_reminder_work(), exactly as Postgres serialises it. */
export interface WorkRow {
  profile_id: string;
  local_date: string; // YYYY-MM-DD
  undone_count: number;
  token: string;
  environment: Environment;
}

export const TOPIC = "com.metsahalme.Chores";

export function gateway(environment: Environment): string {
  return environment === "development"
    ? "https://api.sandbox.push.apple.com"
    : "https://api.push.apple.com";
}

/**
 * loc-args are strings, so the device cannot choose a plural form from them.
 * The server chooses the key; the device renders it in its own language.
 */
export function bodyKey(undone: number): string {
  return undone === 1 ? "EVENING_PUSH_BODY_ONE" : "EVENING_PUSH_BODY_MANY";
}

/** Three keys and a number. No names cross this boundary. */
export function payload(undone: number): Record<string, unknown> {
  return {
    aps: {
      alert: {
        "title-loc-key": "EVENING_PUSH_TITLE",
        "loc-key": bodyKey(undone),
        "loc-args": [String(undone)],
      },
      sound: "default",
    },
  };
}

export type Outcome = "delivered" | "dead" | "failed";

/**
 * 410 is Apple saying the token no longer exists. 400 BadDeviceToken is the
 * same fact for a token registered against the wrong gateway — a debug build's
 * token sent to production, say. Both mean: stop sending to it. Everything
 * else is our problem or Apple's, and the token stays.
 */
export function classify(status: number, reason: string | undefined): Outcome {
  if (status === 200) return "delivered";
  if (status === 410) return "dead";
  if (status === 400 && reason === "BadDeviceToken") return "dead";
  return "failed";
}

export function jwtHeader(keyID: string) {
  return { alg: "ES256", kid: keyID };
}

export function jwtClaims(teamID: string, issuedAt: number) {
  return { iss: teamID, iat: issuedAt };
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** The .p8 Apple hands out is PKCS#8 PEM; Web Crypto wants the DER inside. */
export async function importKey(pem: string): Promise<CryptoKey> {
  const body = pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

/** ES256 over header.claims. Web Crypto's ECDSA output is already r‖s, which is what JWS wants. */
export async function signJWT(
  key: CryptoKey,
  keyID: string,
  teamID: string,
  issuedAt: number,
): Promise<string> {
  const encoder = new TextEncoder();
  const header = base64url(encoder.encode(JSON.stringify(jwtHeader(keyID))));
  const claims = base64url(encoder.encode(JSON.stringify(jwtClaims(teamID, issuedAt))));
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    encoder.encode(`${header}.${claims}`),
  );
  return `${header}.${claims}.${base64url(new Uint8Array(signature))}`;
}
