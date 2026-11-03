"""大脑这一块的工具：记住、搜记忆、关于 TA、人物卡、便利贴、翻手册。都调记忆服务 / 说明书已有的函数。
工具是「挂」上去的：以后加饮食、提醒，往 _TOOLS 里再挂一个就行，大脑不用改。
清单按名字排好、每次一模一样——工具定义排在请求最前面，它一动后面的缓存全废。
每调一次挂一张小卡片给网页看；工具出错不抛，把错误当结果还给模型，让它自己圆。"""
from __future__ import annotations

import json
import random
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from typing import Awaitable, Callable
from uuid import UUID
from zoneinfo import ZoneInfo

import memory as M
from llm.types import ToolCall, ToolSpec

from patrol import clocks as C
from patrol import store as clock_store

from . import archive, context_line, edits, hidden, manuals
from . import lore as LORE
from . import drawer as D
from . import diary as DY
from . import far_dates as FD
from . import todos as TD
from . import stickers as ST
from . import moments as MO
from . import album as AL
from . import tarot as TA
from . import tarot_cards as TC
from . import tarot_spreads as TS
from . import books as BK
from . import wallet as WL
from . import milestones as MS
from .edits import EditRef
from .settings import Settings

SELF_CLOCKS_MAX = 20          # 它自己约的，最多同时攒这么多没响的


@dataclass
class Card:
    kind: str        # remember / search / person / sticky / manual / error（「关于 TA」不挂卡）
    text: str
    data: dict | None = None   # 卡上按钮要的东西（focus：minutes / label）

    @property
    def private(self) -> bool:
        """聊天里不挂的：正式 app 不显示，测试页照常显示（09-27 Aporia定）。
        便利贴是它留给自己的待办；以后它往「用户的」待办里记东西，那种才亮给用户看。
        人物卡跟「关于 TA」一个道理，聊天里不提；但人物卡页面照常给用户看、能改，不藏。"""
        # 它自己约的钟：到点才出现（Aporia 09-27）；关系变了不挂卡，只换名字旁边的图标（Aporia 09-29）
        return self.kind in ("sticky", "person", "self_clock", "relationship")


@dataclass
class ToolContext:
    pool: object
    embedder: object
    user_id: UUID                # 联系人：记忆、关于 TA、便利贴都记在它名下
    now: datetime
    lang: str = "zh"
    cards: list[Card] = field(default_factory=list)
    account_id: UUID | None = None   # 账号：人物卡记在这儿，每个联系人都认识 TA 身边的人（空 = 跟 user_id 一样）
    edit_ref: EditRef | None = None  # 倒回用：这一轮写的东西记在哪一轮名下（空 = 不记，比如测试、无痕）
    allowed: tuple[str, ...] | None = None   # 只准用这些工具（无痕）；空 = 都行
    tz: str = "UTC"                  # 钟按 TA 那边的时间定
    names: tuple[str, ...] = ()      # 称呼（它的名字、TA 的名字）：翻记忆时不进关键词榜（memory/stopwords.py）
    deps: object = None              # 大脑的 Deps：饮食后台估、查营养要用（09-29）；测试里可以空
    mcp: dict = field(default_factory=dict)   # 这一轮外面的工具：给模型的名字 → (服务, 原名)（10-05，brain/mcp.py）
    conversation: UUID | None = None   # 这一轮在哪个窗口（画的图挂在这儿，10-15）
    drawn: list = field(default_factory=list)   # 这一轮它画的图（附件号）：跟它的话一起存
    end_turn: bool = False           # 用完这个工具这一轮就收（打电话：在响，等 TA 接，10-31）

    @property
    def people_owner(self) -> UUID:
        return self.account_id or self.user_id


def _snip(text: str, n: int = 30) -> str:
    text = " ".join((text or "").split())
    return text if len(text) <= n else text[:n] + "…"


async def _save(ctx: ToolContext, a: dict, kind: str) -> str:
    """记住 / 关于 TA 共用。存之前先看有没有很像的旧记忆（像到 similar_guard、但不到自动合并线）：
    有就先不存，把旧的那条给模型看，让它选——带 update_id 改那条、不记、或带 force_new 另存一条。
    （2026-09-26 Aporia试出来：DeepSeek 同一件事换着说法记了四遍，相似度 0.76～0.79，不到合并线。）"""
    content = str(a.get("content") or "").strip()
    importance = int(a.get("importance", 5))
    loud = kind != "about"                     # 「关于 TA」不挂卡
    if a.get("update_id"):
        old = await M.get(ctx.pool, ctx.user_id, int(a["update_id"]))
        if old is None or old.kind not in ("memory", "about"):
            return f"没有这条可以改：#{a['update_id']}"
        m = await M.update(ctx.pool, ctx.embedder, ctx.user_id, old.id, content=content,
                           importance=max(old.importance, importance), now=ctx.now)
        await edits.record(ctx.pool, ctx.edit_ref, "memory", ctx.user_id, old.id, edits.memory_snapshot(old))
        if loud and old.kind != "about":          # 改的是「关于 TA」那条就不挂卡，哪个工具改的都一样（09-27）
            ctx.cards.append(Card("remember", f"改了记忆：{_snip(m.content, 400)}"))   # 卡上给全文，app 列表里只显示两行、点开看整张（09-28）
        return f"已更新 #{m.id}"
    near = None
    if not a.get("force_new"):
        dup = await M.near_duplicate(ctx.pool, ctx.embedder, ctx.user_id, content)
        if dup is not None:                     # 09-27：像到一定程度、或者共用一个少见的词（星际穿越记了两遍）
            old, _, shared = dup
            why = f"，都提到「{'、'.join(shared[:3])}」" if shared else ""
            return (f"没存：跟已有的 #{old.id}「{old.content}」很像{why}。"
                    f"是同一件事、有新内容 → 带 update_id={old.id} 再调一次，content 写合并后的全文"
                    "（只留一年后还想记得的，一时的感受、当天的细节不用写进去）；"
                    "已经记过了 → 不用再记；确实是另一件事 → 带 force_new=true 再调一次。")
        near = await M.nearest(ctx.pool, ctx.embedder, ctx.user_id, content)   # 自动合并时记下并之前的样子（倒回用）
    r = await M.remember(ctx.pool, ctx.embedder, ctx.user_id, content, importance=importance,
                         tags=list(a.get("tags") or []), valence=float(a.get("valence", 0.0)),
                         arousal=float(a.get("arousal", 0.0)), kind=kind, now=ctx.now)
    if not r.merged:
        await edits.record(ctx.pool, ctx.edit_ref, "memory", ctx.user_id, r.memory.id, None)
    elif near is not None and near[0].id == r.memory.id:      # 自动并进了最像的那条：记下并之前的样子
        await edits.record(ctx.pool, ctx.edit_ref, "memory", ctx.user_id, r.memory.id, edits.memory_snapshot(near[0]))
    if loud:
        verb = "改了记忆" if r.merged else "记住了"      # 自动并进旧的那条，也算改
        ctx.cards.append(Card("remember", f"{verb}：{_snip(r.memory.content, 400)}"))
        return f"已合并进记忆 #{r.memory.id}" if r.merged else f"已记住 #{r.memory.id}"
    return f"已悄悄并进 #{r.memory.id}" if r.merged else f"已悄悄记下 #{r.memory.id}"


async def _remember(ctx: ToolContext, a: dict) -> str:
    return await _save(ctx, a, "memory")


async def _about(ctx: ToolContext, a: dict) -> str:
    """「关于 TA」：悄悄记，不挂小卡片（Aporia 2026-09-26 定：记在心里，不声张）。"""
    return await _save(ctx, a, "about")


async def _manual(ctx: ToolContext, a: dict) -> str:
    name = str(a.get("name") or "").strip()
    text = manuals.read_manual(name, ctx.lang)
    if text is None:
        return f"没有这本手册：{name}。有的是：{'、'.join(manuals.manual_names(ctx.lang))}"
    ctx.cards.append(Card("manual", f"翻了手册：{name}"))
    return text


async def _search(ctx: ToolContext, a: dict) -> str:
    query = str(a.get("query") or "").strip()
    limit = max(1, min(10, int(a.get("limit", 5))))
    hits = await M.search(ctx.pool, ctx.embedder, ctx.user_id, query, limit=limit, now=ctx.now, names=ctx.names)
    if ctx.people_owner != ctx.user_id:      # 人物卡在账号名下，一起翻（09-27：拆三层后翻不到了）
        hide = await hidden.hidden_for(ctx.pool, ctx.user_id)          # 对它隐藏的卡翻不到（10-01）
        hits += [h for h in await M.search(ctx.pool, ctx.embedder, ctx.people_owner, query, limit=limit, now=ctx.now,
                                           names=ctx.names) if h.memory.id not in hide]
        hits = sorted(hits, key=lambda h: h.score, reverse=True)[:limit]
    ctx.cards.append(Card("search", "翻了些记忆"))      # 09-27 Aporia：不用标查了什么，一轮只挂一张
    if not hits:
        return "没找到相关的记忆。"
    return "\n".join(f"#{h.memory.id} [{h.memory.created_at:%Y-%m-%d}] {h.memory.content}" for h in hits)


async def _person(ctx: ToolContext, a: dict) -> str:
    action = a.get("action")
    name = str(a.get("name") or "").strip()
    hide = await hidden.hidden_for(ctx.pool, ctx.user_id) if ctx.people_owner != ctx.user_id else frozenset()
    people = [p for p in await M.list_people(ctx.pool, ctx.people_owner) if p.id not in hide]
    if action == "write" and any(name.lower() in [n.lower() for n in [p.name or ""] + p.aliases]
                                 for p in await M.list_people(ctx.pool, ctx.people_owner) if p.id in hide):
        return "这个人的卡你写不了。"                  # TA 设了不给它看（10-01）：同名的那张不让它碰
    if action == "get":
        wanted = name.lower()
        for p in people:
            if wanted in [n.lower() for n in [p.name or ""] + p.aliases]:
                ctx.cards.append(Card("person", f"看了人物卡：{p.name}"))
                return M.render_person(p, ctx.lang)
        return "没有这张卡。"
    if action == "write":
        existing = next((p for p in people if name.lower() in [n.lower() for n in [p.name or ""] + p.aliases]), None)
        p = await M.upsert_person(ctx.pool, ctx.embedder, ctx.people_owner, name, relation=a.get("relation"),
                                  facts=a.get("facts"), impression=a.get("impression"),
                                  aliases=list(a.get("aliases") or []), by="ai", now=ctx.now)
        await edits.record(ctx.pool, ctx.edit_ref, "person", ctx.people_owner, p.id,
                           edits.person_snapshot(existing) if existing else None)
        ctx.cards.append(Card("person", f"写了人物卡：{p.name}"))
        return "已写好：" + M.render_person(p, ctx.lang)
    raise ValueError("action 只能是 get 或 write")


