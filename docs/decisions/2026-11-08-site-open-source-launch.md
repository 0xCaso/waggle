# How should waggle.so show that Waggle is open source?

Decided: 2026-11-08 · Case: c_13196e72-29d8-40f7-b40f-3ad1feb0f76a

## Question and choice
Two points for waggle.so at the open source launch.

- GitHub link on the home page: "Header and footer". A small "GitHub" link at the top right of the header, and
  "Open source · Apache 2.0" in the footer.
- Pilot words: "Remove pilot". Remove the "Pilot" badge on the install page. The help line says "open an issue on
  GitHub". The terms say "an early version".

The operator also wrote: "the home page should point to download, focus on the inbox use case i think we need to
redesign it".

## Why
- The operator's message: the home page must lead to the download and show the inbox use case. Today it shows the
  manifesto hero and the essay link only.
- Header and footer: the essay stays the main reading link, and people who look for the code find it at the top
  right.
- Remove pilot: a public repo is open to all. "Pilot" and "the person who invited you" tell a new reader that they
  are not invited.

## Constraints
- The GitHub link goes live only after waggle-so/waggle is public. Deploy the site at the cut, not before.
- The privacy page must say that Sharing is not available in this version, and that existing shared pages stay
  until the owner stops them.
- The terms say that the app code is under Apache 2.0, and that the terms cover waggle.so and the sharing service.
- The home redesign follows the waggle-taste skill and its copy rules (plain, friendly, no em-dashes).
- The download links stay on limone-eth/waggle-releases until a separate decision moves them.

## Ruled out
- Line under the hero ("Waggle is open source. Read the code →"): it competes with the essay link and the download.
- Both: too many code links on a short page.
- Keep pilot: it reads as a closed group.

## Comments
- "the home page should point to download, focus on the inbox use case i think we need to redesign it": I open a
  redesign as its own task (task 3). It needs its own design round in Waggle before code.

## Open questions
- The redesigned home page: what it shows first (the app window, a short flow, a GIF), and if the manifesto line
  and the essay stay on it. This goes to a design round.
- If the redesign is not ready at the cut, does the launch wait for it? This record assumes: no. The launch ships
  with tasks 1 and 2, and the redesign follows.

## Sources
- Case c_13196e72-29d8-40f7-b40f-3ad1feb0f76a.
- site/index.html, site/install/index.html, site/privacy/index.html, site/terms/index.html.
- Prototype: .knock-review/oss-site/ (three home page variants, not committed).

## Tasks

1. **GitHub link and pilot words.** Criteria: the home header has a "GitHub" link to
   https://github.com/waggle-so/waggle at the top right. The footers of home, privacy and terms say
   "Open source · Apache 2.0" with a link to the repo. The install page has no "Pilot" badge, and its help line
   points to GitHub issues. The terms say "an early version". From: Question and choice, lines 1 and 2.
2. **Privacy and terms for the open source launch.** Criteria: the privacy page says Sharing is not available in
   this version and existing shared pages stay until stopped, and it links the source code. The terms name the
   Apache 2.0 license for the app code. The "Last updated" dates change. From: Constraints, lines 2 and 3.
3. **Redesign the home page around the download and the inbox.** Criteria: a Download for Mac button above the
   fold. The page shows the inbox use case (an agent asks, you answer in Waggle). One design round in Waggle with
   a prototype before code. Follows the waggle-taste skill. From: Question and choice, the operator's message.
4. **Deploy at the cut.** Criteria: `vercel deploy --prod` from site/ only after the repo is public, and the
   GitHub links return 200. From: Constraints, line 1.
