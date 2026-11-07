"""正式接口（api/）：认人、归属、登录全流程、等候区、事件流、补拉、倒回、导出、删号。
测试数据一律是编出来的小满 / Mia。"""
import asyncio
import json
import socket
from uuid import UUID

import httpx
import pytest
import uvicorn
from cryptography.fernet import Fernet

import memory as M
from api.app import create_app
from api.deps import ApiConfig
from brain import archive, auth
from brain.turn import Deps
from llm.fake import FakeModel
from llm.router import Route
from memory.embed import FakeEmbedder

SECRET = "test-secret"


async def nosleep(_):
    return None


class Env:
    def __init__(self, pool, script=()):
        self.model = FakeModel(list(script))
        self.codes: dict[str, str] = {}
        box = auth.KeyBox(Fernet.generate_key())

        async def send_code(email, code):
            self.codes[email] = code

        trial = Route("fake", "ours", "fake-chat", "fake-ledger", trial=True)
        self.deps = Deps(pool=pool, embedder=FakeEmbedder(), keys=auth.DbKeys(pool, box, trial),
                         adapter_for=lambda r: self.model, sleep=nosleep)
        self.app = create_app(self.deps, ApiConfig(secret=SECRET, box=box, wait_scale=0.02, send_code=send_code))
        self.rooms = self.app.state.api.rooms
        self.pool = pool

    def client(self, token=None):
        headers = {"Authorization": f"Bearer {token}"} if token else {}
        return httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app), base_url="http://test", headers=headers)

    async def login(self, email="xiaoman@example.com", device_id=None):
        async with self.client() as c:
            assert (await c.post("/auth/email/code", json={"email": email})).status_code == 204
            body = {"email": email, "code": self.codes[email]}
            if device_id:
                body["device_id"] = device_id
            r = await c.post("/auth/email/verify", json=body)
        assert r.status_code == 200
        return r.json()["token"]

    async def first_window(self, c):
        comp = (await c.get("/companions")).json()[0]
        return comp, (await c.get(f"/companions/{comp['id']}/conversations")).json()[0]


async def test_no_token_is_401(pool):
    e = Env(pool)
    async with e.client() as c:
        assert (await c.get("/me")).status_code == 401
    async with e.client("made-up") as c:
        assert (await c.get("/companions")).status_code == 401


async def test_email_login_gives_a_lumi_and_a_window(pool):
    e = Env(pool)
    token = await e.login()
    async with e.client(token) as c:
        me = (await c.get("/me")).json()
        comp, conv = await e.first_window(c)
        assert (await c.post("/auth/logout")).status_code == 204
        assert (await c.get("/me")).status_code == 401
    assert me["email"] == "xiaoman@example.com" and me["plan"] == "trial" and me["trial"]["ratio"] == 1.0
    assert comp["name"] == "Lumi" and conv["incognito"] is False
    token2 = await e.login()                                   # 同一个邮箱再登录还是同一个账号
    async with e.client(token2) as c:
        assert (await c.get("/me")).json()["id"] == me["id"]


async def test_wrong_code_and_bad_email(pool):
    e = Env(pool)
    async with e.client() as c:
        assert (await c.post("/auth/email/code", json={"email": "不是邮箱"})).status_code == 400
        await c.post("/auth/email/code", json={"email": "mia@example.com"})
        r = await c.post("/auth/email/verify", json={"email": "mia@example.com", "code": "000000"
                                                     if e.codes["mia@example.com"] != "000000" else "111111"})
        assert r.status_code == 400 and r.json()["detail"] == "验证码不对"
        assert (await c.post("/auth/apple", json={})).status_code == 501


async def test_second_account_on_same_phone_gets_no_trial(pool):
    e = Env(pool)
    await e.login("xiaoman@example.com", device_id="phone-1")
    t = await e.login("mia@example.com", device_id="phone-1")
    async with e.client(t) as c:
        assert (await c.get("/me")).json()["trial"]["ratio"] == 0.2          # 没礼包，只有每日份（0.01 / 0.05）


