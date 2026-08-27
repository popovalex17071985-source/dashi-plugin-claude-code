# TASK: audit your own agent setup and build what's missing

Audit YOUR OWN configuration and build the missing parts. Work step by step.
One report at the end.

## The principle everything rests on

Reliability grows bottom-up:
1. Session memory — lost on compact
2. A note in a memory file — read on demand, never fires at the moment of the mistake
3. Docs (TOOLS/AGENTS) — read on demand
4. Constitution (CLAUDE.md / rules.md) — always in context
5. A script or hook — fires automatically, independent of my confidence

Rules lose to confidence. Mechanisms don't.
The more critical the class of mistake, the higher up the pyramid the fix must go.
A note saying "I won't do that again" is NOT a fix.

## STEP 1. Inventory

Read and write down the ACTUAL state (open the files, don't recall):

- What lives in `~/.claude/` and in the project's `.claude/`
- `CLAUDE.md` — global and project: what's in them
- `settings.json` — which hooks are registered, which env vars
- `.claude/hooks/` — which hooks actually exist and are executable
- `.claude/agents/` — which subagents are defined
- Which skills are exposed through the Skill tool
- Whether these exist: primary-source registry, lessons log, projects board,
  open-promises ledger, hot/warm memory

Per item: PRESENT / MISSING / PRESENT BUT EMPTY.

## STEP 2. Checklist — score yourself

For each item answer PRESENT / MISSING and where exactly it lives.

### A. Constitution (level 4 — always in context)
1. Identity and role: who I am, who I report to, how I address the operator
2. Autonomy zones: green (act) / red (ask). Rule: green = reversible, red = not
3. Primary-source rule: never conclude from a proxy (a neighbouring file, a
   subagent summary, my own memory, a config lying nearby) while a primary source
   exists. NEGATIVE claims ("X has no Y", "X isn't configured") are the highest
   risk — never ship one without reading the source
4. Close-out protocol: "done" = done + verified + REPORTED + next step offered,
   in one unprompted message
5. "Refusal = hypothesis" rule: before saying "can't / no access / no data",
   try at least 5 routes and show the list
6. Language policy and default reply-length limit
7. Editing discipline: surgical changes, don't refactor adjacent code; before
   deleting a field/service grep ALL of its forms

### B. Mechanisms (level 5 — hooks and scripts)
8. Stop-hook that blocks a refusal phrasing when few attempts were made
9. Hook requiring a mechanism for every recorded lesson (a lesson with no change
   in the constitution / registry / script is not accepted)
10. Hook catching forward promises ("I'll come back with…", "later", "let's defer")
    into the open-threads ledger
11. Hook/script writing session state (handoff) so the thread survives a compact
12. A wrapper for long background runs that reports success AND failure BY ITSELF.
    Hand-rolled waiters like `until pgrep -f x; sleep; done` break silently —
    `pgrep -f` matches its own command line and hangs forever
13. Secret redaction in output

### C. Sources and memory
14. Primary-source registry: a table `domain → primary source → how to read it →
    the proxy I habitually mistake for it`. Opened FIRST on any data task.
    Domain missing → establish the primary, then add the row
15. Tagged lessons log; a tag repeating 2+ times = a stable rule, promote it to
    the constitution
16. Projects board: status, last / next per workstream
17. Open-promises ledger
18. Layered memory: only identity is loaded into context, the rest is Read on
    demand. Everything wired via @include costs tokens EVERY session

### D. Subagents and gates
19. Skeptic subagent: audits your conclusion for proxy reasoning BEFORE delivery.
    Fires when the answer contains a number, a diagnosis, a negative claim, a
    claim about system state, or precedes an irreversible action
20. Reviewer subagent on a different model — second opinion before critical work ships
21. A cheap model for bulk mechanics (parsing, classification, reformatting).
    Don't burn the top model on grunt work
22. Rule: critical/irreversible work (money, prod, schema, deletes) — the reviewer
    runs on the FIRST pass, not after a failure

### E. Hygiene
23. Default reply-length limit
24. Don't spawn sessions: each new one = a full context reload
25. Heavy output (logs, huge greps) → a file; only the tail goes into context
26. An operator imperative ("do it", "go") = EXECUTE, no re-confirming. Anomalies
    go as a line AFTER acting, never as a blocking question before

## STEP 3. Diagnosis

Group the gaps:
- **CRITICAL** — the absence has already caused, or will cause, data damage, lost
  work, or false reports to the operator
- **IMPORTANT** — systematically burns tokens or time
- **LATER**

For each gap name the CLASS OF MISTAKE it closes. Not "hook X is missing", but
"without this I quote numbers from a subagent summary without recomputing from source".

## STEP 4. Build

Close top-down by criticality. Rules:

- Text rules → the constitution, short, no filler. Every line in permanent context
  costs tokens every session
- Mechanisms → a real executable hook, registered in settings.json, proven by a
  live run. A hook that never fired is not a mechanism
- Registries → create with STRUCTURE and at least one real row, not an empty template
- Don't build what never hurt you. An item with no class of mistake behind it —
  skip it and say why

## STEP 5. Verification

For every mechanism you built — a live run that TRIGGERS it. The hook must actually
fire and that must be visible in the output. Not "written and looks right", but
"ran it, here's the output".

## REPORT (one message, no walls of text)

1. What was PRESENT / MISSING — compact, by section letter
2. What you built and which class of mistake it closes
3. What you deliberately skipped and why
4. What was verified by a live run and what wasn't
5. One next step with a question to the operator