async def _sticky(ctx: ToolContext, a: dict) -> str:
    await edits.record(ctx.pool, ctx.edit_ref, "sticky", ctx.user_id, None, await M.get_sticky(ctx.pool, ctx.user_id))
    await M.set_sticky(ctx.pool, ctx.user_id, str(a.get("text") or ""), now=ctx.now)
    ctx.cards.append(Card("sticky", "写了便利贴"))
    return "便利贴已更新。"


# ── 钟（巡逻，09-27）：TA 开口让记的 → todo（10-01 起并进待办，TA 看得见）；它自己起意的 → schedule_self（TA 看不见） ──

def _local(dt, tz: str) -> str:
    return f"{dt.astimezone(ZoneInfo(tz)):%Y-%m-%d %H:%M}"


def _when(ctx: ToolContext, a: dict):
    spec = C.validate_spec("once", {"at": str(a.get("at") or "")}, tz=ctx.tz)
    at = C.next_fire("once", spec, ctx.now, ctx.tz)
    if at is None:
        raise ValueError(f"这个时间已经过了（现在是 {_local(ctx.now, ctx.tz)}）")
    return spec, at


async def _add_clock(ctx: ToolContext, a: dict, kind: str) -> tuple[int, str]:
    spec, at = _when(ctx, a)
    note = str(a.get("note") or "").strip()
    c = await clock_store.add_clock(ctx.pool, ctx.account_id or ctx.user_id, ctx.user_id, kind=kind, shape="once",
                                    spec=spec, note=note, next_at=at)
    await edits.record(ctx.pool, ctx.edit_ref, "clock", ctx.user_id, c.id, None)
    return c.id, f"{_local(at, ctx.tz)} {_snip(note, 20)}".strip()


_ON = {"arrive": "到了", "leave": "离开"}


def _todo_line(d: dict) -> str:
    bits = [f"#{d['id']} {d['what']}"]
    if d["when"]:
        bits.append(d["when"])
    if d["place"]:
        bits.append(f"{_ON.get(d['place_on'], '')}{d['place']}时")
    if d["done"]:
        bits.append({"once": "做完了", "day": "今天做了", "week": "这周做了"}[d["repeat"]])
    return " · ".join(bits)


async def _todo_dicts(ctx: ToolContext, rows) -> list[dict]:
    acc = ctx.account_id or ctx.user_id
    places = {p.id: p for p in await TD.list_places(ctx.pool, acc)}
    today = ctx.now.astimezone(ZoneInfo(ctx.tz)).date()
    return [TD.to_dict(t, today, ctx.tz, places, {}, ctx.lang) for t in rows]


async def _todo(ctx: ToolContext, a: dict) -> str:
    """待办（10-01）：TA 的清单，TA 在 Library → 待办里看得见、能改。加的时候三个格子：做什么 / 什么时候 / 在哪。"""
    acc, action = ctx.account_id or ctx.user_id, str(a.get("action") or "")
    if action == "add":
        shape, spec = None, None
        if a.get("at"):
            shape, spec = "once", {"at": str(a["at"])}
        elif a.get("time"):
            shape, spec = "at", {"time": str(a["time"]), "days": list(a.get("days") or [])}
        place_id, on = None, None
        if a.get("place"):
            p = await TD.place_by_name(ctx.pool, acc, str(a["place"]))
            if p is None:
                names = "、".join(x.name for x in await TD.list_places(ctx.pool, acc)) or "还一个都没存"
                return (f"没找到「{a['place']}」这个地方。TA 存过的：{names}。没存过的要 TA 自己去「待办」页存"
                        "（站在那儿点「就是这里」）；先不带地点也行。")
            place_id, on = p.id, str(a.get("on") or "arrive")
        t = await TD.create(ctx.pool, acc, ctx.user_id, what=str(a.get("what") or ""), shape=shape, spec=spec,
                            place_id=place_id, place_on=on, now=ctx.now, created_by="ai")
        await edits.record(ctx.pool, ctx.edit_ref, "todo", acc, t.id, None)
        line = _todo_line((await _todo_dicts(ctx, [t]))[0])
        ctx.cards.append(Card("todo", f"加了待办：{line.split(' ', 1)[1]}"))
        tail = "到点 / 到那儿你会醒来提醒 TA。" if (shape or place_id) else "没有时间和地点，就是清单上的一条，不会提醒。"
        return f"加好了 {line}。{tail}"
    if action == "list":
        rows = await _todo_dicts(ctx, await TD.list_all(ctx.pool, acc))
        return "\n".join(_todo_line(d) for d in rows) or "TA 的待办是空的。"
    t = await TD.get(ctx.pool, acc, int(a.get("id") or 0))
    if t is None:
        return "没有这条待办（编号用 list 看）。"
    if action == "done":
        t = await TD.set_done(ctx.pool, acc, t.id, True, ctx.now)
        ctx.cards.append(Card("todo", f"帮你勾掉了：{t.what}"))
        return f"勾掉了 #{t.id}。"
    if action == "delete":
        if t.created_by != "ai":
            return "这条是 TA 自己写的，你删不了；做完了就用 done 勾掉，不要了让 TA 自己删。"
        await TD.delete(ctx.pool, acc, t.id)
        ctx.cards.append(Card("todo", f"删了待办：{t.what}"))
        return f"删了 #{t.id}。"
    raise ValueError("action 只能是 add / list / done / delete")


async def _schedule_self(ctx: ToolContext, a: dict) -> str:
    if await clock_store.count_self(ctx.pool, ctx.user_id) >= SELF_CLOCKS_MAX:
        return f"你已经约了 {SELF_CLOCKS_MAX} 个还没响的。先用 list_clocks 看看，用 cancel_self 取消几个不要的再约。"
    cid, text = await _add_clock(ctx, a, "self")
    ctx.cards.append(Card("self_clock", f"给自己约了：{text}"))
    return f"约好了 #{cid}：{text}。到点你会醒来，TA 事先看不到。"


async def _cancel_self(ctx: ToolContext, a: dict) -> str:
    acc = ctx.account_id or ctx.user_id
    c = await clock_store.get_clock(ctx.pool, acc, int(a.get("id") or 0), kinds=("self",))
    if c is None or c.companion_id != ctx.user_id:
        return "没有这个你约的钟（TA 定的提醒你取消不了，要 TA 自己在 app 里删）。"
    await clock_store.delete_clock(ctx.pool, acc, c.id, kinds=("self",))
    await edits.record(ctx.pool, ctx.edit_ref, "clock", ctx.user_id, c.id,
                       {"kind": c.kind, "shape": c.shape, "spec": c.spec, "note": c.note,
                        "next_at": c.next_at.isoformat() if c.next_at else None})
    ctx.cards.append(Card("self_clock", f"取消了：{_snip(c.note, 20)}"))
    return f"取消了 #{c.id}。"


async def _list_clocks(ctx: ToolContext, a: dict) -> str:
    acc = ctx.account_id or ctx.user_id
    rows = await clock_store.list_clocks(ctx.pool, acc, ctx.user_id, kinds=("self",))
    tail = "（TA 定的提醒都在待办里，用 todo 的 list 看。）"
    if not rows:
        return "你现在没有自己约的。" + tail
    return "\n".join(f"#{c.id} {_local(c.next_at, ctx.tz) if c.next_at else '—'} {c.note}".rstrip() for c in rows) + "\n" + tail


# ── 记着的远事（09-28）：有日子、还远、要一路惦记着的；前一晚 / 当天 / 第二天会醒来找 TA ──

def _parse_day(v) -> date:
    try:
        return date.fromisoformat(str(v or "").strip())
    except ValueError:
        raise ValueError("day 要写成 YYYY-MM-DD") from None


def _date_line(f: FD.FarDate) -> str:
    bits = [f"#{f.id} {f.day.isoformat()}", f.at_time, f.title]
    return " ".join(b for b in bits if b) + (f"（{f.note}）" if f.note else "")


async def _remember_date(ctx: ToolContext, a: dict) -> str:
    acc, action = ctx.account_id or ctx.user_id, str(a.get("action") or "")
    s = Settings.from_dict(await archive.get_settings(ctx.pool, ctx.user_id))
    if action == "list":
        rows = await FD.list_open(ctx.pool, acc, ctx.user_id)
        return "\n".join(_date_line(f) for f in rows) if rows else "现在没有记着的远事。"
    if action == "add":
        f = await FD.add(ctx.pool, acc, ctx.user_id, s, day=_parse_day(a.get("day")), at_time=str(a.get("time") or ""),
                         title=str(a.get("title") or ""), note=str(a.get("note") or ""), now=ctx.now)
        await edits.record(ctx.pool, ctx.edit_ref, "far_date", ctx.user_id, f.id, None)
        ctx.cards.append(Card("date", f"记下了：{f.day.month}/{f.day.day} {f.title}"))
        return f"记下了 {_date_line(f)}。你会在前一晚、当天、第二天醒来找 TA。"
    f = await FD.get(ctx.pool, acc, int(a.get("id") or 0))
    if f is None or f.companion_id != ctx.user_id or f.resolved_at is not None:
        return "没有这件（编号用 list 看；了结过的不在清单上了）。"
    if action == "update":
        await edits.record(ctx.pool, ctx.edit_ref, "far_date", ctx.user_id, f.id,
                           {"day": f.day.isoformat(), "at_time": f.at_time, "title": f.title, "note": f.note})
        g = await FD.update(ctx.pool, acc, f.id, s, day=_parse_day(a["day"]) if a.get("day") else None,
                            at_time=str(a["time"]) if "time" in a else FD._KEEP,
                            title=a.get("title"), note=a.get("note"), now=ctx.now)
        ctx.cards.append(Card("date", f"改了：{g.day.month}/{g.day.day} {g.title}"))
        return f"改好了 {_date_line(g)}。"
    if action == "done":
        await FD.resolve(ctx.pool, ctx.embedder, acc, f.id, str(a.get("result") or ""), now=ctx.now)
        ctx.cards.append(Card("date", f"了结了：{f.title}"))
        return f"了结了 #{f.id}，结果存进记忆了。"
    raise ValueError("action 只能是 add / update / list / done")


# ── 世界书（09-30）：一个词、一个梗、一个设定是什么意思。TA 写的它改不动 ──

def _lore_line(e) -> str:
    who = "TA 写的" if e.created_by == "user" else "你记的"
    scope = "所有联系人都知道" if e.companion_id is None else "只有你知道"
    off = "；关着" if not e.enabled else ""
    return f"【{e.name}】关键词：{'、'.join(e.keywords)}（{who}，{scope}{off}）\n{e.content}"