async def test_other_peoples_ids_are_404(pool):
    e = Env(pool)
    a, b = await e.login("xiaoman@example.com"), await e.login("mia@example.com")
    async with e.client(a) as c:
        comp, conv = await e.first_window(c)
    async with e.client(b) as c:
        assert (await c.get(f"/companions/{comp['id']}")).status_code == 404
        assert (await c.patch(f"/companions/{comp['id']}", json={"persona": {"name": "偷"}})).status_code == 404
        assert (await c.get(f"/conversations/{conv['id']}/messages")).status_code == 404
        assert (await c.post(f"/conversations/{conv['id']}/messages", json={"text": "hi"})).status_code == 404
        assert (await c.delete(f"/conversations/{conv['id']}")).status_code == 404
        assert (await c.get(f"/conversations/{conv['id']}/events")).status_code == 404


async def test_companions_crud(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        lumi, _ = await e.first_window(c)
        r = await c.post("/companions", json={"name": "阿澄"})
        assert r.status_code == 201 and r.json()["name"] == "阿澄" and r.json()["conversation"]
        cid = r.json()["id"]
        r = await c.patch(f"/companions/{cid}", json={"persona": {"style": "说话很短"},
                                                      "settings": {"reply_wait": 3, "warmth": "high"}})
        body = r.json()
        assert body["persona"]["name"] == "阿澄" and body["persona"]["style"] == "说话很短"
        assert body["settings"]["reply_wait"] == 3 and body["settings"]["warmth"] == "high"
        assert (await c.patch(f"/companions/{cid}", json={"settings": {"reply_wait": 99}})).status_code == 400
        assert [x["name"] for x in (await c.get("/companions")).json()] == ["Lumi", "阿澄"]
        assert (await c.delete(f"/companions/{cid}")).status_code == 204
        assert (await c.delete(f"/companions/{lumi['id']}")).status_code == 400      # 最后一个不让删
        assert [x["name"] for x in (await c.get("/companions")).json()] == ["Lumi"]


async def test_keys_and_companion_uses_one(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        lumi, _ = await e.first_window(c)
        r = await c.post("/keys", json={"provider": "deepseek", "api_key": "sk-mia-abcdef9876",
                                        "chat_model": "deepseek-flash"})
        assert r.status_code == 201 and r.json()["last4"] == "9876" and "api_key" not in r.json()
        kid = r.json()["id"]
        assert (await c.post("/keys", json={"provider": "nope", "api_key": "sk-xxxxxxxxx",
                                            "chat_model": "m"})).status_code == 400
        assert (await c.patch(f"/companions/{lumi['id']}", json={"key_id": kid})).json()["key_id"] == kid
        assert (await c.get("/me")).json()["plan"] == "byok"
        assert (await c.delete(f"/keys/{kid}")).status_code == 204
        assert (await c.get(f"/companions/{lumi['id']}")).json()["key_id"] is None
        assert (await c.get("/keys")).json() == []


async def test_waiting_room_joins_quick_messages_into_one_turn(pool):
    e = Env(pool, ["嗯嗯，三件事我都听到了"])
    t = await e.login()
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 1}})
        q = e.rooms.listen(UUID(conv["id"]))
        for i, text in enumerate(["今天好累", "开了一天会", "晚饭还没吃"]):
            r = await c.post(f"/conversations/{conv['id']}/messages", json={"text": text, "client_id": f"c{i}"})
            assert r.status_code == 202 and r.json()["queued"] is True
        dup = await c.post(f"/conversations/{conv['id']}/messages", json={"text": "晚饭还没吃", "client_id": "c2"})
        assert dup.json()["queued"] is False                       # app 重发同一条：不排第二次
        await e.rooms.idle(UUID(conv["id"]))
        msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()
    assert len(e.model.requests) == 1                               # 三条拼成一轮
    assert [m["text"] for m in msgs["messages"]] == ["今天好累\n开了一天会\n晚饭还没吃", "嗯嗯，三件事我都听到了"]
    assert msgs["busy"] is False
    got = []
    while not q.empty():
        got.append(q.get_nowait())
    assert [g["text"] for g in got if g["type"] == "bubble"] == ["嗯嗯，三件事我都听到了"] and got[-1]["type"] == "done"


async def test_message_during_a_turn_waits_for_the_next_one(pool):
    gate = asyncio.Event()
    e = Env(pool, ["第一轮", "第二轮"])
    real = e.model.stream

    async def slow(req):
        if len(e.model.requests) == 0:
            await gate.wait()
        return await real(req)
    e.model.stream = slow
    t = await e.login()
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 0}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "一"})
        await asyncio.sleep(0.05)
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "二"})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "三"})
        assert (await c.get(f"/conversations/{conv['id']}/messages")).json()["busy"] is True
        gate.set()
        await asyncio.sleep(0.05)
        await e.rooms.idle(UUID(conv["id"]))
        texts = [m["text"] for m in (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]]
    assert texts == ["一", "第一轮", "二\n三", "第二轮"]


