"""打电话（10-31，Host）：切句、洗句、纸条（跟 Lite 零件包 CallSpeechTests 同一套）；/call/turn 边写边推句子、
电话里不想事不写独白、你那句标〔电话〕；打断后存档只留念到的；挂断那行；合成转发 + 存档重听；通话记录。假模型、假声音。测试用小满。"""
import asyncio
import json
from uuid import UUID

from api import routes_call
from brain import call_speech as C
from llm.fake import FakeModel
from llm.tts import FakeTTS
from test_api import Env


def stream(text: str, s: C.Splitter) -> list[str]:
    out: list[str] = []
    for ch in text:
        out += s.feed(ch)
    return out + s.finish()


def test_one_line_per_sentence_and_cuts_inside_lines():
    assert stream("小满你回来啦\n今天累不累？\n我在等你吃饭。", C.Splitter()) == ["小满你回来啦", "今天累不累？", "我在等你吃饭。"]
    assert stream("真的假的？！你考了一百分。太厉害了吧", C.Splitter()) == ["真的假的？！", "你考了一百分。", "太厉害了吧"]
    assert stream("That's 3.5 hours. Go to sleep, okay?", C.Splitter()) == ["That's 3.5 hours.", "Go to sleep, okay?"]


def test_first_sentence_comes_out_early_and_short_bits_wait():
    s = C.Splitter()
    assert s.feed("我一直在呢") == []
    assert s.feed("。你") == ["我一直在呢。"]
    assert s.finish() == ["你"]
    assert stream("嗯。\n小满，我想你了。", C.Splitter()) == ["嗯。小满，我想你了。"]
    assert stream("好的，晚安。\n嗯。", C.Splitter()) == ["好的，晚安。", "嗯。"]


def test_clean_and_monologue():
    assert C.clean("（笑）好呀，那就说好了") == "好呀，那就说好了"
    assert C.clean("*抱住你* 别走嘛") == "别走嘛"
    assert C.clean("🎤 [soft] 晚安") == "晚安"
    assert C.clean("[表情包：抱抱]") is None and C.clean("⟪里程碑：第一通电话⟫") is None and C.clean("……") is None
    assert C.clean("- **记得**吃饭") == "记得吃饭"
    assert stream("[独白]\n小满听起来好累。\n[/独白]\n今天辛苦啦。\n快去躺着吧。", C.Splitter()) == ["今天辛苦啦。", "快去躺着吧。"]


def test_notes():
    assert C.clock(201) == "03:21" and C.clock(3723) == "1:02:03"
    assert C.duration_line(201, "zh") == "📞 通话时长 03:21"
    assert C.hang_up_note(201, "zh") == "〔电话挂了，这通打了 3 分 21 秒。接下来回到打字聊天。〕"
    assert "一句一行" in C.rules("zh", "她") and C.rules("en", "she").startswith("[You're on a phone call] She")


def test_ctx_keeps_only_spoken_when_cut():
    got: list[str] = []
    ctx = C.CallCtx("c1", on_line=got.append)
    for ch in "第一句话来了。\n第二句也来了。\n":
        ctx.feed(ch)
    ctx.stop(["第一句话来了。"])
    assert got == ["第一句话来了。", "第二句也来了。"] and ctx.saved_text() == "第一句话来了。——"
    try:
        ctx.feed("还")
        raise AssertionError("cut 之后再推字要停")
    except C.CallCut:
        pass


REPLY = "（笑）小满你回来啦。\n今天累不累？\n我在等你吃饭。"


async def _env(pool, tmp_path, script):
    e = Env(pool, script)
    fake = FakeTTS()
    e.deps.tts_for, e.deps.tts_key, e.deps.files_dir = (lambda k: fake), "srv", tmp_path
    t = await e.login()
    return e, fake, t


async def _turn(c, conv, text, call_id="call-1"):
    async with c.stream("POST", f"/conversations/{conv}/call/turn", json={"text": text, "call_id": call_id}) as r:
        assert r.status_code == 200
        body = (await r.aread()).decode()
    return [json.loads(l[6:]) for l in body.split("\n\n") if l.startswith("data: ")]


