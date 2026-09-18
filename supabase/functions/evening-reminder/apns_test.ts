import { assertEquals } from "jsr:@std/assert@1";
import {
  bodyKey,
  classify,
  gateway,
  jwtClaims,
  jwtHeader,
  payload,
  TOPIC,
} from "./apns.ts";

Deno.test("one chore uses the singular key, more the plural", () => {
  assertEquals(bodyKey(1), "EVENING_PUSH_BODY_ONE");
  assertEquals(bodyKey(2), "EVENING_PUSH_BODY_MANY");
  assertEquals(bodyKey(7), "EVENING_PUSH_BODY_MANY");
});

Deno.test("the payload carries keys and a count, never a name", () => {
  const p = payload(3) as { aps: { alert: Record<string, unknown>; sound: string } };
  assertEquals(p.aps.alert["title-loc-key"], "EVENING_PUSH_TITLE");
  assertEquals(p.aps.alert["loc-key"], "EVENING_PUSH_BODY_MANY");
  assertEquals(p.aps.alert["loc-args"], ["3"]);
  assertEquals(p.aps.sound, "default");
  assertEquals(Object.keys(p.aps.alert).length, 3);
});

Deno.test("410, and 400 BadDeviceToken, mean the token is dead", () => {
  assertEquals(classify(200, undefined), "delivered");
  assertEquals(classify(410, "Unregistered"), "dead");
  assertEquals(classify(400, "BadDeviceToken"), "dead");
});

Deno.test("anything else is a failure to report, not a token to drop", () => {
  assertEquals(classify(400, "BadTopic"), "failed");
  assertEquals(classify(403, "InvalidProviderToken"), "failed");
  assertEquals(classify(429, "TooManyRequests"), "failed");
  assertEquals(classify(503, undefined), "failed");
});

Deno.test("development tokens go to the sandbox gateway", () => {
  assertEquals(gateway("development"), "https://api.sandbox.push.apple.com");
  assertEquals(gateway("production"), "https://api.push.apple.com");
});

Deno.test("the JWT names the key and the team", () => {
  assertEquals(jwtHeader("KEY123"), { alg: "ES256", kid: "KEY123" });
  assertEquals(jwtClaims("HPD6U8BLB5", 1_700_000_000), { iss: "HPD6U8BLB5", iat: 1_700_000_000 });
});

Deno.test("the topic is the bundle id", () => {
  assertEquals(TOPIC, "com.metsahalme.Chores");
});
