# Which tracker counts page views and downloads on waggle.so?

Decided: 2026-11-10 · Case: c_0f3776ce-a5f1-4c02-b494-b67352b19f49

## Question and choice
The operator asked for a page tracker and a download tracker on waggle.so, "so we see how it goes".

The choice: "Vercel, with a redirect page". "Vercel Web Analytics on every page. Download buttons open /download/, which counts one page view and starts the DMG at once."

## Why
The operator's words:

- "check if the hobby plan offers analytics"
- "can't we track page click or redirect to download?"

The agent's reasons:

- The Vercel Hobby plan counts page views (50,000 events each month, one month of data) but has no custom events, so it cannot count a click.
- A page that loads before the file starts is counted as a page view. This gives a download number on Hobby with no new service.

## Constraints
- Every page of the site loads the Vercel Web Analytics script. No cookies, no other tracker.
- Every download button on the site opens `/download/`. Only that page links to the DMG.
- The privacy page says what the website counts. The Mac app stays without analytics.

## Ruled out
- PostHog: real click events, but a second service and a project key. Not needed now.
- Plausible: a paid plan and a new account.
- A server redirect in `vercel.json`: Web Analytics does not count it, because its script runs only when a page loads.

## Comments
none

## Open questions
- Web Analytics must be turned on for the project in the Vercel dashboard. Until then the script loads but counts nothing.
- `/download/` does not show which page the visitor came from.

## Sources
- Case c_0f3776ce-a5f1-4c02-b494-b67352b19f49.
- https://vercel.com/docs/analytics/limits-and-pricing (Hobby: 50,000 events each month, one month of data, no custom events).
- `site/download/index.html`, `site/index.html`, `site/install/index.html`, `site/privacy/index.html`.
