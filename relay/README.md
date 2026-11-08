# Waggle relay

Shares a Waggle case with a team: a page with the rounds, comments on the page, and two share
modes. The daemon calls it only when the operator turns Sharing on (see `../docs/protocol-mvp.md`,
"Sharing a case" and "Accounts").

- **Anyone with the link** (default): anyone can read. A signed-in visitor comments as their account.
  A guest gives a name to comment. A guest cannot take the word "owner", or the name of a signed-in
  author on that case, or the owner's name or email.
- **Only these emails**: a listed person signs in with that email (email link or Google). A signed-in
  person who is not on the list sees "This case is shared with a list of people. You are not on it."
  The owner can change the mode and the list later (`PATCH`), and each new address gets one invite mail.
- **Accounts** (WAG-392): one user row per email, whatever way the person signs in. A Mac connects to
  an account with the device flow and keeps a device token in the Keychain. A case made with a device
  token has an owner. Cases made before accounts (WAG-391) keep working with their owner key.
- **Keychain names** (daemon, `daemon/src/connectors/secrets.ts`): service `Knock chat connector`. Account `<bundle id>.relay-device`
  holds the device token. Account `<bundle id>.relay-owner.<relay case id>` holds the owner key of one case. The bundle id is
  `dev.limone.knock` (a dev build uses its own). Neither value goes to `knock.db`, a log or an RPC result.
- **Owner**: the account that made the case (device token or web session), or whoever holds the owner key.
  The relay stores only SHA-256 hashes of the owner key and of every token.

## How it fits

One Worker, two origins. `APP_ORIGIN` serves `/d/<id>` and the API. `CONTENT_ORIGIN` serves the
artifact files only, in a sandboxed frame (CSP `sandbox allow-scripts`, `connect-src 'none'`),
with a signed ticket in the path that is good for one hour. Deployed, the two origins must be two
different sites (for example `app.waggle.so` and a separate content domain).

Rounds: with `ROUND_STORE=artifacts`, one Cloudflare Artifacts repo per case, one commit per round,
one branch per variant. The daemon uploads the files of a round (`files`, base64) to the Worker, and the
Worker pushes them as one Git commit with `src/git.ts` (a minimal pack writer and git-receive-pack v1
over `fetch`, with the 10-minute write token from the binding). The user's Mac needs no `git` and
talks to one host. A Git client can still push by itself and register the round with its `commit`
(`scripts/share.mjs`). `bun scripts/verify-git-push.ts` checks the pack writer against a real
`git receive-pack`. Locally `ROUND_STORE=d1`: Artifacts has no local simulator, so the files
are uploaded and kept in D1 behind the same interface (`src/store.ts`).

D1 keeps the cases, the people, the sessions and the comments. A comment is anchored to the round's
commit and file, and then to one of two things: selected text (the quote and 64 characters on each
side), or an area the reader dragged with "Comment on an area" (a box in document CSS pixels, the
frame width when it was drawn, and the words inside the box).

## The comment loop (WAG-394)

- **Threads**: a comment can have replies (`parent_id`, one level; a reply to a reply goes to the first comment of the thread).
  The page shows replies under their comment with a Reply control. The owner's Mac posts a reply with the owner key or the
  device token and `author_kind: "owner" | "agent"`; the agent shows as "Agent".
- **Resolve**: `POST /comments/<id>/resolve` and `/reopen`. The owner and the author of the first comment may do it. A
  resolved thread folds to one line on the page.
- **Decision**: `PATCH` the case with `status: "decided"` and `decided: { options, note?, at }`. The page shows a "Decided" block
  above the ask and the ask reads as past. A new round with an ask, or a new `ask` in a `PATCH`, opens the case again.
