#!/usr/bin/env python3
"""Run a scheduled node job, report its result, wake the agent only if needed.

Replaces the old pattern "type the job into the agent's own session": that made a
scheduled turn look like a human message, the turn lost the chat it came from and
the human's answer was dropped (gorbot, 19.09.2026). Here the schedule runs the
job deterministically and sends the finished report; the agent is woken only for
the cases a human judgement was wanted for.

Usage:
  job-report.py drift   --workspace DIR --chat ID
  job-report.py manual  --workspace DIR --chat ID
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

BIN = Path(__file__).resolve().parent
NODE = "node"
QUOTA_MARKERS = ("quota", "userRateLimitExceeded", "rateLimitExceeded")


def run_node(workspace: Path, script: str) -> tuple[int, str]:
    proc = subprocess.run([NODE, script], cwd=workspace, capture_output=True, text=True, timeout=1800)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


def notify(chat: str, text: str) -> None:
    subprocess.run([sys.executable, str(BIN / "tg-send.py"), text, "--chat", chat], check=False)


def wake_agent(prompt: str) -> None:
    helper = BIN / "pane-send-when-idle.sh"
    if helper.exists():
        subprocess.run(["/bin/bash", str(helper), "channel-gorbot", prompt], check=False)


def json_after(out: str, label: str) -> object | None:
    """Pull the JSON blob the node job prints right after its own label."""
    idx = out.find(label)
    if idx < 0:
        return None
    tail = out[idx + len(label):]
    start = min((p for p in (tail.find("["), tail.find("{")) if p >= 0), default=-1)
    if start < 0:
        return None
    try:
        obj, _ = json.JSONDecoder().raw_decode(tail[start:])
    except ValueError:
        return None
    return obj


def count_after(out: str, label: str) -> int:
    m = re.search(re.escape(label) + r"\D*(\d+)", out)
    return int(m.group(1)) if m else 0


def do_drift(workspace: Path, chat: str) -> int:
    code, out = run_node(workspace, "src/checkPriceDrift.js")
    if code != 0:
        notify(chat, "Проверка ручных правок цены упала. Разбираюсь.")
        wake_agent(f"[СБОЙ ЗАДАНИЯ] src/checkPriceDrift.js вернул код {code}. Разберись и починИ, отчитайся владельцу. Хвост вывода:\n{out[-1500:]}")
        return 1
    n = count_after(out, "ручных правок цены найдено и вписано:")
    drifts = json_after(out, "ручных правок цены найдено и вписано:") or {}
    if n:
        lines = [f"Ручные правки цены подхватил и закрепил: {n}."]
        for item_id, val in list(drifts.items())[:15]:
            price = val.get("price") if isinstance(val, dict) else val
            lines.append(f"{item_id} -- {price}")
        notify(chat, "\n".join(lines))

    code2, out2 = run_node(workspace, "src/refreshReconciliationSheet.js")
    if code2 != 0:
        if any(m.lower() in out2.lower() for m in QUOTA_MARKERS):
            print("таблица согласования: квота Диска, молчим -- известная плавающая проблема")
        else:
            notify(chat, "Таблицу согласования освежить не смог -- ошибка не про квоту. Смотрю.")
            wake_agent(f"[СБОЙ ЗАДАНИЯ] src/refreshReconciliationSheet.js вернул код {code2} (не квота). Разберись. Хвост:\n{out2[-1500:]}")
    return 0


def do_manual(workspace: Path, chat: str) -> int:
    code, out = run_node(workspace, "src/checkNewManualItems.js")
    if code != 0:
        notify(chat, "Проверка новых ручных объявлений упала. Разбираюсь.")
        wake_agent(f"[СБОЙ ЗАДАНИЯ] src/checkNewManualItems.js вернул код {code}. Разберись и отчитайся. Хвост:\n{out[-1500:]}")
        return 1
    new_found = json_after(out, "новых ручных найдено:") or []
    completed = json_after(out, "добавлено в фид (фото уже были):") or []
    pending = json_after(out, "всё ещё ждут фото/данных:") or []

    parts: list[str] = []
    if new_found:
        parts.append(f"Нашёл новых ручных объявлений: {len(new_found)}.")
        for it in new_found[:10]:
            if isinstance(it, dict):
                parts.append(f"{it.get('id')} -- {it.get('title', '?')}, {it.get('price', '?')}")
    if completed:
        parts.append(f"Добавил в фид и опубликовал: {len(completed)}. Автозагрузка подхватит на ближайшем часовом прогоне.")
    # The waiting pile barely moves between runs; repeating the same number three
    # times a day is noise. Report it only when it changed.
    state = workspace / "data" / "pending-reported.json"
    prev = None
    try:
        prev = json.loads(state.read_text(encoding="utf-8")).get("pending")
    except (OSError, ValueError):
        prev = None
    if pending and len(pending) != prev:
        parts.append(f"Ждут фото или данных: {len(pending)} (было {prev if prev is not None else '--'}).")
    try:
        state.parent.mkdir(parents=True, exist_ok=True)
        state.write_text(json.dumps({"pending": len(pending)}), encoding="utf-8")
    except OSError:
        pass
    if parts:
        notify(chat, "\n".join(parts))

    # Only a case needing judgement wakes the agent: a missing field or a feed
    # sheet nobody has created. "нет фото" resolves by itself on the next run.
    hard = [p for p in pending if isinstance(p, dict) and p.get("blockReason") and "нет фото" not in str(p.get("blockReason"))]
    if hard:
        listing = "; ".join(f"{p.get('id')}: {p.get('blockReason')}" for p in hard[:10])
        wake_agent("[РУЧНОЙ РАЗБОР] Эти объявления сами не поедут, нужен твой разбор и ответ владельцу в группу: " + listing)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("job", choices=["drift", "manual"])
    ap.add_argument("--workspace", required=True)
    ap.add_argument("--chat", required=True)
    args = ap.parse_args()
    workspace = Path(args.workspace)
    return do_drift(workspace, args.chat) if args.job == "drift" else do_manual(workspace, args.chat)


if __name__ == "__main__":
    sys.exit(main())
