# How do I clean the private data from PR #1 and add images?

Decided: 2026-11-10 · Case: c_abba85ea-e434-41e5-a5d5-25eba654c522

## Question and choice
PR #1 (waggle-so/waggle, public) held real requests from the operator's queue in the mockups and a personal email as commit author. How do I clean it, and how do I put screenshots and a video in the PR?
- Cleanup: "Replace the real requests in the mockups with sample requests, remove the path and the line that names a client project, set the author to the 0xCaso noreply address, and force-push the same branch. PR #1 stays."
- Proof: "I make before/after screenshots from the render harness and a video from a test copy of Waggle Dev, both with sample data only. I give you the files and the comment text; you drag the files into a PR comment in the browser."

## Why
- The operator asked: "I want to know if you attached anything private to the pull request" and wants "a video recording or screenshots, but without showing my data".
- The PR and its links stay; the mockups stay useful as a design record with sample data.
- Drag and drop keeps binaries out of git and is the only way a fork PR shows a video inline (`gh --attach` needs write access).

## Constraints
- No real request, client, person, place or project name from the operator's queue in any file of the PR.
- Commit author: 0xCaso noreply address, not a personal email.
- No absolute local paths in the repo files of the PR.
- Screenshots and video use sample data only; no screenshot or binary in a commit.

## Ruled out
- New branch and new PR: a new link, and the old SHA stays reachable anyway.
- Remove the mockups: the PR loses the design record of the directions.
- Images on a fork branch: binaries in git, and no inline video in the PR body.

## Comments
none

## Open questions
- The old commit a66c2e1 stays reachable by SHA on GitHub; only GitHub Support can purge it. The operator decides whether to ask.
- Disk: 128 MB free; the screenshots and the video need about 2–3 GB (estimate).

## Sources
- Case c_abba85ea-e434-41e5-a5d5-25eba654c522
- https://github.com/waggle-so/waggle/pull/1
- design/mockups/2026-11-09-request-page/index.html, design/mockups/2026-11-09-request-page-cases/index.html
- apps/macos/Tests/KnockTests/RequestPageRenderTests.swift (sample data)
