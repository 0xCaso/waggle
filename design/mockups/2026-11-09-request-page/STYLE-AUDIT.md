# Style audit: decision column, mockups vs Swift

Date: 2026-11-10 · Branch `request-page-simplify` (HEAD `19a26b7`) · Decision: `docs/decisions/2026-11-10-match-request-page-to-mockups.md`

Sources:
- **CM** = case map mockup `design/mockups/2026-11-09-request-page-cases/index.html`, `<style id="tokens">` (lines 19-168), templates `plan`, `shots`, `multi`, `conv`, `full`. This one sets the sizes.
- **B** = `design/mockups/2026-11-09-request-page/index.html`, tokens (lines 32-94) + template `inplace` (lines 171-254). Used only for what CM does not show.
- Swift paths are relative to `apps/macos/Sources/Knock/`. 1 CSS px = 1 pt.

## 0. Rules that apply to every row below

1. **Line height is computed differently.** CSS `line-height: L` gives a line box of `L × size`. `knockTextStyle` (`Theme/Theme.swift:807-816`) and `AskTextFace.lineSpacing` (`Review/Comments/AskText.swift:83`) add `size × (L − 1)` **on top of** the font's own line height. Measured from the bundled TTFs (hhea): Inter Tight = **1.2100 × size**, JetBrains Mono = **1.32 × size**. So a Swift style with `lineHeight: 1.5` gives about 1.71 × size, and a style with `lineHeight: nil` gives 1.21 (sans) or 1.32 (mono). To get CSS `L`, Swift needs `lineSpacing = size × (L − 1.21)` (sans) or a fixed min/max line height. Where CSS says `/1` (`.ol`, `.rec`, `.key`, `.tabs .n`, `.latest .who`, `.msg .h`, `.ctx`), Swift draws at 1.21 / 1.32.
2. **The CSS default line height is 1.45** (`html, body { font: 400 13px/1.45 }`, CM:33). Every element without its own line height inherits 1.45 × its own size, buttons too (`button { font: inherit }`, CM:35).
3. **"Semibold" in AppKit text is Bold 700.** `PromptBarLogic.sansFont` (`Composer/PromptBarLogic.swift:28-35`) turns any weight ≥ semibold into `NSFontManager.convert(…, toHaveTrait: .boldFontMask)`. Checked with a script against the bundled fonts: `InterTight-Regular` → **`InterTight-Bold`**. Every commentable text on the request page goes through it (`CommentableAskText`, `AskText.swift:230-239`): the title, the need's lead sentence, the "Why you:" prefix, table headers, the pick card title. The mockup uses 600 (SemiBold) everywhere and never uses 700. Weight `.medium` in the same path falls back to **Regular 400** (the `>= semibold` test fails), so a `.medium` commentable text loses its 500.
4. **Font families.** Mockup: `Inter Tight` 400/500/600 and `JetBrains Mono` 400 only (CM:20-23). App: the same families are bundled (`Resources/Fonts/`, plus InterTight-Bold and JetBrainsMono-SemiBold). Outside that: the status line uses the **system font (SF)** (`Queue/RequestStatus.swift:346, 350`), and all icons are SF Symbols, where the mockup uses text glyphs (✓ ★ ↩ + –).
5. **Column frame.** CM `.col` (CM:96): 440 wide, `border-left: 1px solid --line`, white. Swift: `AskLayout.columnWidth = 440` (`Plan/AskArtifactLayout.swift:19`), **no left border** (not found in `Queue/CasePaneView.swift` or `Review/ReviewWorkspaceView.swift`).
6. **Content edges.** CM: the tabs have a 14 pt side margin (`.tabs` margin `10px 14px 0`, CM:97), the scroll has an 18 pt side padding (`.cs` padding `14px 18px 10px`, CM:102), and the answer area has a 14 pt side padding (`.ans` padding `10px 14px 12px`, CM:150). Swift pane: every part uses leading **12** (beside an artifact) or **24** (no artifact or folded) and trailing **24** (`Queue/CasePaneView.swift:405-406`; used at 465, 472, 487, 822). Swift full size: 16 on all sides (`Review/AskColumnView.swift:109, 122, 164`).

## 1. Token map

`=`: same hex. `≠`: not the same, nearest token named.

| Mockup variable | Hex | Swift token | Swift hex | Match |
|---|---|---|---|---|
| `--win` | #ffffff | `Theme.Colors.win` (Theme.swift:11) | FFFFFF | = |
| `--side` | #f3f3f3 | `Theme.Colors.side` (:31) | F3F3F3 | = |
| `--list` | #fafafa | `Theme.Colors.list` (:32) | FAFAFA | = |
| `--sel` | #ebebeb | `Theme.Colors.sel` (:56) | EBEBEB | = |
| `--hover` (B only) | #f0f0f0 | `Theme.Colors.hover` (:39) | F0F0F0 | = |
| `--ink` | #16181a | `Theme.Colors.ink` (:33) | 16181A | = |
| `--ink2` | #4a4c50 | `Theme.Colors.ink2` (:34) | 4A4C50 | = |
| `--ink3` | #6b6b6b | `Theme.Colors.ink3` (:35) | 6B6B6B | = |
| `--quiet` | #8a8a8a | `Theme.AskDoc.Colors.quiet` (Theme/AskDocTheme.swift:12) | 8A8A8A | = (not in `Theme.Colors`; most column code uses `ink3` where the mockup has `--quiet`) |
| `--line` | #e6e6e6 | `Theme.Colors.line` (:36) | E6E6E6 | = |
| `--line2` | #d9d9d9 | `Theme.Colors.line2` (:37) | D9D9D9 | = |
| `--honey300` | #f9c846 | `Theme.Colors.honey300` (:44) | F9C846 | = |
| `--honey500` | #f2b01e | `Theme.Colors.honey500` (:45) | F2B01E | = |
| `--honey600` | #e89a0c | `Theme.Colors.honey600` (:46) | E89A0C | = |
| `--honey-soft` | #fdf4da | `Theme.Colors.honeySoft` (:47) | FDF4DA | = |
| `--need-bg` (CM only) | #fbf3d9 | none; the need box uses `honeySoft` | FDF4DA | ≠ (new token needed) |
| `--need-label` | #9a6a00 | `Theme.AskDoc.Colors.needLabel` (AskDocTheme.swift:10) | 9A6A00 | = |
| `--rec-text` | #c98a00 | `Theme.Colors.recommendedTagText` (:49) | C98A00 | = |
| `--open` | #e0352b | `Theme.Colors.accent` (:41) | E0352B | = |
| `--ok` | #18a058 | `Theme.Colors.ok` (:57) | 18A058 | = |
| `--ok-soft` | #e3f5ea | `Theme.Colors.okSoft` (:58) | E3F5EA | = |
| `--pro` | #0e7a43 | `Theme.AskDoc.Colors.pro` (AskDocTheme.swift:14) | 0E7A43 | = (the option rows' Good marks use `ok` #18A058 instead, see §2.10) |
| `--watch` | #c2410c | `Theme.AskDoc.Colors.watch` (AskDocTheme.swift:18) | C2410C | = |
| `--watch-soft` (B only) | #ffede3 | `Theme.AskDoc.Colors.watchSoft` (:20) | FFEDE3 | = |
| `--link` (CM only) | #2f5bd8 | none; nearest `Theme.Colors.ds` (:59) | 2B59F0 | ≠ (new token needed) |
| literal `.choice.on` bg | #fffdf5 | none; picked row uses `honeySoft` | FDF4DA | ≠ |
| literal `.latest`, `.msg.latestm` bg | #f4f6fd | none; nearest `dsWash` (:28) F3F6FE or `dsUpdateFill` (:62) F2F5FE | — | ≠ |
| literal `.need .why` top line | #efe2b8 | none; Swift draws `ink` at 8 % opacity (`AskDoc/AskDocPage.swift:95`) | ≈ #EAE2CB on honeySoft (computed) | ≠ |
| literal `.ver.new` bg (artifact header) | #eef2fd | nearest `dsSoft` (:60) | E8EEFE | ≠ |
| literal `.msg.you .h` | #aaaaaa | nearest `onInkMuted` (:16) | A9A9A9 | ≠ (1 step) |
| literal `.row.sel` (sidebar, not column) | #fdf6e1 | not checked (outside the column) | — | — |
| `.tabs span.on` shadow | `0 1px 2px rgb(0 0 0/.1)` | `Theme.Shadow.columnTab` (:720) | black 0x1A (0.102), y 1, blur **3** | alpha =, blur ≠ (2 vs 3) |
| `--sans` | "Inter Tight" | `Theme.FontFamily.sans` (:110) | Inter Tight | = |
| `--mono` | "JetBrains Mono" | `Theme.FontFamily.mono` (:111) | JetBrains Mono | = |
| (no mockup) | — | `Theme.AskDoc.Colors.con` (AskDocTheme.swift:16) | B3261E | no mockup counterpart |

