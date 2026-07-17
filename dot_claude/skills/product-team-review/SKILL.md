---
name: product-team-review
description: Review the current codebase as a full cross-functional product team — product, QA, development (lead + senior), design, UX, security, DevOps/SRE, data privacy, accessibility, analytics, docs, customer support, and engineering management — then publish a Claude artifact of prioritized bugs, improvements, new features, and design ideas (with mockups where useful). Use when the user asks for a holistic product/eng/design review, a "team review", a product audit, or "what should we build/fix next" on a project. ALWAYS asks clarifying questions before reviewing.
version: 0.3.0
---

# Product Team Review

Simulate a senior cross-functional product team reviewing the codebase you are
working in, then deliver a single, polished Claude **artifact** the user can
read and share. The team has six voices; each looks at the same product through
a different lens and reports what *they* would fix, improve, or build.

The deliverable is not a code dump — it is a decision-ready review: prioritized
**Bugs**, **Improvements**, **New Features**, and **New Design Elements**, with
**mockups** where a picture beats a paragraph.

## Non-negotiable rules

1. **Always ask clarifying questions first.** Never start reviewing blind — you
   cannot judge "the right features" or "good UX" without knowing the product's
   goal, audience, and stage. Use `AskUserQuestion` (see Phase 1). Ask again
   mid-flight whenever an assumption would materially change a recommendation.
2. **The output is a Claude artifact**, published with the `Artifact` tool. Load
   the `artifact-design` skill before writing it. Text-only summaries don't
   satisfy this skill.
3. **Every finding is actionable and located.** Reference real files as
   `path:line`. No vague "consider improving error handling" — say where and how.
4. **Prioritize.** Tag each item with a severity/impact and effort so the user
   knows what to do first. Don't bury the lede under nitpicks.
5. **Stay grounded.** Only claim a bug exists if you can point at the code that
   causes it. Separate "confirmed" from "worth investigating".

## Phase 1 — Ask before you look

Open with `AskUserQuestion`. Adapt the questions to what you can already infer
from the repo (read the README / package manifest first so you don't ask what
the code already answers). Cover at least:

- **Product & goal** — what is this, and what outcome should it drive? What
  prompted this review?
- **Audience & stage** — who uses it; is it prototype, MVP, or in production?
- **Focus & weighting** (multiSelect) — which lenses matter most right now:
  correctness/bugs, code quality/architecture, product/roadmap, visual design,
  UX/flows, performance, security, accessibility?
- **Constraints** — timeline, tech constraints, areas that are off-limits or
  known-broken, and how much appetite there is for new work vs. hardening.

Keep it to 2–4 sharp questions. Weave the answers into every later phase.

## Phase 2 — Reconnaissance

Build a shared understanding before the personas opine:

- Identify the stack, entry points, and overall architecture.
- Skim the README, docs, config, and the primary source directories.
- Note where the UI lives (if any) so the design/UX personas have something
  concrete to react to.

Keep this lightweight — enough context to brief the team, not a full audit yet.

## Phase 3 — Convene the team (parallel personas)

Launch the reviewers **in parallel** — one `Agent` (general-purpose) call per
persona, batched into single messages so they run concurrently. Give each the
Phase 1 answers, the Phase 2 context, and its lens below. Ask each to return a
compact, structured list of findings: `title`, `where` (path:line), `severity`
(critical/high/medium/low), `effort` (S/M/L), `category` (bug / improvement /
feature / design), and a one-line `why`.

If the repo is small, you may instead adopt each persona inline — but keep the
perspectives distinct and labeled.

**Pick the relevant team, don't force all fourteen.** Use the Phase 1 answers
and Phase 2 recon to skip personas a project can't benefit from — e.g. no UI →
drop the two designers and Accessibility; no personal/regulated data → drop Data
Privacy; a pure library → drop Customer Support and Analytics. Note which
personas you convened and which you skipped and why. The **core six** (PM, QA,
Lead Dev, Senior Dev, Designer, UX) are the default; the rest are added when the
codebase warrants them.

**Core lenses:**

- **Lead Product Manager** — user value, feature gaps, roadmap, prioritization,
  positioning, metrics that aren't captured, and what would move the needle.
- **Lead QA Tester** — bugs, edge cases, error/empty/loading states, data
  validation, regressions waiting to happen, and missing test coverage.
- **Lead Developer** — architecture, module boundaries, security, performance,
  scalability, dependency and tech-debt risk, correctness of core logic.
- **Senior Developer** — implementation-level bugs, refactors, readability,
  naming, duplication, and maintainability of day-to-day code.
- **Lead Designer** — visual hierarchy, spacing/typography, color and contrast,
  brand consistency, design-system gaps, and polish.
