"""MiniMax 声音（11-08）：接头（请求样子、错误码归类、流式、转写、国内 / 国际版探测）和接口（存 key、选嗓子、念、试听、
收语音、电话、提示里的写法）。不联网（MockTransport / FakeTTS）。"""
import base64
import json
from uuid import UUID

import httpx

from brain import voice as V
from brain.settings import Settings
from llm.tts import MM_HOSTS, FakeTTS, MiniMax, TTSError, minimax_region, models_public
from test_api import Env


def _client(handler):
    return httpx.AsyncClient(transport=httpx.MockTransport(handler))


def _ok(**kw):
    return {**kw, "base_resp": {"status_code": 0, "status_msg": "success"}}


async def test_synth_request_shape():
    seen = {}

    def handler(req: httpx.Request):
        seen.update(path=req.url.path, host=req.url.host, auth=req.headers.get("authorization"), body=json.loads(req.content))
        return httpx.Response(200, json=_ok(data={"audio": b"ID3mm".hex(), "status": 2}))

    m = MiniMax("mm_key", MM_HOSTS["cn"], client=_client(handler))
    out = await m.synth("晚安…(sighs)", "Chinese (Mandarin)_Warm_Girl", "speech-2.8-hd", previous_text="不收这个")
    assert out == b"ID3mm"
    assert seen["path"] == "/v1/t2a_v2" and seen["host"] == "api.minimax.cn" and seen["auth"] == "Bearer mm_key"
    b = seen["body"]
    assert b["model"] == "speech-2.8-hd" and b["text"] == "晚安…(sighs)" and b["stream"] is False
    assert b["voice_setting"]["voice_id"] == "Chinese (Mandarin)_Warm_Girl"
    assert b["audio_setting"]["format"] == "mp3" and "previous_text" not in b


async def test_error_codes_map_to_kinds():
    for code, kind in ((1004, "auth"), (2049, "auth"), (1008, "quota"), (2054, "voice_not_found"), (1026, "sensitive"),
                       (2013, "bad_request"), (1000, "server")):
        def handler(req, code=code):
            return httpx.Response(200, json={"base_resp": {"status_code": code, "status_msg": "x"}})
        try:
            await MiniMax("k", client=_client(handler)).synth("hi", "v", "speech-2.8-hd")
            raise AssertionError("should fail")
        except TTSError as e:
            assert e.kind == kind, (code, e.kind)


async def test_stream_pcm_reads_sse_hex():
    def handler(req: httpx.Request):
        b = json.loads(req.content)
        assert b["stream"] is True and b["audio_setting"] == {"sample_rate": 24000, "format": "pcm", "channel": 1}
        assert b["stream_options"] == {"exclude_aggregated_audio": True}
        lines = [json.dumps(_ok(data={"audio": bytes([1, 2]).hex(), "status": 1})),
                 json.dumps(_ok(data={"audio": bytes([3, 4]).hex(), "status": 1})),
                 json.dumps(_ok(data={"audio": "", "status": 2}))]
        return httpx.Response(200, content="".join(f"data: {x}\n\n" for x in lines).encode(),
                              headers={"content-type": "text/event-stream"})

    got = [c async for c in MiniMax("k", client=_client(handler)).stream_pcm("你好", "v", "speech-2.8-turbo")]
    assert got == [bytes([1, 2]), bytes([3, 4])]


async def test_stream_error_midway_raises():
    def handler(req):
        return httpx.Response(200, content=b'data: {"base_resp": {"status_code": 1008, "status_msg": "insufficient balance"}}\n\n')
    try:
        _ = [c async for c in MiniMax("k", client=_client(handler)).stream_pcm("你好", "v", "speech-2.8-turbo")]
        raise AssertionError("should fail")
    except TTSError as e:
        assert e.kind == "quota"


