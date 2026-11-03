"""TA 打给你（10-31 第 4 步，Host）：手机登记过来电才给 phone_call；打出去这一轮就收、经中转发一条 VoIP 推送（加密的）；
接了 TA 先开口（旁白不存成你说的话）；拒绝 / 60 秒未接 / TA 撤回各留一行灰字，正文是给 TA 的纸条。假模型、假推送。测试用小满。"""
import asyncio
import base64
import json
import os
from uuid import UUID

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from brain import call_speech as C
from brain.call_ring import Ringer
from test_api import Env

KEY = base64.b64encode(os.urandom(32)).decode()


def _open(sealed: str) -> dict:
    raw = base64.b64decode(sealed)
    return json.loads(AESGCM(base64.b64decode(KEY)).decrypt(raw[:12], raw[12:], None))


async def _env(pool, script, ring_seconds=60.0):
    e = Env(pool, script)
    sent: list[tuple[str, dict, dict]] = []

    async def send(url, headers, body):
        sent.append((url, headers, json.loads(body)))
        return 200, ""
    e.deps.ringer = Ringer(pool, "https://relay.test", publish=e.rooms.publish, send=send, ring_seconds=ring_seconds)
    t = await e.login()
    return e, sent, t


async def _say(e, c, conv, text):
    await c.post(f"/conversations/{conv}/messages", json={"text": text})
    await e.rooms.idle(UUID(conv))


async def _lite(c, comp):
    await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})


def test_ring_notes():
    assert C.ring_line("missed", "zh") == "📞 未接来电" and C.ring_line("withdrawn", "zh") == "📞 对方已取消"
    assert "她没接" in C.ring_note("missed", "zh", "她") and "declined" in C.ring_note("declined", "en", "she")
    assert "你先开口" in C.answered_nudge("zh", "她", "想听听她声音") and "因为" not in C.answered_nudge("zh", "她", " ")


async def test_no_phone_tool_until_the_phone_registers(pool):
    e, sent, t = await _env(pool, ["在呢", "在呢"])
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await _lite(c, comp)
        await _say(e, c, conv["id"], "在吗")
        assert "phone_call" not in {x.name for x in e.model.requests[-1].tools}
        r = await c.post("/me/voip", json={"relay_id": "r1", "relay_secret": "s1", "push_key": KEY})
        assert r.status_code == 204
        await _say(e, c, conv["id"], "在吗")
        assert "phone_call" in {x.name for x in e.model.requests[-1].tools}


async def test_call_rings_answer_and_ta_speaks_first(pool):
    e, sent, t = await _env(pool, [{"text": "我打给你。", "calls": [("phone_call", {"reason": "想听听你声音"})]},
                                   "喂，小满。\n我想你了。"])
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        cid = conv["id"]
        await _lite(c, comp)
        await c.post("/me/voip", json={"relay_id": "r1", "relay_secret": "s1", "push_key": KEY})
        await _say(e, c, cid, "今天好想你")
        assert len(e.model.requests) == 1                          # 打出去这一轮就收，没有第二次来回
        url, h, body = sent[-1]
        assert url == "https://relay.test/push" and body["voip"] is True and h["authorization"] == "Bearer s1"
        got = _open(body["sealed"])
        assert got["conversation"] == cid and got["reason"] == "想听听你声音" and got["name"]
        call_id = got["call"]
        assert (await c.get(f"/conversations/{cid}/call/ring/{call_id}")).json()["state"] == "ringing"
        assert (await c.post(f"/conversations/{cid}/call/ring/{call_id}/answer")).json()["ok"]
        assert (await c.get(f"/conversations/{cid}/call/ring/{call_id}")).json()["state"] == "answered"

        before = len((await c.get(f"/conversations/{cid}/messages")).json()["messages"])
        async with c.stream("POST", f"/conversations/{cid}/call/turn",
                            json={"text": "", "call_id": call_id, "answered": True, "reason": "想听听你声音"}) as r:
            evs = [json.loads(l[6:]) for l in (await r.aread()).decode().split("\n\n") if l.startswith("data: ")]
        assert [x["text"] for x in evs if x["type"] == "line"] == ["喂，小满。我想你了。"]   # 不到四个字的跟下一句并着念
        last = e.model.requests[-1].messages[-1].text
        assert "你先开口" in last and "想听听你声音" in last
        assert "phone_call" not in {x.name for x in e.model.requests[-1].tools}      # 电话里不再打电话
        msgs = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        assert len(msgs) == before + 1 and msgs[-1]["role"] == "assistant" and msgs[-1]["call"]   # 旁白没存成你说的


async def test_decline_leaves_a_line_and_a_note(pool):
    e, sent, t = await _env(pool, [{"calls": [("phone_call", {})]}, "好吧，那你忙。"])
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        cid = conv["id"]
        await _lite(c, comp)
        await c.post("/me/voip", json={"relay_id": "r1", "relay_secret": "s1", "push_key": KEY})
        await _say(e, c, cid, "嗯")
        call_id = _open(sent[-1][2]["sealed"])["call"]
        assert (await c.post(f"/conversations/{cid}/call/ring/{call_id}/decline")).json()["ok"]
        end = (await c.get(f"/conversations/{cid}/messages")).json()["messages"][-1]
        assert end["ring"] == "declined" and end["divider"] == "📞 已拒绝" and end["bubbles"] == [] and not end["call"]
        assert (await c.get(f"/conversations/{cid}/call/ring/{call_id}")).json()["state"] == "declined"
        await _say(e, c, cid, "刚在洗澡")
        texts = [m.text for m in e.model.requests[-1].messages]
        assert any("按了拒绝" in x and "〔电话〕" not in x for x in texts)
        assert (await c.get(f"/conversations/{cid}/calls")).json() == []           # 没接通的不算一通电话


async def test_missed_after_a_minute(pool):
    e, sent, t = await _env(pool, [{"calls": [("phone_call", {"reason": "到家了吗"})]}], ring_seconds=0.05)
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        cid = conv["id"]
        await _lite(c, comp)
        await c.post("/me/voip", json={"relay_id": "r1", "relay_secret": "s1", "push_key": KEY})
        await _say(e, c, cid, "出门了")
        await asyncio.sleep(0.2)
        end = (await c.get(f"/conversations/{cid}/messages")).json()["messages"][-1]
        assert end["ring"] == "missed" and end["divider"] == "📞 未接来电"


async def test_withdraw_before_answer(pool):
    e, sent, t = await _env(pool, [{"calls": [("phone_call", {})]}, {"text": "算了不打了", "calls": [("phone_call", {"withdraw": True})]},
                                   "嗯嗯"])
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        cid = conv["id"]
        await _lite(c, comp)
        await c.post("/me/voip", json={"relay_id": "r1", "relay_secret": "s1", "push_key": KEY})
        await _say(e, c, cid, "在吗")
        assert len(sent) == 1
        await _say(e, c, cid, "等一下我在开会")
        msgs = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        assert any(m.get("ring") == "withdrawn" and m["divider"] == "📞 对方已取消" for m in msgs)
