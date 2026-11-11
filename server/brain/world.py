"""地图 + 它的一天，Host 这一份（11-11 Aporia：连 Host 的人也要有地图）。
跟 ios/Lite/LocalMap.swift 同一套规矩、同一套接口和字段，改一边改另一边。

- 每个人有自己的世界：用钥匙照人设 + 世界书起 6～8 个地方（名字 / 一句描述 / 固定图标集里挑一个），永远有一个「家」。
- 它的一天：每天第一次聊（或打开地图）排今天几点在哪、在干嘛，只从它自己的地方里挑。
  聊天时每轮给一行〔现在〕；地图上点它在的地方 = 在那儿进线下，开场是它正在做的事。
- 线下生活关着的人没有这些（谈人机恋的有人不喜欢 AI 角色扮演，默认关）；线下模式当开着。
"""
from __future__ import annotations

import asyncio
import json
import logging
from datetime import date, datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

from llm.catalog import cost
from llm.types import Block, ChatRequest, Msg

from . import archive
from .settings import Settings

log = logging.getLogger(__name__)

# 地方能用的图标（App 的 WorldMap.swift 画的就是这几个，名字一致）
ICONS = ("home", "cafe", "library", "office", "park", "shop", "restaurant", "gym", "music", "studio",
         "school", "hospital", "beach", "mountain", "station", "bar", "temple", "garden")
KEEP_DAYS = 14

_busy: set[str] = set()          # 正在起世界 / 排行程的（同一个人别并发跑两次）
_tasks: set[asyncio.Task] = set()


def life_on(s: Settings) -> bool:
    return bool(s.offline_life or s.long_mode)


def _local(now: datetime, tz: str) -> datetime:
    return now.astimezone(ZoneInfo(tz))


# ── 读 ──

def _place(r) -> dict:
    return {"id": r["id"], "companion_id": str(r["companion_id"]), "name": r["name"], "desc": r["descr"],
            "icon": r["icon"], "slot": r["slot"], "home": r["home"], "by": r["by_who"]}


async def places(pool, comp: UUID) -> list[dict]:
    rows = await pool.fetch("SELECT id, companion_id, name, descr, icon, slot, home, by_who FROM world_places "
                            "WHERE companion_id = $1 ORDER BY slot, id", comp)
    return [_place(r) for r in rows]


async def today(pool, comp: UUID, day: date) -> list[dict]:
    raw = await pool.fetchval("SELECT items FROM world_days WHERE companion_id = $1 AND day = $2", comp, day)
    return json.loads(raw) if isinstance(raw, str) else list(raw or [])


async def _save_day(pool, comp: UUID, day: date, items: list[dict]) -> None:
    await pool.execute("""INSERT INTO world_days (companion_id, day, items) VALUES ($1, $2, $3::jsonb)
                          ON CONFLICT (companion_id, day) DO UPDATE SET items = EXCLUDED.items""",
                       comp, day, json.dumps(items, ensure_ascii=False))
    await pool.execute("DELETE FROM world_days WHERE companion_id = $1 AND day < $2", comp, day - timedelta(days=KEEP_DAYS))


def current(items: list[dict], pls: list[dict], hm: str) -> dict | None:
    """此刻：今天行程里时间 ≤ 现在的最后一条（还没到第一条 = 第一条之前在家）"""
    if not items:
        return None
    done = [it for it in items if str(it.get("time", "")) <= hm]
    if done:
        return done[-1]
    home = next((p for p in pls if p["home"]), None)
    return {"time": "", "place_id": home["id"], "doing": "", "place": home["name"]} if home else None


async def snapshot(pool, comp: UUID, s: Settings, now: datetime) -> dict:
    if not life_on(s):
        return {"off": True, "places": [], "today": [], "generating": False}
    loc = _local(now, s.tz)
    hm = loc.strftime("%H:%M")
    pls = await places(pool, comp)
    names = {p["id"]: p["name"] for p in pls}
    items = await today(pool, comp, loc.date())
    shown = []
    for it in items:
        o = {**it, "place": names.get(it.get("place_id"), "")}
        if str(it.get("time", "")) > hm:          # 没到点的只给时间和地点（它还没去，「在干嘛」到了才出现，不然像剧透）
            o.update(doing="", later=True)
        shown.append(o)
    out = {"places": pls, "today": shown, "generating": str(comp) in _busy or f"{comp}#day" in _busy}
    n = current(items, pls, hm)
    if n:
        out["now"] = {**n, "place": names.get(n.get("place_id"), n.get("place", ""))}
    return out


def minutes(hm: str) -> int:
    try:
        h, m = (int(x) for x in hm.split(":"))
        return h * 60 + m
    except ValueError:
        return -1


