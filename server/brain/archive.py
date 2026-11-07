"""对话存档：原文、账本、设置、状态、人设版本、每轮记录、用量账。
所有 SQL 的 WHERE 都带 user_id——别人的东西在这一层就看不见。JSON 以文本进出（asyncpg 默认如此）。"""
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from uuid import UUID

import asyncpg

from llm.types import Usage

SCHEMA_FILE = Path(__file__).with_name("schema.sql")
_MSG_COLS = "id, role, text, thinking, created_at, tools, parts, cards, thinking_ms, inner_voice, speaker_id, speaker_name, translations, call, variants, variant"
_JSON_TABLES = ("user_settings", "user_state")
USER_SIDE = ("user", "wake")      # 历史里算用户那一侧的：TA 说的话、叫醒它的〔醒来〕
_ALL_TABLES = ("chat_messages", "ledger_days", "user_settings", "user_state", "personas", "turn_logs",
               "usage_daily")


@dataclass
class StoredMsg:
    id: int
    role: str
    text: str
    thinking: str
    created_at: datetime
    tools: str = ""              # 它这一轮用过的工具，一行一个（只有它说的话才有）
    parts: list[str] | None = None   # TA 连发的几句原来怎么分的（只有拼过的才有）
    cards: list[dict] | None = None  # 这一轮挂出来的动作卡片 [{kind, text}]（只有它说的话才有）
    thinking_ms: int | None = None   # 这一轮想了多久（10-05）；早先的消息、没思考的是 None
    inner_voice: str = ""            # 回复后的心声（10-11）
    speaker: UUID | None = None      # 群里是哪个 TA 说的（10-11）；私聊是 None
    speaker_name: str = ""
    translations: list | None = None     # 双语气泡（10-15）：跟气泡一一对应的译文
    variants: list[str] | None = None    # 重新回留下的几版（11-07），含现在这版
    variant: int | None = None           # 现在显示第几版
    call: dict | None = None             # 电话（10-31）：{id, cut, end, seconds, line}；不是电话里的话是 None


def _now(now: datetime | None) -> datetime:
    return now or datetime.now(timezone.utc)


def _msg(r) -> StoredMsg:
    def js(v):
        return json.loads(v) if isinstance(v, str) else v
    return StoredMsg(r["id"], r["role"], r["text"], r["thinking"], r["created_at"], r["tools"],
                     js(r["parts"]), js(r["cards"]), r["thinking_ms"], r["inner_voice"] or "",
                     r["speaker_id"], r["speaker_name"] or "", js(r["translations"]), js(r["variants"]), r["variant"], js(r["call"]))


async def apply_brain_schema(dsn: str) -> None:
    conn = await asyncpg.connect(dsn)
    try:
        await conn.execute(SCHEMA_FILE.read_text(encoding="utf-8"))
    finally:
        await conn.close()


async def add_message(pool, user_id: UUID, role: str, text: str, *, thinking: str = "", tools: str = "",
                      parts: list[str] | None = None, cards: list[dict] | None = None,
                      thinking_ms: int | None = None, inner_voice: str = "", now: datetime | None = None,
                      speaker: UUID | None = None, speaker_name: str = "", translations: list | None = None,
                      call: dict | None = None) -> StoredMsg:
    r = await pool.fetchrow(
        f"INSERT INTO chat_messages (user_id, role, text, thinking, created_at, tools, parts, cards, thinking_ms, inner_voice, "
        f"speaker_id, speaker_name, translations, call) "
        f"VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8::jsonb, $9, $10, $11, $12, $13::jsonb, $14::jsonb) RETURNING {_MSG_COLS}", user_id, role, text, thinking,
        _now(now), tools, json.dumps(parts, ensure_ascii=False) if parts and len(parts) > 1 else None,
        json.dumps(cards, ensure_ascii=False) if cards else None, thinking_ms if thinking.strip() else None, inner_voice,
        speaker, speaker_name, _translations(translations), json.dumps(call, ensure_ascii=False) if call else None)
    return _msg(r)


async def set_variants(pool, message_id: int, variants: list[str], index: int) -> None:
    await pool.execute("UPDATE chat_messages SET variants = $2::jsonb, variant = $3 WHERE id = $1",
                       message_id, json.dumps(variants, ensure_ascii=False), index)


