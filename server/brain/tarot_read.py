"""塔罗：抽完牌那一小轮解读（10-03，样子照 album_look）。

- 联系人：它的人设 + 跟问题有关的几条记忆 + 最近聊的几句 + 〔塔罗〕（说明书 + 牌位 × 牌义）→ 只带 tarot_write。
- 解牌人（companion_id = NULL）：没有人设、没有记忆、没有聊天，只有说明书 + 问题 + 牌；钥匙用问牌时所在那个联系人（route_from）的。
- 回话不进聊天、不推送。存档后接口立刻起一个后台任务跑（TA 在等着看）；巡逻兜底：卡了两分钟的再跑，三次不成标 failed。
- 照常记账（试用按钱算），不挪 DeepSeek 高峰。"""
from __future__ import annotations

import json
import logging
from datetime import datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

import memory as M
from llm.catalog import cost
from llm.errors import LLMError
from llm.types import Block, ChatRequest, Msg

from . import archive, manuals
from . import tarot as T
from . import tarot_cards as TC
from .auth import TrialOver
from .moment_visit import _recent
from .persona import Persona, render_base, tone_lines
from .scope import Scope
from .settings import Settings
from .tarot_spreads import SPREADS
from .tools import ToolContext, tool_specs

log = logging.getLogger(__name__)
TOOLS = ("tarot_write",)
STUCK = timedelta(minutes=2)
MAX_TRIES = 3

HEAD = {"zh": "〔塔罗〕TA 问了牌，请你来解。", "en": "〔Tarot〕They've asked the cards and want you to read."}
NEUTRAL = {"zh": "你是 Mele 里的解牌人。你不认识这个人，也不扮演任何角色；只就 TA 的问题和抽到的牌说话。",
           "en": "You are the Reader in Mele. You don't know this person and play no character; speak only to their question and the cards."}
TAIL = {"zh": "照上面的手册解，写好用 tarot_write(text=…) 交上来，写完不用回话。",
        "en": "Read by the manual above, hand it in with tarot_write(text=…), and don't reply afterwards."}


def _manual(lang: str) -> str:
    return next(m.text for m in manuals.load(lang)[1] if m.name == "tarot")


def _card_lines(cards: list, lang: str) -> str:
    return "\n".join(f"· {c['position']}｜{TC.entry_line(c['card'], c['reversed'], lang)}" for c in cards)


def ask_text(r: T.Reading, lang: str, followup: int | None) -> str:
    zh = lang == "zh"
    sp = SPREADS[r.spread]
    lines = [HEAD[lang], "", _manual(lang), "",
             (f"TA 问：「{r.question}」\n牌阵：{sp.name[lang]}" if zh else f"They asked: \"{r.question}\"\nSpread: {sp.name[lang]}"),
             _card_lines(r.cards, lang)]
    if followup is not None:
        lines += ["", ("你之前的解读：" if zh else "Your earlier reading:"), r.interpretation]
        for i, f in enumerate(r.followups[:followup]):
            lines += ["", (f"之前追问：「{f['question']}」" if zh else f"Earlier follow-up: \"{f['question']}\""),
                      _card_lines([f["card"]], lang), f.get("interpretation", "")]
        f = r.followups[followup]
        lines += ["", (f"现在 TA 接着问：「{f['question']}」，又抽了一张——只解这一张，接上前面的。" if zh else
                       f"Now they ask: \"{f['question']}\" and drew one more card — read just this one, carrying on from before."),
                  _card_lines([f["card"]], lang)]
    lines += ["", TAIL[lang]]
    return "\n".join(lines)


async def _claim(pool, rid: int, followup: int | None, *, stale_before: datetime | None = None) -> bool:
    """占成 asked，免得后台任务和巡逻撞车。stale_before：巡逻只捞卡住的。"""
    async with pool.acquire() as conn, conn.transaction():
        r = await conn.fetchrow("SELECT status, tries, followups, created_at FROM tarot_readings WHERE id = $1 FOR UPDATE", rid)
        if r is None:
            return False
        if followup is None:
            ok = r["status"] == "pending" or (stale_before is not None and r["status"] == "asked"
                                              and r["created_at"] < stale_before)
            if ok:
                await conn.execute("UPDATE tarot_readings SET status = 'asked', tries = tries + 1 WHERE id = $1", rid)
            return ok
        fus = T._j(r["followups"])
        if not 0 <= followup < len(fus):
            return False
        f = fus[followup]
        ok = f.get("status") == "pending" or (stale_before is not None and f.get("status") == "asked"
                                              and datetime.fromisoformat(f["ts"]) < stale_before)
        if ok:
            f.update(status="asked", tries=int(f.get("tries", 0)) + 1)
            await conn.execute("UPDATE tarot_readings SET followups = $2::jsonb WHERE id = $1", rid, T._dump(fus))
        return ok