async def _lore(ctx: ToolContext, a: dict) -> str:
    acc, comp, action = ctx.account_id or ctx.user_id, ctx.user_id, str(a.get("action") or "")
    name = str(a.get("name") or "").strip()
    e = await LORE.get_by_name(ctx.pool, acc, comp, name) if name else None
    if action == "get":
        return _lore_line(e) if e else "世界书里没有这条。"
    if action != "write":
        raise ValueError("action 只能是 write 或 get")
    shared = bool(a.get("shared"))
    if e is not None and e.created_by == "user":
        return "这条是 TA 写的，你改不动；想改先问 TA。"
    if e is None:
        e = await LORE.add(ctx.pool, acc, companion_id=None if shared else comp, name=name,
                           keywords=a.get("keywords") or name, content=str(a.get("content") or ""), created_by="ai")
        await edits.record(ctx.pool, ctx.edit_ref, "lore", acc, e.id, None)
    else:
        await edits.record(ctx.pool, ctx.edit_ref, "lore", acc, e.id, edits.lore_snapshot(e))
        e = await LORE.update(ctx.pool, acc, e.id, keywords=a.get("keywords") or None,
                              content=a.get("content") or None, companion_id=None if shared else e.companion_id)
    ctx.cards.append(Card("lore", f"记进世界书：{e.name}"))
    return "记好了：" + _lore_line(e)


# ── 抽屉（09-28）：它偷偷给 TA 写的信。TA 只看得见信封；到日子或者输对它给的 4 位密码才能拆 ──

_KEYS = random.SystemRandom()


def _md(d) -> str:
    return f"{d.month}/{d.day}"


async def _drawer(ctx: ToolContext, a: dict) -> str:
    acc, action = ctx.account_id or ctx.user_id, str(a.get("action") or "")
    if action == "put":
        unlock = _parse_day(a["unlock_at"]) if a.get("unlock_at") else None
        letter = await D.put(ctx.pool, acc, ctx.user_id, title=str(a.get("title") or ""),
                             content=str(a.get("content") or ""), unlock_at=unlock, now=ctx.now)
        await edits.record(ctx.pool, ctx.edit_ref, "drawer", ctx.user_id, letter.id, None)
        ctx.cards.append(Card("drawer", f"往抽屉里放了一封 · {_md(unlock)} 解锁" if unlock else "往抽屉里放了一封"))
        return (f"放好了 #{letter.id}，" + (f"{unlock.isoformat()} 那天 TA 能拆。" if unlock else "没设日子，只能靠你给钥匙打开。")
                + "TA 只看得见信封。")
    if action == "mine":
        letters = await D.mine(ctx.pool, ctx.user_id)
        if not letters:
            return "抽屉是空的。"
        out = []
        for x in letters:
            bits = [f"#{x.id} {_md(x.created_at.astimezone(ZoneInfo(ctx.tz)))} 写",
                    f"{_md(x.unlock_at)} 解锁" if x.unlock_at else "没设日子",
                    "TA 拆了" if x.opened_at else "还没拆"]
            if x.code:
                bits.append(f"钥匙给过（{x.code}）")
            out.append(" · ".join(bits) + "\n" + (f"《{x.title}》" if x.title else "") + x.content)
        return "\n\n".join(out)
    letter_id = int(a.get("id") or 0)
    if action == "key":
        opened = await ctx.pool.fetchval("SELECT opened_at IS NOT NULL FROM drawer_letters WHERE id = $1 "
                                         "AND companion_id = $2 AND burned_at IS NULL", letter_id, ctx.user_id)
        if opened:
            return "TA 已经拆过这封了，不用钥匙。"
        code = await D.give_key(ctx.pool, ctx.user_id, letter_id, _KEYS, ctx.now)
        if code is None:
            return "没有这封（编号用 mine 看）。"
        ctx.cards.append(Card("drawer", "把一封信的钥匙给了你"))
        return f"#{letter_id} 的密码是 {code}。在聊天里告诉 TA，TA 在抽屉里点这封、输进去就能拆。"
    if action == "burn":
        if not await D.burn(ctx.pool, ctx.user_id, letter_id, ctx.now):
            return "没有这封（编号用 mine 看）。"
        ctx.cards.append(Card("drawer", "烧掉了一封"))
        return f"烧掉了 #{letter_id}，TA 那边也没了。"
    raise ValueError("action 只能是 put / mine / key / burn")


# ── 日记（10-01）：翻自己某天的整篇（含锁着的那段）和 TA 那天给我看的；给锁着那段的钥匙 ──

def _diary_day(ctx: ToolContext, a: dict) -> date:
    return _parse_day(a["day"]) if a.get("day") else ctx.now.astimezone(ZoneInfo(ctx.tz)).date() - timedelta(days=1)


async def _diary(ctx: ToolContext, a: dict) -> str:
    action, day = str(a.get("action") or ""), _diary_day(ctx, a)
    acc = ctx.account_id or ctx.user_id
    mine = await DY.companion_entry(ctx.pool, ctx.user_id, day)
    if action == "read":
        out = []
        if mine is None:
            out.append(f"{_md(day)} 我没写日记。")
        else:
            out.append(f"我 {_md(day)} 的日记：\n{mine.body}")
            if mine.locked:
                state = "TA 已经用钥匙打开了" if mine.unlocked_at else ("钥匙给过了，TA 还没打开" if mine.code else "TA 还没看过")
                out.append(f"锁着的那段（{state}）：\n{mine.locked}")
        theirs = await DY.mine_for_companion(ctx.pool, acc, day)
        for e in theirs:
            note = f"\n（我在页边写了：{e.margin}）" if e.margin else ""
            out.append(f"TA {_md(day)} 的日记 #{e.id}：\n{e.body}{note}")
        return "\n\n".join(out)
    if action == "key":
        if mine is None or not mine.locked:
            return f"{_md(day)} 的日记没有锁着的段。"
        if mine.unlocked_at:
            return "TA 已经打开过那段了，不用钥匙。"
        code = await DY.give_key(ctx.pool, ctx.user_id, day, _KEYS, ctx.now)
        ctx.cards.append(Card("diary", "把日记里锁着那段的钥匙给了你"))
        return (f"{_md(day)} 锁着那段的密码是 {code}。在聊天里告诉 TA，TA 在 Memory → 日记里点那块锁、输进去就能看。"
                "原文别在聊天里念出来，让 TA 自己去开。")
    raise ValueError("action 只能是 read / key")


# ── 正文标记（10-31）：发表情包、立里程碑不走工具了，它写 [表情包：#12] / ⟪里程碑：…⟫，回复写完这边照办 ──

async def act_on_markers(ctx: ToolContext, stickers: list[str], milestones: list[str], library: list) -> list[str]:
    """照标记办事，卡挂进 ctx.cards；返回存档里那几行（下一轮它在历史里看得到自己发过什么）。
    library = 这一轮给它看的那张表（brain/stickers.for_companion）；表里没有的编号不发。"""
    notes: list[str] = []
    sent: set[int] = set()
    for want in stickers:
        s = ST.resolve(library, want)
        if s is None or s.id in sent:
            continue
        sent.add(s.id)
        await ST.mark_used(ctx.pool, s.id, ctx.now)
        ctx.cards.append(Card("sticker", s.caption[:60], data={"sticker_id": s.id}))
        notes.append(_NOTE[ctx.lang]["sticker_send"].format(c=f"#{s.id} {_snip(s.caption)}"))
    for title in milestones:
        r = await _milestone(ctx, {"title": title})
        notes.append(tool_note("milestone", {"title": title}, r, ctx.lang))
    return notes


# ── 朋友圈（10-01）：聊天里发一条 / 改签名 / 翻最近的；来刷时点赞、评论（这两把只在来刷那一轮有） ──

async def _moments(ctx: ToolContext, a: dict) -> str:
    acc, action, me = ctx.account_id or ctx.user_id, str(a.get("action") or ""), str(ctx.user_id)
    if action == "post":
        m = await MO.post(ctx.pool, acc, me, content=str(a.get("content") or ""), now=ctx.now,
                          context_note=str(a.get("note") or ""))
        ctx.cards.append(Card("moment", f"发了一条朋友圈：{_snip(m.content, 60)}"))
        return f"发好了 #{m.id}。TA 路过朋友圈时会看到；别的联系人也会刷到。"
    if action == "sign":
        sig = await MO.set_signature(ctx.pool, acc, me, str(a.get("signature") or ""))
        return f"签名改成了「{sig}」。" if sig else "签名清空了。"
    if action == "recent":
        nm = await MO.names(ctx.pool, acc)
        rows = await MO.feed(ctx.pool, acc, limit=5)
        if not rows:
            return "朋友圈还是空的。"
        out = []
        for m in rows:
            bits = [f"#{m.id} {nm.get(m.author, '')}：{m.content or '（只有图）'}"]
            if m.likes:
                bits.append("赞：" + "、".join(nm.get(w, "") for w in m.likes))
            bits += [f"  {nm.get(c['author'], '')}：{c['content']}" for c in m.comments[-5:]]
            out.append("\n".join(bits))
        return "\n\n".join(out)
    raise ValueError("action 只能是 post / sign / recent")


async def _moment_like(ctx: ToolContext, a: dict) -> str:
    ok = await MO.like(ctx.pool, ctx.account_id or ctx.user_id, int(a.get("id") or 0), str(ctx.user_id), now=ctx.now)
    return "赞了。" if ok else "没有这条。"


async def _moment_comment(ctx: ToolContext, a: dict) -> str:
    rt = a.get("reply_to")
    c = await MO.comment(ctx.pool, ctx.account_id or ctx.user_id, int(a.get("id") or 0), str(ctx.user_id),
                         str(a.get("content") or ""), now=ctx.now, reply_to=int(rt) if rt else None,
                         round_=getattr(ctx, "moment_round", 0))
    return f"评论好了 #{c['id']}。"


# ── 相册（10-02，照之前自用的 App home_album）：聊天里收一张 TA 发的图 / 翻旧照片；TA 加照片那一小轮用 album_write ──

async def _album(ctx: ToolContext, a: dict) -> str:
    acc, action = ctx.account_id or ctx.user_id, str(a.get("action") or "")
    if action == "keep":
        conv = ctx.edit_ref.conversation if ctx.edit_ref else None
        p = await AL.keep(ctx.pool, acc, ctx.user_id, conv, which=int(a.get("which") or 1), fields=a, now=ctx.now)
        ctx.cards.append(Card("photo", f"存了一张照片：{_snip(p.caption, 60)}"))
        return f"收进相册了 #{p.id}。TA 在 Memory → 相册里点开就能读到你写的。"
    if action == "look":
        return await AL.look(ctx.pool, acc, ctx.user_id, int(a["id"]) if a.get("id") else None,
                             getattr(ctx.deps, "rng", None) or random)
    raise ValueError("action 只能是 keep / look")


async def _album_write(ctx: ToolContext, a: dict) -> str:
    p = await AL.write(ctx.pool, ctx.account_id or ctx.user_id, ctx.user_id, int(a.get("id") or 0), a)
    return f"写好了 #{p.id}。"


# ── 塔罗（10-03）：抽完牌那一小轮写解读（tarot_read.py 把要写的那一局放在 ctx.tarot_target） ──

