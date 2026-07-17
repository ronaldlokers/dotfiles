---
name: product-team-review
description: Review the current codebase as a full cross-functional product team — product, QA, development (lead + senior), design, UX, security, DevOps/SRE, data privacy, accessibility, analytics, docs, customer support, and engineering management — then verify the findings and publish a Claude artifact of prioritized, attributed bugs, improvements, new features, and design ideas (with mockups where useful). Supports quick/standard/deep effort levels, whole-product or diff/PR scope, and can open GitHub issues or implement fixes afterward. Use when the user asks for a holistic product/eng/design review, a "team review", a product audit, or "what should we build/fix next" on a project. ALWAYS asks clarifying questions before reviewing.
version: 0.6.0
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
  or research. A fast sanity read. Confidence tags still applied. **Default to
  quick for small repos** (roughly a few dozen files / no separate frontend +
  backend) — a large fan-out re-reads the same small tree many times for little
  extra signal; suggest quick and let the user upgrade.
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

**Produce a recon digest.** Write a compact shared brief — stack, layout, entry
points, key files with paths, the scope/changeset, secrets/CI facts, and any
screenshots/runtime errors — and pass it verbatim into every persona prompt in
Phase 3. This is the main cost lever: without it, each subagent re-explores the
whole repo from scratch (the dominant token sink on a fan-out); with it, they
read the digest and only open the few files their lens needs.

Keep recon lightweight — enough to brief the team.

## Phase 3 — Convene the team (parallel personas)

Launch the reviewers **in parallel** — one `Agent` (general-purpose) call per
persona, batched into single messages. Give each the Phase 1 answers, the **Phase
2 recon digest** (so they don't re-explore — instruct them to start from it and
open only the files their lens needs), any screenshots/diff, and its lens below.
Each returns a compact,
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

**When agents die (graceful degradation).** A persona agent can return
null/partial or terminate on a terminal API error (spend/rate limit, timeout) —
`Agent`/`parallel` surface this rather than crashing the run. **Never abort the
whole review because some personas failed.** Instead:

- Track each convened persona's status: `completed`, `failed` (with the reason,
  e.g. spend limit), or `skipped` (relevance-gated).
- Synthesize from the personas that completed, and **label the coverage gap
  explicitly** in the artifact — name which lenses did not run and what they
  would have covered, so a reader doesn't mistake a partial review for a
  complete one. Fold this into the executive summary and footer.
- If a majority died, tell the user, publish what you have, and offer to resume
  (below) rather than silently shipping a thin review.

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

**Persist a tracking record.** Write a machine-readable record to a stable
per-project location — prefer a `.product-team-review/` directory in the repo
root; add it to `.gitignore` unless the user wants reviews committed. Include:

- the **findings** (id, title, where, severity, confidence, category, raisedBy,
  status);
- the **coverage map** — every convened persona and its outcome (`completed` /
  `failed` + reason / `skipped` + reason). This is what a resume reads to know
  which lenses still owe a review;
- the **recon digest** from Phase 2, so a resume can re-brief a persona without
  redoing recon;
- the **artifact URL** and the effort/scope config.

This is what the next run diffs against *and* what a resume run continues from.

Keep the page responsive (wide tables and mockups scroll in their own
container); give it a stable title and favicon.

## Phase 7 — Follow-through

After publishing, give the URL and a 2–3 sentence verbal summary. Then **ask what
to do next with `AskUserQuestion` — a clickable choice, never a free-text prompt
in prose.** The user should be able to pick an action by clicking, not by typing.

Present the follow-through options with `AskUserQuestion` (use `multiSelect: true`
so they can pick several). Draw the option set from what this review actually
produced — typically:

- **Create GitHub issues** — open issues with `gh` for selected findings (title,
  body with location + fix + persona attribution + confidence, severity/type
  labels). Confirm *which* findings in a follow-up question (e.g. "critical +
  highs", "everything", or a hand-picked set) before filing; never mass-file
  without approval. Respect the repo's git workflow (this user: branch + PR, no
  direct pushes; conventional-commit style).
- **Implement fixes now** — on a fresh `fix/<topic>` / `feat/<topic>` branch. For
  several independent fixes, hand them to parallel subagents (or a workflow).
  Verify each change before opening a PR; don't bundle unrelated fixes.
- **Write a REVIEW.md** — drop the findings into the repo as a committed
  checklist.
- **Re-run deeper / resume** — escalate effort, or resume any personas still
  marked `failed`.
- **Nothing for now** — stop here; the artifact stands on its own.

Tailor the labels to the run (e.g. lead with the critical finding: "Fix the
critical recovery gap"). Then act only on what the user clicks. Do nothing
outward-facing — issues, branches, commits — without that explicit selection.

## Resuming a partial run

When a run finished with personas in a `failed` state (Phase 3 graceful
degradation) — or the user says "continue"/"finish the review"/"reinvoke the
ones that died" — complete it instead of starting over:

1. **Load the tracking record** (Phase 6) for this project. Read its coverage map
   to find every persona still marked `failed` (or never convened but now
   wanted), plus the stored recon digest and artifact URL.
2. **Re-spawn only the missing personas.** A subagent that died on a terminal
   error can't be reliably resumed, so start each one **fresh** with the stored
   recon digest and its lens — cheap, because recon isn't repeated. (Use
   `SendMessage` only for an agent that is still alive from this same session.)
   If the original failure was a spend/rate limit, confirm the user has
   head-room before re-spawning, or the same wall will be hit again.
3. **Merge, don't duplicate.** Fold the new findings into the existing set —
   re-run the Phase 4 verify and Phase 5 synthesis (attribution, consensus,
   ranking) across the *combined* findings, so consensus counts pick up the
   late-arriving personas.
4. **Update the same artifact in place.** Republish to the **existing artifact
   URL** (pass it as `url`, or redeploy the same file path in-session) — don't
   mint a new one. Remove or shrink the coverage-gap callout for the lenses now
   filled; keep it for any still missing.
5. **Update the tracking record** — flip the resumed personas to `completed`.

The goal: a review interrupted by dying agents is always finishable later with no
lost work and no re-review of what already succeeded.

## Style

- Senior and direct. No praise padding, no filler. Each finding earns its place.
- Honest about uncertainty — confidence tags mean what they say.
- The user is the decision-maker: recommend, show trade-offs, let them choose.
