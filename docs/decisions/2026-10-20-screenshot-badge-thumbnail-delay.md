# How should the badge deal with the macOS thumbnail delay?

Decided: 2026-10-20 · Case: c_0e1668a0-0d3f-40ee-990a-aa303186e87a

## Question and choice
With the macOS floating thumbnail on, the badge shows only after the thumbnail goes, about 5 s late. Keep it and add a tip, add a button that turns the thumbnail off, or ask for Full Disk Access?
The operator chose "Keep it, add a tip".

## Why
The operator gave no note. Waggle cannot see a screenshot earlier: macOS keeps the file in a blocked temp folder ("Operation not permitted") while the thumbnail shows, and the window list showed no thumbnail window. With "Show Floating Thumbnail" off, macOS saves the file at once and the badge shows at once.

## Constraints
- The badge keeps its place: where the thumbnail was, after it goes.
- Settings › Screenshots shows one line: "For the badge to show at once, turn off Show Floating Thumbnail (Command Shift 5 › Options)."
- Waggle changes no macOS setting and asks for no new permission.

## Ruled out
- A button that turns the macOS thumbnail off: Waggle would change a macOS setting.
- Full Disk Access to watch the temp folder: a heavy permission for a small add-on, and the folder name can change.

## Comments
none

## Open questions
- If the operator uses the badge a lot, the button is a small next step.

## Sources
- Case c_0e1668a0-0d3f-40ee-990a-aa303186e87a.
- Operator's screenshots: the first file path was in TemporaryItems/NSIRD_screencaptureui_…; the badge showed after the thumbnail went.
