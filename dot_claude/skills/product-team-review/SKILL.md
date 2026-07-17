---
name: product-team-review
description: Review the current codebase as a full cross-functional product team — product, QA, development (lead + senior), design, UX, security, DevOps/SRE, data privacy, accessibility, analytics, docs, customer support, and engineering management — then verify the findings and publish a Claude artifact of prioritized, attributed bugs, improvements, new features, and design ideas (with mockups where useful). Supports quick/standard/deep effort levels, whole-product or diff/PR scope, and can open GitHub issues or implement fixes afterward. Use when the user asks for a holistic product/eng/design review, a "team review", a product audit, or "what should we build/fix next" on a project. ALWAYS asks clarifying questions before reviewing.
version: 0.4.0
---

# Product Team Review

Simulate a senior cross-functional product team reviewing the codebase you are
working in, verify what they find, then deliver a decision-ready Claude
**artifact**: prioritized **Bugs**, **Improvements**, **New Features**, and
**New Design Elements** — each attributed to the roles that raised it, tagged
with severity, effort, and confidence, with **mockups** where a picture beats a
paragraph. Afterward, optionally turn the findings into tracked work.

## Non-negotiable rules

1. **Always ask clarifying questions first** (Phase 1). You cannot judge "the
   right features" or "good UX" without knowing the product's goal, audience,
   stage, scope, and how much rigor to apply. Ask again mid-flight whenever an
   assumption would materially change a recommendation.
2. **The primary output is a Claude artifact**, published with the `Artifact`
   tool. Load the `artifact-design` skill before writing it.
3. **Every finding is actionable, located, and attributed.** Reference real code
   as `path:line`, name the persona(s) who raised it, and give a confidence
   level. No vague "consider improving error handling."
4. **Verify before you report** (Phase 4). Only present a bug as confirmed if
   the code (or the running app) shows it. Separate confirmed from suspected.
5. **Prioritize.** Lead with severity × impact × consensus. Don't bury the lede
   under nitpicks.

## Effort levels

Pick a level in Phase 1 (default **standard**); it scales cost vs. depth:

- **quick** — core six personas only, no verification pass, no live-app driving
  or research. A fast sanity read. Confidence tags still applied.
- **standard** (default) — the relevant team (see Phase 3), verification of all
  critical/high bugs, live-app driving and light research only if clearly
  useful.
- **deep** — full relevant team, verification of every bug and high-impact
  claim, live-app driving, competitor/best-practice research, and cross-run
  tracking. The thorough audit.

State the chosen level in the artifact so the reader knows how much rigor backs
it.

## Phase 1 — Ask before you look

Open with `AskUserQuestion`. Read the README / package manifest first so you
don't ask what the repo already answers. Cover at least:

- **Product & goal** — what is this, what outcome should it drive, what prompted
  the review?
- **Audience & stage** — who uses it; prototype, MVP, or production?
- **Focus & weighting** (multiSelect) — correctness/bugs, code quality, product/
  roadmap, visual design, UX, performance, security, accessibility.
- **Constraints** — timeline, tech constraints, off-limits or known-broken
  areas, appetite for new work vs. hardening.
- **Scope** — review the **whole product**, or just the **current diff / branch
  / PR** ("review my changes")? Default to whole-product unless the user is
  clearly mid-change.
- **Effort level** — quick / standard / deep (see above). Infer a sensible
  default from the ask, but confirm if unclear.
- **Live app** — may I run/screenshot the app, and if so how is it started?
  (Enables the real rendered product for the design/UX personas.)
- **External research** — OK to pull competitor/best-practice context from the
  web / `context7`?

Keep it to 2–4 sharp questions (bundle related ones). Weave the answers into
every later phase.

## Phase 2 — Reconnaissance

- Identify the stack, entry points, and architecture; skim README, docs, config,
  and primary source. Note where the UI lives.
- **Scope prep** — if scope is diff/branch/PR, get the changeset (`git diff`,
  branch range, or the PR) and constrain the review to it plus its blast radius.