- **Close comments**: `PATCH { comments_closed: true }` (owner key, device token, or the owner's web session from the page).
  The page shows "Comments are closed." and no composer. The comment routes answer `403 Comments are closed.`
- **Ask per round**: each round keeps the ask it came with, and `PATCH { ask }` changes the ask of the last round without a new
  round. The page shows the question that belongs to the round it shows.
- **Image and diagram rounds** open in a wrapper page on the content origin (`?view=1`) with the area script. SVG goes inline. A screenshots round sends `gallery` (the image names) and the wrapper stacks them; an area names its image (`near: "image 02.png"`) and the box is in that image's pixels.
- **Stopped link**: `DELETE` leaves a row in `stopped_cases`. The page and `/state` answer 410 "Sharing for this case was
  stopped by its owner."
- **Live page**: `/state` is polled every 20 s while the page is visible. Round links get a fresh ticket before the old one ends.

## Run it

```bash
npm install
cp .dev.vars.example .dev.vars            # then set TICKET_SECRET
npx wrangler d1 migrations apply waggle-relay --local
npx wrangler dev --ip 127.0.0.1 --port 8787
npm test                                  # vitest in the Workers runtime, no network
```

Play the daemon (`RELAY_KEY_FILE=keys.json` keeps the owner key in a file instead of the Keychain; `create` needs `WAGGLE_DEVICE_TOKEN`, a device token from the connect flow):

```bash
node scripts/share.mjs create "Flagged conversations: what comes first?"
node scripts/share.mjs push <case> examples/round-1 --label "Two orders"
node scripts/share.mjs comments <case>
node scripts/share.mjs open <case>       # a one-time owner link for the browser
node scripts/share.mjs delete <case>
```

## Run your own relay

The relay at `app.waggle.so` is one deployment of this code. You can run your own on your Cloudflare account.
It needs Workers Paid (for Artifacts), a zone on Cloudflare for the page host, and Cloudflare Email Service for
the sign-in mail.

1. `npx wrangler login`.
2. Create the database: `npx wrangler d1 create waggle-relay`. Keep the `database_id` it prints.
3. Copy the config: `cp wrangler.jsonc wrangler.deploy.jsonc`. Git ignores the copy. In `env.production` and
   `env.files`, set:
   - `routes[0].pattern` and `APP_ORIGIN`: your page host, for example `relay.yourteam.dev`.
   - `CONTENT_ORIGIN`: `https://waggle-relay-files.<your workers.dev subdomain>.workers.dev`. It must be a
     different site from the page host: untrusted artifact files are served there.
   - `MAIL_FROM`: a sender address on a domain onboarded in Cloudflare Email Service.
   - `database_id`: the id from step 2.
4. `bash scripts/deploy.sh`. It stops if the copy is missing or still has a placeholder.
5. Optional: Google sign-in (below). Without it, people sign in with an email link.

`scripts/deploy.sh` runs these steps in this order:

1. Apply the D1 migrations to the remote database.
2. Deploy the page Worker `waggle-relay` (`env.production`).
3. Deploy the files Worker `waggle-relay-files` (`env.files`). It has the same code and serves only the shared files.
4. Set `TICKET_SECRET` on both Workers, if it is not set yet. The value is the same on both.
5. Run a smoke test. Both hosts must answer 404.

The page Worker is a Cloudflare custom domain: `env.production` has the route
`{ "pattern": "<page host>", "custom_domain": true }` and `"workers_dev": false`. The custom domain needs no
other DNS record on that host. Delete an old CNAME first. The Worker answers on that host only: any other host
gets 404, so `cf-connecting-ip` is always the real client address and a client cannot forge it. The files Worker
keeps its workers.dev host (the content origin).

Set the Google secrets once, before the first sign-in with Google:

```bash
npx wrangler secret put GOOGLE_CLIENT_ID --env production
npx wrangler secret put GOOGLE_CLIENT_SECRET --env production
```

Run `wrangler secret put` in a real terminal. It reads the value from input. A script, a pipe from an agent or a
non-interactive shell does not give it the value.

## Accounts and sign-in

Every token (web session, device token, one-time link, device code) is stored as a SHA-256 hash only.

- **Email link**: `POST /api/auth/email {email, next}` sends one link (15 minutes, one use) from
  `Waggle <MAIL_FROM>` (default `signin@waggle.so`) with the Workers `send_email` binding `EMAIL`. The answer is always 202
  `{sent: true}`: it never says if the email has an account or is on a list. The link opens
  `/signin/<token>`, a page that posts by itself (a mail scanner that only fetches the link signs nobody in),
  then sets the web session cookie `wr_session` (HttpOnly, SameSite=Lax, 30 days, Secure on https) and goes to
  `next`. `next` is a path on this site only; anything else becomes `/`.
- **Google**: `GET /api/auth/google/start?next=` and `GET /api/auth/google/callback`. OIDC code flow
  with `state` (also in a cookie) and PKCE (S256), scope `openid email`. The Worker exchanges the code with
  `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`. Only `email_verified: true` signs in. The account is found by `google_sub` first; the verified email links an account only when no user has that sub and the email's account has no sub. Another sub for a linked email is refused. The redirect URI is
  `<APP_ORIGIN>/api/auth/google/callback`.
  Without both secrets the routes answer 404 and the sign-in page has no Google button.
- **Mac connect (device flow)**: `POST /api/auth/device {label}` gives `device_code` (secret), `user_code`
  (`WXYZ-2345`) and `verify_url` (`/connect?code=<user_code>`). The person signs in on that page and
  confirms "Connect <Mac name> to your Waggle account?". `POST /api/auth/device/poll {device_code}` answers
  `{status: "pending"}`, then `{status: "approved", device_token, email}` once, then 410. Codes last 10 minutes.
  `POST /api/auth/device/approve` (the connect page, signed in), `POST /api/auth/signout` and `GET /api/auth/session` serve the web page.
  `GET /api/me`, `DELETE /api/me/device` (sign out: revokes the token) and `GET /api/me/cases` (every case
  the account shares, from any Mac: title, URL, mode, created, comment count, which Mac) use the device token.

### Secrets, bindings and the cron

| Name | What | How |
|---|---|---|
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | Google OAuth client | `wrangler secret put` (production). Redirect URI above. |
| `EMAIL` | `send_email` binding for sign-in and invite mail | `"send_email": [{ "name": "EMAIL" }]` in `env.production`. The domain of `MAIL_FROM` must be onboarded in Cloudflare Email Service. |
| `TICKET_SECRET` | signs content tickets (same value on both Workers) | `scripts/deploy.sh` sets it once on both. Rotate it by deleting it on both first |
| Cron `17 3 * * *` | daily cleanup | `triggers.crons` in `env.production`. Deletes expired sessions, used or expired links, expired or collected device codes and rate-limit rows older than two days. Cases have no time to live. |

Local dev and tests have no `EMAIL` binding. The relay then writes each mail to the `dev_outbox` table and logs
it, and `GET /api/dev/outbox?to=<email>` reads it. That route, and the Google endpoint overrides
(`GOOGLE_AUTH_URL`, `GOOGLE_TOKEN_URL`), work only when `DEV_MODE` is `"1"`. The production environment never
sets it. With no binding and no dev mode the relay sends nothing and logs no link.

### Limits (fixed window, in D1)

Over a limit the answer is 429 with plain text and `retry-after`.

| What | Limit |
|---|---|
| sign-in emails | 5 per email per hour from the same IP (a stranger cannot lock a person out), 20 per IP per hour, 30 per email per day |
| device codes | 10 per IP per hour |
| code approvals | 30 per IP per hour |
| new cases | 30 per user per day (a retried share does not count) |
| guest joins | 20 per IP per hour |
| comments | 60 per person (account or guest) per hour, 2000 per case |
| invites | at most 100 invite mails per user per day and 50 per share or change call. Over the limit the share or change still works, and the answer says how many mails were not sent |

The IP is `cf-connecting-ip`. `x-forwarded-for` is never read.

## API

| Call | Who | What |
|---|---|---|
| `POST /api/cases` | device token | `{title, mode, emails?, owner_key_hash, ask?, request_id?}` → `{id, url, invites?}`; 401 "Sign in to Waggle first." without a device token; the same `request_id` and key hash give the same case (200). Each listed email gets an invite mail; `invites: {sent, failed, limited}` counts them. A 401 with `code: "invalid_token"` means the device token is not valid any more |
| `PATCH /api/cases/<id>` | owner | any mix of `mode`, `emails`, `ask` (with `round_seq` to name the round), `status` (`open` \| `decided`), `decided` (`{options, note?, at?}`) and `comments_closed` → `{id, mode, emails, invited, invites: {sent, failed, limited}}`. Same URL, comments kept. Same checks and 50 cap. A removed email loses web access at its next request. A switch to emails mode ends the guest sessions of that case |
| `DELETE /api/cases/<id>` | owner | the case, its repo and its comments. The link then answers `410` with `code: "stopped"` |
| `POST /api/cases/<id>/push-access` | owner | `{remote, token, expiresAt}`; 409 without Artifacts |
| `POST /api/cases/<id>/rounds` | owner | `{label, entry, variant?, ask?, files}` (200 files, 1 MB each, 15 MB in all; a retry with the same files gives the same round) or `{..., commit}` after your own git push |
| `GET /api/cases/<id>/comments?since=&after=` | owner | `{comments, resolved, case}`: the comments after the cursor `(since, after)` (created_at, then id), every resolved thread, and `case: {status, comments_closed}`. Each comment has `author_kind` (`owner`, `member`, `guest`, `agent`) and `author_email` |
| `POST /api/cases/<id>/owner-link` | owner | a one-time link that opens the page signed in |
| `GET /api/cases/<id>/state` | reader | `ask`, `status`, `decided`, `comments_closed`, rounds (with content URLs and the ask of each round), comments and `viewer` (`author_email` only for the owner); 401 when sign-in is needed, 403 when signed in but not on the list, 410 when stopped |
| `POST /api/cases/<id>/guest` | page | `{name}`, "Anyone with the link" only |
| `POST /api/cases/<id>/comments` | page, signed in | `{round_seq, body, quote?, prefix?, suffix?, box?: {x, y, w, h, vw, near}, parent_id?}`; `parent_id` makes a reply. With the owner key or the device token: `{parent_id, body, author_kind: "owner" \| "agent"}`. `403 Comments are closed.` when the owner closed them |
| `POST /api/cases/<id>/comments/<comment id>/resolve` and `/reopen` | owner, or the author of the first comment | resolve or reopen the thread of that comment |

"Owner" means: `Authorization: Bearer <owner key>`, or `Bearer <device token>` of the account that owns the
case, or the web session of that account (a write by cookie must come from `APP_ORIGIN`).

`ask` is the question the agent asks, shown above the round as plain text (the page never builds HTML
from it): `{need: string ≤600, why?: string ≤1000, recommendation?: string ≤300, options?: [{title ≤80,
label ≤600, recommended?: boolean}] ≤12}`. Bad input gets a 400. The latest ask is stored on the case: a
new round may send a new one, and a round without one keeps the old one. A case with no ask shows none.

The page serves its own fonts (Inter Tight and JetBrains Mono, latin, variable woff2, SIL Open Font
License 1.1) from `/fonts/*.woff2`, kept in `src/fonts.ts`. No call goes to a third party.

Writes with a cookie must come from `APP_ORIGIN` (Origin header check).

## Migrations

Files in `migrations/`, applied in order by `wrangler d1 migrations apply`.

| File | What |
|---|---|
| `0001_init.sql` | cases, rounds, sessions, comments |
| `0002_comment_box.sql` | area comments (a dragged box) |
| `0003_ask.sql` | the ask on the case |
| `0004_idempotent_share.sql` | `request_id`, so a retried share gives the same case |
| `0005_accounts.sql` | users, sign-in links, web sessions, device codes and tokens, limit rows, dev outbox |
| `0006_threads.sql` | replies, resolve, the decision, closed comments, the ask of each round, stopped links |
| `0007_gallery.sql` | the image names of a screenshots round |

## Not yet

The Git push to the real Artifacts service is checked only against a fake remote and a real `git receive-pack`, not against Cloudflare (the deploy shows it). Not checked live: the Email Service sender, the Google client, and `cf-connecting-ip` on the custom domain.