async def test_catch_up_after_id(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        _, conv = await e.first_window(c)
        m1 = await archive.add_message(pool, UUID(conv["id"]), "user", "早")
        await archive.add_message(pool, UUID(conv["id"]), "assistant", "早呀", thinking="她起得挺早")
        r = (await c.get(f"/conversations/{conv['id']}/messages", params={"after": m1.id})).json()
    assert [(m["role"], m["text"], m["thinking"]) for m in r["messages"]] == [("assistant", "早呀", "她起得挺早")]


async def test_rewind_edit_and_regenerate(pool):
    e = Env(pool, ["第一次的回答", "重新回的"])
    t = await e.login()
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        cid = conv["id"]
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 0}})
        await c.post(f"/conversations/{cid}/messages", json={"text": "推荐一本书"})
        await e.rooms.idle(UUID(cid))
        user, reply = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        r = await c.post(f"/conversations/{cid}/rewind", json={"message_id": reply["id"]})
        assert r.json() == {"kind": "regenerate"}
        await e.rooms.idle(UUID(cid))
        msgs = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        assert [m["text"] for m in msgs] == ["推荐一本书", "重新回的"]
        r = await c.post(f"/conversations/{cid}/rewind", json={"message_id": user["id"]})
        assert r.json() == {"kind": "edit", "text": "推荐一本书"}
        assert (await c.get(f"/conversations/{cid}/messages")).json()["messages"] == []
        assert (await c.post(f"/conversations/{cid}/rewind", json={"message_id": 999999})).status_code == 400


async def test_recall_keeps_reply_and_tells_it(pool):
    """撤回自己的一句（10-20，照之前自用的 App）：只删这一句，它的回复留着；它读过了 → 递一句「撤回了」让它接"""
    e = Env(pool, ["第一次的回答", "嗯，看到了"])
    t = await e.login()
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        cid = conv["id"]
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 0}})
        await c.post(f"/conversations/{cid}/messages", json={"text": "发错了这句"})
        await e.rooms.idle(UUID(cid))
        user, reply = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        assert (await c.post(f"/conversations/{cid}/recall", json={"message_id": reply["id"]})).status_code == 400
        r = await c.post(f"/conversations/{cid}/recall", json={"message_id": user["id"]})
        assert r.json() == {"recalled": user["id"], "told": True}
        for _ in range(200):
            await asyncio.sleep(0.01)
            await e.rooms.idle(UUID(cid))
            texts = [m["text"] for m in (await c.get(f"/conversations/{cid}/messages")).json()["messages"]]
            if "嗯，看到了" in texts:
                break
        assert "发错了这句" not in texts and "第一次的回答" in texts and "嗯，看到了" in texts
        assert (await c.post(f"/conversations/{cid}/recall", json={"message_id": 999999})).status_code == 400


async def test_recall_while_waiting_is_silent(pool):
    """还在「等你说完」里的那句（10-20）：按 client_id 拿掉，它没看到、不跑这一轮；拿完了再撤回 = 409"""
    e = Env(pool, ["不该出现的回答"])
    t = await e.login()
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        cid = conv["id"]
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 30}})
        await c.post(f"/conversations/{cid}/messages", json={"text": "发错了", "client_id": "abc"})
        r = await c.post(f"/conversations/{cid}/recall", json={"client_id": "abc"})
        assert r.json() == {"recalled": None, "told": False}
        await e.rooms.idle(UUID(cid))
        assert (await c.get(f"/conversations/{cid}/messages")).json()["messages"] == []
        assert (await c.post(f"/conversations/{cid}/recall", json={"client_id": "abc"})).status_code == 409


async def test_incognito_window_closes_clean(pool):
    e = Env(pool, ["悄悄话收到"])
    t = await e.login()
    async with e.client(t) as c:
        lumi, normal = await e.first_window(c)
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 0}})
        inc = (await c.post(f"/companions/{lumi['id']}/conversations", json={"incognito": True})).json()
        assert inc["incognito"] is True
        await c.post(f"/conversations/{inc['id']}/messages", json={"text": "别记这个"})
        await e.rooms.idle(UUID(inc["id"]))
        listed = [x["id"] for x in (await c.get(f"/companions/{lumi['id']}/conversations")).json()]
        assert inc["id"] not in listed and normal["id"] in listed         # 无痕窗口不在列表里
        assert (await c.delete(f"/conversations/{inc['id']}")).status_code == 204
        assert (await c.get(f"/conversations/{inc['id']}/messages")).status_code == 404
    assert await pool.fetchval("SELECT count(*) FROM chat_messages WHERE text = '别记这个'") == 0


