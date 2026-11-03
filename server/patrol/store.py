"""巡逻的表（第 3 步）：钟、醒来账。每个查询都带着账号或联系人，别人家的钟看不见也改不动。

钟的三类：user（你定的，TA 看得见）/ self（它约的，TA 看不见——接口默认只给 user）/ heartbeat（心跳，每个联系人一行）。
领钟：`claim_due` 用 FOR UPDATE SKIP LOCKED，领到的先把 next_at 往后占 5 分钟，跑完再写真的；
以后开两台服务器也只会被领一次，跑到一半服务器崩了，5 分钟后会被重新领。"""
from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timedelta
from uuid import UUID

CLAIM_HOLD = timedelta(minutes=5)
WOKE = ("said", "silent", "error")          # 真的醒了（调了模型）的几种结果
_COLS = "id, account_id, companion_id, kind, shape, spec, note, next_at, created_at, todo_id"


@dataclass
class Clock:
    id: int
    account_id: UUID
    companion_id: UUID
    kind: str
    shape: str
    spec: dict
    note: str
    next_at: datetime | None
    created_at: datetime
    todo_id: int | None = None      # 待办的钟（kind='todo'，10-01）


def _clock(r) -> Clock:
    d = dict(r)
    d["spec"] = json.loads(d["spec"]) if isinstance(d["spec"], str) else dict(d["spec"] or {})
    return Clock(**d)


async def add_clock(pool, account: UUID, companion: UUID, *, kind: str, shape: str, spec: dict, note: str,
                    next_at: datetime | None) -> Clock:
    r = await pool.fetchrow(
        f"""INSERT INTO clocks (account_id, companion_id, kind, shape, spec, note, next_at)
            SELECT $1, $2, $3, $4, $5::jsonb, $6, $7 WHERE EXISTS
              (SELECT 1 FROM companions WHERE id = $2 AND account_id = $1)
            RETURNING {_COLS}""", account, companion, kind, shape, json.dumps(spec), note, next_at)
    if r is None:
        raise PermissionError("没有这个联系人")
    return _clock(r)


async def list_clocks(pool, account: UUID, companion: UUID, *, kinds=("user",)) -> list[Clock]:
    rows = await pool.fetch(
        f"""SELECT {_COLS} FROM clocks WHERE account_id = $1 AND companion_id = $2 AND kind = ANY($3::text[])
            ORDER BY next_at NULLS LAST, id""", account, companion, list(kinds))
    return [_clock(r) for r in rows]


async def get_clock(pool, account: UUID, clock_id: int, *, kinds=("user",)) -> Clock | None:
    r = await pool.fetchrow(f"SELECT {_COLS} FROM clocks WHERE id = $1 AND account_id = $2 AND kind = ANY($3::text[])",
                            clock_id, account, list(kinds))
    return _clock(r) if r else None


_UNSET = object()


async def update_clock(pool, account: UUID, clock_id: int, *, shape: str | None = None, spec: dict | None = None,
                       note: str | None = None, next_at=_UNSET, kinds=("user",)) -> Clock | None:
    """只改带了的项；不是这个账号的、类别不对的（比如接口想改它约的）返回 None。"""
    c = await get_clock(pool, account, clock_id, kinds=kinds)
    if c is None:
        return None
    r = await pool.fetchrow(
        f"""UPDATE clocks SET shape = $2, spec = $3::jsonb, note = $4, next_at = $5 WHERE id = $1
            RETURNING {_COLS}""", clock_id, shape or c.shape, json.dumps(c.spec if spec is None else spec),
        c.note if note is None else note, c.next_at if next_at is _UNSET else next_at)
    return _clock(r)


async def delete_clock(pool, account: UUID, clock_id: int, *, kinds=("user",)) -> bool:
    done = await pool.execute("DELETE FROM clocks WHERE id = $1 AND account_id = $2 AND kind = ANY($3::text[])",
                              clock_id, account, list(kinds))
    return done.endswith(" 1")


async def ensure_heartbeat(pool, account: UUID, companion: UUID, next_at: datetime) -> None:
    await pool.execute(
        """INSERT INTO clocks (account_id, companion_id, kind, shape, next_at) VALUES ($1, $2, 'heartbeat', 'heartbeat', $3)
           ON CONFLICT (companion_id) WHERE kind = 'heartbeat' DO NOTHING""", account, companion, next_at)


async def claim_due(pool, now: datetime, *, limit: int = 50) -> list[Clock]:
    rows = await pool.fetch(
        f"""UPDATE clocks SET next_at = $2 WHERE id IN (
              SELECT id FROM clocks WHERE next_at <= $1 ORDER BY next_at LIMIT $3 FOR UPDATE SKIP LOCKED)
            RETURNING {_COLS}""", now, now + CLAIM_HOLD, limit)
    return [_clock(r) for r in rows]


async def reschedule(pool, clock_id: int, next_at: datetime | None) -> None:
    """下一次什么时候；None = 这个钟响完了，删掉（心跳不会传 None）。"""
    if next_at is None:
        await pool.execute("DELETE FROM clocks WHERE id = $1", clock_id)
    else:
        await pool.execute("UPDATE clocks SET next_at = $2 WHERE id = $1", clock_id, next_at)


async def set_spec(pool, clock_id: int, spec: dict) -> None:
    await pool.execute("UPDATE clocks SET spec = $2::jsonb WHERE id = $1", clock_id, json.dumps(spec))