- **Prior-review tracking** — look for a stored record from a past run (see
  Phase 6). If found, load it so Phase 5 can diff resolved vs. new vs. still-open
  findings.
- **Drive the live app** — when enabled and useful, start and exercise the app
  (use the `run` skill, or the `playwright` / `chrome-devtools` plugins) and
  capture screenshots of key screens/flows, so the design, UX, and accessibility
  personas review the real product, not just source. Note runtime errors seen.

Keep recon lightweight — enough to brief the team.

## Phase 3 — Convene the team (parallel personas)

Launch the reviewers **in parallel** — one `Agent` (general-purpose) call per
persona, batched into single messages. Give each the Phase 1 answers, Phase 2
context (including screenshots/diff), and its lens below. Each returns a compact,
structured list of findings, every finding carrying: `title`, `where`
(path:line), `severity` (critical/high/medium/low), `effort` (S/M/L),
`confidence` (confirmed / likely / speculative), `category` (bug / improvement /
feature / design), `raisedBy` (this persona), and a one-line `why`. On **deep**,
personas may use web / `context7` research to ground feature and design calls.

If the repo is small, adopt each persona inline — but keep the perspectives
distinct and labeled.

**Pick the relevant team, don't force all fourteen.** Use Phase 1 + recon to
skip personas a project can't benefit from — no UI → drop the two designers and
Accessibility; no personal/regulated data → drop Data Privacy; a pure library →
drop Customer Support and Analytics. On **quick**, use only the core six. Note
which personas you convened and which you skipped and why.

**Core lenses:**

- **Lead Product Manager** — user value, feature gaps, roadmap, prioritization,
  positioning, uncaptured metrics, what would move the needle.
- **Lead QA Tester** — bugs, edge cases, error/empty/loading states, data
  validation, regressions waiting to happen, missing test coverage.
- **Lead Developer** — architecture, module boundaries, security, performance,
  scalability, dependency and tech-debt risk, correctness of core logic.
- **Senior Developer** — implementation-level bugs, refactors, readability,
  naming, duplication, maintainability of day-to-day code.
- **Lead Designer** — visual hierarchy, spacing/typography, color and contrast,
  brand consistency, design-system gaps, polish.
- **Lead UX Designer** — user flows, information architecture, friction points,
  onboarding, copy/microcopy, accessibility, mobile/responsive behavior.

**Security, reliability & compliance lenses:**

- **Lead Security Officer** — threat modeling, authn/authz, secrets handling,
  input validation/injection, dependency and supply-chain vulns, OWASP Top 10,
  sensitive-data exposure. Go deeper than the Lead Developer's general pass.
- **DevOps / SRE Lead** — CI/CD, build/deploy pipeline, observability, scale,
  infrastructure-as-code, failure modes, backups, operational readiness.
- **Data Privacy Officer** — PII handling, GDPR/CCPA, retention/minimization,
  consent, logging of sensitive data, licensing/legal risk. Convene when the
  product touches personal or regulated data.
- **Accessibility Specialist** — a dedicated WCAG audit: keyboard nav,
  screen-reader/ARIA semantics, contrast, focus management, reduced motion.
  Convene when there is a UI.

**Product, growth & delivery lenses:**

- **Data / Analytics Lead** — instrumentation, event tracking, funnels, metrics
  that aren't captured, experiment/measurement design.
- **Technical Writer / Docs Lead** — README, onboarding, API reference, inline
  docs, gaps in developer/user documentation.
- **Customer Support Lead** — voice of the customer: likely support burden,
  confusing flows, missing self-service, error messages that generate tickets.
- **Engineering Manager** — delivery risk, process, team-scalability,
  maintainability, "what will hurt us in six months" at a higher altitude than
  the two developer personas.

## Phase 4 — Verify

Before anything reaches the artifact, run a verification pass whose depth
follows the effort level (skipped on **quick**; critical/high bugs on
**standard**; every bug and high-impact claim on **deep**):

