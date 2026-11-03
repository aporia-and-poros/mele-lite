"""哨兵的服务器这一半（巡逻第 6 步；手机那一半跟 app 一起做，要苹果的屏幕使用时间权限）。

开始专注：它照着自己平时的口气、看着记得的 TA 的事，写一串越来越急的提醒交给手机——手机里的小插件据说不能联网，
所以要预先写好，TA 分心越久弹得越急。结束专注：手机报分心了几次、几分钟，下一轮聊天时以一行〔专注〕告诉它（说过就不再说）。"""
from __future__ import annotations

import json
import re
import uuid
from datetime import date, datetime
from uuid import UUID

import memory as M
from llm.catalog import cost
from llm.errors import LLMError
from llm.router import call
from llm.types import Block, ChatRequest, Msg

from . import archive
from .context import user_tag
from .persona import Persona, render_base
from .scope import Scope
from .settings import Settings

LINES = 5
_BULLET = re.compile(r"^\s*(?:[-*•·]|\d+[.、)）])\s*")
_LOCK = re.compile(r"^\s*(?:锁|lock)\s*[:：]\s*(\S+)", re.I)
_PEEK = re.compile(r"^\s*(?:看一下|peek)\s*[:：]\s*(.+)$", re.I)
# 挡板上点「我就看一下」那一刻它说的一句（09-29 Aporia：不是固定的「确定吗」，看聊天记录写；按下去照样能看）。
# 挡板那个插件不一定能联网，所以开始时就写好。
PEEK_ASK = {
    "zh": "\n\n另外，TA 要是在挡板上点了「我就看一下」，你会马上说一句话——不拦 TA，但让 TA 想一下。照你们最近聊的写，"
          "别写成「确定吗」这种套话。最后单独一行写「看一下：……」。",
    "en": "\n\nAlso: if they tap \"just a quick look\" on the lock screen, you'll say one line right away — not stopping them, "
          "just making them think. Write it from what you've been talking about lately, not a generic \"are you sure\". "
          "Put it on one last line starting with \"Peek: \".",
}
PEEK_FALLBACK = {"zh": "就看一下哦，说好的。", "en": "Just a quick look, okay? You promised."}
RECENT_ASK = {"zh": "\n\n你们最近聊的：\n{chat}", "en": "\n\nWhat you two talked about lately:\n{chat}"}
# 允许它锁的时候多要一行（09-29 Aporia：插件离线跑、它没法实时插手，所以开始时就定好刷到第几条还不停就锁）
LOCK_ASK = {
    "zh": "\n\nTA 允许你锁：TA 刷到某一条提醒还不停，就把那些 app 锁住。写完提醒后，最后单独一行写「锁：N」——N 是第几条之后锁（1 到 {n}），"
          "不想锁就写「锁：0」。看你知道的 TA 的事定松紧。",
    "en": "\n\nThey've allowed you to lock: if they're still on those apps after a certain reminder, the apps get locked. After the "
          "reminders, add one last line \"Lock: N\" — lock after reminder N (1 to {n}), or \"Lock: 0\" for no lock. Decide how strict "
          "to be from what you know about them.",
}