## 2. Element tables

"same" = equal value. "change" = Swift must change. "n/a" = the part does not exist on that side (see §3).

### 2.1 Tabs (Decision · Conversation · Comments)

Mockup: `.tabs`, `.tabs span`, `.tabs span.on`, `.tabs .n`, `.tabs .new` (CM:97-101). Swift: `Review/ReviewColumnTabsView.swift`, placed by `Queue/ConversationTab.swift:454-477` (`DecisionColumnHeader`).

| Property | Mockup | Swift | |
|---|---|---|---|
| Track background | `--side` #f3f3f3 (`.tabs`) | `Theme.Colors.side` (ReviewColumnTabsView.swift:25) | same |
| Track radius | 9 (`.tabs`) | `Radius.columnTabsTrack` = 8 (:26, Theme.swift:687) | change |
| Track padding | 3 (`.tabs`) | 3 (:24) | same |
| Gap between segments | 2 (`.tabs`) | 2 (:19) | same |
| Track margin | top 10, sides 14, bottom 0 (`.tabs`); first thing in the column | pane: top 16, leading 12/24, trailing 24, bottom 4 (CasePaneView.swift:472); full size: 16/16/4/16 (AskColumnView.swift:109); in the pane the context line sits **above** the tabs (CasePaneView.swift:464-465) | change |
| Segment width | `flex: 1` (equal thirds) | `.frame(maxWidth: .infinity)` (:46) | same |
| Segment padding | 6 top/bottom, 0 sides (`.tabs span`) | 6 top/bottom, **8** sides (:45) | change |
| Segment radius | 7 (`.tabs span`) | `Radius.columnTabsSegment` = 6 (:48, Theme.swift:690) | change |
| Label font | Inter Tight (inherited) | Inter Tight (`buttonSm12_5w500/600`) | same |
| Label size | **13** (inherited from body) | **12.5** (:33; Theme.swift:215-222) | change |
| Label weight | 500, active and inactive (`.tabs span`) | 500 inactive, **600 active** (:33) | change |
| Label line height | 1.45 → 18.85 | natural 1.21 → 15.1 (no lineHeight) | change |
| Segment height (derived) | 18.85 + 12 = 30.85 | 15.1 + 12 = 27.1 | change |
| Inactive color | `--ink3` #6b6b6b | `ink2` #4a4c50 (:34) | change |
| Active color | `--ink` | `ink` (:34) | same |
| Active background | #fff (`.tabs span.on`) | `win` (:47) | same |
| Active shadow | 0 1 2, black 10 % | 0 1 blur 3 (radius 1.5), black 10.2 % (:49-53) | change (blur) |
| Label–count gap | 6 (`.tabs span` gap) | 6 (:31) | same |
| Count ("Conversation 3") | mono 400 11/1, `--quiet`, no fill (`.tabs .n`), on Conversation | not shown on Conversation; on Comments a pill: Inter Tight 600 10.5 (`countBadge10_5w600`, Theme.swift:627-630), white on `accent` when active / `ink2` on `line` inactive, padding 1/6, radius 8 (:61-69) | change |
| New dot | 6 × 6 circle `--link` #2f5bd8 (`.tabs .new`) | 6 × 6 circle `ds` #2B59F0 (:41) | change (color) |

### 2.2 Context / follow-up line (`.fu`)

Mockup: `.fu`, `.fu b`, `.fu u` (CM:103-105), markup "↩ Follow-up to **title** · you chose B Show". Swift: `Queue/RequestContextLine.swift`.

| Property | Mockup | Swift | |
|---|---|---|---|
| Place | inside the scroll, first line under the tabs | pane: above the tabs (CasePaneView.swift:464-465); full size: first in the scroll (AskColumnView.swift:141) | change (pane) |
| Margin below | 10 (`.fu`) | pane: 16 to the tabs (CasePaneView.swift:472); full size: VStack spacing 12 (AskColumnView.swift:139) | change |
| Piece gap | 6 (`.fu` gap) | 5 (RequestContextLine.swift:169) | change |
| Prefix glyph and words | "↩ Follow-up to" | "↳ Follow-up to" (:32) | change (glyph) |
| Prefix font | Inter Tight 400 12, `--ink3` | `recommendLine12w400` Inter Tight 400 12, `ink3` (:171-172; Theme.swift:246-249) | same |
| Title font | 12, weight 500, `--ink`, ellipsis (`.fu b`) | `rowLabel12_5w500`: **12.5**, 500, `ink` (:202-203; Theme.swift:331-334) | change (size) |
| Answer words | "you chose B" (lower case), 12 ink3 | "You chose B" (`PreviousAnswer.label`, :45-47), 12 ink3 (:179-180) | change (case) |
| "Show" | 12, `--ink3`, underline offset 2 (`.fu u`) | 12, **`ink`**, underline (default offset) (:187-190) | change |
| Line height | 1.45 → 17.4 | natural → 14.5 | change |
| Wrap | one line, `nowrap`, title cut | one line, title cut (`ViewThatFits`, :123-135) | same |
| Plan track (`.track`) | step circles: 15 × 15, border 1 `--line2`, 9 pt glyph; done: `--ok` fill, white ✓; current: `--ink` fill, white number, label 600 ink; words 11.5 `--quiet`; `hr` 1 pt `--line2` between, min 8; gap 6/5; margin-bottom 12 (CM:110-115) | `PlanWordTrack` words: "Questions · Approaches · …" 12/400 (`recommendLine12w400`), current 12.5/600 ink, done ink2 with SF `checkmark` 9 bold `ok`, upcoming ink3, "·" separators, gap 6/3 (RequestContextLine.swift:220-255) | change (structure + values) |

### 2.3 Eyebrow line (`.ctx`, B only)

Mockup: `.ctx` (B, inplace `<style>` line 175): "SAMPLE BLOG · IMAGE HOSTING · ROUND 2 · 15:00". CM has no eyebrow in the column; it moves project / session into the top bar `.top` (CM:61-62: mono 400 11.5/1, `--ink3`, project `--ink` 400).

| Property | Mockup | Swift | |
|---|---|---|---|
| Exists in column | B: yes; CM: no (top bar) | no eyebrow in the column; top bar `TopBarCrumb` (AskDoc/AskDocPage.swift:208-239); "Round 2" tag `RoundTagView` above the title (Queue/RoundHeading.swift:124-132) | see §3 |
| Font | JetBrains Mono 400 11.5, line height 1 | top bar: mono 400 **12** (`monoMeta12w400`, AskDocPage.swift:224, 234); round tag: mono 400 10.5 (`monoMetaRow10_5w400`, RoundHeading.swift:129) | change |
| Transform | uppercase | none (top bar), as written (round tag) | change |
| Color | `--quiet` #8a8a8a (B) / top bar `--ink3`, project `--ink` (CM) | top bar `ink3` for both parts; round tag `ds` #2B59F0 | change |
| Margin below | 10 | round tag: VStack spacing 4 to the title (RoundHeading.swift:142) | change |

### 2.4 Title (`h1`)

Mockup: `h1` (CM:121). Swift: `AskDoc/AskDocPage.swift:274-310` (`AskTitleView`, `TitleText`), style from `AskHeaderWidth` (:191-203). Pane: CasePaneView.swift:850 (and 889-891 for a stepped ask); full size: AskColumnView.swift:151.

