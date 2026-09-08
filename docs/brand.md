# Hark: persona and style guide

Hark is a hawk. Everything in this document follows from that one decision.

The name is the archaic imperative *listen*. The bird is the Red-tailed Hawk,
the falconer's first bird in North America: common, steady, unglamorous, and
better at its job than anything flashier. Hark is built by a falconer, and
the product should feel the way a good hawk feels on the fist. Quiet until it
is needed. Instant when it is. Never asking for attention it has not earned.

Style rule for everything here and everything derived from it: no em dashes,
ever. Rewrite the sentence with a comma, colon, period, or parentheses.

---

## 1. Persona

### 1.1 Who Hark is

| | |
|---|---|
| **Archetype** | The trained hawk. A working animal, not a pet and not a mascot. |
| **Temperament** | Attentive, fast, self-contained. It waits; it does not fidget. |
| **Relationship to the user** | Partner on the fist. The user leads, Hark responds. It never acts on its own and never leaves with anything. |
| **One-line promise** | Hold a key. Speak. Release. Clean text lands wherever your cursor is. |
| **Position** | The dictation tool that never sends your voice anywhere. |
| **What it is not** | Not an assistant, not a chatbot, not "AI-powered". It is a tool that hears. |

### 1.2 Voice

Hark speaks the way a falconer talks in the field: short, plain, in the
present tense, and only when there is something to say.

- **Second person, active verbs.** "Hold the key to dictate." Not "Dictation
  can be initiated by holding the key."
- **Short sentences.** One idea per sentence. A sentence beats a label with a
  colon.
- **Say what it did, not how it feels.** "Pasted 42 words." Not "Great job!
  Your transcript is ready." No exclamation marks in UI copy.
- **State the mechanism when it earns trust.** "Transcribed on the Neural
  Engine. Nothing left this Mac." The user's whole reason for choosing Hark
  is that claim, so make it checkable and repeat it where it matters.
- **Name the failure and the next move.** "The cleanup server is not
  answering. The raw transcript was pasted instead." Failures are stated,
  never apologised for.
- **Falconry vocabulary is a seasoning, not a language.** *Hark*, *call*,
  *listening*, *on the fist* are fine in headings and marketing. *Jesses*,
  *mews*, *manning*, *yarak* are not: the reader should never need a
  glossary.

Words we use: listen, hear, hold, release, on-device, local, your Mac,
nothing leaves. Words we avoid: AI-powered, magic, seamless, revolutionary,
smart, effortless, supercharge, unlock, delight.

### 1.3 Voice in practice

| Situation | Write | Not |
|---|---|---|
| Menu bar idle | Hark (mark only) | "Hark is ready!" |
| Listening | Listening… | "Recording your voice…" |
| After paste | (nothing; the text arriving is the feedback) | "Success! Text inserted." |
| Cleanup unavailable | Cleanup server not answering. Raw transcript pasted. | "Oops, something went wrong with AI cleanup." |
| No permission | Hark needs Accessibility to paste. Open System Settings. | "Please grant permissions to enable functionality." |
| Empty dictionary | No terms yet. Add names or jargon the transcriber keeps misspelling. | "Your dictionary is empty. Get started by adding your first term!" |
| Meeting stored | Meeting #12 stored. 3 speakers, 41 minutes. | "Your meeting has been successfully processed and saved!" |

### 1.4 Claims discipline

- **Do** say: fully local, on-device, nothing leaves your Mac unless you
  point cleanup at a cloud endpoint. The one exception is stated every time
  the claim is made.