def elapsed(mins: int, zh: bool) -> str:
    h, m = divmod(mins, 60)
    if zh:
        return f"{m} 分钟" if h == 0 else f"{h} 小时" if m == 0 else f"{h} 小时 {m} 分"
    return f"{m} min" if h == 0 else f"{h} h" if m == 0 else f"{h} h {m} min"


async def now_line(pool, comp: UUID, s: Settings, now: datetime, lang: str) -> str:
    """聊天每轮给的那一行（没排行程就不给）。跟 LocalMap.nowLine 同一份话"""
    zh = lang == "zh"
    pls = await places(pool, comp) if life_on(s) else []
    if s.long_mode:
        pl = next((p for p in pls if p["id"] == s.scene_place), None) if s.scene_place is not None else None
        if pl:            # 从地图上找过去的那场线下还没结束：你们一起在那儿，不跟行程走
            return (f"〔现在〕线下：你和 TA 一起在「{pl['name']}」。今天原本的安排先放一边，照着眼前说。" if zh else
                    f"[Right now] In person: you and them are together at \"{pl['name']}\". Set today's plan aside; stay in this scene.")
        # 10-16 内测：没开地图直接线下聊「我们在吃火锅」，它却说「我马上到」——线下模式里一律跟着聊天走
        return ("〔现在〕线下：你和 TA 在一起，在哪、在干嘛照你们聊的来。今天原本的安排先放一边，照着眼前说。" if zh else
                "[Right now] In person: you and them are together; where you are and what you're doing follow your "
                "conversation. Set today's plan aside; stay in this scene.")
    if not s.offline_life:
        return ""
    loc = _local(now, s.tz)
    n = current(await today(pool, comp, loc.date()), pls, loc.strftime("%H:%M"))
    if not n:
        return ""
    pl = next((p for p in pls if p["id"] == n.get("place_id")), None)
    name = pl["name"] if pl else ""
    if not name:
        return ""
    doing = str(n.get("doing") or "")
    since = str(n.get("time") or "")
    mins = minutes(loc.strftime("%H:%M")) - minutes(since) if since else -1
    # 不给钟点只说来了多久（10-20：给了「13:55 到的」它当成现在）；来了一小时以上，来时在干的算早过去了
    stale = mins >= 60 and bool(doing)
    clock = "" if not since or mins < 0 else (
        f"来了 {elapsed(mins, True)}" + (f"；刚来时{doing}，那是 {elapsed(mins, True)}前的事了" if stale else "") if zh else
        f"been here {elapsed(mins, False)}" + (f"; you came to {doing}, but that was {elapsed(mins, False)} ago" if stale else ""))
    shown = "" if stale else doing
    if zh:
        return (f"〔现在〕你在「{name}」{'，' + shown if shown else ''}{'（' + clock + '）' if clock else ''}。"
                "这只是背景：不用每句都提，刚说过的不再重复；时间长了事情自然往前走（吃完了、在路上了）。"
                "要挪地方——你自己想去哪，或 TA 说你在别处而你接受了——就用 go_to，不然下一句你还在这儿。")
    return (f"[Right now] You're at \"{name}\"{', ' + shown if shown else ''}{' (' + clock + ')' if clock else ''}. "
            "Background only: don't mention it every line, don't repeat what you just said; as time passes things "
            "naturally move on (done eating, on the way). To change place — you want to go somewhere, or they say "
            "you're elsewhere and you go with it — use go_to, or you'll still be here next line.")


# ── 写 ──

async def add_place(pool, acc: UUID, comp: UUID, name: str, desc: str, icon: str) -> dict:
    used = {r["slot"] for r in await pool.fetch("SELECT slot FROM world_places WHERE companion_id = $1", comp)}
    slot = next(i for i in range(len(used) + 1) if i not in used)
    r = await pool.fetchrow("""INSERT INTO world_places (account_id, companion_id, name, descr, icon, slot, home, by_who)
                               VALUES ($1, $2, $3, $4, $5, $6, false, 'user')
                               RETURNING id, companion_id, name, descr, icon, slot, home, by_who""",
                            acc, comp, name[:16], desc[:60], icon if icon in ICONS else "park", slot)
    return _place(r)


async def patch_place(pool, comp: UUID, pid: int, body: dict) -> dict | None:
    r = await pool.fetchrow("SELECT id FROM world_places WHERE id = $1 AND companion_id = $2", pid, comp)
    if r is None:
        return None
    name = str(body.get("name") or "").strip()
    if name:
        await pool.execute("UPDATE world_places SET name = $2 WHERE id = $1", pid, name[:16])
    if isinstance(body.get("desc"), str):
        await pool.execute("UPDATE world_places SET descr = $2 WHERE id = $1", pid, body["desc"][:60])
    if body.get("icon") in ICONS:
        await pool.execute("UPDATE world_places SET icon = $2 WHERE id = $1", pid, body["icon"])
    return _place(await pool.fetchrow("SELECT id, companion_id, name, descr, icon, slot, home, by_who FROM world_places "
                                      "WHERE id = $1", pid))


