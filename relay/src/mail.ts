import type { Env } from "./env";

export const MAIL_FROM = { name: "Waggle", email: "signin@waggle.so" };

export function mailFrom(env: Env): { name: string; email: string } {
  const email = env.MAIL_FROM?.trim();
  return email ? { name: MAIL_FROM.name, email } : MAIL_FROM;
}

function esc(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

// A subject has no line breaks, whatever the case title holds.
function oneLine(s: string): string {
  return s.replace(/[\r\n\u2028\u2029]+/g, " ").trim().slice(0, 200);
}

export type Mail = { to: string; subject: string; text: string; html: string };

// Sends through the Workers `send_email` binding. Without the binding (local dev, tests) the mail goes to
// the dev_outbox table. A link is logged only in dev mode, never in production.
export async function sendMail(env: Env, mail: Mail): Promise<void> {
  if (env.EMAIL) {
    await env.EMAIL.send({ from: mailFrom(env), to: mail.to, subject: mail.subject, text: mail.text, html: mail.html });
    return;
  }
  if (env.DEV_MODE !== "1") {
    throw new Error("the EMAIL binding is not set");
  }
  await env.DB.prepare("INSERT INTO dev_outbox (to_email, subject, body_text, body_html, created_at) VALUES (?, ?, ?, ?, ?)")
    .bind(mail.to, mail.subject, mail.text, mail.html, Date.now())
    .run();
  console.log(`[dev mail] to ${mail.to}: ${mail.subject}\n${mail.text}`);
}

function shell(lines: string[], link: string, linkText: string, foot: string): { text: string; html: string } {
  const text = `${lines.join("\n\n")}\n\n${link}\n\n${foot}\n`;
  const html =
    `<div style="font-family:-apple-system,system-ui,sans-serif;font-size:15px;line-height:1.5;color:#16181A">` +
    lines.map((l) => `<p style="margin:0 0 14px">${esc(l)}</p>`).join("") +
    `<p style="margin:0 0 14px"><a href="${esc(link)}" style="color:#16181A;font-weight:600">${esc(linkText)}</a></p>` +
    `<p style="margin:0;color:#6B6B6B;font-size:13px">${esc(foot)}</p></div>`;
  return { text, html };
}

export function signInMail(to: string, link: string, minutes: number): Mail {
  const { text, html } = shell(
    [`Open this link to sign in to Waggle. It works once, for ${minutes} minutes.`],
    link,
    "Sign in to Waggle",
    "If you did not ask for this email, you can ignore it.",
  );
  return { to, subject: "Your Waggle sign-in link", text, html };
}

export function inviteMail(to: string, who: string, title: string, url: string): Mail {
  const { text, html } = shell(
    [`${who} shared "${title}" with you on Waggle.`, `Open the link and sign in with ${to} to see it. You do not need the Waggle app.`],
    url,
    "Open the case",
    "If you did not expect this email, you can ignore it.",
  );
  return { to, subject: oneLine(`${who} shared "${title}" with you on Waggle`), text, html };
}