| Property | Mockup | Swift | |
|---|---|---|---|
| Family | Inter Tight | Inter Tight | same |
| Weight | 600 | `.narrow`: style font `.medium` (Theme.swift:153-156) but drawn through `CommentableAskText` with `weight: .semibold` (AskDocPage.swift:302) → **Bold 700** (rule 3) | change |
| Size | 19 | `.narrow` (beside artifact, full size): 19; `.wide` (pane with no artifact or folded): **28** (`askTitle28`, AskDocTheme.swift:47-49; `headerWidth`, CasePaneView.swift:939) | same narrow / change wide |
| Line height | 1.25 → 23.75 | lineHeight 1.3 on top of 1.21 → 19 × 1.51 = 28.7 (narrow); wide 28 × 1.36 = 38.1 | change |
| Letter spacing | −0.02 em = −0.38 | −0.665 (−0.035 em) narrow; −0.84 (−0.03 em) wide | change |
| Color | `--ink` | `ink` (:302) | same |
| Margin below | 10 | pane VStack spacing 14 (CasePaneView.swift:779); full size 12 (AskColumnView.swift:139); description under it spacing 6 (AskDocPage.swift:284) | change |
| Tag next to the title | none in the column h1 | `RoundTagView` above it for later rounds (RoundHeading.swift:143) | see §3 |

### 2.5 Need box, "Why you", "Show" link

Mockup: `.need`, `.need p`, `.need .q`, `.need .why`, `.need .more` (CM:122-126). Swift: `NeedCalloutView` (AskDoc/AskDocPage.swift:58-116), `NeedText` (:120-187). Pane calls it **without** `isCompact` (CasePaneView.swift:854-857, 895); full size calls it with `isCompact: true` (AskColumnView.swift:67-71).

| Property | Mockup | Swift | |
|---|---|---|---|
| Background | `--need-bg` #fbf3d9 | `honeySoft` #FDF4DA (:103) | change (token) |
| Radius | 10 | `AskDoc.Radius.need` = 14 (:104; AskDocTheme.swift:29) | change |
| Padding | 11 top/bottom, 13 sides | pane 16/18 (:101); full size 12/14 (:100) | change |
| Margin below | 14 | pane VStack spacing 14 (CasePaneView.swift:779) / full size 12 (AskColumnView.swift:64) | same pane / change full size |
| Base font | Inter Tight 400 **13**, line height 1.5 → 19.5 | details: `NeedText.detailStyle` = base − 2, min 12 (:182-186) → pane **15** (base `need17`, AskDocTheme.swift:59), full size **12** (base `body13_5w400`); lineHeight 1.55 / 1.5 on top of 1.21 | change |
| Base color | `--ink` (inherited) | details `ink2` (:89) | change |
| Lead sentence (`.q`) | 600 **13.5**, `--ink`, line height 1.5 → 20.25 | `questionStyle`: pane **17**, full size 13.5; weight semibold → **Bold 700** (rule 3) (:80-82, 177-179); line height pane 17 × 1.76 = 29.9, full size 13.5 × 1.71 = 23.1 | change |
| Paragraph gap | 7 (`.need p` margin-bottom) | 10 between question and details (:78); 8 between blocks inside (AskText.swift:354-359) | change |
| "Why you" separator | 1 pt line #efe2b8, then padding-top 7, margin-top 8 (`.why`) | 1 pt `ink` 8 % (:95), VStack spacing 10 above and below (:75) | change |
| "Why you" font | Inter Tight 400 **12**, `--ink3`, line height 1.45 | `why13_5`: **13.5**, line height 1.5 (AskDocTheme.swift:60), `ink3` (:113) | change (size) |
| "Why you:" prefix | plain text, same 400 | bold lead-in (`prefix:` → `Builder.font(bold: true)`, AskText.swift:172-173) → **Bold 700** | change |
| "▸ Show …" link (`.more`) | 12, `--need-label` #9a6a00, underline, offset 2; defined in CSS, not used in the CM markup | not found (no fold in the need box) | n/a (to add) |
| Inline bold (`<b>`) | 600 (B `.body b`) | `**…**` → Bold 700 in the AppKit path (AskText.swift:236) | change |

### 2.6 Table inside the need

Mockup (decision: "styled as in mockup B"): B `table.t`, `.t th`, `.t td`, `.t td.num`, `.t .muted` (B tokens lines 79-83). CM's own `table.t` (CM:85-87) is the artifact table (12 px, collapsed borders), shown here for reference. Swift on the request page: `NSTextTable` in `AskText.swift:324-351` (commentable path). The SwiftUI fallback `AgentMarkdownText.table` (Review/AgentMarkdownText.swift:77-107) is used where no comment hub is set.

| Property | Mockup B | Swift (`AskText.swift`) | |
|---|---|---|---|
| Outer border | 1 `--line`, around the table only (`border-collapse: separate`) | 1 `line` on **every cell** (vertical lines too), collapsed (:327, 338-339) | change |
| Outer radius | 10, `overflow: hidden` | 0 (NSTextTable has none) | change |
| Row lines | `border-top: 1px --line` on body cells, no vertical lines | every cell border (:338) | change |
| Header background | `--side` | `side` (:340) | same |
| Header weight / color | 600, `--ink` | bold → **700** (:344, rule 3), color = need detail color `ink2` | change |
| Body cell background | #fff (table bg) | white 60 % (:340) on honey = tinted | change |
| Body text color | `--ink2` | `ink2` (details color) | same |
| Font size | 13.5 (B page) ; CM artifact table 12 | the need detail size: pane 15, full size 12 | change (pick one size for the 13 px box; 12 or 13 suggested) |
| Cell padding | 8 top/bottom, 12 sides | 5 top/bottom, 10 sides (:334-337) | change |
| Numbers right-aligned | `.num`: `text-align: right`, `nowrap` | not found (all cells left) | change |
| Muted cell | `.muted` `--quiet` | not found | change |
| Margin | 4 top, 16 bottom | 8 to the next block (`blockGap`, :354-359) | change |
| SwiftUI fallback (reference) | — | radius 12, border 1 `line2`, row line `line`, padding 6/10, header semibold (600) (AgentMarkdownText.swift:77-107) | — |

### 2.7 "YOUR CHOICE" label (`.ol`)

Mockup: `.ol`, `.ol u` (CM:127-128). Swift: not found for a single-choice ask. Pick-several shows `PickSeveralHeaderView` (Composer/PickSeveralHeaderView.swift, via ComposerCardView.swift:258, 298-303).

| Property | Mockup | Swift | |
|---|---|---|---|
| Exists | yes, over the option list, all cases | no (single); multi: "Pick up to N" header | n/a (to add) |
| Font | Inter Tight 600 10.5, line height 1 | nearest token `labelCaps10_5w600` (Theme.swift:189-192): 600 10.5, **tracking 0.5** | — |
| Letter spacing | 0.06 em = 0.63 | (token 0.5) | change if the token is reused |
| Transform | uppercase | — | — |
| Color | `--quiet` | multi header `ink3` 11.5/400 (`caption11_5w400`) | change |
| Margin below | 8 | — | — |
| Right link (`.ol u`) | no transform, 0 tracking, 500 12 `--ink3`, underline offset 2 | multi "Clear" etc. 11.5/400 `ink2` | change |

### 2.8 Option card, closed (`.choice` + `.ch.slim` + `.tl`)

Mockup: `.choice`, `.ch`, `.ch.slim`, `.ch b`, `.key`, `.tl` (CM:129-149). Swift: `CompactOptionRow` (Composer/CalmOption.swift:284-503), via `OptionChipView` (`isCalm` is always true, Composer/OptionChipView.swift:49) from `ComposerCardView.optionRowList` (Composer/ComposerCardView.swift:254-295).

