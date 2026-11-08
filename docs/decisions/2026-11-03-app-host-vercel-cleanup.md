# Remove app.waggle.so from Vercel and fix the privacy page?

Decided: 2026-11-03 · Case: c_287e757c-accb-409e-9162-01ba19e60350

## Question and choice

Vercel shows "Invalid Configuration" for app.waggle.so, but the host works on Cloudflare. Which clean up do you want?

The operator chose: "I remove only app.waggle.so from the Vercel project waggle. I also correct line 72 of the privacy page on a branch for your review. I do not deploy the page."

## Why

The operator gave no extra reasons. The agent's reasons:

- The Cloudflare Worker `waggle-relay` serves app.waggle.so as a custom domain. Vercel is not in the path, so the warning has no use.
- The privacy page said that Vercel passes app.waggle.so requests to Cloudflare. That stopped being true on 18 Oct (`ab3d3785`).

## Constraints

- Do not add the CNAME that Vercel asks for. It could stop sharing and sign-in.
- waggle.so and www.waggle.so stay on the Vercel project waggle.
- Remove the domain from the project only. Do not use `vercel domains remove`: it removes ownership from the team.
- The privacy page does not deploy until the operator reviews it.

## Ruled out

- Remove domain only: the privacy page stays incorrect.
- Fix page only: the Vercel warning stays.
- Change nothing: the warning stays and the privacy page stays incorrect.

## Comments

none

## Open questions

none

## Tasks

1. Remove app.waggle.so from the Vercel project waggle. Status: done by the operator on 2026-11-03. The Claude Code auto mode classifier blocked the agent from this action.
   - Criteria: the Vercel project waggle no longer lists app.waggle.so. It still lists waggle.so and www.waggle.so. `https://app.waggle.so/api/me` still returns 401 with `server: cloudflare`.
   - From: "I remove only app.waggle.so from the Vercel project waggle."
2. Correct the privacy page. Status: done on branch `fix/privacy-app-host`, not deployed.
   - Criteria: the Vercel line names only waggle.so. The "Last updated" date is 3 November 2026.
   - From: "I also correct line 72 of the privacy page on a branch for your review."

## Sources

- Case c_287e757c-accb-409e-9162-01ba19e60350
- `relay/wrangler.jsonc:30`, `relay/README.md:91-95`, `site/privacy/index.html:72`
- Commits `405743f7` and `ab3d3785`
- Cloudflare API: Worker custom domains list. Vercel API: domains of the project waggle.
