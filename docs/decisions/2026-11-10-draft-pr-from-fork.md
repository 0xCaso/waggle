# Can I fork waggle to 0xCaso to open the draft PR?

Decided: 2026-11-10 · Case: c_48774ab4-c9b2-4be8-aeae-19f3cef5ee50 (follows c_5076fdc5-fe22-4f60-bdd8-64a95035e3c7)

## Question and choice
The push to waggle-so/waggle failed: 0xCaso can only read the repo.
Chosen: "Fork waggle-so/waggle to 0xCaso/waggle, push the branch there and open the draft PR from the fork to waggle-so/waggle main."

## Why
- The repo is public and allows forks; a PR from a fork needs no new access on waggle-so.

## Constraints
- The fork is 0xCaso/waggle; every GitHub write goes out as 0xCaso.
- The PR is a draft against waggle-so/waggle main, as decided in c_0d5db705.

## Ruled out
- Wait for write access: the PR would wait for limone-eth.
- Keep it local: the work would stay only on this Mac.

## Comments
none

## Open questions
none

## Sources
- Case c_48774ab4-c9b2-4be8-aeae-19f3cef5ee50
- `gh api repos/waggle-so/waggle`: push false, visibility public, allow_forking true
