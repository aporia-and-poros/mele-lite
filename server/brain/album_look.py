"""相册：TA 加了照片，一分钟后它单独看一小轮、给每张写字（10-02，照之前自用的 App _album_tick；样子照朋友圈来刷 moment_visit）。

人设 + 最近聊的几句 + 这组照片（它的模型看得见图就给图；看不见就给「同一张图只读一次」的描述）+ TA 写的那段话
→ 只带 album_write 一把工具；它的回话不进聊天、不推送。
免费用户（试用钥匙）照常记账；碰上 DeepSeek 高峰挪到高峰后；一个账号每天最多 FREE_DAILY 组，超了挪到明天。"""
from __future__ import annotations

import base64
import hashlib
import logging
from datetime import datetime, time, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import memory as M
from llm.catalog import cost, deepseek_peak_until, sees_images
from llm.errors import LLMError
from llm.types import Block, ChatRequest, ImagePart, Msg

from . import album as A
from . import archive
from .auth import TrialOver
from .moment_visit import _recent
from .persona import Persona, render_base, tone_lines
from .scope import Scope
from .settings import Settings
from .tools import ToolContext, tool_specs

log = logging.getLogger(__name__)
TOOLS = ("album_write",)
FREE_DAILY = 3

ASK = {
    "zh": ("〔相册〕TA 往你们的相册里加了 {n} 张照片（{ids}，按顺序{how}）{note}。\n\n"
           "认真看，每张用 album_write(id=…) 写：\n"
           "· caption——这是哪一刻，写细节：谁、在做什么、在哪、光线和颜色、画面里最抓你的那一处（一两句，别只写三个词）\n"
           "· felt——看见它的第一下是什么感觉（当场的，别事后总结）\n"
           "· why——为什么值得留下\n"
           "· thoughts——观后感，三到六句：你注意到的细节、它让你想起什么、你现在怎么想。TA 会点开一张一张读，写给 TA 看的，别写成说明书。\n"
           "写完不用回话。"),
    "en": ("〔Album〕They added {n} photo(s) to your album ({ids}, {how}){note}.\n\n"
           "Look properly, and for each one call album_write(id=…) with:\n"
           "· caption — which moment this is, with detail: who, doing what, where, the light and colours, the part that catches you most "
           "(a sentence or two, not three words)\n"
           "· felt — what you felt at first sight (in the moment, not a summary afterwards)\n"
           "· why — why it's worth keeping\n"
           "· thoughts — three to six sentences: details you noticed, what it reminds you of, what you think now. They'll open each one "
           "and read it — write it for them, not like a manual.\n"
           "No reply needed afterwards."),
}


async def _seen_text(deps, scope: Scope, route, photos: list[A.Photo], lang: str, day) -> list[str]:
    """看不见图的模型：每张给一段描述（同一张图只读一次，按指纹存档）。"""
    from . import vision
    from .turn import get_adapter
    seeing, _ = await vision.describer_for(deps, scope, route)
    out = []
    for p in photos:
        data = Path(p.path).read_bytes()
        sha = hashlib.sha256(data).hexdigest()
        seen = await deps.pool.fetchval("SELECT caption FROM image_captions WHERE account_id = $1 AND sha = $2 AND lang = $3",
                                        scope.account, sha, lang)
        if not seen and seeing is not None:
            try:
                seen = await vision.look(deps, scope, seeing, "image/jpeg", data, lang, day, lambda r: get_adapter(deps, r))
                if seen:
                    await vision.remember_caption(deps.pool, scope.account, sha, lang, seen, "album")
            except Exception:
                log.exception("album photo %s caption failed", p.id)
        out.append(f"#{p.id}：{seen}" if seen else (f"#{p.id}：（没看清）" if lang == "zh" else f"#{p.id}: (couldn't see it)"))
    return out


