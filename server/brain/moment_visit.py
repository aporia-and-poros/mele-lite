"""朋友圈：到点它来刷一下（10-01，照之前自用的 App的「递给他刷」，但 Mele 是单独的一小轮——教程第六章路线一）。

人设 + 最近聊的几句 + 这条动态和评论区 → 只带 moment_like / moment_comment 两把工具；它的回话不进聊天、不推送。
免费用户（试用钥匙）不扣额度，但一个账号每天最多 FREE_DAILY 次，联系人之间引出来的（peer）不跑。"""
from __future__ import annotations

import logging
from datetime import datetime, time
from pathlib import Path
from zoneinfo import ZoneInfo

import memory as M
from llm.catalog import cost, deepseek_peak_until
from llm.errors import LLMError
from llm.types import Block, ChatRequest, Msg

from . import archive, ledger
from . import moments as MO
from .auth import TrialOver
from .persona import Persona, render_base, tone_lines
from .scope import Scope
from .settings import Settings
from .tools import ToolContext, tool_specs

log = logging.getLogger(__name__)
TOOLS = ("moment_like", "moment_comment")
RECENT = 8

TAIL = {"zh": "朋友圈是 TA 路过才看的地方，不是聊天——评论像随手留的一两句，别写成长信。不想说就只点个赞，或者都不做；做完不用回话。",
        "en": "Moments is somewhere they only see in passing, not a chat — a comment is a line or two dropped on the way, "
              "not a letter. If there's nothing to say, just like it, or do nothing; no reply needed afterwards."}


def _who(author: str, nm: dict, me: str, lang: str) -> str:
    if author == me:
        return "我" if lang == "zh" else "me"
    if author == MO.USER:
        return f"{nm.get(MO.USER, 'TA')}（TA）" if lang == "zh" else f"{nm.get(MO.USER, 'them')} (them)"
    return nm.get(author, "")


def thread(comments: list[dict], nm: dict, me: str, lang: str) -> str:
    rows = comments[-MO.THREAD_LIMIT:]
    by = {c["id"]: c for c in comments}
    out = []
    if len(comments) > MO.THREAD_LIMIT:
        out.append(f"（更早还有 {len(comments) - MO.THREAD_LIMIT} 条，略）" if lang == "zh"
                   else f"({len(comments) - MO.THREAD_LIMIT} earlier, skipped)")
    for c in rows:
        to = by.get(c["reply_to"]) if c["reply_to"] else None
        arrow = (f" 回复 {_who(to['author'], nm, me, lang)}" if lang == "zh" else f" → {_who(to['author'], nm, me, lang)}") if to else ""
        out.append(f"  #{c['id']} {_who(c['author'], nm, me, lang)}{arrow}：{c['content']}")
    return "\n".join(out)


def render(m: MO.Moment, nm: dict, me: str, lang: str, *, comment: dict | None, minutes_ago: int) -> str:
    zh = lang == "zh"
    who = _who(m.author, nm, me, lang)
    body = m.content or ("（只有图）" if zh else "(photos only)")
    pics = ""
    if m.images:
        pics = (f"\n配了 {len(m.images)} 张图：{m.image_desc}" if zh else f"\nWith {len(m.images)} photo(s): {m.image_desc}") \
            if m.image_desc else (f"\n配了 {len(m.images)} 张图（没看清）" if zh else f"\nWith {len(m.images)} photo(s) (couldn't see them)")
    note = ""
    if m.author == me and m.context_note:
        note = f"\n（我发的时候的备注：{m.context_note}）" if zh else f"\n(My note when I posted it: {m.context_note})"
    th = thread(m.comments, nm, me, lang)
    if comment is None:
        head = (f"〔朋友圈〕我刷到了 {who} {minutes_ago} 分钟前发的一条（#{m.id}）：\n「{body}」" if zh
                else f"〔Moments〕I came across a post by {who} from {minutes_ago} minutes ago (#{m.id}):\n\"{body}\"")
        ask = ((f"想点赞就 moment_like(id={m.id})，想评论就 moment_comment(id={m.id}, content=\"…\")。"
                + ("TA 发朋友圈，连个赞都不点有点怪——但说什么、说不说，我自己定。" if m.author == MO.USER else "不想就算了。"))
               if zh else (f"To like it: moment_like(id={m.id}); to comment: moment_comment(id={m.id}, content=\"…\"). "
                           + ("Not even liking their post would be a bit odd — but what to say, if anything, is up to me."
                              if m.author == MO.USER else "Or leave it.")))
    else:
        head = (f"〔朋友圈·评论〕{who}那条（#{m.id}）：「{body}」" if zh else f"〔Moments · comment〕{who}'s post (#{m.id}): \"{body}\"")
        cw = _who(comment["author"], nm, me, lang)
        ask = (f"{cw}刚留了 #{comment['id']}，是说给我的。回就用 moment_comment(id={m.id}, content=\"…\", reply_to={comment['id']})。"
               if zh else f"{cw} just left #{comment['id']}, meant for me. Reply with moment_comment(id={m.id}, content=\"…\", "
                          f"reply_to={comment['id']}).")
    sec = ("\n评论区：\n" if zh else "\nComments:\n") + th if th else ""
    return f"{head}{pics}{note}{sec}\n\n{ask}\n{TAIL['zh' if zh else 'en']}"