async def test_call_turn_streams_lines_and_folds_in_chat(pool, tmp_path):
    e, fake, t = await _env(pool, tmp_path, [REPLY, "好呀，我听着呢。\n那我先等你说完。"])
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        cid = conv["id"]
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"inner_voice": True, "long_mode": True}})
        evs = await _turn(c, cid, "我到家啦")
        assert [x["text"] for x in evs if x["type"] == "line"] == ["小满你回来啦。", "今天累不累？", "我在等你吃饭。"]
        assert evs[-1]["type"] == "done"
        req = e.model.requests[0]
        last = req.messages[-1].text
        assert last.startswith("〔电话〕我到家啦") or "〔电话〕我到家啦" in last
        assert not req.thinking
        everything = "\n".join(b.text for b in req.system) + "\n" + last
        assert "〔现在在打电话〕" in everything and "[心声]" not in last           # 电话里不写心声
        hist = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        mine, its = hist[-2], hist[-1]
        assert mine["call"] and its["call"] and mine["bubbles"] == [] and its["bubbles"] == []
        assert its["text"] == "小满你回来啦。\n今天累不累？\n我在等你吃饭。"

        # 第二轮：TA 写完了、念到第一句被打断 → 存档只留念到的 + 「——」；下一轮历史里带〔电话〕和「打断」
        evs = await _turn(c, cid, "等一下")
        assert (await c.post(f"/conversations/{cid}/call/cut", json={"call_id": "call-1", "spoken": ["好呀，我听着呢。"]})).json()["ok"]
        hist = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        assert hist[-1]["text"] == "好呀，我听着呢。——"

        r = await c.post(f"/conversations/{cid}/call/end", json={"call_id": "call-1", "seconds": 83})
        assert r.status_code == 200
        hist = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        end = hist[-1]
        assert end["call_end"] and end["divider"] == "📞 通话时长 01:23" and end["bubbles"] == []
        assert end["text"].startswith("〔电话挂了，这通打了 1 分 23 秒")


async def test_history_marks_call_lines_and_cut(pool, tmp_path):
    e, fake, t = await _env(pool, tmp_path, ["你好呀，我在。\n再说一句给你听。", "嗯，我接着说。"])
    async with e.client(t) as c:
        _, conv = await e.first_window(c)
        cid = conv["id"]
        await _turn(c, cid, "喂")
        await c.post(f"/conversations/{cid}/call/cut", json={"call_id": "call-1", "spoken": ["你好呀，我在。"]})
        await _turn(c, cid, "刚才说到哪了")
        texts = [m.text for m in e.model.requests[-1].messages]
        assert any(x.startswith("〔电话〕喂") for x in texts)
        assert any("你好呀，我在。——" in x and "被打断" in x for x in texts)


async def test_tts_relays_pcm_and_keeps_a_copy(pool, tmp_path):
    e, fake, t = await _env(pool, tmp_path, ["今天辛苦啦。"])
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        cid = conv["id"]
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"voice_id": "v1", "call_voice": "fast"}})
        info = (await c.get(f"/conversations/{cid}/call/info")).json()
        assert info["voice"] and info["call_voice"] == "fast" and info["voice_id"] == "v1"
        await _turn(c, cid, "我回来了")
        r = await c.post(f"/conversations/{cid}/call/tts", json={"text": "今天辛苦啦。", "call_id": "call-1"})
        assert r.status_code == 200 and len(r.content) == 9600
        assert fake.calls[-1][0] == "stream" and fake.calls[-1][3] == "eleven_flash_v2_5"
        await c.post(f"/conversations/{cid}/call/end", json={"call_id": "call-1", "seconds": 12})
        calls = (await c.get(f"/conversations/{cid}/calls")).json()
        assert len(calls) == 1 and calls[0]["seconds"] == 12 and calls[0]["end_message"]
        line = [l for l in calls[0]["lines"] if not l["mine"]][0]
        assert line["text"] == "今天辛苦啦。" and line["audio"]
        wav = await c.get("/" + line["audio"])
        assert wav.status_code == 200 and wav.content[:4] == b"RIFF"
        assert (await c.post(f"/conversations/{cid}/calls/call-1/hide")).json()["ok"]
        assert (await c.get(f"/conversations/{cid}/calls")).json() == []


async def test_call_voice_setting_is_checked(pool, tmp_path):
    e, fake, t = await _env(pool, tmp_path, [])
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        r = await c.patch(f"/companions/{comp['id']}", json={"settings": {"call_voice": "loud"}})
        assert r.status_code == 400


# ── 11-10：回顾里有、通话里没有 ──
# 手机上「打断上一轮」和「开始下一轮」是两个各走各的请求，谁先到不一定。以前打断只认「这通电话现在那一轮」，
# 下一轮先到的话，打断就落在新的一轮头上：没念出口的那句照存，该说的这句被掐掉。现在每一轮带自己的编号。

class GatedModel(FakeModel):
    """第 n 次调用先卡着，等测试放行（模拟它还在想）"""
    def __init__(self, script):
        super().__init__(script)
        self.gates: dict[int, asyncio.Event] = {}
        self.entered = asyncio.Event()

    async def stream(self, req):
        gate = self.gates.get(len(self.requests))
        if gate is not None:
            self.entered.set()
            await gate.wait()
        return await super().stream(req)