| Property | Mockup | Swift | |
|---|---|---|---|
| Border | 1 `--line` | 1 `line` (CalmOption.swift:374-379) | same |
| Radius | 10 | `CalmOption.rowRadius` = 12 (:14, 373) | change |
| Background | none (white) | `win` (:319-321) | same |
| Gap between cards | 6 (`.choice` margin-bottom) | 8 (ComposerCardView.swift:257) | change |
| Row padding | slim: 7 top/bottom, 12 sides; open: 9/12 (`.ch.slim`, `.ch`) | 8/12 always (:370) | change |
| Row item gap | 10 | 10 (:339) | same |
| Row cross alignment | center | center (HStack default) | same |
| Leading mark | radio 16 (box 16 when pick-several) | number chip 24 × 24 (`CalmNumberChip`, :266-279; check box 22 slot in front of it when pick-several) | change (§2.11) |
| Title family / weight | Inter Tight 600 | `value13_5w600` (Theme.swift:193-196): Inter Tight 600 (SwiftUI) | same |
| Title size | 13.5 | 13.5 | same |
| Title line height | 1.45 → 19.6 | natural 16.3 (lineHeight nil) | change |
| Title tracking | 0 | nil | same |
| Title color | `--ink` | `ink` (:344) | same |
| Title wrap | not set (wraps) | up to 3 lines (:347; `rowTitleLines` :32) | same |
| Recommended tag place | right after the title (gap 10) | after a `Spacer(minLength: 6)`, on the right before the counts (:350-363) | change (§2.12) |
| Key badge place | right edge (`margin-left: auto`) | none on the right; number chip on the left | change (§2.13) |
| Height (derived, one-line title) | 7 + 19.6 + 7 + 2 border = 35.6, plus `.tl` row 17.4 + 9 = 26.4 → ≈ 62 | 8 + 24 + 8 = 40 (chip and icon buttons 24) | change |
| Second line (`.tl`) | first pro, first con, "+N" (§2.15) | none; ✓N ⚠N counts in the row (:364-366) | change (§3) |
| Recommended, not picked | plain card + tag | honey edge `honey500` 40 % + tint `honeySoft` 45 % (`softMark`, :33-34, 315, 320, 378) | change |
| Leaning | not in the mockup | fill `dsSoft`, stroke `ds` 1.5 (:320, 377-379) | keep (no mockup) |
| Ruled out | not in the mockup | opacity 0.55 + strikethrough title (:16, 345, 382) | keep (no mockup) |
| Locked, other rows | not in the mockup | opacity 0.45 (:382) | keep |

### 2.9 Option card, picked / open (`.choice.on` + `.x`)

Mockup: `.choice.on`, `.x`, `.x .d`, `.pc`, `.pc div::before`, `.x .because` (CM:130, 139-144; B `.expand`, `.grid`, `.because` for the larger B values). Swift: the picked row is the same closed `CompactOptionRow`; it never opens (`CalmOption.rowsExpand = false`, CalmOption.swift:13). Description, pros, cons and the reason show only in the hover tooltip `OptionTooltipView` (:584-602) and, for a folded earlier round, in `YourPickBlockView` (:634-696).

| Property | Mockup | Swift (picked row; tooltip for the open parts) | |
|---|---|---|---|
| Border | 1 `--honey500` + `box-shadow 0 0 0 1px --honey500` → 2 pt honey | 1.5 `honey500` (:376-379) | change |
| Background | #fffdf5 | `honeySoft` #FDF4DA (:320) | change |
| Opens under the title | yes | no | change (§3) |
| Body padding | 0 right 12, bottom 11, left **38** (aligned with the title) (`.x`) | tooltip: 14 all sides, 320 wide (:599-600) | change |
| Body font | Inter Tight 400 12, `--ink2`, line height 1.45 | description `body13w400` 13 / 1.45 on top of 1.21, `ink2` (`OptionText`, :257-263) | change |
| Description margin below | 6 (`.x .d`) | tooltip VStack spacing 10 (:593) | change |
| Pros/cons layout | 2-column grid, pros and cons interleaved, gap 3 row / 14 column (`.pc`) | `GoodWatchOutView`: two lists side by side, HStack spacing 28 (:145), or stacked with spacing 10 in the tooltip (:150) | change |
| Pros/cons titles | none | "Good" / "Watch out", 11.5 semibold, list color (:165-168) | change |
| Pro mark | "+" 600, `--pro` #0e7a43, margin-right 5 | 6 × 6 dot, `Theme.Colors.ok` #18A058 (:146, 171) | change (glyph + color) |
| Con mark | "–" 600, `--watch` #c2410c | 6 × 6 dot, `AskDoc.watch` #C2410C (:147, 171) | change (glyph) |
| Pro/con text | 12, `--ink2` | `optionCard13`: 13, line height 1.4 (AskDocTheme.swift:68), `ink2` (:173) | change |
| Line gap in a list | 3 | 5 (:164) | change |
| "Why I recommend it" | inline text "Why I recommend it: …" 12 `--ink3`; margin-top 7, `border-top: 1px dashed --line2`, padding-top 6 (`.x .because`) | `CalmNoteView`: title 11.5 semibold `ink3` on its own line, text 12.5 `ink2`, padding 9/12, background `list` #FAFAFA, radius 10 (:221-243) | change |
| B sizes (reference) | B: body 13.5, grid 13 gap 6/24, because 13 margin-top 12 padding-top 10, padding 0 16 16 46 | — | CM wins |

### 2.10 First pro / first con line (`.tl`)

Mockup: `.tl`, `.tl span::before`, `.tl .p/.c`, `.tl .n` (CM:145-148). Swift: not found; the row shows count marks instead (`countMark`, CalmOption.swift:480-494).

| Property | Mockup | Swift (count marks) | |
|---|---|---|---|
| Exists | yes, on every closed card | no; ✓N ⚠N →N icons in the title row | change (§3) |
| Padding | 0 right 12, bottom 9, left 38 | — | — |
| Gap | 14 | marks: HStack spacing 3 inside, row spacing 10 | — |
| Font | Inter Tight 400 12, `--ink2`, `nowrap`, cut | count: `tagLabel10_5w500` 10.5/500 + SF symbol 11 semibold (:482-483) | change |
| Pro mark | "+" 600 `--pro`, margin-right 4 | SF `checkmark.circle`, `ok` #18A058 (:364) | change |
| Con mark | "–" 600 `--watch` | SF `exclamationmark.triangle`, `watch` (:365) | change |
| "+N" more | `--quiet` | — (effects: SF `arrow.right` `ink3`, :366) | change |

### 2.11 Radio and check box

Mockup: `.radio`, `.box`, `.on .radio::after`, `.on .box::after` (CM:132-135). Swift: no radio (number chip `CalmNumberChip`, CalmOption.swift:266-279); check box `CheckBoxMark` (Composer/OptionChipView.swift:175-197).

| Property | Mockup | Swift | |
|---|---|---|---|
| Radio size | 16 × 16 | not found (chip 24 × 24, radius 7) | change |
| Radio border | 1.5 `--line2`; on: 1.5 `--honey600` | chip stroke 1 `line`; on: 1 `honey600` + fill `honey500` (:275-277) | change |
| Radio dot (on) | 8 × 8 `--honey600` | — (chip shows the number, mono 600 12 ink) | change |
| Box size | 16 × 16 | 17 × 17 in a 22 × 22 slot (OptionChipView.swift:177, 183, 196) | change |
| Box radius | 4 | 5 (:178) | change |
| Box border | 1.5 `--line2`; on: `--honey600` | 1.5 `line2`; on: none (:186) | change |
| Box fill (on) | `--honey600` | `honey500` (:182) | change |
| Box tick | "✓" 11, white, line height 1 | SF `checkmark` 9 bold, `ink` (:190-192) | change |
| Number beside the box | none (key on the right) | number chip also shown next to the box (CalmOption.swift:340-341) | change |
| Nearest existing token | `Theme.Stroke.radioUnselected` = line2 @ 1.5 (Theme.swift:705); `Theme.Spacing.radioSize` = 14 (Theme.swift:773) | — | radioSize ≠ 16 |

### 2.12 "★ Recommended" tag (`.rec`)

Mockup: `.rec` (CM:137). Swift: `CompactOptionRow.chip` (CalmOption.swift:466-477), text at :356.

| Property | Mockup | Swift | |
|---|---|---|---|
| Text | "★ Recommended" | "✦ Recommended", or "✦" alone when tight (:48-53, 355-361) | change (glyph) |
| Family | Inter Tight | Inter Tight | same |
| Weight | 600 | 500 (`tagLabel10_5w500`, Theme.swift:326-329) | change |
| Size | 10.5, line height 1 | 10.5, natural 1.21 | change (line height) |
| Color | `--rec-text` #c98a00 | `recommendedTagText` #C98A00 | same |
| Background | `--honey-soft` | `honeySoft` | same |
| Radius | 5 | `Capsule()` (:473) | change |
| Padding | 3 top/bottom, 6 sides | 2 / 8 (:471) | change |
| Height (derived) | 16.5 | 12.7 + 4 = 16.7 | ≈ same |
| Place | right after the title | right side, after the spacer (:350-363) | change |
| B (reference) | `.rec-tag` 600 11, padding 4/7, radius 5 | — | CM wins |

### 2.13 Key badge (`.key`)

Mockup: `.key` (CM:138). Swift: `CalmNumberChip` (CalmOption.swift:266-279), the nearest part; it sits on the left.