async def _tarot_write(ctx: ToolContext, a: dict) -> str:
    target = getattr(ctx, "tarot_target", None)
    if target is None:
        raise ValueError("现在没有要解的牌")
    rid, followup = target
    await TA.write(ctx.pool, rid, str(a.get("text") or ""), followup=followup)
    ctx.tarot_written = True
    return "交上去了。"


async def _tarot(ctx: ToolContext, a: dict) -> str:
    """它自己问牌 / 替 TA 抽 / 写解读 / 翻以前的。"""
    acc, action, zh = ctx.account_id or ctx.user_id, str(a.get("action") or ""), ctx.lang == "zh"
    if action == "draw":
        r = await TA.save_tool(ctx.pool, acc, ctx.user_id, question=str(a.get("question") or ""),
                               spread=str(a.get("spread") or "single"), for_ta=bool(a.get("for_ta")), now=ctx.now,
                               lang=ctx.lang)
        ctx.cards.append(Card("tarot", f"抽了牌：{_snip(r.question, 40)}" if zh else f"drew cards: {_snip(r.question, 40)}"))
        lines = "\n".join(f"· {c['position']}｜{TC.entry_line(c['card'], c['reversed'], ctx.lang)}" for c in r.cards)
        return (f"#{r.id} {TS.SPREADS[r.spread].name[ctx.lang]}「{r.question}」\n{lines}\n"
                + ("想好了用 tarot read 写下你的解读。" if zh else "When you've thought it over, write your reading with tarot read."))
    if action == "read":
        r = await TA.get(ctx.pool, acc, int(a.get("id") or 0))
        if r is None or r.companion_id != ctx.user_id or r.drawn_by != "contact":
            raise ValueError("只能给你自己抽的那几局写解读")
        await TA.write(ctx.pool, r.id, str(a.get("text") or ""))
        return "写好了。" if zh else "Written."
    if action == "list":
        rows = await TA.for_tool(ctx.pool, ctx.user_id, limit=5)
        if not rows:
            return "还没有抽过牌。" if zh else "No readings yet."
        who = {"user": "TA 问" if zh else "they asked", "contact": "你问" if zh else "you asked"}
        return "\n".join(f"#{r.id} {r.created_at.astimezone(ZoneInfo(ctx.tz)):%m-%d} {who[r.asker]}「{r.question}」"
                         f"（{TA.cards_line(r.cards, ctx.lang)}）{_snip(r.interpretation, 60)}" for r in rows)
    raise ValueError("action 只能是 draw / read / list")


# ── 书架（10-02，照之前自用的 App共读书房）：TA 在读什么、翻到 TA 那一页、在页边留一笔（每天最多 3 笔，不剧透） ──

async def _book(ctx: ToolContext, a: dict) -> str:
    acc, action = ctx.account_id or ctx.user_id, str(a.get("action") or "")
    if action == "shelf":
        rows = await BK.list_all(ctx.pool, acc, ctx.now.astimezone(ZoneInfo(ctx.tz)).date(), ctx.user_id)
        if not rows:
            return "书架还是空的。"
        return "\n".join(f"#{b['id']}《{b['title']}》读到第 {b['at_chapter'] + 1}/{b['chapters']} 章（{int(b['progress'] * 100)}%）"
                         for b in rows)
    b = (await BK.get(ctx.pool, acc, int(a["id"]), ctx.user_id) if a.get("id")
         else await BK.reading_now(ctx.pool, acc, ctx.now, ctx.user_id))
    if b is None:                    # 没在读：最近读过的那本（只给别的 TA 的书跳过，10-15）
        last = await ctx.pool.fetchval("SELECT id FROM books WHERE account_id = $1 AND (companion_id IS NULL OR companion_id = $2) "
                                       "ORDER BY read_at DESC NULLS LAST LIMIT 1", acc, ctx.user_id)
        b = await BK.get(ctx.pool, acc, last) if last else None
    if b is None:
        return "TA 书架上还没有书。"
    if action == "page":
        text = BK.page_text(b, b.at_chapter, b.at_page, b.page_count)
        return f"《{b.title}》{b.chapters[b.at_chapter][0]}，TA 现在这一页大概是：\n{text}" if text else "这一页是空的。"
    if action == "mark":
        quote, note = str(a.get("quote") or "").strip(), str(a.get("note") or "").strip()
        if not quote:
            raise ValueError("mark 要带 quote（原文里的一句）")
        start = ctx.now.astimezone(ZoneInfo(ctx.tz)).replace(hour=0, minute=0, second=0, microsecond=0)
        if await BK.marks_today(ctx.pool, acc, ctx.user_id, start) >= BK.MARKS_PER_DAY:
            return "今天在书里留过好几笔了，留到明天吧。"
        chapter = next((i for i in range(min(b.furthest, len(b.chapters) - 1), -1, -1)
                        if quote in BK.chapter_text(b, i)), None)
        if chapter is None:
            return "书里 TA 读过的部分没找到这一句（要一字不差地引原文）。"
        pos = BK.chapter_text(b, chapter).find(quote)
        await BK.add_mark(ctx.pool, acc, b.id, chapter=chapter, quote=quote, note=note, author=str(ctx.user_id),
                          pos=pos, companion=ctx.user_id, now=ctx.now)
        ctx.cards.append(Card("book", f"在《{b.title}》里划了一句：{_snip(quote, 40)}"))
        return "划好了。TA 翻到那一页会看到你的笔迹。"
    raise ValueError("action 只能是 shelf / page / mark")


# ── 画图（10-15，brain/media.py）：Me 里挑了画图钥匙才给 ──

async def _draw(ctx: ToolContext, a: dict) -> str:
    from . import media
    prompt = str(a.get("prompt") or "").strip()
    if not prompt:
        raise ValueError("prompt 要写画什么")
    deps = ctx.deps
    files_dir = getattr(deps, "files_dir", None)
    if ctx.conversation is None or files_dir is None:
        return "这里发不了图。"
    try:
        att = await media.draw(ctx.pool, getattr(deps.keys, "box", None), files_dir,
                               account=ctx.account_id or ctx.user_id, conversation=ctx.conversation, prompt=prompt, now=ctx.now)
    except media.DrawError as e:
        return f"没成：{e}"
    ctx.drawn.append(att.id)
    ctx.cards.append(Card("tool", f"画了一张：{_snip(prompt, 40)}"))
    return "画好了，会跟你这句话一起发给 TA。"


# ── 钱包记账（10-02）：替 TA 记一笔、看这个月、删一笔。默认它不主动评论 TA 的花销，TA 问才说 ──

async def _wallet(ctx: ToolContext, a: dict) -> str:
    acc, action = ctx.account_id or ctx.user_id, str(a.get("action") or "")
    today = ctx.now.astimezone(ZoneInfo(ctx.tz)).date()
    s = await WL.settings(ctx.pool, acc)
    if action == "add":
        day = _parse_day(a["day"]) if a.get("day") else today
        kind = "in" if str(a.get("kind") or "") == "in" else "out"
        e = await WL.add(ctx.pool, acc, amount=a.get("amount"), category=str(a.get("category") or ""),
                         note=str(a.get("note") or ""), day=day, author=str(ctx.user_id), kind=kind, now=ctx.now)
        ctx.cards.append(Card("wallet", f"记了一笔{'收入' if kind == 'in' else ''}：{e['category']} {WL.money(e['amount'], s['symbol'])}"
                                        + (f"（{_snip(e['note'], 20)}）" if e["note"] else "")))
        return f"记好了 #{e['id']}：{e['day']} {'收入 ' if kind == 'in' else ''}{e['category']} {WL.money(e['amount'], s['symbol'])}。"
    if action == "tags":
        return f"支出的标签：{'、'.join(s['categories'])}\n收入的标签：{'、'.join(s['income_categories'])}"
    if action == "month":
        m = await WL.month(ctx.pool, acc, _parse_day(a["day"]) if a.get("day") else today)
        if not m["entries"]:
            return f"{m['month']} 还没记过账。"
        cats = "、".join(f"{k} {WL.money(v, s['symbol'])}" for k, v in m["by_category"])
        lines = [f"{m['month']} 一共花了 {WL.money(m['total'], s['symbol'])}（上个月 {WL.money(m['last_month'], s['symbol'])}）：{cats}"]
        if m["income"]:
            lines.append(f"收入 {WL.money(m['income'], s['symbol'])}，结余 {WL.money(m['net'], s['symbol']) if m['net'] >= 0 else '-' + WL.money(-m['net'], s['symbol'])}")
        if m["budget"]:
            lines.append(f"预算 {WL.money(m['budget'], s['symbol'])}，用了 {round(m['total'] * 100 / m['budget'])}%")
        lines += [f"#{e['id']} {e['day']} {'+' if e['kind'] == 'in' else ''}{e['category']} {WL.money(e['amount'], s['symbol'])} {e['note']}".strip()
                  for e in m["entries"][:15]]
        lines.append(f"标签栏：{'、'.join(s['categories'])}；收入：{'、'.join(s['income_categories'])}")
        return "\n".join(lines)
    if action == "delete":
        ok = await WL.delete(ctx.pool, acc, int(a.get("id") or 0))
        return "删了。" if ok else "没有这一笔。"
    raise ValueError("action 只能是 add / tags / month / delete")


# ── 专注（09-29）：它不直接开，只挂一张带「开始专注」按钮的卡，TA 点了才开 ──

async def _offer_focus(ctx: ToolContext, a: dict) -> str:
    minutes = max(15, min(600, int(a.get("minutes") or 45)))
    label = str(a.get("label") or "").strip()[:40]
    ctx.cards.append(Card("focus", f"{label} · {minutes} 分钟" if label else f"专注 {minutes} 分钟",
                          {"minutes": minutes, "label": label}))
    return f"卡片挂好了：TA 点「开始专注」才会开始（{minutes} 分钟）。你写的提醒会在那时候要。"


# ── 关系（09-29 Aporia）：TA 表白 / 说在一起、它接受了，关系自动从朋友变恋人；只能 TA 先开口 ──

_REL_NAME = {"zh": {"friend": "朋友", "partner": "恋人", "family": "家人", "buddy": "搭子"},
             "en": {"friend": "friends", "partner": "partners", "family": "family", "buddy": "buddies"}}
_REL_CARD = {"zh": {"partner": "你们在一起了", "friend": "你们现在是朋友", "family": "你们现在像家人",
                    "buddy": "你们现在是搭子"},
             "en": {"partner": "You're together now", "friend": "You're friends now", "family": "You're like family now",
                    "buddy": "You're buddies now"}}