- **Do** say: open source, MIT or Apache-2.0. (Unlike the sibling projects,
  Hark's license is OSI-approved, so the phrase is honest here.)
- **Do not** claim "the fastest" or "the most accurate". The defensible
  claim is *the one that never phones home and never needs an account*.
- **Do not** call the speech model "Hark's model". It is NVIDIA Parakeet via
  FluidAudio's Core ML conversion, CC-BY-4.0, and the credit is part of the
  product's honesty.

---

## 2. Identity

### 2.1 The Call

The mark is the outline of a Red-tailed Hawk's head in profile, beak open,
with the word HARK issuing from it. It is called **the Call**. The letters
grow as they travel: the sound is leaving the bird and reaching you.

Three forms, all drawn from one source (`docs/brand/source/`):

| Form | File | Use |
|---|---|---|
| **Lockup** | `lockup.svg` | Website header, README banner, OG card, anywhere there is horizontal room. The head and the word are one object; never separate them by more than their native gap, never re-kern the letters. |
| **Mark** | `mark.svg` | App icon, favicon, menu bar (template image), avatars, any square slot. The head alone, beak open. |
| **Wordmark** | The word set in text | Running prose, window titles, the About box. Set "Hark" in the system face, semibold. Do not reproduce the shouted letters as a typeface; they exist only as part of the Call. |

Rules:

- The mark is a single line weight. Never add a fill, a gradient, a shadow,
  or a second color inside the bird.
- It is always `currentColor`: ink on canvas in light mode, ivory on dark
  ground in dark mode, ivory on rufous for the app icon. Those three
  pairings are the whole set.
- Minimum size: the mark at 16 px (favicon), the lockup at 120 px wide. Below
  that use the wordmark.
- Clear space around the lockup is the height of the letter H on every
  side.
- The beak points right. Do not mirror the mark.
- Do not rotate it, outline the outline, or place it on a photograph.

### 2.2 App icon

The mark in ivory on a rufous rounded square, macOS-standard corner radius.
Rufous is the tail of the bird the icon does not show; the icon is the only
place the accent is used as a ground rather than a highlight. In the menu
bar the mark is a template image and takes the system's color.

### 2.3 Source and regeneration

The Call was drafted with an image model from the description "outline of a
Red-tailed Hawk, beak open, the word HARK coming from it", then traced to
vector with potrace and cleaned. The raw drafts are kept in
`docs/brand/raw/` for provenance. `tools/mark/build-assets.py` regenerates
every derived asset (icns, favicon, touch icon, OG card, README banner) from
the two source SVGs; edit the sources, run the script, commit the outputs.

---

## 3. Foundations

Hark shares its bones with the other projects in this family (warm neutrals,
system type, one accent, easeOutQuart), so the sites read as siblings. Its
own contribution is the accent: the hawk's tail.

### 3.1 Color

**Nothing is a pure grey.** `#1c1917` is not black, `#faf8f3` is not white,
and the muted tone leans toward the buff of a hawk's breast. Use a pure grey
anywhere and the whole system goes cold.

| Token | Light | Dark | Notes |
|---|---|---|---|
| `canvas` | `#faf8f3` | `#161412` | page ground; parchment / night |
| `surface` | `#f1ede4` | `#211e1b` | code blocks, cards, transcript containers |
| `surfaceRaised` | `#e9e3d7` | `#2a2622` | sheets, popovers |
| `ink` | `#1c1917` | `#f3eee6` | body text, the mark |
| `inkMuted` | `#625b54` | `#b3aa9e` | secondary text, labels |
| `inkFaint` | `#8b847b` | `#8b847b` | timestamps only |
| `hairline` | ink @ 10% | ivory @ 10% | alpha, never a grey stroke |
| `rufous` | `#b8432a` | `#d9674a` | **the accent**: the red tail |
| `rufousPressed` | `#9c3520` | `#b8432a` | hover / pressed |
| `buff` | `#d9b98c` | `#c9a877` | the breast; decorative highlights only, never text |
| `positive` | `#3d9a57` | `#7fd88f` | success, meeting stored |
| `negative` | `#c9403a` | `#e06c75` | destructive, capture lost |
| `caution` | `#d68c27` | `#f5a742` | permission prompts |

Rules:

- **Rufous is reserved** for: the listening indicator, one primary action per
  screen, the app icon ground, and link hover. It is never a default control
  color and never a background for text-heavy areas.
- Hairlines are 10% alpha ink, 1 px, and only bound a surface. No
  free-floating dividers. No drop shadows; elevation is a lighter surface.
- Body text aims for roughly 13:1 contrast, not 21:1. `#f3eee6` on `#161412`
  is the deliberate step down from pure white on black.
- Light mode is the default on the website and the management window. The
  menu bar and indicator follow the system.

### 3.2 Type

System faces only. SF Pro for prose, SF Mono for code and transcripts. On
the web that is the `ui-sans-serif` / `ui-monospace` stacks with Helvetica
and Menlo fallbacks. No webfont ships.

| Role | Web | macOS | Color |
|---|---|---|---|
| Display (hero h1) | clamp(2.25rem, 6vw, 3.5rem), 600, -0.02em | `.largeTitle` bold | `ink` |
| Heading | clamp(1.5rem, 3.5vw, 2rem), 600 | `.title2` semibold | `ink` |
| Subheading | 1.1875rem, 600 | `.headline` | `ink` |
| Body | 1.0625rem / 1.55 | `.body` 13pt (macOS) | `ink` |
| Lede | 1.25rem | `.title3` regular | `inkMuted` |
| Note | 0.875rem | `.footnote` | `inkFaint` |
| Transcript | mono 0.95em / 1.6 | `.body` mono | `ink` on `surface` |
| Speaker label | 0.8125rem, 600, +0.04em, uppercase | `.caption` semibold | `inkMuted` |
| Code | mono 0.9em | `.body` mono | `ink` on `surface` |

Measure is 34rem for prose and 38rem for a lede. Headings are balanced
(`text-wrap: balance`).

### 3.3 Space and radius

4 px base unit. Every spacing and radius value is a multiple.

Radii are semantic: `4` chip · `8` control · `12` content block · `16`
sheet · pill for capsules and the listening indicator. Shape alone should
say what kind of thing you are looking at.

The one rule that replaces divider lines: **space between sections is at
least twice the space between paragraphs.** On the site that is a 6rem
section gap over a 1rem paragraph gap.

### 3.4 Motion

House curve: `cubic-bezier(0.165, 0.84, 0.44, 1)` (easeOutQuart). In
SwiftUI: `.timingCurve(0.165, 0.84, 0.44, 1, duration:)`.

- Interaction feedback at or under 200 ms; sheets 200 to 500 ms.
- Never ease-in on UI.
- Reduced Motion substitutes a gentler animation; it never removes the
  signal.

### 3.5 The listening indicator

The signature state. While the push-to-talk key is held, a rufous pill
floats near the cursor with a level meter inside it. It is a heartbeat, not
a spinner: an asymmetric 1.8 s pulse (fast rise, bright hold, slow decay,
dim hold) so it reads as alive rather than mechanical. On release it
collapses toward the insertion point in 200 ms and the text arrives. If
cleanup takes longer than one second, the pill stays and says what it is
doing ("Cleaning up…"); it never shows a percentage it cannot honour.

---

## 4. Website

The site is one page plus Download, Privacy, and 404, on the same Astro,
S3, CloudFront, and CDK shape as the sibling sites, deployed with the same
`radius` AWS profile. See `website/README.md`.

Structure of the overview, top to bottom:

1. **Hero.** The lockup, the one-line promise, one rufous button (Install
   with Homebrew), one secondary (Read the source), and the local-only note.
2. **The three things it does.** Dictation, meetings, knowledge. Cards, no
   icons.
3. **Zero to dictating.** Three numbered steps: install, grant two
   permissions, hold the key.
4. **For your AI tools.** The MCP server, with the one-line install per
   client.
5. **What the subscriptions charge for.** The comparison table: Wispr
   Flow, superwhisper, Granola, on the axes Hark owns (where speech is
   transcribed, where transcripts live, account, bot-free meetings, MCP,
   source). Two honest "not yet" rows at the bottom (iPhone, Windows).
   Every cell is read from the vendor's own pricing or privacy page and the
   note carries the date and the links. Never claim parity on polish.
6. **What stays on your Mac.** The privacy claim, with the one exception
   stated.

Every page carries the license line in the footer: "Open source, MIT or
Apache-2.0. Speech model by NVIDIA via FluidAudio, CC-BY-4.0."

---

## 5. Verification

- [ ] No em dashes anywhere (`grep -rnP "\x{2014}" website/src docs README.md`)
- [ ] No pure greys in any stylesheet (`grep -rniE "#(808080|999|ccc|ddd|eee|f5f5f5|333|666)" website/src`)
- [ ] Lockup and mark render in light and dark without edits
- [ ] Rufous appears at most once as a control per screen
- [ ] Every copy string in §1.3 style: present tense, no exclamation marks
- [ ] `brew audit --cask --online tjameswilliams/tap/hark` passes after each release
