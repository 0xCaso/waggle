# Sharing a case

Sharing is optional. Waggle works without it. Without Sharing, Waggle needs no account and makes no network call
for your cases.

When you share a case, your team reads it in a browser and can comment. You see the comments in Waggle. Your agent
sees them too.

## Turn Sharing on

1. Open Settings, then the Sharing page.
2. Turn Sharing on.

Sharing is off until you do this. You cannot turn it off while a case is shared. Stop sharing the case first.

## Sign in from the Mac

You need a Waggle account to share. Sign-in uses an email link or Google.

1. Choose **Sign in to share**. It shows in the share sheet of a case and in Settings, on the Sharing page.
2. Waggle shows a sign-in code. Choose **Continue in browser**.
3. Sign in on the page that opens. Check the code. Confirm that you want to connect this Mac.
4. Go back to Waggle. The page updates by itself.

The Mac keeps a sign-in token in the Keychain. You can sign out in Settings. The list **Your shared links** shows every page you
share from any Mac. You can stop a page from this list.

## Share a case

1. Open the case.
2. Choose **Share** in the case header. The sheet is titled **Share this case**.
3. Choose who can read it:
   - **Anyone with the link**: people with the link can read it. They give a name to comment. A signed-in person comments
     as their account.
   - **Only these emails**: you list the emails (50 at most). Each person signs in with that email, by email link or
     Google. Waggle sends each new address one invite mail.
4. Confirm in the sheet. Then copy the link with **Copy link**.

You can change the mode or the list later. The link stays the same and the comments stay.

Waggle puts each round of the case on the page. A new round goes up by itself. Waggle also puts the question your agent
asked on the page. The agent cannot share a case. Only you can.

## What your teammates see

- The question, and the rounds as tabs.
- Your artifacts: HTML, markdown, screenshots and diagrams.
- The decision, after you decide. The page then shows the question as a past question.
- The comments, with replies and resolved threads.

A teammate selects text, or drags an area on a page or an image, and writes a comment. A person who is not on your list
sees: "This case is shared with a list of people. You are not on it."

The page checks for new comments about every 20 seconds while it is open.

## Comments, replies and resolve

Comments from your team show in the case under **FROM YOUR TEAM**. Waggle can show a notice when a new comment arrives.
A setting controls whether the notice shows the comment text.

- **Reply**: you can reply to a comment. The page shows your reply under the comment. One level only: a reply to a reply goes
  under the first comment.
- **Resolve**: you, or the person who wrote the first comment, can resolve a thread. A resolved thread folds to one line.
  You can open it again.
- **Close comments**: use **Close comments** to stop new comments. The page shows "Comments are closed." and no box to
  write in. Use **Open comments** to allow them again.

Your agent also gets the team comments. They come with the answer or the wait result, marked "not an answer". A team comment
never decides the case. Only you decide in Waggle. The agent can reply to a comment. The page shows that reply as from the
Agent.

## Stop sharing

Choose **Stop sharing**, then confirm. The link stops working for everyone. The page answers: "Sharing for this case was
stopped by its owner." Their comments stay in Waggle. If you share the case again, it gets a new link.

If you delete a shared case, Waggle stops the share too.

## What goes to the relay

Waggle calls one host: `app.waggle.so`. It calls it only when Sharing is on.

What goes there:

- The case title, the mode and the emails you list.
- The question: the need, the reason, the recommendation and the options (cut to set lengths).
- The files of each round you share: HTML bundle, markdown, screenshots and diagrams.
- Your replies, the decision you made, and whether comments are closed.
- Your account email, and the label of this Mac.

What stays on the Mac: the other cases, your agent sessions and your settings. The owner key of each shared case and the
sign-in token stay in the Keychain. The relay stores only hashes of them.

What comes back: the comments from your team, with the name of the author and, for a signed-in person, the email.

The relay keeps a shared case until you stop sharing it. Waggle sends nothing for a case you did not share.