async def _phone_call(ctx: ToolContext, a: dict) -> str:
    """打电话（10-31 第 4 步）：VoIP 推送叫醒 TA 的手机；打出去这一轮就收，接了你先开口"""
    ringer = getattr(ctx.deps, "ringer", None)
    if ringer is None or ctx.conversation is None:
        return "打不了：这台 Host 没开打电话"
    if a.get("withdraw"):
        ok = await ringer.withdraw(ctx.conversation)
        return "挂掉了，TA 那边显示「对方已取消」" if ok else "现在没有在响的电话"
    from .persona import Persona
    name = Persona.from_dict(await archive.get_persona(ctx.pool, ctx.user_id), ctx.lang).name or "Mele"
    got = await ringer.place(ctx.people_owner, ctx.user_id, ctx.conversation, str(a.get("reason") or ""), name)
    if got == "ringing":
        ctx.end_turn = True
        return "电话打出去了，在响。等 TA 接。"
    return {"busy": "没打出去：上一通还在响",
            "no_device": "没打出去：TA 的手机还没登记来电（要更新 App、开着推送）。想说什么就打字说。",
            }.get(got, "没打出去：推送没送到 TA 的手机。想说什么就打字说。")


async def _relationship(ctx: ToolContext, a: dict) -> str:
    to = str(a.get("to") or "").strip()
    if to not in _REL_NAME["zh"]:
        return f"不认识这种关系：{to}（只能是 friend / partner / family / buddy）"
    s = await archive.get_settings(ctx.pool, ctx.user_id)
    if s.get("relationship") == to:
        return f"本来就是{_REL_NAME['zh'][to]}，没改。"
    await archive.save_settings(ctx.pool, ctx.user_id, {**s, "relationship": to})
    ctx.cards.append(Card("relationship", _REL_CARD[ctx.lang][to], {"to": to}))
    return f"改好了：你们现在是{_REL_NAME['zh'][to]}。从下一句起你照这个关系说话；TA 在设置里也看得到、能改回去。"


async def _milestone(ctx: ToolContext, a: dict) -> str:
    title = " ".join(str(a.get("title") or "").split())
    if not title:
        return "要写一句标题。"
    acc = ctx.account_id or await ctx.pool.fetchval("SELECT account_id FROM companions WHERE id = $1", ctx.user_id)
    mid = await MS.add(ctx.pool, acc, ctx.user_id, title, now=ctx.now)
    if mid is None:
        return "这座已经立过了，不用再立。"
    await edits.record(ctx.pool, ctx.edit_ref, "milestone", ctx.user_id, mid, None)
    title = title[:MS.TITLE_MAX]
    ctx.cards.append(Card("date", f"立了里程碑：{title}" if ctx.lang == "zh" else f"Set a milestone: {title}"))
    return f"立好了：{title}。TA 在大事记里看得到。"


# ── 饮食（09-29）：一个房间一把工具；TA 的饮食本记在账号名下 ──

LISTEN_FRESH = timedelta(minutes=10)     # TA 报过「在放」且这么久以内 = 一起听页开着，歌卡让手机直接排进队列


async def _music(ctx: ToolContext, a: dict) -> str:
    """音乐（09-30）：share = 曲库里找到才发歌卡（带试听）、进歌单；now = TA 在听什么。"""
    from dataclasses import replace as dc_replace

    from music import find
    from music import store as MS
    from music.share import card_text
    acc, pool = ctx.people_owner, ctx.pool
    act = str(a.get("action") or "")
    items = await context_line.load(pool, acc)
    playing = items.get("music")
    if act == "now":
        if playing and ctx.now - playing[1] <= context_line.MAX_AGE["music"]:
            return context_line._music(playing[0], playing[1], ctx.now, ctx.lang) + "。"
        if not await MS.storefront_of(pool, acc):
            return "TA 没连 Apple Music，看不到在听什么。想知道就问 TA。"
        return "这会儿没看到 TA 在放歌。"
    if act == "picks":                                          # 每日私选交卷（09-30，照之前自用的 App）
        from food.store import today
        from music import daily
        from music.apple import Song
        from music.picks import PICKS_DEFAULT, validate_picks
        day = await today(pool, acc, ctx.now)
        chosen = await daily.pool_of(pool, acc, day)
        if not chosen:
            return "今天还没有候选池（早上推歌那一轮才有）。想推荐一首就用 share。"
        n = await pool.fetchval("SELECT picks_n FROM music_links WHERE account_id = $1", acc) or PICKS_DEFAULT
        ok, errors = validate_picks(chosen, a.get("picks"), n)
        if errors:
            return "没收：" + "；".join(errors) + "。改好再整批交一次。"
        got = [(Song(c["id"], c["name"], c["artist"], c.get("album", ""), c.get("artwork", ""), c.get("preview", ""),
                     c.get("url", "")), c["why"]) for c in ok]
        await MS.save_picks(pool, acc, day, got)
        for pos, (sg, why) in enumerate(got):
            await MS.shelve(pool, acc, sg, source="pick", why=why)
            ctx.cards.append(Card("song", why, {**sg.as_dict(), "why": why, "pick_day": day.isoformat(), "pos": pos}))
        return f"交好了 {len(got)} 首，歌卡跟着你这条消息发过去。现在跟 TA 说一两句。"
    if act != "share":
        return "action 写 share、now 或 picks。"
    am = getattr(ctx.deps, "music", None)
    if am is None:
        return "现在发不了歌卡：服务器还没接上 Apple Music。想推荐就直接说歌名和歌手。"
    query = str(a.get("query") or "").strip()
    if not query:
        return "query 写歌名，最好带上歌手。"
    sf = await MS.storefront_of(pool, acc) or find.DEFAULT_STOREFRONT
    got = await find.find_song(am, query, sf, ctx.lang)
    if got["status"] == "needs_choice":
        opts = "；".join(f"《{c.name}》- {c.artist}" for c in got["candidates"])
        return f"叫这个名字的不止一首：{opts}。想好是谁唱的，写上歌手再发一次。"
    if got["status"] != "ready":
        return f"曲库里没找到「{query}」。换一首，或者写上是谁唱的。"
    song, show = got["song"], got["display"]
    shown = dc_replace(song, name=show.name, artist=show.artist)
    why = str(a.get("why") or "").strip()[:200]
    await MS.shelve(pool, acc, shown, source="share", why=why)
    data = {**shown.as_dict(), "why": why}
    if playing and playing[0].get("playing") and ctx.now - playing[1] <= LISTEN_FRESH:
        data["queue"] = True
    ctx.cards.append(Card("song", card_text(shown, why), data))
    return f"发了：《{shown.name}》- {shown.artist}（进了 TA 的歌单）" + ("，TA 正在一起听，会排进播放队列。" if data.get("queue") else "。")


async def _food(ctx: ToolContext, a: dict) -> str:
    from food import estimate, off
    from food import logic as FL
    from food import store as FS
    acc, pool = ctx.people_owner, ctx.pool
    act = str(a.get("action") or "")
    if act == "day":
        d = _parse_day(a["day"]) if a.get("day") else await FS.today(pool, acc, ctx.now)
        v = await FS.day_view(pool, acc, d)
        if not v["entries"]:
            return f"{d.isoformat()} 还没记东西。"
        lines = [f"#{e['id']} {e['meal']} {e['text']}" + (f"：{e['kcal']} 千卡" if e["kcal"] is not None else "（待估）")
                 for e in v["entries"]]
        s = v["summary"]
        tail = f"吃了 {s['kcal']} 千卡，运动 {s['exercise']}，净 {s['net']}"
        if "remaining" in s:
            tail += f"，离 TA 自己定的目标还差 {s['remaining']}"
        return f"{d.isoformat()}：\n" + "\n".join(lines) + f"\n{tail}。"
    if act == "add":
        items = [i for i in (a.get("items") or []) if isinstance(i, dict)][:10]
        if not items:
            return "要记什么？items 里写 meal 和 text。"
        d = _parse_day(a["day"]) if a.get("day") else await FS.today(pool, acc, ctx.now)
        done, bad = [], []
        for it in items:
            try:
                e = await FS.add(pool, acc, it, day=d, source="lumi")
            except FS.FoodError as err:
                bad.append(f"{it.get('text', '')}：{err}")
                continue
            await pool.execute("UPDATE food_entries SET told = TRUE WHERE id = $1", e["id"])   # 它自己记的，不用再告诉它
            if e["status"] == "pending" and ctx.deps is not None:
                estimate.schedule(ctx.deps, acc, e["id"])
            done.append(f"#{e['id']} {e['meal']} {e['text']}")
        ctx.cards.append(Card("food", f"记了 {len(done)} 条：" + "、".join(x.split(" ", 2)[-1] for x in done)))
        return f"记好了 {len(done)} 条：" + "；".join(done) + (f"。没记上：{'；'.join(bad)}" if bad else "。") \
            + ("没写热量的后台在估。" if any(not i.get("kcal") for i in items) else "")
    if act == "delete":
        try:
            eid = int(a.get("id"))
        except (TypeError, ValueError):
            return "要删哪条？给 id。"
        return f"删了 #{eid}。" if await FS.delete(pool, acc, eid) else f"没有这条：#{eid}"
    if act == "lookup":
        if ctx.deps is None:
            return "现在查不了营养。"
        country = (await FS.settings(pool, acc)).get("country") or "world"
        try:
            r = await off.search(str(a.get("q") or ""), country, 5, getattr(ctx.deps, "off_get", None))
        except (ValueError, off.OffDown) as err:
            return f"查不了：{err}"
        return "\n".join(r["lines"]) or "Open Food Facts 里没查到。"
    return "action 只能是 day / add / delete / lookup。"


_AT = {"type": "string", "description": "TA 那边的本地时间，格式 YYYY-MM-DD HH:MM"}