- **Lead UX Designer** — user flows, information architecture, friction points,
  onboarding, copy/microcopy, accessibility, and mobile/responsive behavior.

**Security, reliability & compliance lenses:**

- **Lead Security Officer** — threat modeling, authentication/authorization,
  secrets handling, input validation/injection, dependency and supply-chain
  vulns, OWASP Top 10, and sensitive-data exposure. Go deeper than the Lead
  Developer's general security pass.
- **DevOps / SRE Lead** — CI/CD, build/deploy pipeline, observability and
  monitoring, scalability, infrastructure-as-code, failure modes, backups, and
  operational readiness.
- **Data Privacy Officer** — PII handling, GDPR/CCPA exposure, data retention
  and minimization, consent, logging of sensitive data, and licensing/legal
  risk. Convene when the product touches personal or regulated data.
- **Accessibility Specialist** — a dedicated WCAG audit: keyboard navigation,
  screen-reader/ARIA semantics, color contrast, focus management, and reduced
  motion. Convene when there is a UI.

**Product, growth & delivery lenses:**

- **Data / Analytics Lead** — instrumentation, event tracking, funnels, metrics
  that aren't being captured, and experiment/measurement design.
- **Technical Writer / Docs Lead** — README, onboarding, API reference, inline
  docs, and gaps in developer/user documentation.
- **Customer Support Lead** — voice of the customer: likely support burden,
  confusing flows, missing self-service, and error messages that will generate
  tickets.
- **Engineering Manager** — delivery risk, process, team-scalability,
  maintainability, and "what will hurt us in six months" at a higher altitude
  than the two developer personas.

## Phase 4 — Synthesize

Merge the persona reports into one prioritized review:

- **Attribute every finding.** Track which persona(s) raised each item — each
  finding carries a `raisedBy` list of role names. This is the backbone of the
  attribution shown in the artifact, so don't drop it during clustering.
- **De-duplicate and cluster** overlapping findings. When several personas flag
  the same thing, merge them into one item and **union their `raisedBy`** — a
  finding raised by three roles is a consensus item and a strong signal. Sort
  consensus items toward the top of their section.
- **Rank** within each of the four output sections by impact-vs-effort, with
  cross-persona consensus breaking ties upward.
- **Resolve conflicts** (e.g. PM wants a feature the Lead Dev says is risky) by
  presenting the trade-off and naming which personas sit on each side — don't
  silently pick a side.
- **Draft mockups** where they add clarity — new UI, a redesigned flow, a
  layout fix. Use inline HTML/CSS or SVG wireframes in the artifact; ASCII
  sketches are fine inside clarifying questions/previews.

## Phase 5 — Publish the artifact

Load `artifact-design` first, then build a self-contained, theme-aware HTML
artifact and publish it with the `Artifact` tool. Structure:

1. **Executive summary** — the product in one line, top 3–5 things to do next,
   and the overall health read from the team. Surface any **critical security,
   privacy, or reliability risk** here explicitly, even though it also lives in
   its detailed section — these must not be buried.
2. **🐛 Bugs** — confirmed defects first, then suspected; each with location,
   severity, and the fix.
3. **📈 Improvements** — hardening, refactors, performance, a11y, tech-debt
   paydown.
4. **✨ New Features** — proposals with the user value and a rough effort call.
5. **🎨 New Design Elements** — visual/UX changes, with **mockups** embedded.
6. **Prioritized roadmap** — a "do now / do next / later" cut across all of the
   above, so the user leaves with a plan.

**Persona attribution.** Every finding shows **who raised it** — render the
`raisedBy` roles as small labelled tags/pills on each item (e.g. `Security`,
`SRE`, `UX`). When more than one persona raised it, mark it a **consensus** item
(e.g. a "3× consensus" badge listing the roles) and give it visual weight —
consensus is the strongest prioritization signal on the page. Give each persona
a consistent short label and, ideally, a stable color so the same role reads the
same everywhere. Include a small **legend** mapping labels to full role names,
and open with a one-line note of which personas were convened and which were
skipped (from Phase 3). Attribution is a requirement, not decoration — a reader
should be able to answer "why is this here, and who's worried about it?" for
every item.

Use severity/effort tags consistently, keep the page responsive (wide tables and
mockups scroll inside their own container), and give it a stable title and
favicon. After publishing, give the user the URL and a 2–3 sentence verbal
summary — then ask what they want to drill into or turn into work.

## Style

- Senior and direct. No praise padding, no filler. Each finding earns its place.
- Honest about uncertainty — flag guesses as guesses.
- The user is the decision-maker: recommend, show trade-offs, let them choose.