async def test_voices_transcribe_design():
    def handler(req: httpx.Request):
        p = req.url.path
        if p == "/v1/get_voice":
            return httpx.Response(200, json=_ok(
                system_voice=[{"voice_id": "Chinese (Mandarin)_Warm_Girl", "voice_name": "温暖少女", "description": ["温暖"]}],
                voice_cloning=[{"voice_id": "my_clone", "description": []}], voice_generation=[]))
        if p == "/v1/speech_to_text":
            assert b"asr-1.0" in req.content and b"verbose_json" in req.content
            return httpx.Response(200, json={"text": "今天 好累", "duration": 3.0, "segments": [
                {"start": 0.0, "end": 0.6, "text": "今天"}, {"start": 1.6, "end": 2.2, "text": "好累"}]})
        if p == "/v1/voice_design":
            assert json.loads(req.content)["prompt"] == "低一点、懒洋洋的"
            return httpx.Response(200, json=_ok(voice_id="ttv-1", trial_audio=b"mp3".hex()))
        if p == "/v1/t2a_v2":
            return httpx.Response(200, json=_ok(data={"audio": b"x".hex(), "status": 2}))
        raise AssertionError(p)

    m = MiniMax("k", client=_client(handler))
    vs = await m.voices()
    assert [(v["voice_id"], v["category"]) for v in vs] == [("my_clone", "cloned"), ("Chinese (Mandarin)_Warm_Girl", "premade")]
    assert vs[1]["name"] == "温暖少女" and vs[1]["preview"] == ""
    got = await m.transcribe(b"aac", "audio/mp4")
    assert got["text"] == "今天 好累" and [w["text"] for w in got["words"]] == ["今天", "好累"]
    d = await m.design("低一点、懒洋洋的")
    assert d == [{"generated_voice_id": "ttv-1", "audio_base_64": base64.b64encode(b"mp3").decode(), "duration_secs": 0}]
    assert await m.save_design("x", "y", "ttv-1") == "ttv-1"           # 念一个字激活


async def test_region_tries_cn_then_intl():
    tried = []

    def make(key, base):
        def handler(req):
            tried.append(req.url.host)
            code = 0 if req.url.host == "api.minimax.io" else 2049
            return httpx.Response(200, json={"base_resp": {"status_code": code, "status_msg": ""}})
        return MiniMax(key, base, client=_client(handler))

    assert await minimax_region("k", make) == "intl" and tried == ["api.minimax.cn", "api.minimax.io"]

    def bad(key, base):
        return MiniMax(key, base, client=_client(lambda r: httpx.Response(200, json={"base_resp": {"status_code": 1004}})))
    try:
        await minimax_region("k", bad)
        raise AssertionError("should fail")
    except TTSError as e:
        assert e.kind == "auth"


def test_script_and_lines():
    assert V.script("[soft] 晚安…(sighs) 早点<#0.5#>睡", "speech-2.8-hd") == "晚安…(sighs) 早点<#0.5#>睡"
    assert V.script("[soft] 晚安…(sighs) 早点睡", "speech-02-hd") == "晚安… 早点睡"            # 老模型不认语气词
    assert V.strip_tags("晚安…(laughs) 早点<#0.5#>睡（笑）") == "晚安… 早点睡（笑）"           # 逐字稿：只去认得的
    s = Settings.from_dict({"voice_provider": "minimax"})
    assert V.voice_id_of(s) == "Chinese (Mandarin)_Warm_Girl"
    assert V.voice_id_of(Settings.from_dict({"voice_provider": "minimax", "lang": "en"})) == "English_Graceful_Lady"
    line = V.mode_lines("zh", "sometimes", s)[0]
    assert "(sighs)" in line and "[soft" not in line
    old = V.mode_lines("zh", "often", Settings.from_dict({"voice_provider": "minimax", "mm_voice_model": "speech-02-hd"}))[0]
    assert "(laughs)" not in old and "<#0.5#>" in old
    assert V.mode_lines("zh", "off", s) == []
    assert "[soft" in V.mode_lines("zh", "sometimes", Settings())[0]                        # ElevenLabs 照旧
    assert [m["id"] for m in models_public(provider="minimax")][0] == "speech-2.8-hd"


async def _env(pool, tmp_path, fake=None):
    e = Env(pool, ["今天辛苦啦\n\n🎤 [soft] 明天见…(sighs)"])
    fake = fake or FakeTTS()
    el = FakeTTS()
    e.deps.tts_for, e.deps.tts_key, e.deps.files_dir = (lambda k: el), "", tmp_path
    seen = []
    e.deps.minimax_for = lambda k, base: (seen.append((k, base)), fake)[1]
    return e, fake, seen


