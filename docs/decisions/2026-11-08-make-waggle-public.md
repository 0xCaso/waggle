# Make waggle-so/waggle public now?

Decided: 2026-11-08 · Case: c_a03ef6f9-7392-4f7c-ad70-77767b8bf98d

## Question and choice
Two points at the cut.

- When the repo goes public: "Public now". Make the repo public, then turn on private vulnerability reporting
  and deploy waggle.so.
- The old private repo: "Rename to waggle-archive". limone-eth/waggle becomes limone-eth/waggle-archive and
  stays private.

## Why
- CI was green on the one first commit (daemon, app, relay, secret scan), and the new home page links to the
  repo.
- The old name invited pushes to the wrong repo. The rename keeps the full history safe.

## Constraints
- waggle-so/waggle starts from one commit by the GitHub noreply address. The private history stays in
  limone-eth/waggle-archive.
- waggle.so deploys only after the repo is public, so its GitHub links work.
- Private vulnerability reporting is on, as SECURITY.md says.

## Ruled out
- Wait, I look first: the operator chose to publish now.
- Keep limone-eth/waggle as is: the old name invites pushes to the wrong repo.

## Comments
none

## Open questions
- Moved: waggle-releases is now waggle-so/waggle-releases (2026-11-08). Old URLs redirect.
- Credit for the second author (from the launch plan).
- New og:image for the home page (case c_97b1fb8f).

## Sources
- Case c_a03ef6f9-7392-4f7c-ad70-77767b8bf98d.
- docs/decisions/2026-11-08-open-source-waggle.md (task 1 rename, task 9 cut).

## Tasks

1. **Make the repo public.** Criteria: waggle-so/waggle shows "Public". From: Question and choice, line 1.
2. **Turn on private vulnerability reporting.** Criteria: the API for private-vulnerability-reporting returns
   enabled: true. From: Constraints, line 3.
3. **Deploy waggle.so.** Criteria: `vercel deploy --prod` from site/, and the home page, privacy and terms pages
   load with the GitHub link returning 200. From: Constraints, line 2.
4. **Rename the old repo.** Criteria: limone-eth/waggle-archive exists and is private; local remotes point to
   it. Done 2026-11-08. From: Question and choice, line 2.
