"""地图 + 它的一天搬上 Host（11-11）：/world/* 跟 Lite 本机同一套字段；聊天每轮〔现在〕、go_to。测试用小满。"""
import asyncio
from datetime import date, datetime, timezone
from uuid import UUID

from test_api import Env

from brain import archive
from brain import world as W
from brain.settings import Settings

NOW = datetime(2026, 10, 1, 4, 0, tzinfo=timezone.utc)             # 新加坡 10/1 12:00
DAY = date(2026, 10, 1)
WORLD = "家｜海边的小公寓｜home\n咖啡馆｜街角那家｜cafe\n图书馆｜很安静｜library\n公园｜散步的地方｜park"
PLAN = "08:00｜家｜起床\n10:00｜咖啡馆｜写东西\n14:00｜图书馆｜看书\n20:00｜家｜休息"


async def _until(check, tries=250):
    for _ in range(tries):
        if await check():
            return
        await asyncio.sleep(0.02)
    raise AssertionError("等不到")


async def _setup(e, c):
    comp, conv = await e.first_window(c)
    await c.patch(f"/companions/{comp['id']}", json={"settings": {"tz": "Asia/Singapore", "reply_wait": 0}})
    return comp, conv


async def test_world_snapshot_places_and_regenerate(pool):
    e = Env(pool, [WORLD, PLAN])
    e.deps.now = lambda: NOW
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await _setup(e, c)
        cid = comp["id"]
        assert (await c.get(f"/world/{cid}")).json() == {"off": True, "places": [], "today": [], "generating": False}
        await c.patch(f"/companions/{cid}", json={"settings": {"offline_life": True}})
        await c.get(f"/world/{cid}")                                   # 打开地图 = 今天第一次：后台起世界、排一天
        await _until(lambda: W.today(pool, UUID(cid), DAY))
        snap = (await c.get(f"/world/{cid}")).json()
        assert [p["name"] for p in snap["places"]] == ["家", "咖啡馆", "图书馆", "公园"]
        assert snap["places"][0]["home"] and snap["places"][0]["icon"] == "home" and snap["places"][1]["icon"] == "cafe"
        assert (snap["now"]["place"], snap["now"]["doing"]) == ("咖啡馆", "写东西")
        later = [d for d in snap["today"] if d.get("later")]
        assert [(d["time"], d["place"], d["doing"]) for d in later] == [("14:00", "图书馆", ""), ("20:00", "家", "")]

        r = await c.post(f"/world/{cid}/places", json={"name": "海边", "desc": "看日落", "icon": "beach"})
        assert r.status_code == 201 and (r.json()["by"], r.json()["slot"]) == ("user", 4)
        sea = r.json()["id"]
        assert (await c.post(f"/world/{cid}/places", json={"name": " "})).status_code == 400
        r = await c.patch(f"/world/{cid}/places/{sea}", json={"name": "海滩", "icon": "nope"})
        assert (r.json()["name"], r.json()["icon"]) == ("海滩", "beach")
        home = snap["places"][0]["id"]
        assert (await c.delete(f"/world/{cid}/places/{home}")).status_code == 400

        e.model.script += ["家｜山上的木屋｜home\n书店｜旧书很多｜library\n车站｜每天经过｜station", "09:00｜书店｜整理书"]
        assert (await c.post(f"/world/{cid}/generate")).status_code == 202
        await _until(lambda: _named(pool, cid, "木屋"))
        await _until(lambda: W.today(pool, UUID(cid), DAY))
        names = [p["name"] for p in (await c.get(f"/world/{cid}")).json()["places"]]
        assert names == ["家", "书店", "车站", "海滩"]                 # 它起的换了，你加的留着、挪到后面
    other = await e.login("ava@example.com")
    async with e.client(other) as c:
        assert (await c.get(f"/world/{cid}")).status_code == 404
        assert (await c.delete(f"/world/{cid}/places/{sea}")).status_code == 404


async def _named(pool, cid, word):
    return any(word in p["desc"] for p in await W.places(pool, UUID(cid)))


async def test_turn_gets_now_line_and_go_to_moves(pool):
    e = Env(pool, [WORLD, PLAN, {"calls": [("go_to", {"place": "图书馆", "doing": "还书"})]}, "我去图书馆啦"])
    e.deps.now = lambda: NOW
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await _setup(e, c)
        cid = comp["id"]
        await c.patch(f"/companions/{cid}", json={"settings": {"offline_life": True}})
        await c.get(f"/world/{cid}")
        await _until(lambda: W.today(pool, UUID(cid), DAY))
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "你在干嘛"})
        await e.rooms.idle(UUID(conv["id"]))
        snap = (await c.get(f"/world/{cid}")).json()
        msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
    req = e.model.requests[2]
    blob = "\n".join(b.text for b in req.system) + "\n".join(m.text for m in req.messages)
    assert "〔现在〕你在「咖啡馆」，写东西（来了 2 小时）" not in blob         # 来了一小时以上：来时在干的不算此刻
    assert "〔现在〕你在「咖啡馆」（来了 2 小时；刚来时写东西，那是 2 小时前的事了）" in blob
    assert "go_to" in [tl.name for tl in req.tools]
    assert (snap["now"]["place"], snap["now"]["doing"], snap["now"]["time"]) == ("图书馆", "还书", "12:00")
    assert [k["kind"] for k in msgs[-1]["cards"]] == ["place"]


async def test_visit_switches_to_in_person_and_back_clears_scene(pool):
    e = Env(pool, [WORLD, PLAN, "（抬头看见你）你怎么来了"])
    e.deps.now = lambda: NOW
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await _setup(e, c)
        cid = comp["id"]
        await c.patch(f"/companions/{cid}", json={"settings": {"offline_life": True}})
        await c.get(f"/world/{cid}")
        await _until(lambda: W.today(pool, UUID(cid), DAY))
        cafe = next(p for p in (await c.get(f"/world/{cid}")).json()["places"] if p["name"] == "咖啡馆")
        r = await c.post(f"/world/{cid}/visit", json={"place_id": cafe["id"]})
        assert r.json()["conversation"] == conv["id"]
        s = Settings.from_dict(await archive.get_settings(pool, UUID(cid)))
        assert (s.long_mode, s.scene_place) == (True, cafe["id"])
        await _until(lambda: _said(c, conv["id"]))
        wake = e.model.requests[2].messages[-1].text
        assert "TA 来「咖啡馆」找你了，你这会儿正在写东西" in wake
        assert "〔现在〕线下：你和 TA 一起在「咖啡馆」" in "\n".join(m.text for m in e.model.requests[2].messages) + \
            "\n".join(b.text for b in e.model.requests[2].system)
        await c.patch(f"/companions/{cid}", json={"settings": {"long_mode": False}})
        s = Settings.from_dict(await archive.get_settings(pool, UUID(cid)))
        assert (s.long_mode, s.scene_place) == (False, None)
        assert (await c.post(f"/world/{cid}/visit", json={"place_id": 99999})).status_code == 404


async def _said(c, conv):
    msgs = (await c.get(f"/conversations/{conv}/messages")).json()["messages"]
    return any(m["role"] == "assistant" for m in msgs)


def test_now_line_off_when_life_off():
    s = Settings.from_dict({"tz": "Asia/Singapore"})
    assert not W.life_on(s)
    assert W.find_place([{"id": 1, "name": "家", "home": True}, {"id": 2, "name": "咖啡馆", "home": False}], "回家")["id"] == 1
    assert W.find_place([{"id": 2, "name": "咖啡馆", "home": False}], "去咖啡馆坐坐")["id"] == 2