async def test_key_choose_speak_sample(pool, tmp_path):
    e, fake, seen = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        assert (await c.get("/voice/library?provider=minimax")).status_code == 403
        r = await c.post("/keys/minimax", json={"api_key": "mm_key_12345678", "region": "cn"})
        assert r.status_code == 201 and r.json()["region"] == "cn"
        keys = (await c.get("/keys")).json()
        mm = [k for k in keys if k["provider"] == "minimax"][0]
        assert mm["chores"] == ["voice"] and mm["base_url"] == MM_HOSTS["cn"]
        assert (await c.get("/voice/quota?provider=minimax")).json()["own_key"] is True
        assert (await c.get("/voice/quota")).json()["own_key"] is False               # ElevenLabs 那把还没有
        ps = (await c.get("/voice/presets?provider=minimax&lang=zh")).json()
        assert ps[0]["voice_id"] == "Chinese (Mandarin)_Warm_Girl" and ps[0]["preview"].startswith("voice/sample?")
        sample = await c.get("/" + ps[0]["preview"])
        assert sample.status_code == 200 and fake.calls[-1][2] == "Chinese (Mandarin)_Warm_Girl"
        assert seen[-1] == ("mm_key_12345678", MM_HOSTS["cn"])
        n = len(fake.calls)
        await c.get("/" + ps[0]["preview"])
        assert len(fake.calls) == n                                                      # 念过的不再花钱
        ok = await c.post(f"/companions/{comp['id']}/voice",
                          json={"provider": "minimax", "voice_id": "Chinese (Mandarin)_Gentleman", "name": "温润男声"})
        assert ok.json() == {"voice_id": "Chinese (Mandarin)_Gentleman", "voice_name": "温润男声", "provider": "minimax"}
        s = (await c.get(f"/companions/{comp['id']}")).json()["settings"]
        assert s["voice_provider"] == "minimax" and s["mm_voice_id"] == "Chinese (Mandarin)_Gentleman" and s["voice_id"] == ""
        lib = (await c.get("/voice/library?provider=minimax")).json()
        assert lib[0]["preview"].startswith("voice/sample?") and lib[1]["preview"].startswith("https://")   # 没链接的才补
        assert (await c.get("/voice/models?provider=minimax")).json()[0]["id"] == "speech-2.8-hd"

        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "嗨"})
        await e.rooms.idle(UUID(conv["id"]))
        msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
        it = [m for m in msgs if m["role"] == "assistant"][0]
        assert it["bubbles"][1] == "明天见…"                                              # 逐字稿里没有 [soft] 和 (sighs)
        assert it["lazy_voices"][1] is not None                                           # 只有 MiniMax key 也能发语音条
        r = await c.post(f"/messages/{it['id']}/speak", json={"index": 1})
        assert r.status_code == 200
        call = fake.calls[-1]
        assert call[0] == "synth" and call[1] == "明天见…(sighs)" and call[2] == "Chinese (Mandarin)_Gentleman"
        assert call[3] == "speech-2.8-hd"


async def test_voice_in_and_call_use_minimax(pool, tmp_path):
    e, fake, _ = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.post("/keys/minimax", json={"api_key": "mm_key_12345678"})
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"voice_provider": "minimax"}})
        r = await c.post(f"/conversations/{conv['id']}/voice", files={"audio": ("v.m4a", b"aac", "audio/mp4")},
                         data={"seconds": "3"})
        assert r.status_code == 201 and r.json()["text"] == "今天好累"
        assert any(x[0] == "transcribe" for x in fake.calls)
        info = (await c.get(f"/conversations/{conv['id']}/call/info")).json()
        assert info["voice"] and info["hear"] and info["provider"] == "minimax"
        assert info["voice_id"] == "Chinese (Mandarin)_Warm_Girl"
        r = await c.post(f"/conversations/{conv['id']}/call/tts", json={"text": "[soft] 你好", "call_id": "c1"})
        assert r.status_code == 200 and len(r.content) == 9600
        call = fake.calls[-1]
        assert call[0] == "stream" and call[1] == "你好" and call[3] == "speech-2.8-turbo"


async def test_minimax_without_key_is_silent(pool, tmp_path):
    e, fake, _ = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0, "voice_provider": "minimax"}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "嗨"})
        await e.rooms.idle(UUID(conv["id"]))
        msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
        it = [m for m in msgs if m["role"] == "assistant"][0]
        assert it["bubbles"][1] == "明天见…" and not any(it.get("lazy_voices") or [])   # 没 key：当文字发
        bad = await c.post(f"/companions/{comp['id']}/voice", json={"provider": "minimax", "voice_id": "bad/id"})
        assert bad.status_code == 400