async def delete_place(pool, comp: UUID, pid: int) -> str:
    """'' = 删了或本来就没有；不能删就说为什么"""
    home = await pool.fetchval("SELECT home FROM world_places WHERE id = $1 AND companion_id = $2", pid, comp)
    if home:
        return "家不能删"
    await pool.execute("DELETE FROM world_places WHERE id = $1 AND companion_id = $2", pid, comp)
    return ""


def find_place(pls: list[dict], want: str) -> dict | None:
    want = (want or "").strip()
    return (next((p for p in pls if p["name"] == want), None)
            or next((p for p in pls if want and (p["name"] in want or want in p["name"])), None)
            or (next((p for p in pls if p["home"]), None) if want.lower() in ("家", "回家", "home") else None))


async def move(pool, comp: UUID, tz: str, now: datetime, place_id: int, doing: str) -> None:
    """它自己挪地方（go_to）：今天行程里在此刻插一条（同一分钟的换掉），后面排好的照旧"""
    loc = _local(now, tz)
    hm = loc.strftime("%H:%M")
    items = [it for it in await today(pool, comp, loc.date()) if it.get("time") != hm]
    items.append({"time": hm, "place_id": place_id, "doing": doing[:30]})
    items.sort(key=lambda it: str(it.get("time", "")))
    await _save_day(pool, comp, loc.date(), items)


# ── 起世界、排一天（用钥匙串里管「它的一天」的那把，没人勾就是聊天那把）──

async def _ask(deps, acc: UUID, comp: UUID, s: Settings, ask: str, max_tokens: int) -> str | None:
    import memory as M
    from . import persona as P
    from .auth import TrialOver
    from .scope import Scope
    from .turn import get_adapter, resolve_route
    pool = deps.pool
    try:
        route = await resolve_route(deps.keys, Scope(acc, comp, None), chore="day")
    except TrialOver:
        return None
    persona = P.Persona.from_dict(await archive.get_persona(pool, comp), s.lang)
    core = [x.content for x in sorted(await M.list_memories(pool, comp, kind="core"), key=lambda x: x.id)]
    base = P.render_base(persona, core, s.lang,
                         tone=[] if s.bare_mode else P.tone_lines(s.lang, s.warmth, s.initiative, s.humor),
                         relationship=s.relationship, chat_rules=False, bare=s.bare_mode)
    req = ChatRequest(model=route.chat_model, system=[Block(base)], messages=[Msg("user", ask)], max_tokens=max_tokens)
    try:
        reply = await get_adapter(deps, route).stream(req)
    except Exception as e:       # 起不成就算了：下次打开地图 / 聊天再试
        log.warning("world ask failed for %s: %s", comp, e)
        return None
    if reply.usage is not None:
        day = _local(deps.now(), s.tz).date()
        await archive.add_usage(pool, acc, day, route.chat_model, reply.usage, cost(reply.usage, route.chat_model))
    return reply.text or ""


def _bits(line: str) -> list[str]:
    return [b.strip() for b in line.replace("｜", "|").split("|")]


async def ensure_world(deps, acc: UUID, comp: UUID, *, force: bool = False) -> bool:
    pool = deps.pool
    if not force and await places(pool, comp):
        return True
    key = str(comp)
    if key in _busy:
        return False
    _busy.add(key)
    try:
        from . import lore
        s = Settings.from_dict(await archive.get_settings(pool, comp))
        zh = s.lang == "zh"
        entries = (await lore.list_for(pool, acc, comp))[:8]
        book = "\n".join(f"{e.name}：{e.content[:120]}" for e in entries)
        ask = (f"照你自己的人设和世界，列出你生活里常去的 6～8 个地方。第一个必须是你的家。每行一个，格式：\n"
               f"名字｜一句描述（15 字内）｜图标\n图标只能从这些里挑：{', '.join(ICONS)}\n只写这几行，不要别的。"
               + (f"\n\n世界书里写过的：\n{book}" if book else "")) if zh else (
               f"Based on who you are and your world, list 6-8 places you often go. The first must be your home. "
               f"One per line:\nName | one-line description (under 10 words) | icon\nIcon must be one of: "
               f"{', '.join(ICONS)}\nOnly these lines." + (f"\n\nFrom the lorebook:\n{book}" if book else ""))
        text = await _ask(deps, acc, comp, s, ask, 800)
        if text is None:
            return False
        made: list[tuple[str, str, str]] = []
        for line in text.splitlines():
            bits = _bits(line)
            if len(bits) < 2 or not bits[0]:
                continue
            name = bits[0].strip("-*•0123456789. 、")
            if not name:
                continue
            icon = bits[2].lower() if len(bits) >= 3 and bits[2].lower() in ICONS else "park"
            made.append((name[:16], bits[1][:60], "home" if not made else icon))
            if len(made) == 8:
                break
        if len(made) < 3:
            return False
        async with pool.acquire() as con, con.transaction():
            # 重起世界：它起的换掉，你自己加的留着（挪到后面的空位）
            await con.execute("DELETE FROM world_places WHERE companion_id = $1 AND by_who = 'ai'", comp)
            mine = await con.fetch("SELECT id FROM world_places WHERE companion_id = $1 ORDER BY slot, id", comp)
            for i, r in enumerate(mine):
                await con.execute("UPDATE world_places SET slot = $2 WHERE id = $1", r["id"], len(made) + i)
            for i, (name, desc, icon) in enumerate(made):
                await con.execute("""INSERT INTO world_places (account_id, companion_id, name, descr, icon, slot, home, by_who)
                                     VALUES ($1, $2, $3, $4, $5, $6, $7, 'ai')""", acc, comp, name, desc, icon, i, i == 0)
            await con.execute("DELETE FROM world_days WHERE companion_id = $1", comp)   # 行程跟着旧地方作废
        return True
    finally:
        _busy.discard(key)


