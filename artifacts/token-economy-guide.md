# Token Economy for Claude Code / agents — practical guide (v2)

Battle-tested on a production assistant (Telegram bot on Claude Code, dozens of
turns/day). Principles are portable — apply them to your own setup. Ordered
roughly by payoff.

---

## 0. The real cost law: baseline × caching

The costliest thing isn't a single long answer — it's **whatever sits in
context every turn**. Extra 300 tokens in CLAUDE.md × 60 turns/session = 18k
tokens of pure tax, every session. People trim answers; the silent tax sits in
the prefix.

But "attack the baseline" is incomplete without caching. Under prompt-caching a
stable prefix costs ~10% (cache read) — so what makes baseline expensive is not
its **size**, it's its **growth and churn within a session**. Any write near the
*start* of context invalidates the cache and you pay the full prefix again. A
small but constantly-changing context can cost more than a large frozen one.

**The law: attack the GROWING and NON-CACHED baseline.** Keep the prefix big-but-
frozen if you must; never let it drift mid-session.

## 1. Progressive context disclosure (the main lever)

- **Keep CLAUDE.md / always-on @include minimal.** Only what's needed literally
  every turn (identity, core rules). Everything else — `Read` on demand.
- **Memory = thin index, not a dump.** One line per entry: title + link + hook.
  Details live in separate files, read only when needed. Index files drift the
  least when each fact is one line — directly serves the caching law above.
- Test: "is this line needed RIGHT NOW, every turn?" No → move it to a lazy file.

## 2. Skills instead of always-on playbooks

A skill is three-level lazy loading:
1. **Metadata** (YAML `description`) — always loaded, ~30–50 tokens/skill.
2. **Body** (SKILL.md) — only when `description` matches the task.
3. **Linked files** — on demand from the body.

Any playbook needed "once a week" (reports, special procedures) → make it a
skill. Only the cheap description stays in context. Write the description around
real phrasing — it decides whether the skill triggers.

## 3. Tool results are often the #1 baseline hog

Raw bash/grep/HTTP output lands in history and gets multiplied by every later
turn — frequently more than CLAUDE.md. **Filter at the source, don't haul the
wall and think later:**
- `head`/`tail`/`wc` instead of dumping a whole file or log.
- `jq` / field selection on JSON; `grep -c` when you only need a count.
- Ask for the slice you'll actually use, not "everything, I'll scan it."

This is a standing discipline, not a one-off — a verbose tool call poisons the
whole rest of the session.

## 4. Subagents as context isolation

Push dirty multi-step work (log spelunking, scraping, a noisy migration) into a
**separate agent that returns only the conclusion**. The main context never sees
the mess. This isn't about baseline — it's about *protecting the history* from
accumulating junk that you then pay for on every subsequent turn. One of the
strongest levers.

## 5. Reading files

- **`Read` with offset/limit** — grab the slice you need, not the whole file.
- **No defensive re-reads** — don't re-read a file "just in case" after editing.
  The edit tool fails loudly if the change didn't apply.
- **Grep/search precisely** instead of "read everything and scan with my eyes."

## 6. Sessions, cache & compaction

- **Don't spawn sessions.** Each new one reloads CLAUDE.md/memory from scratch
  (tens of K tokens of baseline) and starts cold (full prefix read, no cache).
  Continue in the current one; start fresh only after auto-compact.
- **Cache lives ~5 minutes (TTL).** Batch work: a pause >5 min means the next
  turn re-reads context (cache miss). Don't drip tiny actions with long gaps.
- **Compact/summarize a bloating history.** Long sessions degrade linearly in
  cost. Tier it: hot (recent, verbatim) → warm (summarized) → cold (index only).
  Without this, every turn drags the full transcript.

## 7. English for internal files

Cyrillic (or any non-ASCII) in UTF-8 costs **2–3× more tokens** than Latin. For
files loaded every session (CLAUDE.md, rules, memory index), English saves ~50%+
of their weight. User-facing replies stay in the user's language — that's an
output token of one turn, not part of the every-turn baseline, so it's a fair
trade. (Yes, this guide is in English on purpose.)

## 8. Models and effort

- **Default effort `medium`.** `high`/`xhigh` — only heavy architecture/debug.
  `low` — trivial work.
- **Per-task routing.** Parsing/classification/bulk grunt → cheap model (Haiku).
  Keep the expensive model (Opus) for architecture/review.

## 9. Output format (output is the expensive token)

Generated output typically costs **4–5× per token vs input**. Brevity saves on
the most expensive part, not just on baseline.
- **Compact JSON** for data exchange (no extra whitespace/newlines).
- **Short answers by default.** Tables/long write-ups only when explicitly asked.

## 10. Automation (loops/cron) with a checkable stop

If you run an agent in a loop / on a schedule — you **must** have a
machine-checkable termination condition (exit code, "tests green", "no new
tasks"). A loop without a stop spins idle and burns tokens. "Make the tests
pass" is a good stop; "improve the code" is infinite.

## 11. Measure, don't guess

Add cost telemetry (`ccusage` reads Claude Code's local logs, or roll your own
per-turn logger). Without measurement it's faith, not engineering. Confirm every
optimization with a before/after delta.

---

## Checklist when starting a project

- [ ] CLAUDE.md thin and FROZEN mid-session (caching law)
- [ ] Memory = index of one-liners + links
- [ ] Rare playbooks → skills with precise descriptions
- [ ] Filter tool output at the source (head/jq/grep -c)
- [ ] Dirty multi-step work → isolated subagent returning only the result
- [ ] Read with offset/limit, no defensive re-reads
- [ ] Compaction tier for long sessions (hot→warm→cold)
- [ ] Internal files in English
- [ ] effort=medium default, cheap model for grunt work
- [ ] Short output by default (output ≈ 4–5× input cost)
- [ ] Loops only with a checkable stop
- [ ] ccusage/telemetry on

**The core idea:** the costliest thing isn't a single long answer — it's the
**growing, non-cached baseline that sits in context every turn**. Freeze it,
filter what enters it, isolate the mess elsewhere. The savings compound.

---
_v2 additions (caching×baseline law, tool-output filtering, subagent isolation,
compaction, output-cost note) — credit to a peer review that caught the gaps._
