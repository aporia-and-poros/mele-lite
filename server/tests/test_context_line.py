"""TA 那边（iOS 第三块第 1 步）：手机报上来的天气 / 位置 / 日历 / 健康 + 快捷指令，拼成易变区一行。测试用小满。"""
from datetime import datetime, timedelta, timezone
from uuid import UUID

from brain import context_line as C
from test_api import Env

NOW = datetime(2026, 9, 28, 6, 0, tzinfo=timezone.utc)       # 新加坡 14:00
TZ = "Asia/Singapore"


def test_render_all_kinds():
    items = {
        "weather": ({"place": "新加坡", "temp_c": 18.4, "desc": "小雨"}, NOW - timedelta(minutes=30)),
        "place": ({"at_home": False, "name": "Kings Park", "km": 3.2}, NOW - timedelta(minutes=20)),
        "calendar": ({"events": [{"title": "牙医", "start": "2026-09-29T02:00:00+00:00", "all_day": False},
                                 {"title": "妈妈生日", "start": "2026-09-30T00:00:00+08:00", "all_day": True}]},
                     NOW - timedelta(hours=5)),
        "health": ({"steps": 6200, "sleep_h": 7.2}, NOW - timedelta(minutes=5)),
        "shortcut": ({"text": "在健身房"}, NOW - timedelta(minutes=10)),
    }
    line = C.render(items, NOW, TZ, "zh")
    assert line.startswith("〔TA 那边〕")
    assert "新加坡 18°C 小雨" in line
    assert "在 Kings Park（离家 3 公里，20 分钟前）" in line
    assert "明天 10:00 牙医" in line and "后天 妈妈生日" in line
    assert "今天 6,200 步，昨晚睡了 7 小时" in line
    assert "TA 的快捷指令：在健身房（10 分钟前）" in line


def test_stale_items_are_dropped_and_home_is_short():
    items = {
        "weather": ({"place": "新加坡", "temp_c": 18, "desc": "晴"}, NOW - timedelta(hours=4)),     # 过期
        "place": ({"at_home": True}, NOW - timedelta(minutes=5)),
    }
    assert C.render(items, NOW, TZ, "zh") == "〔TA 那边〕在家"
    assert C.render({}, NOW, TZ, "zh") == ""
    assert C.render({"weather": ({"place": "Singapore", "temp_c": 18, "desc": "Rain"}, NOW)}, NOW, TZ, "en") == \
        "〔Their side〕Singapore 18°C Rain"


async def test_put_context_and_hook(pool):
    e = Env(pool)
    t = await e.login()
    t2 = await e.login("mia@example.com")
    async with e.client(t) as c:
        assert (await c.put("/me/context/weather", json={"place": "新加坡", "temp_c": 18, "desc": "小雨"})).status_code == 204
        assert (await c.put("/me/context/nope", json={})).status_code == 400
        hook = (await c.get("/me/hook")).json()
        assert hook["url"].endswith("/hooks/context") and len(hook["token"]) >= 24
        assert (await c.get("/me/hook")).json()["token"] == hook["token"]          # 再拿还是同一个
        me = UUID((await c.get("/me")).json()["id"])
    async with e.client(hook["token"]) as h:
        assert (await h.post("/hooks/context", json={"text": "在健身房"})).status_code == 204
    async with e.client("wrong-token") as h:
        assert (await h.post("/hooks/context", json={"text": "x"})).status_code == 401
    got = await C.load(pool, me)
    assert got["weather"][0]["desc"] == "小雨" and got["shortcut"][0]["text"] == "在健身房"
    async with e.client(t) as c:
        new = (await c.post("/me/hook/reset")).json()["token"]
        assert new != hook["token"]
    async with e.client(hook["token"]) as h:                                        # 旧口令作废
        assert (await h.post("/hooks/context", json={"text": "x"})).status_code == 401
    async with e.client(t2) as c:                                                   # 别人看不到
        assert await C.load(pool, UUID((await c.get("/me")).json()["id"])) == {}