async def ensure_day(deps, acc: UUID, comp: UUID) -> bool:
    """今天的行程：没有就排（只从它自己的地方里挑）"""
    pool = deps.pool
    s = Settings.from_dict(await archive.get_settings(pool, comp))
    loc = _local(deps.now(), s.tz)
    if await today(pool, comp, loc.date()):
        return True
    if not await ensure_world(deps, acc, comp):
        return False
    pls = await places(pool, comp)
    key = f"{comp}#day"
    if not pls or key in _busy:
        return False
    _busy.add(key)
    try:
        zh = s.lang == "zh"
        listed = "\n".join(f"{p['name']}（{p['desc']}）" for p in pls)
        weekday = "一二三四五六日"[loc.weekday()]
        ask = (f"今天是 {loc:%Y-%m-%d} 星期{weekday}。排一下你今天的一天：从起床到睡觉 5～8 段，只能去这些地方：\n{listed}\n"
               "每行一段，格式：\nHH:MM｜地方名字｜在干嘛（12 字内）\n照你平时的样子排，按时间顺序，只写这几行。") if zh else (
               f"Today is {loc:%A, %d %b}. Plan your day from waking up to bed in 5-8 blocks, only at these places:\n"
               f"{listed}\nOne per line:\nHH:MM | place name | what you're doing (under 8 words)\nIn time order, only these lines.")
        text = await _ask(deps, acc, comp, s, ask, 700)
        if text is None:
            return False
        items = []
        for line in text.splitlines():
            bits = _bits(line)
            if len(bits) < 3:
                continue
            hm = "".join(ch for ch in bits[0].replace("：", ":") if ch.isdigit() or ch == ":")
            try:
                h, m = (int(x) for x in hm.split(":"))
            except ValueError:
                continue
            if not (0 <= h < 24 and 0 <= m < 60):
                continue
            pl = (next((p for p in pls if p["name"] == bits[1]), None)
                  or next((p for p in pls if p["name"] and (p["name"] in bits[1] or bits[1] in p["name"])), None))
            if pl is None:
                continue
            items.append({"time": f"{h:02d}:{m:02d}", "place_id": pl["id"], "doing": bits[2][:30]})
        if not items:
            return False
        items.sort(key=lambda it: it["time"])
        await _save_day(pool, comp, loc.date(), items)
        return True
    finally:
        _busy.discard(key)


def _spawn(coro) -> None:
    t = asyncio.create_task(coro)
    _tasks.add(t)
    t.add_done_callback(_tasks.discard)


async def kick_day(deps, acc: UUID, comp: UUID, s: Settings, now: datetime) -> None:
    """线下生活开着、今天还没排：后台排（不挡这一轮）。线下模式不排——那会儿跟着聊天走，用不上行程"""
    if not s.offline_life or f"{comp}#day" in _busy or str(comp) in _busy:
        return
    if await today(deps.pool, comp, _local(now, s.tz).date()):
        return
    _spawn(ensure_day(deps, acc, comp))


def regenerate(deps, acc: UUID, comp: UUID) -> None:
    async def go():
        if await ensure_world(deps, acc, comp, force=True):
            await ensure_day(deps, acc, comp)
    _spawn(go())


def visit_note(lang: str, name: str, doing: str) -> str:
    if lang == "zh":
        return (f"（TA 来「{name}」找你了{'，你这会儿正在' + doing if doing else ''}。"
                "线下开场：写你在那儿正做着的事、身边的样子，然后看见 TA 来了。）")
    return (f"(They came to find you at \"{name}\"{' while you are ' + doing if doing else ''}. "
            "Open the in-person scene: what you're doing there, the surroundings, then noticing them arrive.)")