| Property | Mockup | Swift | |
|---|---|---|---|
| Place | right edge of the row (`margin-left: auto`) | left, before the title (:341) | change |
| Family | JetBrains Mono 400 | JetBrains Mono **600** (`keyBadge12w600`, Theme.swift:610-613) | change |
| Size | 10.5, line height 1 | 12 | change |
| Color | `--quiet` | `ink` (:273) | change |
| Border | 1 `--line2` | 1 `line`; picked `honey600` (:277) | change |
| Fill | none | none; picked `honey500` (:275) | change |
| Radius | 5 | 7 (:276) | change |
| Padding / size | 3 / 5 → ≈ 18.3 × 18.5 (derived) | fixed 24 × 24 (:274) | change |

### 2.14 Lean ◐ and Rule out × (no mockup)

Decision: always visible, next to the key, on each card. Today's values, `DiscussIconButton` (CalmOption.swift:530-581), placed by `discussMarks` (:440-447) at the end of the row (:368).

| Property | Swift today | Note |
|---|---|---|
| Hit area | 24 × 24 circle (:568, 572) | taller than the mockup's 18.5 key; sets the row height to 40 |
| Gap between the two | 2 (:442) | — |
| Place | after the counts, last in the row | decision: next to the key, right edge |
| Lean icon | 13 × 13: circle stroke 1.2 + right half filled; off `ink3`, on `ds` #2B59F0 (:553-558) | `ds` ≠ `--link` |
| Rule out icon | SF `xmark` 10 semibold `ink3`; on: 16 circle `watch` with SF `xmark` 8 bold white (:559-565) | — |
| Hover | `hover` #F0F0F0 fill (:569) | — |
| Focus ring | 2 `ds` (:571) | — |
| Suggested match | size the hit area to the key height (≈ 18.5) and use `--quiet` for the off state, so the icons read as the same family as the key | proposal, not in the mockups |

### 2.15 Answer box: field

Mockup: `.ans`, `.ans .bar`, `.note`, `.note.typed` (CM:150-153). The decision keeps the field on its own row (B / operator), with tools left and Send right under it. Swift: `ComposerCardView` reply part (Composer/ComposerCardView.swift:143-145, 343-356) → `PromptBarView` → `PromptBarCore` (Composer/PromptBarView.swift:257-412); field on its own row always (`fieldOnOwnRow` → true, :316).

| Property | Mockup | Swift | |
|---|---|---|---|
| Area top line | 1 `--line`, full column width | 1 **`line2`** (ComposerCardView.swift:145), only between the column insets (CasePaneView.swift:487) | change |
| Area shadow | none | `Shadow.dockUp` 0 −6 blur 16, ink 6 % (ComposerCardView.swift:144; Theme.swift:725) | change |
| Area padding | 10 top, 14 sides, 12 bottom | 10 all sides (`barPadding`, PromptBarView.swift:356; PromptBarLogic.swift:14) inside the column inset (12/24 leading, 24 trailing) | change |
| Field border | 1 `--line2` | none (no border on the field) | change |
| Field radius | 9 | none | change |
| Field padding | 8 top/bottom, 11 sides | text inset 5 / 4 (`textInset`, PromptBarLogic.swift:12; PromptBarView.swift:64) | change |
| Placeholder font | Inter Tight 400 12.5, `--quiet` | Inter Tight 400 **13.5**, **`ink3`** (PromptBarView.swift:389-390) | change |
| Typed text | 12.5 `--ink` (`.note.typed`) | 13.5 `ink`, fixed line height 18 (PromptBarView.swift:55-62; PromptBarLogic.swift:9, 37-44) | change |
| Line height | 1.45 → 18.1 | 18 fixed | ≈ same |
| Field height, one line (derived) | 18.1 + 16 + 2 = 36.1 | 18 + 10 = 28 | change |
| Wrap | CM: one line, ellipsis | grows to 40 % of the column, then scrolls (C6) | keep (spec C6) |
| Field → tools gap | B: tools margin-top 12 (`.side-tools`); CM tools margin-top 8 | `rowGap` 6 (PromptBarLogic.swift:16) | change |

### 2.16 Tools row (Let's discuss · Show me more · Ask for…)

Mockup: `.ans .tools`, `.ans .tools .k` (CM:156-157); B `.side-tools` (B inplace line 197). Swift: left group attach "+" and "Ask for…" (PromptBarView.swift:339-348); right group quiet buttons + Send (:350-354).

| Property | Mockup | Swift | |
|---|---|---|---|
| Items | CM: "Let's discuss", "Ask for…", then right meta; B: "Let's discuss", "Show me more", "Ask for…", right status | "+" attach, "Ask for…"; then on the right quiet buttons (Open review, plan "Change"), overflow "⋯", Send | change (§3) |
| Font | Inter Tight 400 12, `--ink3` (B: 12.5) | `promptButton12w500`: 12, **500**, **`ink2`**, hover `ink` (:692-693; Theme.swift:206-209) | change |
| Item gap | 14 | `controlGap` 6 (PromptBarLogic.swift:15) + 8 side padding per button (:697) | change |
| Item shape | plain text, no box | 28 high, radius 8, hover fill `hover` (:698-700) | change |
| Attach "+" | not in the mockup | SF `plus` 13 semibold `ink3`, 28 × 28, radius 7 (:816-821) | keep (no mockup) |
| Right meta (`.k`) | JetBrains Mono 400 11, `--quiet`: "↵" or "2 picked" | not found in the row | change |

### 2.17 Send button

Mockup: `.send`, `.send.off` (CM:154-155); B `.send` (B:86). Swift: `PromptBarCore.sendButton` (PromptBarView.swift:440-471).

| Property | Mockup | Swift | |
|---|---|---|---|
| Label | "Send: B · Options in place", "Send 3 answers", "Send 2 of 4"; decision: "Send: <option> ↵" | "Decide", "Decide: 2 picked", "Ask", etc. (`PromptBarLogic.sendPillLabels`, PromptBarLogic.swift:485-525) | change (words) |
| Family / weight | Inter Tight 600 | Inter Tight 600 (`promptSend12w600`, :449; Theme.swift:211-214) | same |
| Size | 12.5 (B: 13) | 12 | change |
| Line height | 1.45 → 18.1 | fixed 28 frame | — |
| Color | #fff | `win` when it can send, **`ink2`** when not (:444) | change (off state) |
| Background | `--ink`; off: `--line2` | `ink`; off: `line2` (:461) | same |
| Radius | 8 | `Radius.promptButton` 8 (:462; Theme.swift:658) | same |
| Padding | 8 top/bottom, 12 sides (B: 8/14) | 0 / 10, height fixed 28 (:458-460) | change |
| Height (derived) | 18.1 + 16 = 34.1 | 28 | change |
| Arrow | "↵" in the label text (decision) | SF `arrow.up` 12 bold, only with no label or with comments (:452-455) | change |
| Place | CM: right of the field, same row; decision: right of the tools row | right of the tools row (PromptBarRowLayout, :782-790) | same (decision) |

### 2.18 Status / meta at the right

Mockup: CM `.tools .k` (mono 11 `--quiet`, CM:157); B "✓ Round 1 delivered 15:01" in `.pro` color, 12.5 (B inplace line 252); CM top bar pills `.pill.waiting` (500 12/1, `--need-label` on `--honey-soft`, radius 20, padding 4/10, CM:64, 67) and `.pill.closed` (CM:65-66). Swift: `RequestStatusLineView` (Queue/RequestStatus.swift:280-441), in the context line above the tabs (CasePaneView.swift:732-744) and in the card once sent (ComposerCardView.swift:136-140).

| Property | Mockup | Swift | |
|---|---|---|---|
| Place | bottom row, right (B, CM `.k`); waiting / session pills in the top bar (CM) | context line above the tabs (pane) | change |
| Family | Inter Tight (B) / JetBrains Mono (CM `.k`) | **system font SF** 12.5 (:346, 350) | change |
| Weight | 400 (B text in `.pro`) | 500, 600 when failed (:346) | change |
| Size | 12.5 (B) / 11 (CM `.k`) | 12.5 | same (B) |
| Color | `--pro` #0e7a43 (B delivered); `--quiet` (CM `.k`) | `ink` text, `ok` #18A058 SF `checkmark.circle.fill` icon (:363-366) | change |
| Meta | — | mono 400 11 `ink3` (`monoMeta11w400`, :335-337) | — |
| Buttons | CM `.pill.closed button`: 600, `--ink`, underline | 12.5/500, padding 4/10, radius 7, `win` + 1 `line2` border, primary `ink` fill (:424-434) | change |
| Failed state | not in the mockups | `statusFailedFill` box, radius 8, padding 8/10/8/8 (:312-315) | keep |