async def test_hook_url_uses_public_url(pool, monkeypatch):
    """Host 在 Caddy / 隧道后面：request 看到的是 http://，快捷指令要拿对外的 https 地址"""
    monkeypatch.setenv("NEWAPP_PUBLIC_URL", "https://box.tail1234.ts.net/")
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        assert (await c.get("/me/hook")).json()["url"] == "https://box.tail1234.ts.net/hooks/context"
        assert (await c.post("/me/hook/reset")).json()["url"] == "https://box.tail1234.ts.net/hooks/context"


async def test_turn_sees_their_side(pool):
    e = Env(pool, ["嗯嗯"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.put("/me/context/place", json={"at_home": False, "name": "Kings Park", "km": 3})
        me = UUID((await c.get("/me")).json()["id"])
    from brain.scope import Scope
    from brain.turn import run_turn

    async def emit(_):
        return None
    await run_turn(e.deps, Scope(me, UUID(comp["id"]), UUID(conv["id"])), "在吗", emit)
    assert "〔TA 那边〕在 Kings Park" in e.model.requests[-1].messages[-1].text


def test_due_only_when_useful():
    # 09-28 Aporia：它每条思考链都念天气和步数——醒来、隔两小时、换了地方 / 快捷指令新的一句才给
    home = {"place": ({"at_home": True}, NOW), "weather": ({"temp": 14}, NOW)}
    key = C.moment_key(home, NOW)
    assert C.due(home, NOW, last_at=None, last_key=None, wake=False)                       # 第一次
    shown = NOW.isoformat()
    assert not C.due(home, NOW + timedelta(minutes=30), last_at=shown, last_key=key, wake=False)
    warmer = {**home, "weather": ({"temp": 18}, NOW)}                                      # 天气变了不算
    assert not C.due(warmer, NOW + timedelta(minutes=30), last_at=shown, last_key=key, wake=False)
    assert C.due(home, NOW + timedelta(minutes=30), last_at=shown, last_key=key, wake=True)
    assert C.due(home, NOW + timedelta(hours=2), last_at=shown, last_key=key, wake=False)
    gym = {**home, "place": ({"at_home": False, "name": "健身房"}, NOW)}
    assert C.due(gym, NOW + timedelta(minutes=30), last_at=shown, last_key=key, wake=False)


async def test_turn_skips_their_side_right_after(pool):
    e = Env(pool, ["嗯嗯", "好呀"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.put("/me/context/place", json={"at_home": False, "name": "Kings Park", "km": 3})
        me = UUID((await c.get("/me")).json()["id"])
    from brain.scope import Scope
    from brain.turn import run_turn

    async def emit(_):
        return None
    scope = Scope(me, UUID(comp["id"]), UUID(conv["id"]))
    await run_turn(e.deps, scope, "在吗", emit)
    await run_turn(e.deps, scope, "今天好累", emit)
    assert "〔TA 那边〕" in e.model.requests[0].messages[-1].text
    assert "〔TA 那边〕" not in e.model.requests[1].messages[-1].text


def test_cycle_line_and_main_only():
    """经期（11-15）：手机算好的一句；只给主联系人时别的联系人看不到；变了才算「有变化」"""
    d = {"text_zh": "经期第 2 天，流量多，痛经、腰酸，心情低落", "text_en": "day 2 of her period",
         "share": "all", "companion_id": "c1", "key": "2|heavy"}
    items = {"cycle": (d, NOW - timedelta(hours=10))}
    assert C.render(items, NOW, TZ, "zh") == "〔TA 那边〕经期第 2 天，流量多，痛经、腰酸，心情低落"
    assert "day 2 of her period" in C.render(items, NOW, TZ, "en")
    main = {"cycle": ({**d, "share": "main"}, NOW)}
    assert C.render(main, NOW, TZ, "zh", companion="c1").endswith("经期第 2 天，流量多，痛经、腰酸，心情低落")
    assert C.render(main, NOW, TZ, "zh", companion="c2") == ""
    assert C.render(main, NOW, TZ, "zh") == ""
    assert C.render({"cycle": (d, NOW - timedelta(hours=40))}, NOW, TZ, "zh") == ""   # 太旧不写
    k1 = C.moment_key(items, NOW)
    assert k1 != C.moment_key({"cycle": ({**d, "key": "3|medium"}, NOW)}, NOW)