async def test_profile_goes_into_every_companion(pool):
    e = Env(pool)
    t = await e.login()
    async with e.client(t) as c:
        await c.post("/companions", json={"name": "阿澄"})
        r = await c.put("/me/profile", json={"name": "小满", "pronoun": "she", "looks": "短发"})
        assert r.json() == {"name": "小满", "pronoun": "she", "looks": "短发"}
        assert (await c.put("/me/profile", json={"pronoun": "it"})).status_code == 400
        comps = [(await c.get(f"/companions/{x['id']}")).json() for x in (await c.get("/companions")).json()]
        assert all(x["settings"]["user_name"] == "小满" and x["settings"]["user_pronoun"] == "she" for x in comps)
        new = (await c.post("/companions", json={})).json()
        assert new["settings"]["user_name"] == "小满"                       # 后加的联系人也知道


async def test_export_and_delete_account(pool):
    e = Env(pool, ["记下了"])
    t = await e.login("mia@example.com")
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 0}})
        await c.post("/keys", json={"provider": "deepseek", "api_key": "sk-mia-abcdef9876", "chat_model": "deepseek-flash"})
        await M.remember(pool, e.deps.embedder, UUID(lumi["id"]), "Mia 对芒果过敏")
        acc = UUID((await c.get("/me")).json()["id"])
        await M.upsert_person(pool, e.deps.embedder, acc, "阿杰", relation="室友")
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "我对芒果过敏"})
        await e.rooms.idle(UUID(conv["id"]))
        dump = (await c.get("/me/export")).json()
        assert dump["account"]["email"] == "mia@example.com"
        assert dump["keys"][0]["last4"] == "9876" and "sk-mia" not in json.dumps(dump)
        assert [p["content"] for p in dump["people"]] and dump["companions"][0]["memories"][0]["content"] == "Mia 对芒果过敏"
        assert [m["text"] for m in dump["companions"][0]["conversations"][0]["messages"]] == ["我对芒果过敏", "记下了"]
        assert (await c.delete("/me")).status_code == 204
        assert (await c.get("/me")).status_code == 401
    for table in ("memories", "chat_messages", "user_settings", "personas", "usage_daily", "turn_logs", "user_state"):
        assert await pool.fetchval(f"SELECT count(*) FROM {table}") == 0, table
    for table in ("accounts", "companions", "conversations", "keyring", "sessions", "clocks", "wake_log", "push_queue",
                  "devices", "focus_sessions"):
        assert await pool.fetchval(f"SELECT count(*) FROM {table}") == 0, table
    assert await pool.fetchval("SELECT count(*) FROM memories WHERE user_id = $1", acc) == 0


# ── 事件流：真起一个服务器，看它一边跑一边推 ──

def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture
async def live(pool):
    e = Env(pool, ["你好\n\n我在"])
    port = _free_port()
    server = uvicorn.Server(uvicorn.Config(e.app, host="127.0.0.1", port=port, log_level="warning"))
    task = asyncio.create_task(server.serve())
    while not server.started:
        await asyncio.sleep(0.01)
    e.base = f"http://127.0.0.1:{port}"
    yield e
    server.should_exit = True
    await task


async def test_event_stream_pushes_bubbles_then_done(live):
    e = live
    t = await e.login()
    async with httpx.AsyncClient(base_url=e.base, headers={"Authorization": f"Bearer {t}"}, timeout=5) as c:
        lumi, conv = await e.first_window(c)
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 0}})
        got = []

        async def read():
            async with c.stream("GET", f"/conversations/{conv['id']}/events") as r:
                assert r.headers["content-type"].startswith("text/event-stream")
                async for line in r.aiter_lines():
                    if line.startswith("data: "):
                        got.append(json.loads(line[6:]))
                        if got[-1]["type"] == "done":
                            return
        reader = asyncio.create_task(read())
        while not e.rooms.rooms.get(UUID(conv["id"])) or \
                not e.rooms.rooms[UUID(conv["id"])].listeners:
            await asyncio.sleep(0.01)
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "在吗"})
        await asyncio.wait_for(reader, 5)
    assert [g["text"] for g in got if g["type"] == "bubble"] == ["你好", "我在"]
    assert {"typing", "usage", "done"} <= {g["type"] for g in got}


