// The evening reminder's sender. Called by the pg_cron job with the rows
// evening_reminder_work() claimed; signs an APNs token, posts one alert per
// device, and reports back through two service-role RPCs. Nothing here decides
// who is due — that is SQL's job and pgTAP's to test.

import { createClient } from "npm:@supabase/supabase-js@2";
import {
  classify,
  gateway,
  importKey,
  type Outcome,
  payload,
  signJWT,
  TOPIC,
  type WorkRow,
} from "./apns.ts";

const SECRET = Deno.env.get("EVENING_REMINDER_SECRET") ?? "";
const KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY") ?? "";

// Apple honours a provider token for an hour and rate-limits minting them, so
// one is kept for as long as this instance stays warm.
let cached: { jwt: string; issuedAt: number } | null = null;

async function providerToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && now - cached.issuedAt < 50 * 60) return cached.jwt;
  const key = await importKey(PRIVATE_KEY);
  cached = { jwt: await signJWT(key, KEY_ID, TEAM_ID, now), issuedAt: now };
  return cached.jwt;
}

function constantTimeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  if (x.length !== y.length) return false;
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

async function send(row: WorkRow, jwt: string): Promise<{ outcome: Outcome; status: number }> {
  const response = await fetch(`${gateway(row.environment)}/3/device/${row.token}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
      // A phone that is off overnight should not get yesterday's reminder at breakfast.
      "apns-expiration": String(Math.floor(Date.now() / 1000) + 3 * 3600),
    },
    body: JSON.stringify(payload(row.undone_count)),
  });
  let reason: string | undefined;
  if (response.status === 200) {
    await response.body?.cancel();
  } else {
    try {
      reason = (await response.json() as { reason?: string }).reason;
    } catch {
      // No body, or not JSON. The status alone decides.
    }
  }
  return { outcome: classify(response.status, reason), status: response.status };
}

Deno.serve(async (request) => {
  const auth = request.headers.get("authorization") ?? "";
  if (SECRET === "" || !constantTimeEqual(auth, `Bearer ${SECRET}`)) {
    return new Response("unauthorized", { status: 401 });
  }

  const { work } = await request.json() as { work: WorkRow[] | null };
  if (!work || work.length === 0) {
    return Response.json({ sent: 0, dead: 0 });
  }

  const jwt = await providerToken();
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  // Grouped by claim, because record() is per (parent, date) and a parent
  // may have more than one phone.
  const claims = new Map<string, { row: WorkRow; delivered: number; failures: number[] }>();
  const dead: string[] = [];

  for (const row of work) {
    const key = `${row.profile_id}|${row.local_date}`;
    const claim = claims.get(key) ?? { row, delivered: 0, failures: [] };
    const { outcome, status } = await send(row, jwt);
    if (outcome === "delivered") claim.delivered += 1;
    else if (outcome === "dead") dead.push(row.token);
    else claim.failures.push(status);
    claims.set(key, claim);
  }

  if (dead.length > 0) {
    await supabase.rpc("device_tokens_forget", { p_tokens: dead });
  }

  for (const { row, delivered, failures } of claims.values()) {
    const failure = delivered > 0
      ? null
      : failures.length > 0
      ? `apns ${failures.join(",")}`
      : "no live device";
    await supabase.rpc("evening_reminder_record", {
      p_profile_id: row.profile_id,
      p_local_date: row.local_date,
      p_sent_at: delivered > 0 ? new Date().toISOString() : null,
      p_failure: failure,
    });
  }

  return Response.json({ sent: work.length, dead: dead.length });
});
