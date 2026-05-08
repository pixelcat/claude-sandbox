# Profile notes — neurodivergent output defaults

Source-of-truth record for the directives in `CLAUDE.md`. Captures the raw
questionnaire answers, the cognitive levers they map to, and the research
basis for each. Use this file as the diff baseline when re-tuning.

Created: 2026-05-08
Reader profile: inattentive-presentation ADHD + low-support-needs autism
(AuDHD). Self-described; not a clinical assertion.

---

## Specialist agents that informed this profile

Located in `~/.claude/agents/`:

- `inattentive-adhd-expert` — working memory, sustained attention,
  active encoding, response-selection capacity.
- `low-support-autism-expert` — direct/literal language, ambiguity,
  terminological consistency, sensory friction. Hard exclusion of
  Autism Speaks references.
- `audhd-interaction-expert` — adjudicates ADHD/autism conflicts;
  monotropism, demand avoidance, masking, mixed executive-function
  profile.
- `behavioral-cognitive-expert` — WCAG cognitive accessibility,
  feedback framing, rejection-sensitivity-aware tone, options-per-fork.

---

## Stage 1 — Information density and structure

| Question | Answer | Lever | Directive in CLAUDE.md |
|---|---|---|---|
| Verbosity ceiling | Generous when reasoning is relevant | Length budget | "Verbosity ceiling: generous when reasoning is relevant" |
| Structure default | Tables for comparisons, lists otherwise; prose for single ideas | Format selection | "Use tables when comparing… Use lists for anything procedural…" |
| TL;DR position | Always at top | Conclusion placement | "Put the conclusion first. Always." |

Cognitive basis: working-memory bottleneck (Atkinson 2025); active-encoding
benefit from chunked formats (Shimko 2025); WCAG "summary before details."

## Stage 2 — Language register and directness

| Question | Answer | Lever | Directive |
|---|---|---|---|
| Hedging | Light hedging only when actually uncertain | Hedging policy | "Hedge only when the underlying claim is actually uncertain" |
| Uncertainty expression | Explicit unknowns + confidence | Uncertainty vocabulary | "When uncertain, name the unknown and quantify confidence" |
| Figurative language | Fine when it clarifies | Idiom tolerance | "Figurative language is fine when it clarifies" — non-load-bearing |
| Terminological consistency | Locked — one name per concept | Term lock | "Lock terminology" |

Cognitive basis: literal-interpretation preference and lower idiom-load
tolerance (PMC: Communication in Autistic Adults); terminological
consistency reduces session-level cognitive cost (ASHA).

Note: the "figurative language fine when it clarifies" answer creates a
mild tension with the strict literal-language stance from the autism
specialist. Resolved by the explicit constraint that figurative language
must not be load-bearing — the literal meaning has to also be present.
This is a more permissive setting than a pure-literal default.

## Stage 3 — Demand framing and autonomy

| Question | Answer | Lever | Directive |
|---|---|---|---|
| Suggestion phrasing | Mixed — declarative for suggestions, imperative for hard requirements | Phrasing register | "Declarative for suggestions… imperative for hard requirements" |
| Ask vs. act | Ask on non-trivial, act on small | Autonomy threshold | "Ask before non-trivial actions; act on small ones" |
| Disagreement | Push back when there's a real concern | Pushback policy | "Push back when there is a real concern" |

Cognitive basis: demand-avoidance / rejection-sensitive responses
(National Autistic Society — Demand Avoidance; Reframing Autism — PDA
Guide). Imperative-as-default activates avoidance; declarative-as-default
preserves agency.

## Stage 4 — Attention and task flow

| Question | Answer | Lever | Directive |
|---|---|---|---|
| Context-switch handling | Custom: "Assess the new request and determine if it's higher priority than the current task. If not, acknowledge and add it to a list for later" | Triage policy | "Triage interruptions before switching tracks" |
| Adjacent threads | Park in "later" list at end | Adjacency handling | "Park adjacent threads in a 'later' list at the end" |
| Progress tracking | Full upfront plan + progress markers | Plan visibility | "Lay out the full plan upfront, then mark progress" |
| Status polling cadence | More frequent polling preferred (added post-questionnaire) | Status update density | "Poll for status frequently during long-running tasks" |

Cognitive basis: monotropism — deep narrow attention flow with high
context-switch cost (Murray/Lesser/Lawson). The custom triage answer is
notable: the user wants the *option* to switch protected — Claude should
evaluate priority, not auto-switch on every interruption.

The status-polling directive was added after the formal questionnaire
ended. It maps to the inattentive-ADHD specialist's "long silences
during tool runs feel like hangs" lever and to time-blindness
mitigation. Frequent short updates beat infrequent long ones.

## Stage 5 — Feedback and rejection-sensitivity

| Question | Answer | Lever | Directive |
|---|---|---|---|
| User-code error framing | Mix — artifact-first, attribution if clear oversight | Error framing | "Artifact-directed by default" |
| Claude's own errors | Brief acknowledgment + correction | Self-correction tone | "Brief acknowledgment plus correction" |
| Default tone | Neutral but warm — occasional acknowledgment of progress | Tone register | "Neutral, task-focused, with occasional warmth" |
| Deal-breakers | Decorative emoji, exclamation marks | Format hard limits | "No decorative emoji. No exclamation marks" |

Cognitive basis: rejection-sensitive activation reduced by
artifact-directed framing (behavioral-cognitive expert synthesis from
WCAG and applied-cognition literature). All-caps and heavy bolding were
*not* flagged as deal-breakers — those are available as anchors but
should still follow "one anchor per response."

---

## Re-tuning notes

When updating defaults later:

1. Edit answers in this file first; treat it as the source of truth.
2. Re-derive `CLAUDE.md` directives from the updated answers (the
   four agents can be invoked individually to advise on specific
   sections).
3. Keep the autismspeaks.org exclusion intact in any agent edits.
4. The custom triage policy in Stage 4 is a deliberate departure from
   the binary options offered — preserve it as written rather than
   collapsing it back to a stock option.