async def test_deleting_a_window_stops_its_turn(pool):
    gate = asyncio.Event()
    e = Env(pool, ["不该出现"])
    real = e.model.stream

    async def stuck(req):
        await gate.wait()
        return await real(req)
    e.model.stream = stuck
    t = await e.login()
    async with e.client(t) as c:
        lumi, conv = await e.first_window(c)
        await c.patch(f"/companions/{lumi['id']}", json={"settings": {"reply_wait": 0}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "在吗"})
        await asyncio.sleep(0.05)
        assert (await c.delete(f"/conversations/{conv['id']}")).status_code == 204
        gate.set()
        await asyncio.sleep(0.05)
    assert await pool.fetchval("SELECT count(*) FROM chat_messages WHERE text = '不该出现'") == 0


async def test_regenerate_keeps_reply_bubbles(pool):
    """重新回之后 TA 的几条气泡还是几条（11-07 一测说「合在一起了」：回复本身不会合，合的是自己连发那几句，见 ChatStore.rewind）"""
    e = Env(pool, ["第一句\n\n第二句", "第一句\n\n第二句"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        cid = conv["id"]
        await c.post(f"/conversations/{cid}/messages", json={"text": "嗨"})
        await e.rooms.idle(UUID(cid))
        msgs = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        reply = [m for m in msgs if m["role"] == "assistant"][-1]
        assert reply["bubbles"] == ["第一句", "第二句"]
        await c.post(f"/conversations/{cid}/rewind", json={"message_id": reply["id"]})
        await e.rooms.idle(UUID(cid))
        msgs = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        assert [m for m in msgs if m["role"] == "assistant"][-1]["bubbles"] == ["第一句", "第二句"]


async def test_edit_reply_and_variants(pool):
    """改 TA 的话 + 重新回留版本（11-07）"""
    e = Env(pool, ["第一版\n\n后半句", "第二版"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        cid = conv["id"]
        await c.post(f"/conversations/{cid}/messages", json={"text": "嗨"})
        await e.rooms.idle(UUID(cid))

        async def last():
            ms = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
            return [m for m in ms if m["role"] == "assistant"][-1], [m for m in ms if m["role"] == "user"][-1]
        reply, mine = await last()
        assert reply["variants"] is None
        assert (await c.patch(f"/messages/{reply['id']}", json={"bubble": 1, "text": "改过的"})).status_code == 200
        assert (await last())[0]["bubbles"] == ["第一版", "改过的"]
        assert (await c.patch(f"/messages/{reply['id']}", json={"bubble": 9, "text": "x"})).status_code == 400
        assert (await c.patch(f"/messages/{reply['id']}", json={"bubble": 0, "text": " "})).status_code == 400
        assert (await c.patch(f"/messages/{mine['id']}", json={"bubble": 0, "text": "x"})).status_code == 400

        await c.post(f"/conversations/{cid}/rewind", json={"message_id": reply["id"]})
        await e.rooms.idle(UUID(cid))
        reply, _ = await last()
        assert reply["bubbles"] == ["第二版"] and reply["variants"] == 2 and reply["variant"] == 1
        assert (await c.post(f"/messages/{reply['id']}/variant", json={"index": 0})).status_code == 200
        reply, _ = await last()
        assert reply["bubbles"] == ["第一版", "改过的"] and reply["variant"] == 0
        assert (await c.post(f"/messages/{reply['id']}/variant", json={"index": 5})).status_code == 400
        # 翻回去之后再改，切回来那一版还在；改的是当前这一版
        await c.patch(f"/messages/{reply['id']}", json={"bubble": 0, "text": "又改"})
        await c.post(f"/messages/{reply['id']}/variant", json={"index": 1})
        assert (await last())[0]["bubbles"] == ["第二版"]
        await c.post(f"/messages/{reply['id']}/variant", json={"index": 0})
        assert (await last())[0]["bubbles"] == ["又改", "改过的"]
    t2 = await e.login("mia@example.com")
    async with e.client(t2) as c2:
        assert (await c2.patch(f"/messages/{reply['id']}", json={"bubble": 0, "text": "x"})).status_code == 400
