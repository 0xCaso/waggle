# How do I show the PR changes: before/after pairs or video?

Decided: 2026-11-10 · Case: c_e3c7c7ec-f2f2-4276-9bac-226d48fd03f3 (follows c_c0de85fe-f7e7-4e6b-8dac-714249d5c389)

## Question and choice
Ten after-only screenshots do not show the difference. How do I show the changes in PR #1?
Chosen: "I make 4 images. Each image shows main on the left and this branch on the right, with the same sample request: options shown once, Conversation tab, one context line, answer box with long text."

## Why
- The operator: there were too many screenshots, and without before and after the difference is not clear.
- Four pairs show every main change with the least work; a video can come later if a reviewer asks.

## Constraints
- Sample data only, the same sample request on both sides.
- Before = main, after = request-page-simplify, same window size.
- No image in a commit; the operator drags the files into a PR comment.

## Ruled out
- One before/after video: needs a test copy of the app with sample requests, about 2-3 h (estimate), harder to review.
- Images and video: about 3-4 h (estimate).

## Comments
none

## Open questions
none

## Sources
- Case c_e3c7c7ec-f2f2-4276-9bac-226d48fd03f3
- apps/macos/Tests/KnockTests/RequestPageRenderTests.swift
