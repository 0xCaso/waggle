import { expect } from "vitest";
import type { Env } from "../src/index";

// Test helpers for the account flows (WAG-392). They sign in through the real routes: the email goes to the
// dev outbox, the link is read from there, and the Mac connect runs the device flow.

export type Call = (path: string, init?: RequestInit & { origin?: string }) => Promise<Response>;

export function ipHeader(ip = crypto.randomUUID()): Record<string, string> {
  return { "cf-connecting-ip": ip };
}

export function cookieOf(res: Response, name?: string): string {
  const all = res.headers.getSetCookie?.() ?? [res.headers.get("set-cookie") ?? ""];
  const hit = all.find((c) => (name ? c.startsWith(`${name}=`) : true)) ?? "";
  return hit.split(";")[0];
}

export async function lastMail(E: Env, to: string): Promise<{ subject: string; body_text: string; body_html: string }> {
  const row = await E.DB.prepare("SELECT subject, body_text, body_html FROM dev_outbox WHERE to_email = ? ORDER BY id DESC LIMIT 1").bind(to).first<{ subject: string; body_text: string; body_html: string }>();
  expect(row, `a mail to ${to}`).toBeTruthy();
  return row!;
}

export function linkIn(text: string): string {
  const m = text.match(/https?:\/\/[^\s"<]+/);
  expect(m).toBeTruthy();
  return m![0];
}

// Signs the email in on the web with the one-time link. Returns the session cookie.
export async function webSignIn(call: Call, E: Env, email: string, next = "/"): Promise<string> {
  const sent = await call("/api/auth/email", { method: "POST", headers: { origin: E.APP_ORIGIN, ...ipHeader() }, body: JSON.stringify({ email, next }) });
  expect(sent.status).toBe(202);
  const link = linkIn((await lastMail(E, email.toLowerCase())).body_text);
  const res = await call(link.slice(E.APP_ORIGIN.length), { method: "POST", headers: { origin: E.APP_ORIGIN } });
  expect(res.status).toBe(303);
  return cookieOf(res, "wr_session");
}

// The Mac connect flow, end to end. Returns the device token.
export async function connectDevice(call: Call, E: Env, cookie: string, label = "Test Mac"): Promise<string> {
  const made = await call("/api/auth/device", { method: "POST", headers: ipHeader(), body: JSON.stringify({ label }) });
  expect(made.status).toBe(201);
  const d = (await made.json()) as { device_code: string; user_code: string };
  const ok = await call("/api/auth/device/approve", { method: "POST", headers: { origin: E.APP_ORIGIN, cookie, ...ipHeader() }, body: JSON.stringify({ user_code: d.user_code }) });
  expect(ok.status).toBe(200);
  const poll = (await (await call("/api/auth/device/poll", { method: "POST", body: JSON.stringify({ device_code: d.device_code }) })).json()) as { status: string; device_token: string };
  expect(poll.status).toBe("approved");
  return poll.device_token;
}

export async function newUser(call: Call, E: Env, email = `user-${crypto.randomUUID().slice(0, 8)}@example.com`) {
  const cookie = await webSignIn(call, E, email);
  const device = await connectDevice(call, E, cookie);
  return { email, cookie, device, bearer: { authorization: `Bearer ${device}` } };
}