PROMPT = {
    "zh": ("TA 要开始专注 {minutes} 分钟{what}，开了哨兵：TA 要是跑去刷别的 app，手机会按分心的时间长短一条条弹你写的提醒。\n"
           "现在写 {n} 条，一条比一条急：第一条轻轻提醒，最后一条是真急了。用你平时跟 TA 说话的口气，每条一句、短，"
           "能用上你知道的 TA 的事就用上（下面是一些）。一行一条，不编号，别的什么都不写。\n\n{facts}"),
    "en": ("They're starting a {minutes}-minute focus session{what} with the sentry on: if they drift off to other apps, "
           "their phone will show your reminders one by one, the longer they're distracted.\n"
           "Write {n} of them now, each more urgent than the last: the first is a gentle nudge, the last is really fed up. "
           "Use the voice you normally use with them, one short sentence each, and use what you know about them if it helps "
           "(some of it is below). One per line, no numbering, nothing else.\n\n{facts}"),
}
FALLBACK = {
    "zh": ["刷一下就回来哦。", "诶，说好的专注呢？", "已经好几分钟了，回来吧。", "我要生气了！快回去。", "放下手机！现在！"],
    "en": ["Just a quick look, then back to it.", "Hey — weren't we focusing?", "It's been a few minutes. Come back.",
           "I'm getting annoyed. Go back!", "Phone down. Now!"],
}
TOLD = {
    "zh": "〔专注〕刚才 TA 专注了 {minutes} 分钟{what}，中途分心 {times} 次、一共 {dmin} 分钟。",
    "en": "〔Focus〕They just did a {minutes}-minute focus session{what}; got distracted {times} time(s), {dmin} min in total.",
}
SAID_NOTE = {"zh": "手机替你弹给 TA 的那几句在上面。", "en": "The lines the phone showed them for you are above."}
TOLD_EARLY = {
    "zh": "〔专注〕TA 本来要专注 {minutes} 分钟{what}，提前结束了，专注了 {actual} 分钟；中途分心 {times} 次、一共 {dmin} 分钟。",
    "en": "〔Focus〕They planned a {minutes}-minute focus session{what} but ended early after {actual} min; "
          "got distracted {times} time(s), {dmin} min in total.",
}


def _what(label: str, lang: str) -> str:
    label = (label or "").strip()
    return "" if not label else (f"（{label}）" if lang == "zh" else f" ({label})")


def parse_lines(text: str) -> list[str]:
    out = [_BULLET.sub("", ln).strip().strip("「」\"") for ln in (text or "").splitlines()
           if not _LOCK.match(ln) and not _PEEK.match(ln)]
    return [ln for ln in out if ln][:LINES]


def parse_peek(text: str) -> str:
    for ln in (text or "").splitlines():
        m = _PEEK.match(ln)
        if m:
            return m.group(1).strip().strip("「」\"")[:120]
    return ""


def parse_lock(text: str) -> int:
    """「锁：N」→ N（1..5）；没写、写坏、越界都当 0（不锁）。"""
    for ln in (text or "").splitlines():
        m = _LOCK.match(ln)
        if m:
            try:
                n = int(m.group(1).strip("」\"。."))
            except ValueError:
                return 0
            return n if 1 <= n <= LINES else 0
    return 0


async def start(deps, route, adapter, scope: Scope, minutes: int, label: str, day: date,
                allow_lock: bool = False, lock_now: bool = False) -> tuple[UUID, list[str], int, str]:
    """写好一串提醒、存下这次专注。没钥匙（route=None）、模型出错、写得太少，都用出厂的几句兜底——哨兵不能因为模型挂了就不响。"""
    pool = deps.pool
    s = Settings.from_dict(await archive.get_settings(pool, scope.companion))
    persona = Persona.from_dict(await archive.get_persona(pool, scope.companion), s.lang)
    about = await M.list_memories(pool, scope.companion, kind="about", limit=15)
    recent = await M.list_memories(pool, scope.companion, kind="memory", limit=10)
    facts = "\n".join(f"- {m.content}" for m in [*about, *recent]) or "-"
    locking = allow_lock or lock_now
    chat = ""
    if locking:                      # 「我就看一下」那句要照最近聊的写
        who = {"user": "TA", "assistant": "你"} if s.lang == "zh" else {"user": "Them", "assistant": "You"}
        msgs = [m for m in await archive.recent(pool, scope.conversation, 12) if m.role in who]
        chat = "\n".join(f"{who[m.role]}：{' '.join(m.text.split())[:120]}" for m in msgs)
    req = ChatRequest(model=route.chat_model if route else "", system=[Block(render_base(persona, [], s.lang, relationship=s.relationship, bare=s.bare_mode), cache=True)],
                      messages=[Msg("user", PROMPT[s.lang].format(minutes=minutes, what=_what(label, s.lang), n=LINES,
                                                                 facts=facts)
                                       + (RECENT_ASK[s.lang].format(chat=chat) if chat else "")
                                       + (LOCK_ASK[s.lang].format(n=LINES) if allow_lock else "")
                                       + (PEEK_ASK[s.lang] if locking else ""))],
                      max_tokens=800, thinking=False, user_tag=user_tag(scope.account))
    lines: list[str] = []
    lock_after = 0
    peek = ""
    if route is not None:
        try:
            reply = await call(adapter, req)
            await archive.add_usage(pool, scope.account, day, route.chat_model, reply.usage,
                                    cost(reply.usage, route.chat_model))
            lines = parse_lines(reply.text)
            lock_after = parse_lock(reply.text) if allow_lock else 0
            peek = parse_peek(reply.text) if locking else ""
        except LLMError:
            pass
    if len(lines) < 3:
        lines = FALLBACK[s.lang]
    fid = uuid.uuid4()
    await pool.execute(
        """INSERT INTO focus_sessions (id, account_id, companion_id, conversation_id, label, minutes, lines, started_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8)""",
        fid, scope.account, scope.companion, scope.conversation, (label or "")[:40], minutes,
        json.dumps(lines, ensure_ascii=False), deps.now())
    return fid, lines, lock_after, (peek or PEEK_FALLBACK[s.lang]) if locking else ""