- For each bug-class finding, **try to confirm it's real** — re-read the cited
  code adversarially, trace the path, and where a live app is available,
  reproduce it. Prefer independent checking (a fresh `Agent`) so the reviewer
  isn't grading its own work.
- **Update confidence** from the result: confirmed (reproduced or unambiguous in
  code), likely (strong evidence, not proven), speculative (plausible, unproven).
  **Drop** findings that verification refutes; **downgrade** shaky ones.
- Keep a short verification note per confirmed bug (how it was confirmed) so the
  artifact can show its work.

## Phase 5 — Synthesize

Merge the persona reports into one prioritized review:

- **Attribute every finding.** Union `raisedBy` across duplicates so a concern
  flagged by several personas becomes one **consensus** item — a strong signal.
  Sort consensus and confirmed/high-severity items toward the top.
- **Rank** within each of the four output sections by severity × impact ×
  consensus, with confidence and effort as tie-breakers.
- **Resolve conflicts** by presenting the trade-off and naming which personas
  sit on each side — don't silently pick a side.
- **Diff against the last review** (if a prior record was loaded): classify each
  item as **resolved**, **new**, or **still-open**, and surface progress.
- **Draft mockups** where they add clarity. Use inline HTML/CSS or SVG wireframes
  in the artifact; ASCII sketches are fine inside clarifying questions/previews.

## Phase 6 — Publish the artifact

Load `artifact-design` first, then build a self-contained, theme-aware HTML
artifact and publish it with the `Artifact` tool. Structure:

1. **Executive summary** — the product in one line, the effort level and team
   convened/skipped, top 3–5 things to do next, overall health. Surface any
   **critical security, privacy, or reliability risk** here explicitly.
2. **Changes since last review** — resolved / new / still-open (only if a prior
   record existed).
3. **🐛 Bugs** — confirmed first, then suspected; each with location, severity,
   confidence, and the fix.
4. **📈 Improvements** — hardening, refactors, performance, a11y, tech-debt.
5. **✨ New Features** — proposals with user value and a rough effort call.
6. **🎨 New Design Elements** — visual/UX changes, with **mockups** embedded.
7. **Prioritized roadmap** — a "do now / do next / later" cut across all of it.

**Attribution & confidence rendering.** Every finding shows **who raised it** —
`raisedBy` roles as small labelled tags/pills with a stable short label and
color per role; multi-persona items get a **consensus badge** (e.g. "3×
consensus") with visual weight. Every finding also shows a **confidence** tag
(confirmed / likely / speculative). Include a **legend** mapping labels to full
role names. A reader must be able to answer "why is this here, who's worried
about it, and how sure are we?" for every item.

**Persist a tracking record.** Write a machine-readable record of the findings
(id, title, where, severity, confidence, category, raisedBy, status) to a stable
per-project location — prefer a `.product-team-review/` directory in the repo
root; add it to `.gitignore` unless the user wants reviews committed. This is
what the next run diffs against.

Keep the page responsive (wide tables and mockups scroll in their own
container); give it a stable title and favicon.

## Phase 7 — Follow-through

After publishing, give the URL and a 2–3 sentence verbal summary, then offer
(don't assume) to convert findings into action:

- **Create GitHub issues** — for findings the user selects, open issues with
  `gh` (title, body with location + fix + persona attribution + confidence,
  and severity/type labels). Confirm the selection first; never mass-file
  without approval. Respect the repo's git workflow (this user: branch + PR, no
  direct pushes; conventional-commit style).
- **Implement fixes** — offer to implement the top-ranked fixes now, on a fresh
  `fix/<topic>` or `feat/<topic>` branch. For several independent fixes, hand
  them to parallel subagents (or a workflow). Verify each change before opening
  a PR; don't bundle unrelated fixes into one.

Ask which of these the user wants; do nothing outward-facing without a clear go.

## Style

- Senior and direct. No praise padding, no filler. Each finding earns its place.
- Honest about uncertainty — confidence tags mean what they say.
- The user is the decision-maker: recommend, show trade-offs, let them choose.
