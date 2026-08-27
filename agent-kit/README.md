# agent-kit — the discipline layer

`install-agent.sh` produces an agent that runs, talks to its owner and remembers.
This kit gives it the WAY OF WORKING that Jarvis grew over months of operator
corrections — so a fresh agent starts where the old one ended up, not at zero.

Laid down by `install-kit.sh` (called automatically from `install-agent.sh`, step 7b):

| What | Where it lands | Class of mistake it closes |
|---|---|---|
| Constitution | `core/constitution.md` (@include'd) | answering off a proxy; refusing before trying; going silent after finishing; treating an imperative as a question |
| `block-dangerous.sh` | PreToolUse Bash | recursive deletes and destructive SQL run without a confirm |
| `block-red-zone.sh` | PreToolUse Write/Edit | writing secrets to disk; silent edits to the constitution |
| `block-selfmatching-pgrep.sh` | PreToolUse Bash | a `pgrep -f` waiter that matches its own command line and hangs forever |
| `truncate-bash-output.sh` | PostToolUse Bash | a huge log dumped into context, burning cache every turn after |
| `lesson-needs-mechanism.sh` | PostToolUse Edit/Write | a lesson filed as a diary line and repeated the next week |
| `cyrillic-guard.sh` | PostToolUse Edit/Write | non-English prose in files that reload every session — 2-3x the tokens |
| `capture-open-threads.py` | Stop | "I'll come back with…" that never reaches the ledger |
| `stop-closeout-gate.py` | Stop | work finished in the terminal and never reported to the owner |
| `stop-blocker-gate.py` | Stop | handing the task back ("no access", "waiting on you") without an enumeration |
| `bin/bg.sh` | wrapper | a long run whose failure is never reported — silence read as success |
| `bin/promise-sweeper.py` | cron 09:30 | a dated promise sitting in the ledger with nothing to wake the agent |
| `core/SOURCES.md` | registry | not knowing a primary source exists, so a cache becomes the verdict |
| `core/open-threads.md` | ledger | the single board: promises, projects, next steps |
| `agents/{proxy-skeptic,reviewer,parser}.md` | subagents | shipping a number or a diagnosis with no independent check |
| `docs/agent-self-audit.md` | task | the audit the agent runs on itself to find what is still missing |

**What it never touches:** `core/rules.md` — the owner's own log of corrections.
The kit writes the constitution beside it, not over it. An existing `SOURCES.md`
or `open-threads.md` is left alone too.

**Standalone use:**

```
./install-kit.sh --claude-dir ~/.claude-lab/<agent>/.claude \
                 --chat-id <telegram id> --agent <name>
```

Idempotent: re-running refreshes the files and never double-registers a hook.