async def count_self(pool, companion: UUID) -> int:
    return await pool.fetchval("SELECT count(*) FROM clocks WHERE companion_id = $1 AND kind = 'self'", companion)


# ── 醒来账 ──

async def log_wake(pool, *, account: UUID, companion: UUID, conversation: UUID | None, at: datetime, reason: str,
                   clock_id: int | None, outcome: str, cost_usd: float = 0.0, detail: dict | None = None,
                   message_id: int | None = None) -> None:
    await pool.execute(
        """INSERT INTO wake_log (account_id, companion_id, conversation_id, at, reason, clock_id, outcome, cost_usd, detail,
                                  message_id)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10)""",
        account, companion, conversation, at, reason, clock_id, outcome, cost_usd,
        json.dumps(detail or {}, ensure_ascii=False), message_id)


async def wakes_since(pool, companion: UUID, since: datetime) -> int:
    """从 since 起真醒了几次（跳过的不算）——算「今天醒够了没」用。"""
    return await pool.fetchval("SELECT count(*) FROM wake_log WHERE companion_id = $1 AND at >= $2 "
                               "AND outcome = ANY($3::text[]) AND reason NOT IN ('meal', 'picks')", companion, since, list(WOKE))   # 记一餐、每日私选不占每天的份


async def night_found(pool, companion: UUID, since: datetime) -> int:
    """这一晚因为「深夜醒着」说了几次话。"""
    return await pool.fetchval("SELECT count(*) FROM wake_log WHERE companion_id = $1 AND at >= $2 "
                               "AND reason = 'night_awake' AND outcome = 'said'", companion, since)


async def last_woke_at(pool, companion: UUID) -> datetime | None:
    return await pool.fetchval("SELECT max(at) FROM wake_log WHERE companion_id = $1 AND outcome = ANY($2::text[])",
                               companion, list(WOKE))


async def quiet_streak(pool, companion: UUID, *, last_user_at: datetime | None) -> int:
    """最近连着几次醒来没说话：从新往旧数，碰到它说了话、或者数到 TA 上次说话之前就停。"""
    rows = await pool.fetch(
        """SELECT outcome FROM wake_log WHERE companion_id = $1 AND outcome IN ('said', 'silent')
           AND ($2::timestamptz IS NULL OR at > $2) ORDER BY at DESC LIMIT 50""", companion, last_user_at)
    n = 0
    for r in rows:
        if r["outcome"] != "silent":
            break
        n += 1
    return n


async def said_since(pool, companion: UUID, since: datetime) -> int:
    """从 since 起它醒来开口了几次（〔醒来〕里的「今天已经主动找过 TA 几次」）。"""
    return await pool.fetchval("SELECT count(*) FROM wake_log WHERE companion_id = $1 AND at >= $2 AND outcome = 'said' "
                               "AND reason NOT IN ('meal', 'picks')",   # 记一餐是 TA 引出来的、私选是每天的例行，不算主动找
                               companion, since)


async def ensure_all_heartbeats(pool, next_at: datetime) -> None:
    """每个联系人都该有一行心跳；新账号、新联系人、老数据都在这里补上（巡逻每一圈顺手做）。"""
    await pool.execute(
        """INSERT INTO clocks (account_id, companion_id, kind, shape, next_at)
           SELECT account_id, id, 'heartbeat', 'heartbeat', $1 FROM companions c
           WHERE NOT EXISTS (SELECT 1 FROM clocks k WHERE k.companion_id = c.id AND k.kind = 'heartbeat')
           ON CONFLICT (companion_id) WHERE kind = 'heartbeat' DO NOTHING""", next_at)


async def last_said(pool, companion: UUID) -> tuple[datetime | None, str | None, datetime | None]:
    """这个联系人所有窗口里最后一句话：(什么时候, 谁说的 user/assistant, TA 最后一次说话的时候)。"""
    r = await pool.fetchrow(
        """SELECT m.created_at, m.role FROM chat_messages m JOIN conversations c ON c.id = m.user_id
           WHERE c.companion_id = $1 AND m.role IN ('user', 'assistant') ORDER BY m.created_at DESC LIMIT 1""",
        companion)
    user_at = await pool.fetchval(
        """SELECT max(m.created_at) FROM chat_messages m JOIN conversations c ON c.id = m.user_id
           WHERE c.companion_id = $1 AND m.role = 'user'""", companion)
    return (r["created_at"], r["role"], user_at) if r else (None, None, user_at)


async def queue_push(pool, *, account: UUID, companion: UUID, conversation: UUID, text: str,
                     urgent: bool = False, quiet: bool = False) -> None:
    """urgent = 时效性通知（穿过勿扰）：只给 TA 自己定的钟、远事当天那次。quiet = 不响（早上那句，别吵醒 TA）。"""
    from brain import markers, voice      # 通知里是人话（10-31）：语音条给逐字稿（不带 🎤 和 [soft]），标记一个都不留
    text = markers.scrub("\n\n".join(voice.as_text(p) if voice.is_voice(p) else p for p in (text or "").split("\n\n")))
    await pool.execute("INSERT INTO push_queue (account_id, companion_id, conversation_id, text, urgent, quiet) "
                       "VALUES ($1, $2, $3, $4, $5, $6)", account, companion, conversation, text, urgent, quiet)

