# SOURCES.md — registry of primary sources

Open this FIRST on any task touching data or an external system. One row per
domain. Domain missing? Establish the primary source, then ADD the row — that is
part of the task, not extra work.

Why it exists: the most expensive mistakes come from answering off a proxy (a
cached file, a neighbouring config, a subagent's summary, memory) while the
primary source was one command away.

| Domain | Primary source | How to read it | The proxy I mistake for it |
|---|---|---|---|
| My own config | `~/.claude/settings.json`, `.claude/hooks/` | read the file, run the hook | my memory of "how it was set up" |
| _add your own_ | | | |

Rules for a row:
- **Primary** = the system that OWNS the fact (the API, the database, the official
  reference), never a copy of it.
- **How to read it** = a runnable command or endpoint, not a description.
- **The proxy** = the thing that looks authoritative and is not. Name it explicitly:
  that column is what stops the next mistake.