async def set_reply_text(pool, message_id: int, text: str, *, variants: list[str] | None = None, index: int | None = None) -> None:
    """改 TA 说过的话 / 换到另一版（11-07）。气泡切法变了，那条上的译文作废。"""
    await pool.execute("UPDATE chat_messages SET text = $2, translations = NULL, variants = COALESCE($3::jsonb, variants), "
                       "variant = COALESCE($4, variant) WHERE id = $1", message_id, text,
                       json.dumps(variants, ensure_ascii=False) if variants is not None else None, index)


async def set_call_text(pool, message_id: int, text: str, call: dict) -> None:
    """电话里那句改字（准确转写回来了）/ 它那句改成只留念到的（被打断，10-31）"""
    await pool.execute("UPDATE chat_messages SET text = $2, call = $3::jsonb WHERE id = $1",
                       message_id, text, json.dumps(call, ensure_ascii=False))


async def get_message(pool, message_id: int) -> StoredMsg | None:
    r = await pool.fetchrow(f"SELECT {_MSG_COLS} FROM chat_messages WHERE id = $1", message_id)
    return _msg(r) if r else None


def _translations(t: list | None) -> str | None:
    return json.dumps(t, ensure_ascii=False) if t and any(isinstance(x, str) and x for x in t) else None


async def set_translations(pool, message_id: int, translations: list | None) -> None:
    """你那句翻好以后补上（10-15 双语气泡）"""
    await pool.execute("UPDATE chat_messages SET translations = $2::jsonb WHERE id = $1", message_id, _translations(translations))


async def unrolled(pool, user_id: UUID) -> list[StoredMsg]:
    rows = await pool.fetch(
        f"SELECT {_MSG_COLS} FROM chat_messages WHERE user_id = $1 AND NOT rolled ORDER BY id", user_id)
    return [_msg(r) for r in rows]


async def recent(pool, user_id: UUID, limit: int = 100) -> list[StoredMsg]:
    rows = await pool.fetch(
        f"SELECT {_MSG_COLS} FROM chat_messages WHERE user_id = $1 ORDER BY id DESC LIMIT $2", user_id, limit)
    return [_msg(r) for r in reversed(rows)]


async def after(pool, user_id: UUID, after_id: int = 0, limit: int = 200) -> list[StoredMsg]:
    """补拉：比 after_id 新的消息（卷没卷进账本都算），从旧到新。"""
    rows = await pool.fetch(
        f"SELECT {_MSG_COLS} FROM chat_messages WHERE user_id = $1 AND id > $2 ORDER BY id LIMIT $3",
        user_id, after_id, limit)
    return [_msg(r) for r in rows]


async def before(pool, user_id: UUID, before_id: int, limit: int = 50) -> tuple[list[StoredMsg], bool]:
    """往前翻：比 before_id 旧的最多 limit 条（从旧到新），外加还有没有更早的。"""
    rows = await pool.fetch(
        f"SELECT {_MSG_COLS} FROM chat_messages WHERE user_id = $1 AND id < $2 ORDER BY id DESC LIMIT $3",
        user_id, before_id, limit + 1)
    return [_msg(r) for r in reversed(rows[:limit])], len(rows) > limit


async def between(pool, user_id: UUID, start: datetime, end: datetime, limit: int = 500) -> list[StoredMsg]:
    rows = await pool.fetch(
        f"SELECT {_MSG_COLS} FROM chat_messages WHERE user_id = $1 AND created_at >= $2 AND created_at < $3 "
        f"ORDER BY id LIMIT $4", user_id, start, end, limit)
    return [_msg(r) for r in rows]


async def search(pool, user_id: UUID, query: str, limit: int = 50) -> list[StoredMsg]:
    """按字搜：只搜说出口的话（不搜思考链，不含〔醒来〕），新的在前。"""
    like = "%" + query.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%"
    rows = await pool.fetch(
        f"SELECT {_MSG_COLS} FROM chat_messages WHERE user_id = $1 AND role IN ('user', 'assistant') "
        f"AND text ILIKE $2 ORDER BY id DESC LIMIT $3", user_id, like, limit)
    return [_msg(r) for r in rows]