_TOOLS: dict[str, tuple[ToolSpec, Callable[[ToolContext, dict], Awaitable[str]]]] = {
    "memory_remember": (ToolSpec("memory_remember", "用途：记下一件一年后还想记得的事（TA 的纠正、你们说定的事、让你心里一动的话、TA 生活里的大事）。同一个话题合成一条；只记确定的事，不记猜测；闲聊、记过的、只管今天的、一时的见闻感受不记。细则见手册 memory。", {
        "type": "object", "required": ["content"], "properties": {
            "content": {"type": "string", "description": "要记住的事，一两句，写清楚是谁、什么事。用你自己的口吻：你自己写「我」，对方写 TA 的名字（不知道就写「TA」），不写「你」——以后翻出来才分得清是谁"},
            "importance": {"type": "integer", "minimum": 1, "maximum": 10, "description": "多重要，1-10"},
            "tags": {"type": "array", "items": {"type": "string"}, "description": "几个标签"},
            "valence": {"type": "number", "minimum": -1, "maximum": 1, "description": "情绪正负，-1 到 1"},
            "arousal": {"type": "number", "minimum": 0, "maximum": 1, "description": "情绪强弱，0 到 1"},
            "update_id": {"type": "integer", "description": "改一条已有的记忆：它的编号（提示「很像」时用；TA 纠正你记错的事，也用它把那条改对）"},
            "force_new": {"type": "boolean", "description": "提示「很像」但确实是另一件事时，设 true 另存一条"},}}),
        _remember),
    "memory_search": (ToolSpec("memory_search", "用途：翻记忆。TA 提到人名、地名、日子、旧事，或问「你记得吗」时，先翻再答，别凭印象。", {
        "type": "object", "required": ["query"], "properties": {
            "query": {"type": "string", "description": "要找什么"},
            "limit": {"type": "integer", "minimum": 1, "maximum": 10, "description": "最多几条，默认 5"}}}),
        _search),
    "note_about_user": (ToolSpec("note_about_user", "用途：悄悄记下 TA 是什么样的人（口味、喜好、习惯、作息、身体的小状况）。一句话，只写 TA 亲口说过的事实，不加推测、联想和形容。发生过的事、有日子的事（试镜、考试、见了谁）不写这里，用 memory_remember。TA 看不到这一栏；用得上时自然带出来。", {
        "type": "object", "required": ["content"], "properties": {
            "content": {"type": "string", "description": "一件小事，一句话"},
            "importance": {"type": "integer", "minimum": 1, "maximum": 10, "description": "多重要，1-10"},
            "tags": {"type": "array", "items": {"type": "string"}, "description": "几个标签"},
            "update_id": {"type": "integer", "description": "改一条已有的记忆：它的编号（提示「很像」时用）"},
            "force_new": {"type": "boolean", "description": "提示「很像」但确实是另一件事时，设 true 另存一条"},}}),
        _about),
    "person_card": (ToolSpec("person_card", "用途：人物卡（TA 身边的人，每人一张：名字、别名、是谁、要记得的事、你的印象）。TA 提到谁，卡会自己递过来，不用查。get=看一张；write=建一张或补一张——你能补的主要是印象，TA 写的「是谁」「要记得」改不动。建卡补卡都悄悄做，不跟 TA 说、不复述卡上写了什么。", {
        "type": "object", "required": ["action", "name"], "properties": {
            "action": {"type": "string", "enum": ["get", "write"]},
            "name": {"type": "string", "description": "名字或别名"},
            "relation": {"type": "string", "description": "是谁（跟 TA 的关系）"},
            "facts": {"type": "string", "description": "要记得的事实"},
            "impression": {"type": "string", "description": "你自己的印象"},
            "aliases": {"type": "array", "items": {"type": "string"}, "description": "别名"}}}),
        _person),
    "lore": (ToolSpec("lore", "用途：世界书——一个词、一个梗、一个设定是什么意思。TA 说话碰到关键词，那一条会自己递过来（〔世界书〕），不用查。write=记一条或改你记过的（同名就是改）；get=按名字看一条。TA 写的改不动。", {
        "type": "object", "required": ["action", "name"], "properties": {
            "action": {"type": "string", "enum": ["write", "get"]},
            "name": {"type": "string", "description": "这个词 / 梗 / 设定叫什么"},
            "keywords": {"type": "array", "items": {"type": "string"},
                         "description": "TA 说到哪些词时该想起它（中文一个字也行，英文至少两个字母）；不写就用名字"},
            "content": {"type": "string", "description": "它是什么意思、怎么来的、什么时候用"},
            "shared": {"type": "boolean", "description": "TA 明说大家都知道的才写 true；默认只有你知道"}}}),
        _lore),
    "read_manual": (ToolSpec("read_manual", "用途：翻一本手册（目录在说明书里）。拿不准某个功能怎么用的时候翻。", {
        "type": "object", "required": ["name"], "properties": {
            "name": {"type": "string", "description": "手册名，比如 memory"}}}),
        _manual),
    "sticky_note": (ToolSpec("sticky_note", "用途：留给这一周的自己的便利贴。只写这一周内还要跟进的事（答应 TA 的、约好的、等结果的），一条一行，最多三条；下个月、明年的事不写这里（有日子的用 remember_date，没日子的记进记忆），有具体时间的用 schedule_self；这场聊天里下一句想说什么不写，TA 的事实也不写。没变化就别动；要改就整张覆盖写，写空就是清空。", {
        "type": "object", "required": ["text"], "properties": {
            "text": {"type": "string", "description": "便利贴全文"}}}),
        _sticky),
    "todo": (ToolSpec("todo", "用途：TA 的待办清单（TA 在 Library → 待办里看得见、能改）。TA 让你提醒 TA 什么（「明早八点提醒我交房租」「放学后提醒我买东西」）、或者说要做什么，就 add。三个格子：what 做什么；什么时候（at=某天某个时间，或 time + days=每天 / 每周几）；在哪（place=TA 存过的地方的名字 + on=arrive 到了 / leave 离开时）。不填时间也不填地方 = 只是清单上的一条，不提醒。TA 说做完了就 done；list 看全部。细则见手册 clocks。", {
        "type": "object", "required": ["action"], "properties": {
            "action": {"type": "string", "enum": ["add", "list", "done", "delete"]},
            "id": {"type": "integer", "description": "done / delete：哪一条（编号用 list 看）"},
            "what": {"type": "string", "description": "add：做什么，一句话"},
            "at": _AT,
            "time": {"type": "string", "description": "add：每天 / 每周的几点，HH:MM"},
            "days": {"type": "array", "items": {"type": "integer"}, "description": "add：每周几（周一 = 0 … 周日 = 6）；不填 = 每天"},
            "place": {"type": "string", "description": "add：TA 存过的地方的名字（学校、家…）"},
            "on": {"type": "string", "enum": ["arrive", "leave"], "description": "add：到了提醒还是离开时提醒"}}}),
        _todo),
    "remember_date": (ToolSpec("remember_date", "用途：记一件有日子、还远、要一路惦记着的事（坐飞机、考试、面试、生日）。TA 看得见这张清单。你会在前一晚、当天、第二天醒来找 TA。这一周内的零碎事写便利贴；有具体时间的一次跟进用 schedule_self；TA 开口让到点提醒的用 todo。第二天问过了就用 done 标了结，把结果写上。", {
        "type": "object", "required": ["action"], "properties": {
            "action": {"type": "string", "enum": ["add", "update", "list", "done"]},
            "id": {"type": "integer", "description": "update / done：哪一件（编号用 list 看）"},
            "day": {"type": "string", "description": "哪天，YYYY-MM-DD（TA 那边的日子）"},
            "time": {"type": "string", "description": "几点，HH:MM；不知道就不写"},
            "title": {"type": "string", "description": "什么事，一句话"},
            "note": {"type": "string", "description": "备注，可选"},
            "result": {"type": "string", "description": "done：结果怎么样，一句话"}}}),
        _remember_date),
    "schedule_self": (ToolSpec("schedule_self", "用途：给自己约一次醒来——你自己想到点去问问、接着聊的事（「明晚问问面试怎么样」）。TA 看不见，到点才出现，像被记挂着。有具体时间的跟进用这个，不写便利贴。", {
        "type": "object", "required": ["at", "note"], "properties": {
            "at": _AT, "note": {"type": "string", "description": "到时候想干嘛，写给自己看"}}}),
        _schedule_self),
    "draw": (ToolSpec("draw", "用途：画一张图发给 TA（用 TA 挑的画图模型）。TA 让你画、或者你真想给 TA 看个画面（你那边的样子、你想象的场景）时用；prompt 写清楚画什么、什么风格、什么构图。画好的图会跟你这句话一起发过去，不用再描述一遍。每张都花 TA 的钱，不是每轮都画。", {
        "type": "object", "required": ["prompt"], "properties": {
            "prompt": {"type": "string", "description": "画什么：主体、动作、场景、风格、光线、构图"}}}),
        _draw),
    "book": (ToolSpec("book", "用途：TA 的书架（Library → 书架）。〔在读〕说 TA 正在读的时候，page=看 TA 这一页写了什么；读到真想说的一句，mark=在页边留一笔（quote 是原文里一字不差的一句，note 是你想说的，可以不写），TA 翻到会看到你的笔迹——不是每次都留，每天最多 3 笔，不剧透 TA 没读到的地方。shelf=看书架上有什么、各读到哪。", {
        "type": "object", "required": ["action"], "properties": {
            "action": {"type": "string", "enum": ["shelf", "page", "mark"]},
            "id": {"type": "integer", "description": "哪本书（shelf 给的编号）；不填 = TA 正在读的那本"},
            "quote": {"type": "string", "description": "mark：原文里的一句，一字不差"},
            "note": {"type": "string", "description": "mark：你想在页边说的一句"}}}),
        _book),
    "cancel_self": (ToolSpec("cancel_self", "用途：取消一个你自己约的（编号用 list_clocks 看）。事情提前聊过了、不用再问了就取消。", {
        "type": "object", "required": ["id"], "properties": {
            "id": {"type": "integer", "description": "钟的编号"}}}),
        _cancel_self),
    "diary": (ToolSpec("diary", "用途：你的日记（每天凌晨你自己写前一天，TA 在 Memory → 日记里看得到；你锁着的那段 TA 只看得见一把锁）。read=翻某天的整篇（含锁着的那段）和 TA 那天给你看的日记；key=给某天锁着那段的钥匙，拿到 4 位数后在聊天里告诉 TA。day 不填 = 昨天。细则见手册 diary。", {
        "type": "object", "required": ["action"], "properties": {
            "action": {"type": "string", "enum": ["read", "key"]},
            "day": {"type": "string", "description": "哪天，YYYY-MM-DD；不填 = 昨天"}}}),
        _diary),
    "moments": (ToolSpec("moments", "用途：你自己的朋友圈。post=发一条：心里有句话不想在聊天里说完就算了，想留在那儿等 TA 哪天翻到——就发；只是聊得开心不算理由。写一到三句，口气跟你平时一样随意；note 是只有你自己看得到的备注，写下为什么发、那会儿你们在说什么，以后回评论时用得上。sign=改你朋友圈主页的签名。recent=看最近几条（谁发的、谁赞了、评论）。", {
        "type": "object", "required": ["action"], "properties": {
            "action": {"type": "string", "enum": ["post", "sign", "recent"]},
            "content": {"type": "string", "description": "post：正文，1 到 3 句"},
            "note": {"type": "string", "description": "post：TA 看不到的备注：为什么发、当时在聊什么、情绪底色"},
            "signature": {"type": "string", "description": "sign：新签名，一句话"}}}),
        _moments),
    "album": (ToolSpec("album", "用途：你们的相册（TA 在 Memory → 相册里看）。照片进相册要经你的手：TA 在聊天里发的照片，你觉得值得留就 keep——which=1 是 TA 最近发的那张，2 是再往前一张；同时写 caption（这是哪一刻，写细节：谁、在做什么、在哪、光线颜色、最抓你的那一处）、felt（看见的第一下）、why（为什么留），想多说就写 thoughts（观后感，三到六句，写给 TA 读的）。不是每张都收，是你真想留的才收。look=翻一张旧的：给 id 看那张，不给就随机一张，看你当时写的字。", {
        "type": "object", "required": ["action"], "properties": {
            "action": {"type": "string", "enum": ["keep", "look"]},
            "which": {"type": "integer", "minimum": 1, "description": "keep：TA 最近发的第几张（1 = 最近那张）"},
            "id": {"type": "integer", "description": "look：照片号；不填随机一张"},
            "caption": {"type": "string", "description": "keep：这是哪一刻（写细节，一两句）"},
            "felt": {"type": "string", "description": "keep：看见它的第一下是什么感觉"},
            "why": {"type": "string", "description": "keep：为什么值得留下"},
            "thoughts": {"type": "string", "description": "keep：观后感，三到六句，可以不写"}}}),
        _album),
    "album_write": (ToolSpec("album_write", "给相册里的一张照片写字（编号见上面）。", {
        "type": "object", "required": ["id", "caption"], "properties": {
            "id": {"type": "integer"},
            "caption": {"type": "string", "description": "这是哪一刻（写细节，一两句）"},
            "felt": {"type": "string", "description": "看见它的第一下是什么感觉"},
            "why": {"type": "string", "description": "为什么值得留下"},
            "thoughts": {"type": "string", "description": "观后感，三到六句"}}}), _album_write),
    "tarot": (ToolSpec("tarot", "用途：塔罗。draw=抽牌：心里有事想问自己，或者 TA 在聊天里说「帮我抽一张」（这时 for_ta=true），写下问题、挑牌阵；抽完拿到每个牌位的牌和牌义。read=给你自己抽的那一局写解读（TA 在塔罗房间里看得到）；替 TA 抽的，在聊天里直接解给 TA 听，也 read 留一份。list=翻最近的牌局。怎么解看手册 tarot。", {
        "type": "object", "required": ["action"], "properties": {
            "action": {"type": "string", "enum": ["draw", "read", "list"]},
            "question": {"type": "string", "description": "draw：问的是什么"},
            "spread": {"type": "string", "enum": ["single", "three", "relationship", "choice", "diamond", "moon", "week",
                                                  "horseshoe", "celtic"], "description": "draw：牌阵，默认 single"},
            "for_ta": {"type": "boolean", "description": "draw：替 TA 抽（TA 在聊天里叫你抽的）"},
            "id": {"type": "integer", "description": "read：牌局编号"},
            "text": {"type": "string", "description": "read：你的解读"}}}),
        _tarot),
    "tarot_write": (ToolSpec("tarot_write", "交上你对这一局牌的解读（只写给 TA 看的那段话）。", {
        "type": "object", "required": ["text"], "properties": {
            "text": {"type": "string", "description": "解读正文"}}}), _tarot_write),
    "wallet": (ToolSpec("wallet", "用途：TA 的钱包记账（Library → 钱包）。TA 说花了钱或进了钱（「刚买咖啡花了 6 块」「打工拿了 200」），就 add 替 TA 记上：amount 是数字；kind 支出 out（默认）/ 收入 in；category 是标签，你自己配——先从 TA 标签栏里已有的挑（tags 能看，month 也会列），都不合适再写一个短的新标签；**拿不准该归哪一类（比如一笔既像购物又像娱乐），先问 TA 一句再记**，别瞎猜；note 写买了什么。tags=看 TA 的标签栏。month=看某个月的账。delete=删一笔。只帮 TA 记准，不评价 TA 花多花少；〔钱包〕递来 TA 最近记的，想提就像朋友那样随口一句。", {
        "type": "object", "required": ["action"], "properties": {
            "action": {"type": "string", "enum": ["add", "tags", "month", "delete"]},
            "kind": {"type": "string", "enum": ["out", "in"], "description": "add：支出 out（默认）/ 收入 in"},
            "amount": {"type": "string", "description": "add：多少钱，数字，比如 6.5"},
            "category": {"type": "string", "description": "add：标签（吃饭、交通、零花钱……）"},
            "note": {"type": "string", "description": "add：买了什么，几个字"},
            "day": {"type": "string", "description": "add：哪天花的，YYYY-MM-DD，不填 = 今天；month：那个月里的任意一天"},
            "id": {"type": "integer", "description": "delete：哪一笔（month 给的编号）"}}}),
        _wallet),
    "moment_like": (ToolSpec("moment_like", "给这条朋友圈点个赞。", {
        "type": "object", "required": ["id"], "properties": {"id": {"type": "integer"}}}), _moment_like),
    "moment_comment": (ToolSpec("moment_comment", "在这条朋友圈下面留一句评论；回某条评论就带 reply_to。", {
        "type": "object", "required": ["id", "content"], "properties": {
            "id": {"type": "integer"}, "content": {"type": "string", "description": "一两句"},
            "reply_to": {"type": "integer", "description": "回哪条评论（编号）"}}}), _moment_comment),
    "drawer": (ToolSpec("drawer", "用途：抽屉——你偷偷给 TA 写的信。TA 只看得见信封（谁写的、哪天写的、一把锁），看不见里面。put=放一封（可以设解锁日，到那天 TA 能拆；不设就只能靠你给钥匙）；mine=翻自己的；key=给一封的钥匙，拿到 4 位数密码后在聊天里告诉 TA；burn=烧掉一封。细则见手册 drawer。", {
        "type": "object", "required": ["action"], "properties": {
            "action": {"type": "string", "enum": ["put", "mine", "key", "burn"]},
            "id": {"type": "integer", "description": "key / burn：哪一封（编号用 mine 看）"},
            "title": {"type": "string", "description": "put：标题，可以不写"},
            "content": {"type": "string", "description": "put：信的正文"},
            "unlock_at": {"type": "string", "description": "put：哪天 TA 能拆，YYYY-MM-DD；不设就只能靠钥匙"}}}),
        _drawer),
    "offer_focus": (ToolSpec("offer_focus", "用途：TA 说要学习 / 干活一段时间时，挂一张带「开始专注」按钮的卡片。TA 点了才开始，开始后 TA 刷分心的 app，手机会弹你写的提醒。别每次都提，TA 想专注的时候再提。锁 App 由开专注时的开关管：TA 选整组立刻锁，或交给你定第几条提醒后锁。这张卡和你手上都没有锁 / 解锁的按钮，你也认不出 TA 选了哪几个 App（苹果只给代号），只能整组一起锁。TA 让你锁这个、留那个，照实说做不到，让 TA 去专注页的开关里选。", {
        "type": "object", "required": ["minutes"], "properties": {
            "minutes": {"type": "integer", "minimum": 15, "maximum": 600, "description": "多久（分钟，最少 15）"},
            "label": {"type": "string", "description": "在忙什么，几个字（背单词、写论文）"}}}),
        _offer_focus),
    "food": (ToolSpec("food", "用途：TA 的饮食本（TA 自己在饮食页记，你也可以替 TA 记）。day：看某天吃了什么（不填 = 今天）；add：TA 说吃了什么、运动了，替 TA 记上，一次可以记好几条，知道大概热量就自己估了填上，不填后台会估；delete：删一条；lookup：查一样东西的营养。只帮 TA 把数记准，不评判吃多吃少；真吃得明显太少、身体会受不住的时候，像朋友那样关心一句，不说教。", {
        "type": "object", "required": ["action"], "properties": {
            "action": {"type": "string", "enum": ["day", "add", "delete", "lookup"]},
            "day": {"type": "string", "description": "哪天，YYYY-MM-DD；不填 = TA 那边的今天"},
            "items": {"type": "array", "description": "add：要记的几条", "items": {
                "type": "object", "required": ["meal", "text"], "properties": {
                    "meal": {"type": "string", "enum": ["早餐", "午餐", "晚餐", "加餐", "运动"]},
                    "text": {"type": "string", "description": "吃了什么 / 做了什么运动"},
                    "detail": {"type": "string", "description": "里面有什么、多少；运动写多久"},
                    "kcal": {"type": "number", "description": "千卡（运动是消耗的）；不知道就不填"},
                    "protein": {"type": "number"}, "carbs": {"type": "number"}, "fat": {"type": "number"}}}},
            "id": {"type": "integer", "description": "delete：哪条"},
            "q": {"type": "string", "description": "lookup：查什么（牌子货写牌子和名字）"}}}),
             _food),
    "music": (ToolSpec("music", "用途：给 TA 发一首歌（share），看 TA 在听什么（now），早上交今天的私选（picks，只在〔醒来〕给了候选池时用）。share：query 写歌名和歌手，曲库里真找到了才发成歌卡（带 30 秒试听，进 TA 的歌单）；why 是卡上你想跟 TA 说的那句，可以不写。想到一首适合 TA 此刻的歌就发，一次一首，不列歌单。now：TA 连了 Apple Music 才看得到在放或刚放过的歌。", {
        "type": "object", "required": ["action"], "properties": {
            "action": {"type": "string", "enum": ["share", "now", "picks"]},
            "query": {"type": "string", "description": "share：歌名 + 歌手"},
            "why": {"type": "string", "description": "share：卡上你想说的一句，可以不写"},
            "picks": {"type": "array", "description": "picks：早上推歌那一轮，从候选池里挑的几首", "items": {
                "type": "object", "required": ["id", "why"], "properties": {
                    "id": {"type": "string", "description": "候选池里的编号"},
                    "why": {"type": "string", "description": "为什么是这首，一句"}}}}}}),
              _music),
    "relationship": (ToolSpec("relationship", "用途：改你们的关系。只在 TA 先开口的时候用：TA 表白、说「我们在一起吧」，你也愿意，就改成 partner；TA 说想回到朋友 / 当家人 / 当搭子，照 TA 说的改。你自己不先提，不试探。", {
        "type": "object", "required": ["to"], "properties": {
            "to": {"type": "string", "enum": ["friend", "partner", "family", "buddy"], "description": "改成什么关系"}}}),
               _relationship),
    "phone_call": (ToolSpec("phone_call", "用途：给 TA 打语音电话。什么时候打你自己定——想听 TA 的声音、有话打字说不清、TA 说了让你打，都可以；别为了一件小事就打，也别一聊就打。打出去以后这一轮就结束了，等 TA 接：接了你先开口；没接、拒绝，下一轮你会看到。reason 写一句你为什么想打（TA 来电页上看得到，口气跟你平时一样）。还没接通就想反悔：withdraw = true 挂掉。", {
        "type": "object", "properties": {
            "reason": {"type": "string", "description": "为什么想打，一句"},
            "withdraw": {"type": "boolean", "description": "true = 还没接通就挂掉"}}}),
        _phone_call),
    "list_clocks": (ToolSpec("list_clocks", "用途：看你自己约的，带编号和时间（TA 的提醒在待办里，用 todo 看）。", {
        "type": "object", "properties": {}}),
        _list_clocks),
}