async def end(pool, account: UUID, focus_id: UUID, *, times: int, minutes: int, now: datetime,
              early: bool = False) -> bool:
    done = await pool.execute(
        """UPDATE focus_sessions SET ended_at = $3, distracted_times = $4, distracted_minutes = $5, early = $6
           WHERE id = $1 AND account_id = $2 AND ended_at IS NULL""", focus_id, account, now, times, minutes, early)
    return done.endswith(" 1")


async def said(pool, account: UUID, focus_id: UUID, items: list, now: datetime) -> int | None:
    """专注时手机替它弹过的话（提醒、「我就看一下」那句）：按原来的时间存成它的消息，进聊天流（09-29 Aporia）。
    手机回到 app 就报，所以这几条通常比 TA 回来后说的话早、按 id 排也不错位。同一个 key 只存一次；
    时间夹在专注开始和现在之间。返回新存了几条；不是这个账号的专注 → None。"""
    row = await pool.fetchrow("SELECT conversation_id, started_at FROM focus_sessions WHERE id = $1 AND account_id = $2",
                              focus_id, account)
    if row is None:
        return None
    added = 0
    for it in sorted((i for i in items if isinstance(i, dict)), key=lambda i: str(i.get("at") or "")):
        key, text = str(it.get("key") or "")[:40], " ".join(str(it.get("text") or "").split())[:300]
        if not key or not text:
            continue
        try:
            at = datetime.fromisoformat(str(it.get("at")))
            at = at if at.tzinfo else at.replace(tzinfo=now.tzinfo)
        except ValueError:
            at = now
        at = min(max(at, row["started_at"]), now)
        async with pool.acquire() as con, con.transaction():
            if await con.fetchval("INSERT INTO focus_said (focus_id, key) VALUES ($1, $2) ON CONFLICT DO NOTHING RETURNING 1",
                                  focus_id, key) is None:
                continue
            m = await archive.add_message(con, row["conversation_id"], "assistant", text, now=at)
            await con.execute("UPDATE focus_said SET message_id = $3 WHERE focus_id = $1 AND key = $2", focus_id, key, m.id)
        added += 1
    return added


async def pending_note(pool, conversation: UUID, lang: str) -> str:
    """这个窗口里结束了、还没告诉它的专注：拼成一行，标成已告诉。"""
    rows = await pool.fetch(
        """UPDATE focus_sessions SET told = TRUE WHERE conversation_id = $1 AND ended_at IS NOT NULL AND NOT told
           RETURNING id, label, minutes, distracted_times, distracted_minutes, started_at, ended_at, early""", conversation)
    if not rows:
        return ""
    spoke = await pool.fetchval("SELECT count(*) FROM focus_said WHERE focus_id = ANY($1::uuid[]) AND message_id IS NOT NULL",
                                [r["id"] for r in rows])
    note = "\n".join((TOLD_EARLY if r["early"] else TOLD)[lang].format(
        minutes=r["minutes"], what=_what(r["label"], lang), times=r["distracted_times"] or 0,
        dmin=r["distracted_minutes"] or 0, actual=max(0, int((r["ended_at"] - r["started_at"]).total_seconds() // 60)))
        for r in sorted(rows, key=lambda r: r["ended_at"]))
    return f"{note}{'' if lang == 'zh' else ' '}{SAID_NOTE[lang]}" if spoke else note