async def _turn2(c, conv, text, turn, call_id="call-1"):
    async with c.stream("POST", f"/conversations/{conv}/call/turn", json={"text": text, "call_id": call_id, "turn": turn}) as r:
        assert r.status_code == 200
        body = (await r.aread()).decode()
    return [json.loads(l[6:]) for l in body.split("\n\n") if l.startswith("data: ")]


def _lines(evs):
    return [x["text"] for x in evs if x["type"] == "line"]


async def test_cut_for_the_previous_turn_never_lands_on_the_next_one(pool, tmp_path):
    e, fake, t = await _env(pool, tmp_path, [])
    e.model = GatedModel(["这句你没听到。\n后面还有一句。", "两句我都听到了。\n慢慢说。"])
    gate = e.model.gates[0] = asyncio.Event()
    async with e.client(t) as c:
        _, conv = await e.first_window(c)
        cid = conv["id"]
        first = asyncio.create_task(_turn2(c, cid, "今天有点累", "t1"))
        await asyncio.wait_for(e.model.entered.wait(), 60)            # 第一轮还在想
        one = routes_call.ACTIVE["call-1"]
        second = asyncio.create_task(_turn2(c, cid, "而且没吃饭", "t2"))   # 下一轮的请求先到
        for _ in range(200):
            if routes_call.ACTIVE.get("call-1") is not one:
                break
            await asyncio.sleep(0.01)
        r = await c.post(f"/conversations/{cid}/call/cut", json={"call_id": "call-1", "turn": "t1", "spoken": []})
        assert r.json()["ok"]                                          # 打断上一轮的请求后到
        gate.set()
        assert _lines(await first) == []
        assert _lines(await second) == ["两句我都听到了。", "慢慢说。"]
        hist = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        assert [(m["role"], m["text"]) for m in hist if m["call"]] == [
            ("user", "今天有点累"), ("user", "而且没吃饭"), ("assistant", "两句我都听到了。\n慢慢说。")]
        await c.post(f"/conversations/{cid}/call/end", json={"call_id": "call-1", "seconds": 20})
        review = (await c.get(f"/conversations/{cid}/calls")).json()[0]["lines"]
        assert [l["text"] for l in review if not l["mine"]] == ["两句我都听到了。", "慢慢说。"]


async def test_cut_that_arrives_before_its_turn_still_stops_it(pool, tmp_path):
    e, fake, t = await _env(pool, tmp_path, ["这句不该出来。"])
    async with e.client(t) as c:
        _, conv = await e.first_window(c)
        cid = conv["id"]
        assert (await c.post(f"/conversations/{cid}/call/cut", json={"call_id": "call-1", "turn": "t1", "spoken": []})).json()["ok"]
        assert _lines(await _turn2(c, cid, "喂", "t1")) == []
        hist = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        assert [m["role"] for m in hist if m["call"]] == ["user"]


async def test_written_but_never_spoken_reply_leaves_the_record(pool, tmp_path):
    e, fake, t = await _env(pool, tmp_path, ["写完了还没来得及念。\n就被打断了。", "嗯，你说。"])
    async with e.client(t) as c:
        _, conv = await e.first_window(c)
        cid = conv["id"]
        await _turn2(c, cid, "喂", "t1")
        await _turn2(c, cid, "等等", "t2")
        # 手机后来才说：第一轮一句都没念出口
        assert (await c.post(f"/conversations/{cid}/call/cut", json={"call_id": "call-1", "turn": "t1", "spoken": []})).json()["ok"]
        hist = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        assert [(m["role"], m["text"]) for m in hist if m["call"]] == [("user", "喂"), ("user", "等等"), ("assistant", "嗯，你说。")]


async def test_fix_goes_to_its_own_turn(pool, tmp_path):
    e, fake, t = await _env(pool, tmp_path, ["好。", "嗯。"])
    async with e.client(t) as c:
        _, conv = await e.first_window(c)
        cid = conv["id"]
        await _turn2(c, cid, "今天天七不错", "t1")
        await _turn2(c, cid, "出去走走", "t2")
        r = await c.post(f"/conversations/{cid}/call/fix", json={"call_id": "call-1", "turn": "t1", "text": "今天天气不错"})
        assert r.json()["ok"]
        hist = (await c.get(f"/conversations/{cid}/messages")).json()["messages"]
        assert [m["text"] for m in hist if m["role"] == "user" and m["call"]] == ["今天天气不错", "出去走走"]


async def test_turn_that_says_nothing_tells_the_phone(pool, tmp_path):
    e, fake, t = await _env(pool, tmp_path, ["（笑）"])
    async with e.client(t) as c:
        _, conv = await e.first_window(c)
        evs = await _turn2(c, conv["id"], "喂", "t1")
        assert _lines(evs) == [] and [x["type"] for x in evs] == ["error", "done"]
        assert "没说出话" in evs[0]["message"]