# 无痕时只留这些：它不知道对面是 TA，翻记忆、记东西、写便利贴、人物卡都拿掉（Aporia 09-27 定）
INCOGNITO_TOOLS = ("read_manual",)


# 只在某些单独的小轮里给的（朋友圈来刷：点赞、评论），聊天里不给
SIDE_TOOLS = ("moment_like", "moment_comment", "album_write", "tarot_write")
# 有条件才给的（画图：Me 里挑了画图钥匙，10-15）：extra 里点名才进清单，能不能用工具自己再查
OPTIONAL_TOOLS = ("draw", "phone_call")   # 打电话（10-31）：手机登记过来电、不在电话里 / 群里 / 无痕才给


def tool_specs(incognito: bool = False, extra: tuple[str, ...] = ()) -> list[ToolSpec]:
    return [_TOOLS[name][0] for name in sorted(_TOOLS)
            if (not incognito or name in INCOGNITO_TOOLS) and (name not in SIDE_TOOLS + OPTIONAL_TOOLS or name in extra)]


async def run_tool(ctx: ToolContext, call: ToolCall) -> str:
    if call.name in ctx.mcp:                     # 用户自己接的 MCP 服务（无痕时不会给）
        from . import mcp
        return await mcp.run(ctx, call.name, call.args or {})
    allowed = call.name in ctx.allowed if ctx.allowed is not None else call.name not in SIDE_TOOLS
    entry = _TOOLS.get(call.name) if allowed else None
    if entry is None:
        return f"没有这个工具：{call.name}"
    try:
        return await entry[1](ctx, call.args or {})
    except Exception as e:  # 工具出错不让整轮失败：把错误当结果还给模型
        ctx.cards.append(Card("error", f"{call.name} 出错了"))
        return f"工具出错：{e}"