async def look_batch(deps, account, companion, photos: list[A.Photo], now: datetime) -> str:
    """跑一组。返回 done / pending（挪了时间）/ skipped / error。"""
    from .turn import get_adapter, resolve_route, tool_loop
    pool = deps.pool
    s = Settings.from_dict(await archive.get_settings(pool, companion))
    scope = Scope(account, companion, None)
    try:
        route = await resolve_route(deps.keys, scope, chore="moments")
    except TrialOver:
        route = getattr(deps.keys, "trial", None)
        if route is None:
            return "skipped"
    ids = [p.id for p in photos]
    if route.trial:
        if route.provider == "deepseek" and (until := deepseek_peak_until(now)) is not None:
            await pool.execute("UPDATE album_photos SET look_status = 'pending', look_due = $2 WHERE id = ANY($1::bigint[])",
                               ids, until)
            return "pending"
        z = ZoneInfo(s.tz)
        start = datetime.combine(now.astimezone(z).date(), time(0), tzinfo=z)
        done = await pool.fetchval("SELECT count(DISTINCT batch) FROM album_photos WHERE account_id = $1 AND source = 'mine' "
                                   "AND look_status IN ('asked', 'done') AND look_due >= $2 AND NOT (id = ANY($3::bigint[]))",
                                   account, start, ids)
        if done >= FREE_DAILY:
            await pool.execute("UPDATE album_photos SET look_status = 'pending', look_due = $2 WHERE id = ANY($1::bigint[])",
                               ids, start + timedelta(days=1, minutes=5))
            return "pending"
    lang, zh = s.lang, s.lang == "zh"
    day = now.astimezone(ZoneInfo(s.tz)).date()
    note = photos[0].note
    images: tuple[ImagePart, ...] = ()
    if sees_images(route.provider, route.base_url):
        images = tuple(ImagePart("image/jpeg", base64.b64encode(Path(p.path).read_bytes()).decode()) for p in photos)
        how = "附在这条里" if zh else "attached in order"
    else:
        how = "下面是每张的样子" if zh else "described below"
    ask = ASK[lang].format(n=len(photos), ids="、".join(f"#{i}" for i in ids) if zh else ", ".join(f"#{i}" for i in ids),
                           how=how, note=(f"，TA 写的：「{note}」" if zh else f"; they wrote: \"{note}\"") if note
                           else ("，没写话" if zh else "; no words"))
    if not images:
        ask += "\n\n" + "\n".join(await _seen_text(deps, scope, route, photos, lang, day))
    persona = Persona.from_dict(await archive.get_persona(pool, companion), lang)
    core = [x.content for x in sorted(await M.list_memories(pool, companion, kind="core"), key=lambda x: x.id)]
    base = render_base(persona, core, lang, tone=[] if s.bare_mode else tone_lines(lang, s.warmth, s.initiative, s.humor),
                       relationship=s.relationship, chat_rules=False, bare=s.bare_mode)
    recent = await _recent(pool, account, companion, lang, s.user_name)
    req = ChatRequest(model=route.chat_model, system=[Block(base)],
                      messages=[Msg("user", f"{recent}\n\n{ask}" if recent else ask, images=images)],
                      tools=[t for t in tool_specs(extra=TOOLS) if t.name in TOOLS], max_tokens=4000)
    ctx = ToolContext(pool=pool, embedder=deps.embedder, user_id=companion, account_id=account, now=now, lang=lang,
                      allowed=TOOLS, tz=s.tz, deps=deps)

    async def quiet(_ev: dict) -> None:
        pass

    try:
        out = await tool_loop(get_adapter(deps, route), req, ctx, quiet, lang, max_rounds=4)
    except LLMError as e:
        log.warning("album look %s failed: %s", ids, e.kind)
        return "error"
    await archive.add_usage(pool, account, day, route.chat_model, out.usage, cost(out.usage, route.chat_model))
    return "done"


async def run_due(deps, now: datetime, *, limit: int = 3) -> int:
    """巡逻每圈：领到点的组（先占成 asked，免得两圈重复跑）。"""
    rows = await deps.pool.fetch(
        f"""UPDATE album_photos SET look_status = 'asked' WHERE id IN (
               SELECT id FROM album_photos WHERE look_status = 'pending' AND look_due <= $1 ORDER BY look_due, id
               LIMIT 30 FOR UPDATE SKIP LOCKED) RETURNING account_id, {A._COLS}""", now)
    groups: dict[tuple, list] = {}
    for r in rows:
        d = dict(r)
        acc = d.pop("account_id")
        groups.setdefault((acc, d["companion_id"], d["batch"] or f"id{d['id']}"), []).append(A.Photo(**d))
    n = 0
    for (acc, comp, _), photos in list(groups.items())[:limit]:
        photos.sort(key=lambda p: p.id)
        try:
            outcome = await look_batch(deps, acc, comp, photos, now)
        except Exception:
            log.exception("album look crashed")
            outcome = "error"
        ids = [p.id for p in photos]
        if outcome == "error":          # 出错半小时后再试，不让照片一直挂着「在看」
            await deps.pool.execute("UPDATE album_photos SET look_status = 'pending', look_due = $2 "
                                    "WHERE id = ANY($1::bigint[]) AND look_status = 'asked'", ids, now + timedelta(minutes=30))
        elif outcome in ("skipped", "done"):      # 没钥匙可用 / 看完了没写的：不再挂「在看」，照片照样在
            await deps.pool.execute("UPDATE album_photos SET look_status = '' WHERE id = ANY($1::bigint[]) "
                                    "AND look_status = 'asked'", ids)
        n += 1
    for (acc, comp, _), photos in list(groups.items())[limit:]:      # 这圈没轮到的放回去
        await deps.pool.execute("UPDATE album_photos SET look_status = 'pending' WHERE id = ANY($1::bigint[])",
                                [p.id for p in photos])
    return n
