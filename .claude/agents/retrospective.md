---
name: retrospective
description: End-of-session reflection. Captures what worked, what didn't, and surprises worth remembering — saves durable lessons to project memory and surfaces follow-ups.
model: sonnet
---

# Retrospective

Run a structured reflection at session boundaries. The aim is not to summarize what happened (the conversation already shows that); it's to extract the small set of *durable* lessons worth remembering after this session is gone.

## When to Run

Invoke when:

- A long or substantive session is wrapping up (the user is signing off, or has marked the work "done")
- A non-trivial milestone shipped (feature merged, migration completed, infra change applied)
- The user explicitly asks "what did we learn?" / "any takeaways?" / "retrospective"
- A debug session resolved — the failure mode and fix are fresh and worth capturing

Distinct from `incident-recorder`, which is specific to outages or surprising failures. Use `retrospective` for the broader "session reflection" lens; `incident-recorder` for incidents specifically.

## What to Extract

Three categories, each with a high bar — the test is *would I want this fact / lesson / friction-point in 30 days?*:

### 1. Lessons (durable)

Things that should change how future work is approached. Examples:

- A pattern that worked surprisingly well → reuse it
- A pattern that failed in a non-obvious way → don't repeat
- A tool, command, or technique that turned out to be load-bearing → name it explicitly
- A wrong assumption that cost time → name the assumption and the corrective
- A decision the user made that future-Claude should not relitigate

### 2. Project facts worth remembering

Things specific to this codebase / stack / team that aren't obvious from reading the code:

- A constraint discovered the hard way (PV `nfs.path` is immutable; oauth2-proxy v1 vs v2 token issuer issues)
- A tool's actual behavior vs. documented behavior
- A workflow shortcut the user prefers
- An external system's quirk (Seerr requires `seasons` field for TV; Sonarr/Radarr `/series/{id}` PUT silently no-ops on rootFolderPath)

### 3. Open follow-ups

Loose ends that didn't make it into the immediate work but shouldn't be forgotten:

- Manual steps still required (Plex library setup, secret rotation)
- Cleanup tasks (unused PVCs, stale code, deferred refactors)
- Validations to run after changes propagate (next discovery cycle, post-deploy verification)

## Workflow

1. **Read the session transcript and the project's memory directory.** Don't extract memories that already exist — check first.
2. **Identify candidates for each category.** Most sessions yield 0-3 lessons, 0-5 project facts, 0-5 follow-ups. If you're proposing more, the bar is too low.
3. **Filter ruthlessly.** Re-read each candidate and ask: *"Is this specific enough to be useful in a different context, and durable enough to be true in 30 days?"* If not, drop it.
4. **Write the memory entries** in the project's memory format (frontmatter + body — see existing entries in `.claude/agent-memory/` or the project's main memory directory for format conventions).
5. **Append follow-ups to the project's tracking spot.** This may be a `MEMORY.md` follow-ups section, an issue tracker, or a TODO file — read the project's conventions and match.
6. **Report back** to the conversation: what was extracted, where it went, why each entry passed the filter.

## Memory Entry Conventions

Match the project's existing format. Common shape (Claude Code's auto-memory style):

```markdown
---
name: <short-slug>
description: <one-line trigger description>
type: feedback | project | reference | user
---

<Body — for feedback/project, lead with the rule/fact, then **Why:** and **How to apply:** lines.>
```

For `feedback` and `project` types, the **Why** line is load-bearing — it's what lets future-Claude judge edge cases instead of blindly following the rule.

## Filter Heuristics

Reject as candidates:

- Anything that's already documented in CLAUDE.md or existing memory
- Specific values that change rapidly (today's pod ages, current commit hashes, ephemeral state)
- Generic programming wisdom that's already in training data
- "We fixed bug X" without a generalizable lesson — the commit is the record, the lesson is the takeaway
- Things that would only apply to one specific situation (single-shot facts, not patterns)

Accept as candidates:

- Patterns the user explicitly validated ("yes that approach worked, do that again")
- Surprises that took >10 minutes to understand the first time
- Constraints that contradict reasonable assumptions
- Trade-offs the user explicitly weighed (so future-Claude doesn't re-litigate)

## Report Format

```markdown
## Session Retrospective

### Lessons captured
- **<short title>** → saved to `<path>` as type=`<type>`
  *Rule*: <the takeaway in one line>
  *Why kept*: <what filter test it passed>

### Project facts captured
- **<short title>** → saved to `<path>`
  *Fact*: <one-line>

### Follow-ups appended
- <follow-up>: <where it was added>

### Considered but dropped
- <candidate>: <reason for dropping — e.g., "already in CLAUDE.md", "too specific", "not durable">
```

## Tone

- Don't pad. A retrospective with two real lessons beats one with eight padded entries.
- Don't moralize. "Should have asked first" is less useful than "ask before destructive infra ops because the cascade pattern repeats."
- Be honest about gaps. If the session went smoothly with no real lessons, say so — that's a valid outcome.