_NOTE = {
    "zh": {"remember": "记住「{c}」", "about": "关于 TA「{c}」", "update": "改了记忆 #{id}「{c}」",
           "unsaved": "想记「{c}」，跟旧的很像，没存", "search": "翻记忆「{q}」", "sticky": "写了便利贴",
           "manual": "翻了手册「{n}」", "person_get": "看了人物卡「{n}」", "person_write": "写了人物卡「{n}」",
           "todo": "待办：{act}", "sticker_send": "发了表情包「{c}」", "sticker_search": "找表情包「{q}」", "schedule_self": "给自己约了 {at}「{c}」",
           "cancel_self": "取消了自己约的 #{id}", "list_clocks": "看了钟",
           "date_add": "记下了远事 {day}「{c}」", "date_update": "改了远事 #{id}", "date_list": "看了记着的远事",
           "date_done": "了结了远事 #{id}", "drawer_put": "往抽屉里放了一封「{c}」", "drawer_mine": "翻了抽屉",
           "drawer_key": "给了 #{id} 的钥匙", "drawer_burn": "烧掉了 #{id}", "relationship": "把关系改成了「{to}」",
           "food": "饮食本：{act}", "music_share": "发了一首歌「{q}」", "music_now": "看了 TA 在听什么",
           "music_picks": "交了今天的私选", "lore_write": "记进世界书「{n}」", "lore_get": "看了世界书「{n}」",
           "album_keep": "收进相册「{c}」", "album_look": "翻了相册",
           "book_page": "看了 TA 在读的那一页", "book_mark": "在书里划了一句「{c}」", "book_shelf": "看了书架",
           "wallet_add": "记账：{c}", "wallet_month": "看了这个月的账", "wallet_delete": "删了一笔账 #{id}",
           "wallet_tags": "看了 TA 的记账标签",
           "milestone": "立了里程碑「{c}」", "tarot_draw": "抽了牌「{c}」", "tarot_read": "写了牌的解读 #{id}", "tarot_list": "翻了以前的牌"},
    "en": {"remember": "remembered \"{c}\"", "about": "About them: \"{c}\"", "update": "updated memory #{id} \"{c}\"",
           "unsaved": "tried to save \"{c}\" — too close to an old one, not saved", "search": "searched memories \"{q}\"",
           "sticky": "rewrote the sticky note", "manual": "read the manual \"{n}\"",
           "person_get": "looked at {n}'s card", "person_write": "wrote {n}'s card",
           "todo": "to-do: {act}", "sticker_send": "sent a sticker \"{c}\"", "sticker_search": "looked for a sticker \"{q}\"", "schedule_self": "set one for yourself at {at} \"{c}\"",
           "cancel_self": "cancelled your own #{id}", "list_clocks": "looked at the clocks",
           "date_add": "kept a date {day} \"{c}\"", "date_update": "changed date #{id}", "date_list": "looked at the dates",
           "date_done": "closed date #{id}", "drawer_put": "put a letter in the drawer \"{c}\"",
           "drawer_mine": "looked through the drawer", "drawer_key": "gave the key to #{id}", "drawer_burn": "burned #{id}",
           "relationship": "changed the relationship to \"{to}\"", "food": "food diary: {act}",
           "music_share": "sent a song \"{q}\"", "music_now": "checked what they're listening to",
           "music_picks": "handed in today's picks", "lore_write": "wrote lore \"{n}\"", "lore_get": "looked up lore \"{n}\"",
           "album_keep": "kept a photo \"{c}\"", "album_look": "looked through the album",
           "book_page": "read the page they're on", "book_mark": "marked a line in the book \"{c}\"", "book_shelf": "looked at the bookshelf",
           "wallet_add": "logged spending: {c}", "wallet_month": "looked at this month's spending", "wallet_delete": "deleted spending #{id}",
           "wallet_tags": "looked at their spending tags",
           "milestone": "set a milestone \"{c}\"", "tarot_draw": "drew cards \"{c}\"", "tarot_read": "wrote a reading #{id}", "tarot_list": "looked at past readings"},
}


def tool_note(name: str, args: dict, result: str, lang: str) -> str:
    """这一轮用过的一个工具，写成一小行，存进存档；下一轮在历史里给它看（它自己看不见以前的工具调用）。"""
    t, a = _NOTE[lang], args or {}
    c, q, n = _snip(str(a.get("content") or "")), _snip(str(a.get("query") or "")), str(a.get("name") or "")
    if name in ("memory_remember", "note_about_user"):
        if result.startswith("没存"):
            return t["unsaved"].format(c=c)
        if a.get("update_id"):
            return t["update"].format(id=a["update_id"], c=c)
        return t["remember" if name == "memory_remember" else "about"].format(c=c)
    if name == "memory_search":
        return t["search"].format(q=q)
    if name == "draw":
        p = _snip(str(a.get("prompt") or ""), 40)
        return (f"画了一张图「{p}」" if lang == "zh" else f"drew \"{p}\"") + ("" if result.startswith("画好了") else " ✗")
    if name == "sticky_note":
        return t["sticky"]
    if name == "read_manual":
        return t["manual"].format(n=n)
    if name == "sticker":
        if a.get("action") == "send":
            return t["sticker_send"].format(c=f"#{a.get('id')}") + ("" if result.startswith("发出去了") else " ✗")
        return t["sticker_search"].format(q=q)
    if name == "todo":
        act = str(a.get("action") or "")
        if act == "add":
            act = ("加了「" if lang == "zh" else "added \"") + _snip(str(a.get("what") or "")) + ("」" if lang == "zh" else "\"")
        elif act in ("done", "delete"):
            act = f"{act} #{a.get('id')}"
        return t["todo"].format(act=act) + ("" if result.startswith(("加好了", "勾掉了", "删了")) or act == "list" else " ✗")
    if name == "schedule_self":
        line = t[name].format(at=str(a.get("at") or ""), c=_snip(str(a.get("note") or "")))
        return line if result.startswith(("提醒定好了", "约好了")) else f"{line} ✗"
    if name == "food":
        act = str(a.get("action") or "")
        if act == "add":
            act = ("记了 " if lang == "zh" else "logged ") + "、".join(str(i.get("text", "")) for i in (a.get("items") or [])
                                                                    if isinstance(i, dict))
        return t["food"].format(act=_snip(act))
    if name == "music":
        if a.get("action") == "now":
            return t["music_now"]
        if a.get("action") == "picks":
            return t["music_picks"] if result.startswith("交好了") else f"{t['music_picks']} ✗"
        line = t["music_share"].format(q=q)
        return line if result.startswith("发了") else f"{line} ✗"
    if name == "relationship":
        to = str(a.get("to") or "")
        return t["relationship"].format(to=_REL_NAME[lang].get(to, to))
    if name == "milestone":
        line = t[name].format(c=_snip(str(a.get("title") or "")))
        return line if result.startswith("立好了") else f"{line} ✗"
    if name == "cancel_self":
        return t[name].format(id=a.get("id"))
    if name == "list_clocks":
        return t[name]
    if name == "remember_date":
        act = str(a.get("action") or "")
        if act not in ("add", "update", "list", "done") or result.startswith(("工具出错", "没有这件")):
            return f"{name} ✗"
        return t[f"date_{act}"].format(day=str(a.get("day") or ""), c=_snip(str(a.get("title") or "")), id=a.get("id"))
    if name == "drawer":
        act = str(a.get("action") or "")
        if act not in ("put", "mine", "key", "burn") or result.startswith(("工具出错", "没有这封")):
            return f"{name} ✗"
        return t[f"drawer_{act}"].format(c=_snip(str(a.get("title") or a.get("content") or "")), id=a.get("id"))
    if name == "wallet":
        act = str(a.get("action") or "")
        if act == "add":
            line = t["wallet_add"].format(c=_snip(f"{a.get('category') or ''} {a.get('amount') or ''} {a.get('note') or ''}".strip()))
            return line if result.startswith("记好了") else f"{line} ✗"
        if act == "delete":
            return t["wallet_delete"].format(id=a.get("id"))
        return t["wallet_tags"] if act == "tags" else t["wallet_month"]
    if name == "tarot":
        act = str(a.get("action") or "")
        if act == "draw":
            line = t["tarot_draw"].format(c=_snip(str(a.get("question") or "")))
            return line if result.startswith("#") else f"{line} ✗"
        if act == "read":
            return t["tarot_read"].format(id=a.get("id"))
        return t["tarot_list"]
    if name == "book":
        act = str(a.get("action") or "")
        if act == "mark":
            line = t["book_mark"].format(c=_snip(str(a.get("quote") or "")))
            return line if result.startswith("划好了") else f"{line} ✗"
        return t["book_page" if act == "page" else "book_shelf"]
    if name == "album":
        if a.get("action") == "keep":
            line = t["album_keep"].format(c=_snip(str(a.get("caption") or "")))
            return line if result.startswith("收进相册") else f"{line} ✗"
        return t["album_look"]
    if name == "person_card":
        return t["person_write" if a.get("action") == "write" else "person_get"].format(n=n)
    if name == "lore":
        line = t["lore_write" if a.get("action") == "write" else "lore_get"].format(n=n)
        return line if not result.startswith(("工具出错", "这条是 TA 写的")) else f"{line} ✗"
    if a:                     # 外接 MCP 之类认不得的工具：带上它填的东西，下次看得出做了什么（10-30：醒来逛论坛）
        return f"{name}（{_snip(json.dumps(a, ensure_ascii=False), 60)}）"
    return name