async def _recent(pool, account, companion, lang: str, user_name: str) -> str:
    conv = await pool.fetchval("SELECT id FROM conversations WHERE companion_id = $1 AND account_id = $2 AND NOT incognito "
                               "ORDER BY last_at DESC LIMIT 1", companion, account)
    if conv is None:
        return ""
    msgs = [m for m in await archive.recent(pool, conv, RECENT) if m.role in ("user", "assistant")]
    sep = "：" if lang == "zh" else ": "
    lines = [f"{ledger.speaker(m.role, lang, user_name)}{sep}{m.text[:200]}" for m in msgs]
    if not lines:
        return ""
    return ("〔最近聊的几句〕\n" if lang == "zh" else "〔The last few lines we said〕\n") + "\n".join(lines)


async def _describe_images(deps, scope: Scope, m: MO.Moment, route, lang: str, day) -> str:
    from . import vision
    from .turn import get_adapter
    seeing, _ = await vision.describer_for(deps, scope, route)
    if seeing is None:
        return ""
    parts = []
    for img in m.images[:4]:
        seen = await deps.pool.fetchval("SELECT caption FROM image_captions WHERE account_id = $1 AND sha = $2 AND lang = $3",
                                        scope.account, img.get("sha", ""), lang)
        if not seen:
            try:
                seen = await vision.look(deps, scope, seeing, img.get("mime", "image/jpeg"), Path(img["path"]).read_bytes(),
                                         lang, day, lambda r: get_adapter(deps, r))
            except Exception:
                log.exception("moment %s image caption failed", m.id)
                continue
            if seen and img.get("sha"):
                await vision.remember_caption(deps.pool, scope.account, img["sha"], lang, seen, "moment")
        if seen:
            parts.append(seen)
    desc = " / ".join(parts)
    if desc:
        await deps.pool.execute("UPDATE moments SET image_desc = $2 WHERE id = $1", m.id, desc)
    return desc


async def visit(deps, v, now: datetime) -> str:
    """跑一次来刷。返回 done / skipped / gone / error。"""
    from .turn import get_adapter, resolve_route, tool_loop
    pool = deps.pool
    acc, comp = v["account_id"], v["companion_id"]
    m = await MO.get(pool, acc, v["moment_id"])
    if m is None:
        return "gone"
    cmt = next((c for c in m.comments if c["id"] == v["comment_id"]), None) if v["comment_id"] else None
    if v["comment_id"] and cmt is None:
        return "gone"
    s = Settings.from_dict(await archive.get_settings(pool, comp))
    scope = Scope(acc, comp, None)
    try:
        route = await resolve_route(deps.keys, scope, chore="moments")
    except TrialOver:
        route = getattr(deps.keys, "trial", None)
        if route is None:
            return "skipped"
    if route.trial:
        if v["peer"]:
            return "skipped"
        if route.provider == "deepseek" and (until := deepseek_peak_until(now)) is not None:   # 免费的错峰（10-01）
            await pool.execute("UPDATE moment_visits SET due_at = $2 WHERE id = $1", v["id"], until)
            return "pending"
        z = ZoneInfo(s.tz)
        start = datetime.combine(now.astimezone(z).date(), time(0), tzinfo=z)
        done = await pool.fetchval("SELECT count(*) FROM moment_visits WHERE account_id = $1 AND status = 'done' "
                                   "AND due_at >= $2", acc, start)
        if done >= MO.FREE_DAILY:
            return "skipped"
    day = now.astimezone(ZoneInfo(s.tz)).date()
    if m.images and not m.image_desc:
        m.image_desc = await _describe_images(deps, scope, m, route, s.lang, day)
    nm = await MO.names(pool, acc)
    persona = Persona.from_dict(await archive.get_persona(pool, comp), s.lang)
    core = [x.content for x in sorted(await M.list_memories(pool, comp, kind="core"), key=lambda x: x.id)]
    base = render_base(persona, core, s.lang, tone=[] if s.bare_mode else tone_lines(s.lang, s.warmth, s.initiative, s.humor),
                       relationship=s.relationship, chat_rules=False, bare=s.bare_mode)
    recent = await _recent(pool, acc, comp, s.lang, s.user_name)
    ask = render(m, nm, str(comp), s.lang, comment=cmt,
                 minutes_ago=max(1, int((now - m.created_at).total_seconds() // 60)))
    req = ChatRequest(model=route.chat_model, system=[Block(base)],
                      messages=[Msg("user", f"{recent}\n\n{ask}" if recent else ask)],
                      tools=[t for t in tool_specs(extra=TOOLS) if t.name in TOOLS], max_tokens=1500)
    ctx = ToolContext(pool=pool, embedder=deps.embedder, user_id=comp, account_id=acc, now=now, lang=s.lang,
                      allowed=TOOLS, tz=s.tz, deps=deps)
    ctx.moment_round = v["round"]

    async def quiet(_ev: dict) -> None:
        pass

    try:
        out = await tool_loop(get_adapter(deps, route), req, ctx, quiet, s.lang, max_rounds=3)
    except LLMError as e:
        log.warning("moment visit %s failed: %s", v["id"], e.kind)
        return "error"
    await archive.add_usage(pool, acc, day, route.chat_model, out.usage, cost(out.usage, route.chat_model))
    return "done"


async def run_due(deps, now: datetime, *, limit: int = 5) -> int:
    """巡逻每圈：领到点的来刷（先占住，免得两圈重复跑）。"""
    rows = await deps.pool.fetch(
        """UPDATE moment_visits SET status = 'running' WHERE id IN (
               SELECT id FROM moment_visits WHERE status = 'pending' AND due_at <= $1 ORDER BY due_at LIMIT $2
               FOR UPDATE SKIP LOCKED) RETURNING *""", now, limit)
    for v in rows:
        try:
            outcome = await visit(deps, v, now)
        except Exception:
            log.exception("moment visit %s crashed", v["id"])
            outcome = "error"
        await deps.pool.execute("UPDATE moment_visits SET status = $2 WHERE id = $1", v["id"], outcome)
    return len(rows)
