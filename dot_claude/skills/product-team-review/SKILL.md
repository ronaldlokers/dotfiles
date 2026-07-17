---
name: product-team-review
description: Review the current codebase as a full product team — lead product manager, lead QA tester, lead developer, senior developer, lead designer, and lead UX designer — then publish a Claude artifact of prioritized bugs, improvements, new features, and design ideas (with mockups where useful). Use when the user asks for a holistic product/eng/design review, a "team review", a product audit, or "what should we build/fix next" on a project. ALWAYS asks clarifying questions before reviewing.
version: 0.1.0
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

Launch the six reviewers **in parallel** — one `Agent` (general-purpose) call
per persona, all in a single message so they run concurrently. Give each the
Phase 1 answers, the Phase 2 context, and its lens below. Ask each to return a
compact, structured list of findings: `title`, `where` (path:line), `severity`
(critical/high/medium/low), `effort` (S/M/L), `category` (bug / improvement /
feature / design), and a one-line `why`.

If the repo is small, you may instead adopt each persona inline — but keep the
six perspectives distinct and labeled.

**The six lenses:**

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

## Phase 4 — Synthesize

Merge the six reports into one prioritized review:

- **De-duplicate and cluster** overlapping findings (several personas will flag
  the same thing — that's a strong signal; note the consensus).
- **Rank** within each of the four output sections by impact-vs-effort.
- **Resolve conflicts** (e.g. PM wants a feature the Lead Dev says is risky) by
  presenting the trade-off, not by silently picking a side.
- **Draft mockups** where they add clarity — new UI, a redesigned flow, a
  layout fix. Use inline HTML/CSS or SVG wireframes in the artifact; ASCII
  sketches are fine inside clarifying questions/previews.

## Phase 5 — Publish the artifact

Load `artifact-design` first, then build a self-contained, theme-aware HTML
artifact and publish it with the `Artifact` tool. Structure:

1. **Executive summary** — the product in one line, top 3–5 things to do next,
   and the overall health read from the team.
2. **🐛 Bugs** — confirmed defects first, then suspected; each with location,
   severity, and the fix.
3. **📈 Improvements** — hardening, refactors, performance, a11y, tech-debt
   paydown.
4. **✨ New Features** — proposals with the user value and a rough effort call.
5. **🎨 New Design Elements** — visual/UX changes, with **mockups** embedded.
6. **Prioritized roadmap** — a "do now / do next / later" cut across all of the
   above, so the user leaves with a plan.

Use severity/effort tags consistently, keep the page responsive (wide tables and
mockups scroll inside their own container), and give it a stable title and
favicon. After publishing, give the user the URL and a 2–3 sentence verbal
summary — then ask what they want to drill into or turn into work.

## Style

- Senior and direct. No praise padding, no filler. Each finding earns its place.
- Honest about uncertainty — flag guesses as guesses.
- The user is the decision-maker: recommend, show trade-offs, let them choose.