### 2.19 "Latest agent message" line (`.latest`)

Mockup: `.latest`, `.latest .who`, `.latest .txt`, `.latest u` (CM:106-109), first in the scroll of the `multi` case. Swift: `LatestAgentMessageLine` (Queue/ConversationTab.swift:419-451), placed above the tabs by `DecisionColumnHeader` (:467-470).

| Property | Mockup | Swift | |
|---|---|---|---|
| Place | inside the scroll, under the tabs, margin-bottom 12 | above the tabs, spacing 10 (:467) | change |
| Background | #f4f6fd, radius 8 | none | change |
| Padding | 7 / 10 | none | change |
| Gap / alignment | 8, baseline | 6, first-text baseline (:427) | change |
| Who | JetBrains Mono 400 10.5/1, `--link`, "CLAUDE · 15:21" (upper case) | mono 400 10.5 `ink3`, "Claude Code · 15:21" (:431-435) | change |
| Text | Inter Tight 400 12, `--ink2`, one line, ellipsis | 12.5 `ink2`, one line, tail (:436-441) | change (size) |
| "Read" link | `--link`, underline offset 2 | not found (the whole line is the button) | change |

### 2.20 Step bar (`.steps`)

Mockup: `.steps`, `.steps span`, `.ok`, `.on`, `.steps em` (CM:116-120). Swift: `StepBarView` (AskDoc/StepDecisionViews.swift:6-50).

| Property | Mockup | Swift | |
|---|---|---|---|
| Cell size | 24 × 24 | 24 × 24 (:46) | same |
| Radius | 7 | 6 (:36) | change |
| Border | 1 `--line2`; done `--ok`; current `--ink` | none (:35-37) | change |
| Fill | none; current `--ink` | `side`; done `okSoft`; current `ink` (:37) | change |
| Number | Inter Tight 400 12, `--ink3`; current white | `countPill11_5w700` 11.5 **700** `ink2`; current white (:41-43; AskDocTheme.swift:77) | change |
| Done mark | "✓" text in `--ok`, 12 | SF `checkmark` 10 bold `ok` (:39) | change |
| Gap | 6 | 6 (:10) | same |
| Margin below | 8 | VStack spacing 14 (CasePaneView.swift:885) | change |
| Trailing text | "Question 3 of 3 · then Send", `--quiet`, margin-left 4 | not found; a "Send" capsule pill instead (:25-33) | change |

### 2.21 Conversation tab messages

Mockup: `.msg`, `.msg .h`, `.msg.agent`, `.msg.you`, `.msg.you .h`, `.msg.latestm`, `.msg p`, `.round` (CM:160-167). Swift: `ConversationTabView` / `ConversationMessageView` / `ConversationText` (Queue/ConversationTab.swift:189-314).

| Property | Mockup | Swift | |
|---|---|---|---|
| Message gap | 8 (margin-bottom) | 18 (:203, 207) | change |
| Scroll padding | `.cs` 14 / 18 / 10 | top 4, bottom 16, sides = column insets 12/24 + 24 (:218; CasePaneView.swift:520) | change |
| Agent background | `--side`, radius 10, padding 9/12 | none, no padding (:280-281) | change |
| Your background | `--ink`, text #fff | `side`, text ink (:281) | change |
| Your indent | margin-left 40 | leading 40 (:289) | same |
| Your padding | 9 / 12 | 8 top, 12 sides, 9 bottom (:280) | change |
| Radius | 10 | `Radius.conversationBubble` 10 (:282) | same |
| Body font | Inter Tight 400 12.5, line height 1.5 → 18.75 | `body13w400` 13, line height 1.45 on top of 1.21 (:299) | change |
| Paragraph gap | 6 | 6 (:303) | same |
| Agent lead sentence | bold only where the text has `<b>` (600) | first paragraph semibold (`ConversationText`, :304-306) via `AgentMarkdownText`; 600 in SwiftUI, 700 if it goes through the commentable path | change |
| Header | JetBrains Mono 400 10.5/1, `--quiet`; two parts justified left/right ("YOU · 15:20" … "picked up 15:20"); margin-bottom 6 | mono 400 10.5, `ink3`, one string; "✓ picked up …" as a footnote under the bubble (:274-276, 283-287); spacing 4 | change |
| Your header color | #aaaaaa | `ink3` | change |
| Latest message | background #f4f6fd + inset 2 pt bar `--link` on the left | not found | change |
| Round divider | "round 2 · v2 of the artifact", mono 10.5/1 `--quiet`, centred, margin 10 | not found ("v2" is in the message header, :156-160) | change |
| "Copy" on the latest | right side of the header | removed on purpose (commit 19a26b7) | keep (decision) |
| Turn line | not in the mockup | `AgentStatusLine` + timer (:244-260) | keep |
| Answer area under the tab | the same `.ans` stays | the same dock stays (CasePaneView.swift:483-488) | same |

## 3. Structure differences

Present in the app, not in the mockups:
- ✓ N / ⚠ N / → N count icons on each option row (CalmOption.swift:364-366). The decision rules them out ("not in the mockups").
- The number chip on the left of every row (CalmOption.swift:341), also beside the check box when pick-several (:340).
- Lean ◐ and Rule out × on each row (kept by the decision; no mockup values, §2.14).
- Honey edge and tint on the recommended row before any pick (`softMark`, CalmOption.swift:315, 320, 378).
- The context line and the status above the tabs in the pane (CasePaneView.swift:464-465); the latest-message line above the tabs (ConversationTab.swift:467-470).
- Status line in SF with SF Symbol icons and bordered buttons (RequestStatus.swift:280-441).
- The "+" attach button in the answer row (PromptBarView.swift:340, 810-830) and the "⋯" overflow menu (:711-737).
- The answer area's upward shadow (ComposerCardView.swift:144).
- Comments count as an accent pill on the Comments tab (ReviewColumnTabsView.swift:61-69).
- "Good" / "Watch out" headings with dots, and the reason as a grey card (`GoodWatchOutView`, `CalmNoteView`), only in the hover tooltip.
- A "Send" capsule in the step bar (StepDecisionViews.swift:25-33).
- The 28 pt title on a pane with no artifact (`AskHeaderWidth.wide`, AskDocPage.swift:197-201); the mockups only show the 440 pt column with 19 pt.
- The turn line ("Your turn · waiting 3m") at the end of the Conversation tab (ConversationTab.swift:244-260).

Present in the mockups, not in the app:
- The radio (single) and the 16 pt box with a white ✓ (pick-several) as the leading mark.
- "★ Recommended" right after the title.
- The key badge on the right edge (mono 10.5, quiet, bordered).
- The picked card opens in place: description, pros and cons in a 2-column grid with + and – marks, a dashed line, "Why I recommend it: …" inline.
- The first pro, first con and "+N more" line under every closed card.
- The "YOUR CHOICE" caps label above the options.
- A bordered, rounded answer field (border line2, radius 9).
- "Let's discuss" and "Show me more" in the tools row; the right-side meta ("↵", "2 picked", "✓ Round 1 delivered 15:01").
- Send labels that name the pick ("Send: <option> ↵", "Send 2 of 4", "Send 3 answers").
- The "▸ Show …" fold link in the need box (`.need .more`, CSS only).
- Need tables with an outer radius, no vertical lines, and right-aligned numbers.
- The plan track as numbered circles joined by lines; the step bar's "Question 3 of 3 · then Send".
- The latest agent message as a blue box with "Read" inside the scroll.
- Conversation bubbles for the agent (side fill) and an ink bubble for you; the blue bar on the newest message; the "round 2 · v2" divider.
- A count on the Conversation tab ("Conversation 3").
- The column's 1 pt left border.
- The B eyebrow (`.ctx`, mono caps, quiet) when the top bar does not carry the project.

## 4. Files and line ranges that will need changes