async def neighbours(pool, user_id: UUID, message_id: int) -> tuple[StoredMsg | None, StoredMsg | None]:
    """一条消息前后各一条说出口的话（搜索结果给上下文）。"""
    prev = await pool.fetchrow(f"SELECT {_MSG_COLS} FROM chat_messages WHERE user_id = $1 AND id < $2 "
                               f"AND role IN ('user', 'assistant') ORDER BY id DESC LIMIT 1", user_id, message_id)
    nxt = await pool.fetchrow(f"SELECT {_MSG_COLS} FROM chat_messages WHERE user_id = $1 AND id > $2 "
                              f"AND role IN ('user', 'assistant') ORDER BY id LIMIT 1", user_id, message_id)
    return (_msg(prev) if prev else None, _msg(nxt) if nxt else None)


async def delete_message(pool, owner: UUID, message_id: int) -> bool:
    """撤回用（10-20，照之前自用的 App）：只删这一句（还没卷进账本、是用户自己说的），别的不动。"""
    status = await pool.execute("DELETE FROM chat_messages WHERE user_id = $1 AND id = $2 AND role = 'user' AND NOT rolled",
                                owner, message_id)
    return status.split()[-1] != "0"


async def delete_messages_after(pool, owner: UUID, message_id: int) -> int:
    """倒回用：删掉这个窗口里比 message_id 新的所有消息（只删还没卷进账本的）。"""
    status = await pool.execute("DELETE FROM chat_messages WHERE user_id = $1 AND id > $2 AND NOT rolled",
                                owner, message_id)
    return int(status.split()[-1])


async def mark_rolled(pool, user_id: UUID, ids) -> None:
    await pool.execute("UPDATE chat_messages SET rolled = TRUE WHERE user_id = $1 AND id = ANY($2::bigint[])",
                       user_id, [int(i) for i in ids])


async def get_ledger(pool, user_id: UUID) -> dict[date, str]:
    rows = await pool.fetch("SELECT day, text FROM ledger_days WHERE user_id = $1 ORDER BY day", user_id)
    return {r["day"]: r["text"] for r in rows}


async def put_ledger(pool, user_id: UUID, days: dict[date, str], *, now: datetime | None = None) -> None:
    async with pool.acquire() as conn:
        async with conn.transaction():
            for day, text in days.items():
                if text.strip():
                    await conn.execute(
                        """INSERT INTO ledger_days (user_id, day, text, updated_at) VALUES ($1, $2, $3, $4)
                           ON CONFLICT (user_id, day) DO UPDATE SET text = EXCLUDED.text,
                                                                     updated_at = EXCLUDED.updated_at""",
                        user_id, day, text, _now(now))
                else:
                    await conn.execute("DELETE FROM ledger_days WHERE user_id = $1 AND day = $2", user_id, day)


async def _get_json(pool, table: str, user_id: UUID) -> dict:
    assert table in _JSON_TABLES
    raw = await pool.fetchval(f"SELECT data FROM {table} WHERE user_id = $1", user_id)
    return json.loads(raw) if raw else {}


async def _put_json(pool, table: str, user_id: UUID, data: dict, now: datetime | None) -> None:
    assert table in _JSON_TABLES
    await pool.execute(
        f"""INSERT INTO {table} (user_id, data, updated_at) VALUES ($1, $2::jsonb, $3)
            ON CONFLICT (user_id) DO UPDATE SET data = EXCLUDED.data, updated_at = EXCLUDED.updated_at""",
        user_id, json.dumps(data, ensure_ascii=False), _now(now))


async def get_settings(pool, user_id: UUID) -> dict:
    return await _get_json(pool, "user_settings", user_id)


async def save_settings(pool, user_id: UUID, data: dict, *, now: datetime | None = None) -> None:
    await _put_json(pool, "user_settings", user_id, data, now)


async def get_state(pool, user_id: UUID) -> dict:
    return await _get_json(pool, "user_state", user_id)


async def save_state(pool, user_id: UUID, data: dict, *, now: datetime | None = None) -> None:
    await _put_json(pool, "user_state", user_id, data, now)


async def save_persona(pool, user_id: UUID, data: dict, *, now: datetime | None = None) -> int:
    return await pool.fetchval(
        "INSERT INTO personas (user_id, data, created_at) VALUES ($1, $2::jsonb, $3) RETURNING id",
        user_id, json.dumps(data, ensure_ascii=False), _now(now))