async def _settle(pool, rid: int, followup: int | None, *, failed_now: bool) -> None:
    """跑完还没写上：退回 pending 等巡逻；试满三次标 failed。"""
    async with pool.acquire() as conn, conn.transaction():
        r = await conn.fetchrow("SELECT status, tries, followups FROM tarot_readings WHERE id = $1 FOR UPDATE", rid)
        if r is None:
            return
        if followup is None:
            if r["status"] == "asked":
                st = "failed" if failed_now or r["tries"] >= MAX_TRIES else "pending"
                await conn.execute("UPDATE tarot_readings SET status = $2 WHERE id = $1", rid, st)
            return
        fus = T._j(r["followups"])
        f = fus[followup]
        if f.get("status") == "asked":
            f["status"] = "failed" if failed_now or int(f.get("tries", 0)) >= MAX_TRIES else "pending"
            await conn.execute("UPDATE tarot_readings SET followups = $2::jsonb WHERE id = $1", rid, T._dump(fus))


async def _read(deps, account: UUID, r: T.Reading, followup: int | None, now: datetime) -> str:
    """跑一次。返回 done / error / skipped（没钥匙可用）。"""
    from .turn import get_adapter, resolve_route, tool_loop
    pool = deps.pool
    who = r.companion_id or r.route_from
    if r.companion_id is None:                 # 解牌人：问牌时那个联系人删了的话，换账号第一个联系人的钥匙
        from . import accounts
        comps = await accounts.list_companions(pool, account)
        who = who if who in comps else (comps[0] if comps else None)
    if who is None:
        return "skipped"
    s = Settings.from_dict(await archive.get_settings(pool, who))
    lang = s.lang
    try:
        route = await resolve_route(deps.keys, Scope(account, who, None), chore="tarot")
    except TrialOver:
        return "skipped"
    ask = ask_text(r, lang, followup)
    if r.companion_id is None:
        system = NEUTRAL[lang]
    else:
        persona = Persona.from_dict(await archive.get_persona(pool, r.companion_id), lang)
        core = [x.content for x in sorted(await M.list_memories(pool, r.companion_id, kind="core"), key=lambda x: x.id)]
        system = render_base(persona, core, lang, tone=[] if s.bare_mode else tone_lines(lang, s.warmth, s.initiative, s.humor),
                             relationship=s.relationship, chat_rules=False, bare=s.bare_mode)
        q = r.followups[followup]["question"] if followup is not None else r.question
        hits = await M.search(pool, deps.embedder, r.companion_id, q, limit=5, touch=False, now=now)
        if hits:
            ask = ("你记得的、可能有关的：\n" if lang == "zh" else "Things you remember that may be related:\n") + \
                "\n".join(f"- {h.memory.content}" for h in hits) + "\n\n" + ask
        recent = await _recent(pool, account, r.companion_id, lang, s.user_name)
        if recent:
            ask = f"{recent}\n\n{ask}"
    req = ChatRequest(model=route.chat_model, system=[Block(system)], messages=[Msg("user", ask)],
                      tools=[t for t in tool_specs(extra=TOOLS) if t.name in TOOLS], max_tokens=4000)
    ctx = ToolContext(pool=pool, embedder=deps.embedder, user_id=who, account_id=account, now=now, lang=lang,
                      allowed=TOOLS, tz=s.tz, deps=deps)
    ctx.tarot_target = (r.id, followup)

    async def quiet(_ev: dict) -> None:
        pass

    try:
        out = await tool_loop(get_adapter(deps, route), req, ctx, quiet, lang, max_rounds=2)
    except LLMError as e:
        log.warning("tarot read %s failed: %s", r.id, e.kind)
        return "error"
    day = now.astimezone(ZoneInfo(s.tz)).date()
    await archive.add_usage(pool, account, day, route.chat_model, out.usage, cost(out.usage, route.chat_model))
    if not getattr(ctx, "tarot_written", False) and out.text.strip():     # 没调工具、直接写在回话里：也收下
        await T.write(pool, r.id, out.text, followup=followup)
        return "done"
    return "done" if getattr(ctx, "tarot_written", False) else "error"


async def read_now(deps, account: UUID, rid: int, *, followup: int | None = None,
                   stale_before: datetime | None = None) -> None:
    if not await _claim(deps.pool, rid, followup, stale_before=stale_before):
        return
    got = await T.get(deps.pool, account, rid)
    if got is None:
        return
    try:
        outcome = await _read(deps, account, got, followup, deps.now())
    except Exception:
        log.exception("tarot read %s crashed", rid)
        outcome = "error"
    if outcome != "done":
        await _settle(deps.pool, rid, followup, failed_now=outcome == "skipped")


async def run_due(deps, now: datetime, *, limit: int = 3) -> int:
    """巡逻每圈：后台任务没跑成的（还 pending，或 asked 卡了两分钟）再跑一次。"""
    before = now - STUCK
    rows = await deps.pool.fetch(
        """SELECT id, account_id, status, created_at, followups FROM tarot_readings
           WHERE created_at < $1 AND (status IN ('pending', 'asked') OR followups::text LIKE '%"status": "pending"%'
                                      OR followups::text LIKE '%"status": "asked"%')
           ORDER BY created_at LIMIT 20""", before)
    n = 0
    for row in rows:
        if n >= limit:
            break
        if row["status"] in ("pending", "asked"):
            await read_now(deps, row["account_id"], row["id"], stale_before=before)
            n += 1
            continue
        for i, f in enumerate(json.loads(row["followups"]) if isinstance(row["followups"], str) else row["followups"]):
            if f.get("status") in ("pending", "asked") and datetime.fromisoformat(f["ts"]) < before:
                await read_now(deps, row["account_id"], row["id"], followup=i, stale_before=before)
                n += 1
    return n