| File | Lines | What |
|---|---|---|
| `Theme/Theme.swift` | 11-105, 130-631, 646-693, 708-730 | new tokens `needBg` #FBF3D9, `link` #2F5BD8, `pickedFill` #FFFDF5, `latestFill` #F4F6FD, `whyLine` #EFE2B8; mockup type styles (tab 13/500, title 19/600 −0.38, need 13 / 13.5 600, why 12, label caps 10.5 / 0.63, key mono 10.5, rec 600 10.5, option body 12, note 12.5, send 12.5/600); radius 9/7 tabs, 10 cards and need, 5 tag; shadow blur 2 |
| `Theme/AskDocTheme.swift` | 27-34, 45-79 | `Radius.need` 14 → 10, `optionCard` usage; `why13_5`, `need17` not used in the column |
| `Composer/PromptBarLogic.swift` | 9-16, 28-35, 485-525 | `sansFont` must map semibold to InterTight-SemiBold, not the bold trait; bar padding / gaps; Send label words |
| `Review/Comments/AskText.swift` | 230-239, 264-271, 324-359 | font weights (rule 3), line height (rule 1), the need table (outer border, radius, no vertical lines, 8/12 padding, right-aligned numbers, header 600 ink) |
| `Review/AgentMarkdownText.swift` | 77-107 | same table look on the SwiftUI path |
| `Review/ReviewColumnTabsView.swift` | 19-69 | track radius, segment padding/radius, label 13/500 ink3, shadow, mono count on Conversation, dot color |
| `Queue/ConversationTab.swift` | 189-314, 419-477 | latest line as a blue box under the tabs with "Read"; message bubbles, header, gaps, latest bar, round divider |
| `Queue/CasePaneView.swift` | 405-406, 459-490, 777-834, 849-857, 883-913, 939 | column insets 14/18/14, left border, tabs first, context line under the tabs, VStack gaps 10/14/8/6, `NeedCalloutView` compact in the column, 19 pt title |
| `Review/AskColumnView.swift` | 61-95, 102-177 | the same insets and gaps in full size |
| `Queue/RequestContextLine.swift` | 30-35, 120-215, 220-255 | "↩", 12 pt title, lower-case "you chose", Show in ink3, gap 6, plan track circles |
| `AskDoc/AskDocPage.swift` | 58-116, 177-203, 274-310 | need box (bg, radius 10, padding 11/13, 13 / 13.5 600, ink, why 12 no bold prefix, #efe2b8 line, "▸ Show" fold); title style 19/600/1.25/−0.38 |
| `Queue/RoundHeading.swift` | 124-159 | round tag / eyebrow look |
| `Composer/CalmOption.swift` | 10-53, 133-279, 284-503, 517-581 | the card: radio/box, title, tag beside the title, key on the right, Lean/Rule out next to the key, radius 10, padding 7-9/12, picked fill/border, open body (desc, + – grid, dashed "Why I recommend it"), `.tl` line; drop counts and soft mark |
| `Composer/OptionChipView.swift` | 49, 71-83, 175-197 | check box 16 / radius 4 / honey600 / white ✓ |
| `Composer/ComposerCardView.swift` | 143-145, 189-303 | "YOUR CHOICE" label, card gap 6, answer area top line `line` full width, no shadow |
| `Composer/PickSeveralHeaderView.swift` | whole view (~15-40) | fold into the `.ol` label row |
| `Composer/PromptBarView.swift` | 47-70, 337-471, 681-708 | bordered field (line2, radius 9, padding 8/11, 12.5 quiet placeholder), tools as plain 12 ink3 text with gap 14 ("Let's discuss", "Show me more", "Ask for…"), right meta, Send 12.5/600 padding 8/12 with "↵" |
| `Composer/ComposerFooterView.swift` | 60-100 | the same answer area for reply-only asks |
| `Queue/RequestStatus.swift` | 280-441 | Inter Tight instead of SF; delivered in `pro`; place at the bottom right or top bar pill |
| `AskDoc/StepDecisionViews.swift` | 6-50 | step cells: radius 7, border, 12/400 ink3, "Question n of N · then Send" |
| `Plan/AskArtifactLayout.swift` | 19 | 440 includes the 1 pt border (content 403) |

## 5. Not resolved

- Exact rendered line heights are derived from the hhea metrics (Inter Tight 1.2100, JetBrains Mono 1.32), not measured in a running app. Check with the side-by-side render the decision asks for.
- `Font.custom("Inter Tight").weight(.semibold)` in SwiftUI is taken to resolve to InterTight-SemiBold; only the AppKit path was checked (it gives Bold).
- Whether `AgentMarkdownText` in the Conversation tab goes through the commentable (AppKit) path: it has no `target`, so it should be the SwiftUI path (600), not verified at runtime.
- The `AnswersBarView` (stepped asks' answer area, `AskDoc/AnswersBarView.swift`) was not audited line by line; it should take the §2.15-2.17 values too.

## 6. Window chrome: sidebar, top bar, page header, artifact card

Date: 2026-11-10 · Branch `request-page-simplify` (base `fd204f7`). Second pass: the operator wants the whole window as the mockups, not only the column.

Sources: **B** = `index.html` tokens (`.side`, `.side-head`, `.brand`, `.mark`, `.sec`, `.row`, `.row-t`, `.row-m`, `.row.sel`, `.row.done`, `.side-foot`, lines 52-70) and template `inplace` (`.ctx`, `h1`, `.page`). **CM** = case map tokens (`.side` … `.side-foot` lines 43-56, `.top`, `.pill`, `.ico` lines 58-68, `.art`, `.card`, `.card-h`, `.tab-a`, `.ver`, `.btn-s` lines 70-79). Rule: CM wins for the layout with an artifact, B for the layout without one. The sidebar is the same in both layouts (it must not jump when you move between cases), so it follows **B**, the one the operator described ("selected row white with honey left bar", "ANSWERED TODAY · N … Show all N"); CM-only parts (`.needs` + `.count`, the "›" fold) keep CM values.

All new values are in `Theme/ChromeTheme.swift` (`Theme.AskDoc.Chrome`), drawn with `Theme.AskDoc.Column.css` (exact bundled face through `PromptBarLogic.sansFaceName`, line height through `Theme.Typography.cssLineSpacing`). "Before" = the Swift value at `fd204f7`.

### 6.1 Sidebar frame and header (`.side`, `.side-head`, `.brand`, `.needs`, `.count`)

| Property | Mockup | Swift before | |
|---|---|---|---|
| Width | B 300 (CM 280) | `Spacing.listColumnWidth` 392 (Theme.swift) | change → 300 |
| Fill | `--side` #f3f3f3 | `Colors.list` #FAFAFA (QueueListView.swift) | change |
| Right line | 1 pt `--line` | 1 pt `line` | same |
| Header padding | B 40 16 12 (CM 34 16 10) | top 30 under the traffic lights, 16 full screen; sides 18; bottom 12 (QueueHeaderLayout.swift) | change (top 40, sides 16) |
| Mark | 16, gap 7 to the wordmark | `WordmarkLockup` mark 18, gap 6.3 | change |
| Wordmark | 500 15, −0.03 em (−0.45) | `wordmark(15)`: `.weight(.medium)`, −0.035 em | change (exact Medium face, −0.45) |
| "Needs you" (CM `.needs`) | 600 14, ink | `sidebarHeader15w650`: 15, `.weight(.semibold)` | change |
| Count pill (CM `.count`) | 700 11, white on `--open`, padding 1 6, radius 9 | 11.5 bold, padding 1 7, capsule | change (size, padding) |

### 6.2 Section labels (`.sec`, `.sec button`)

| Property | Mockup | Swift before | |
|---|---|---|---|
| Font | 600 10.5/1, Inter Tight | `labelCaps10_5w600` (`.weight(.semibold)`, natural line) | change (exact SemiBold, /1) |
| Tracking | 0.06 em = 0.63 | 0.5 | change |
| Color | `--quiet` #8a8a8a | `ink3` at 70 % opacity (≈ #969696 on #FAFAFA) | change |
| Padding | 14 16 6 | 14 18 6 | change |
| Right word | B `.sec button`: 500 12/1, ink3, no caps ("Show all 271"); CM: caps "SHOW" | "SHOW" / "HIDE" in the caps style | change → "Show" / "Hide", 500 12 ink3 |
| Fold chevron | CM "›" in the label | SF chevron 9 semibold, ink3 70 % | change → 8 pt, quiet |
| Line above a fold header | none | 1 pt `line` | change (removed) |
| Day sections in Answered ("TODAY · 3") | B has one "ANSWERED TODAY · 6" | mono 10.5 ink3, padding 12 18 4 | change → `.sec` look |

### 6.3 Rows (`.row`, `.row-t`, `.row-m`, `.row.sel`, `.row.done`)

| Property | Mockup | Swift before | |
|---|---|---|---|
| Padding | B 9 16 (CM 8 16) | 11 18 11 14 (QueueRowView), 6 18 (Working rows), 8 18 (Answered rows) | change → 9 16 everywhere |
| Dot | 7, on the title's baseline, 1 up | 7, top-aligned + 6 down (5 on Working rows) | change (`sidebarDotOnBaseline`) |
| Dot to text | 9 | 10 | change |
| Title | 600 13.5/1.3 ink, wraps | `sidebarRow14w600`: 14, `.weight(.semibold)`, lineHeight 1.35 on top of 1.21 (≈ 1.56) | change |
| Title, answered (`.row.done`) | 500 13.5/1.3 ink2, wraps | Answered rows: 400 12.5 quiet, one line; waiting rows: the open style at 50 % opacity | change |
| Title, Working (CM inline 500) | 500 13, ink | `sidebarItem13w500`, one line | change → 500 13.5/1.3 ink, two lines |
| Meta | quiet 12 (/1.45), 2 under | `caption11_5w400` ink3, 3 under (Working: 11.5 ink3, 2 under) | change |
| Selected | B: white, inset 3 pt `--honey500` bar (CM: #fdf6e1 fill) | `honeySoft` fill, 3 pt **ink** bar | change → white + honey bar |
| Line between rows | none | 1 pt `line` (`line2` when selected) | change (removed) |
| Follow-up indent | — (no mockup) | +14 | same |

### 6.4 Footer (`.side-foot`)

| Property | Mockup | Swift before | |
|---|---|---|---|
| Padding | 12 16 | 10 18 10 10 (the gear is 28) | change → 10 16 10 10 with a 22 pt gear (same 44 row height as 12 + 20 text) |
| Line on top | 1 pt `--line` | same | same |
| Text | 400 12, ink3 | `daemonStatus11_5w500`: 500 11.5, ink2 | change |
| Dot | 7, gap 7 | 6, gap 10 | change |

### 6.5 Top bar, layout with an artifact (CM `.top`, `.pill`, `.ico`)

| Property | Mockup | Swift before | |
|---|---|---|---|
| Height | 46 | padding 12/12 around 12 pt text (≈ 40) | change → 46 fixed |
| Side padding | 18 | 24 | change |
| Gap | 10 (`.r` gap 12) | 14 | change |
| Crumb font | mono 400 11.5/1 | `monoMeta12w400` (12) | change |
| Project color | `.top b`: ink, 400 | ink3 | change |
| Separator | " / " | "  /  " | change |
| Times | "· arrived 15:24" in the same line, ink3 | separate text "Arrived … · waiting 3m", 14 apart | change |
| Wait | `.pill.waiting`: 500 12/1, need label on honey soft, padding 4 10, round | in the times text | change → pill (`TopBarPill`) |
| Icons | `.ico` ink3 14 | ⋯ 13 ink2 | change → 13, ink3 |
| Line under it | 1 pt `--line` | same | same |

### 6.6 Page header, layout with no artifact (B `.page` padding-top 44, `.ctx`, `h1`)

| Property | Mockup | Swift before | |
|---|---|---|---|
| Top bar | none; the page starts 44 down | the same bar as with an artifact | change → 44 high, no line, no crumb, only the right-hand controls |
| Eyebrow | `.ctx` mono 400 11.5/1, quiet, caps, "SAMPLE BLOG · IMAGE HOSTING · ROUND 2 · 15:00", 10 under | none (the crumb was in the bar; "ROUND 2" alone above the title) | change → `PageEyebrow`; the round tag over the title hides there (`roundTagInEyebrow`) |
| Title | 600 28/1.15, −0.03 em (−0.84) | 19 pt `.narrow` (column `h1`) in every layout | change → `AskHeaderWidth.wide` = `Chrome.pageTitle` |

### 6.7 Artifact card (CM `.art`, `.card`, `.card-h`, `.tab-a`, `.ver`, `.btn-s`)

| Property | Mockup | Swift before | |
|---|---|---|---|
| Card inset | 14 14 14 18 | 20 24 20 12 (CasePaneView.swift) | change |
| Border | 1 pt `--line` #e6e6e6 | `Stroke.card` 1 pt `line2` #D9D9D9 | change |
| Radius | 10 | `Radius.card` 12 | change |
| Header | 40 high, padding 0 10, gap 6, white, line under | padding 8 10 (≈ 44), gap 6, `list` fill, line under | change |
| Tab | 12.5, padding 5 9, radius 6, ink3 | `chip12_5`, padding 5 10, radius 9 | change |
| Tab, selected | side fill, ink, 500 | white fill, 1 pt line border, ink, 400 | change |
| One artifact | shown as the selected tab ("Case map") | kind icon + caps 10.5 caption | change → `ArtifactTabLabel` selected |
| Version | `.ver` mono 400 11/1, quiet | mono 10.5, ink3 | change |
| "Open full size ↗" | `.btn-s` 12, ink, padding 4 9, radius 7, 1 pt `--line2`, white | 500 12.5, ink2, padding 4 10 4 8, radius 6 | change |
| "Show changes" (CM `.btn-s`) | 12 | 600 12.5, 28 pt arrows radius 6 | change → 12, 24 pt arrows radius 7 |
| Thumbnails strip (`.thumbs`) | 52 high, 44 × 30 thumbs | `ScreenshotFilmstrip` (not changed) | not checked (needs a loaded artifact) |

### 6.8 App parts with no mockup counterpart (kept, styled with the nearest mockup element)

| Part | Nearest mockup element | Look now |
|---|---|---|
| Queue fold button (⌘[) next to the count | `.ico` | unchanged icon, in the header row |
| Session filter chip, offline banner, "CACHED · READ-ONLY" | `.sec` | the cached label takes `.sec` padding; chip and banner unchanged |
| Working fold "› WORKING · N … Show" | CM `.sec` + B `.sec button` | as §6.2 |
| In planning section and rows | `.sec`, `.row` (500 title) | as §6.2 / §6.3 |
| Decided for you fold and rows, "Change my mind" | `.sec`, `.row.done`, `.sec button` | fold as §6.2; title 500 13.5 ink2, "Chose: …" quiet 12, "Change my mind" 500 12 ink3 underlined |
| Answered rows' answer line ("you → B") and age | `.row-m` | one meta line "you → B · 16m ago", quiet 12 (the age was on the right) |
| Artifact kind icon on a row | `.row-m` (quiet) | plain 12 pt glyph, quiet, no grey tile |
| Unread comments dot | `.dot` | honey, 7 pt |
| Got it button on a done row | `.btn-s` | 12, padding 4 9, radius 7, line2, white |
| Delivery failed · Retry, Session closed mark | `.row-m` | 12 (accent / quiet) in the meta line |
| Footer gear (Settings), pixel status grid, "· N working" | `.side-foot` | gear 13 ink3 in 22 pt; "· N working" 12 ink3 |
| Agent name in the row meta ("· Claude Code ·") | `.row-m` | kept in the line |
| ← Home + esc, Share, Fold both, ⋯ in the top bar | CM `.back`, `.ico` | unchanged controls; ⋯ ink3 |
| Waiting pill on the page with no artifact | CM `.pill.waiting` | kept on the right of the 44 pt bar (B shows no status there) |
| Artifact Open menu chevron | `.btn-s` | inside the same bordered button |

### 6.9 Differences left (seen in the renders)

- B shows no Decision / Conversation / Comments tabs; the app keeps them (decision column, not in this pass), so the eyebrow sits under the tabs, not at the top of the page.
- B's page is 820 wide (756 of text); the column as a page stays `AskLayout.pageMaxWidth` 640 (decision column, not in this pass).
- B's summary under the title is 16/1.55 plain text; the app keeps the honey need box (column).
- Answered shows two labels ("ANSWERED · 3 … Hide", then "TODAY · 3") where B has one ("ANSWERED TODAY · 6 … Show all 271"); the app's fold and its day sections are kept.
- Row meta keeps the agent name ("Sample blog · Claude Code · just now"); B has "Sample blog · now". Answered rows show "you → Yes · 16m ago" instead of the project.
- Times read "9 Nov 11:00" (`KnockDateFormat.dateTime`) where the mockups show "15:24".
- The sidebar is 300 (B) in both layouts; CM draws 280, with 34 top padding and a #fdf6e1 selected row.
- The mark is the real waggle mark (with the w), not the mockup's plain honey hexagon.