async def get_persona(pool, user_id: UUID) -> dict | None:
    raw = await pool.fetchval("SELECT data FROM personas WHERE user_id = $1 ORDER BY id DESC LIMIT 1", user_id)
    return json.loads(raw) if raw else None


async def persona_history(pool, user_id: UUID, limit: int = 20) -> list[dict]:
    rows = await pool.fetch(
        "SELECT id, created_at, data FROM personas WHERE user_id = $1 ORDER BY id DESC LIMIT $2", user_id, limit)
    return [{"id": r["id"], "created_at": r["created_at"].isoformat(), "data": json.loads(r["data"])}
            for r in rows]


async def log_turn(pool, user_id: UUID, data: dict, *, now: datetime | None = None) -> None:
    await pool.execute("INSERT INTO turn_logs (user_id, data, created_at) VALUES ($1, $2::jsonb, $3)",
                       user_id, json.dumps(data, ensure_ascii=False, default=str), _now(now))


async def add_usage(pool, user_id: UUID, day: date, model: str, usage: Usage, cost_usd: float | None) -> None:
    await pool.execute(
        """INSERT INTO usage_daily (user_id, day, model, calls, input, cache_read, cache_write, output,
                                    cost_usd, unknown_cost_calls)
           VALUES ($1, $2, $3, 1, $4, $5, $6, $7, $8, $9)
           ON CONFLICT (user_id, day, model) DO UPDATE SET
             calls = usage_daily.calls + 1,
             input = usage_daily.input + EXCLUDED.input,
             cache_read = usage_daily.cache_read + EXCLUDED.cache_read,
             cache_write = usage_daily.cache_write + EXCLUDED.cache_write,
             output = usage_daily.output + EXCLUDED.output,
             cost_usd = usage_daily.cost_usd + EXCLUDED.cost_usd,
             unknown_cost_calls = usage_daily.unknown_cost_calls + EXCLUDED.unknown_cost_calls""",
        user_id, day, model, usage.input, usage.cache_read, usage.cache_write, usage.output,
        cost_usd or 0.0, 1 if cost_usd is None else 0)


async def usage_on(pool, user_id: UUID, day: date) -> dict:
    r = await pool.fetchrow(
        """SELECT COALESCE(SUM(calls), 0) AS calls, COALESCE(SUM(input), 0) AS input,
                  COALESCE(SUM(cache_read), 0) AS cache_read, COALESCE(SUM(cache_write), 0) AS cache_write,
                  COALESCE(SUM(output), 0) AS output, COALESCE(SUM(cost_usd), 0) AS cost_usd,
                  COALESCE(SUM(unknown_cost_calls), 0) AS unknown_cost_calls
           FROM usage_daily WHERE user_id = $1 AND day = $2""", user_id, day)
    out = {k: int(r[k]) for k in ("calls", "input", "cache_read", "cache_write", "output", "unknown_cost_calls")}
    out["cost_usd"] = float(r["cost_usd"])
    return out


async def export(pool, user_id: UUID) -> dict:
    msgs = await pool.fetch(f"SELECT {_MSG_COLS}, rolled FROM chat_messages WHERE user_id = $1 ORDER BY id",
                            user_id)
    usage = await pool.fetch("SELECT * FROM usage_daily WHERE user_id = $1 ORDER BY day, model", user_id)
    return {
        "messages": [{"id": r["id"], "role": r["role"], "text": r["text"], "thinking": r["thinking"],
                      "inner_voice": r["inner_voice"] or "",
                      **({"speaker": str(r["speaker_id"]), "speaker_name": r["speaker_name"]} if r["speaker_id"] else {}),
                      "created_at": r["created_at"].isoformat(), "rolled": r["rolled"]} for r in msgs],
        "ledger": {d.isoformat(): t for d, t in (await get_ledger(pool, user_id)).items()},
        "settings": await get_settings(pool, user_id),
        "state": await get_state(pool, user_id),
        "personas": await persona_history(pool, user_id, limit=1000),
        "usage": [{k: (v.isoformat() if isinstance(v, date) else str(v) if isinstance(v, UUID) else v)
                   for k, v in dict(r).items()} for r in usage],
    }


async def wipe(pool, user_id: UUID) -> None:
    async with pool.acquire() as conn:
        async with conn.transaction():
            for table in _ALL_TABLES:
                await conn.execute(f"DELETE FROM {table} WHERE user_id = $1", user_id)
