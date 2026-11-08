"""声音接口（10-03）：念给我听（缓存、越界、别人的）、取语音、描述一把的门槛、存嗓子（声音位满）、额度、ElevenLabs key。"""
from uuid import UUID

from llm.tts import FakeTTS
from test_api import Env


async def _env(pool, tmp_path, fake=None):
    e = Env(pool, ["今天辛苦啦\n\n明天见"])
    fake = fake or FakeTTS()
    e.deps.tts_for, e.deps.tts_key, e.deps.files_dir = (lambda k: fake), "srv", tmp_path
    return e, fake


async def test_speak_and_clip(pool, tmp_path):
    e, fake = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0, "voice_id": "v1"}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "嗨"})
        await e.rooms.idle(UUID(conv["id"]))
        msgs = (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"]
        mine = [m for m in msgs if m["role"] == "user"][0]
        it = [m for m in msgs if m["role"] == "assistant"][0]
        r = await c.post(f"/messages/{it['id']}/speak", json={"index": 1})
        assert r.status_code == 200 and fake.calls[-1][1] == "[warm, relaxed, natural] 明天见"   # 没写标签的先垫一个
        again = await c.post(f"/messages/{it['id']}/speak", json={"index": 1})
        assert again.json()["id"] == r.json()["id"] and len(fake.calls) == 1
        assert (await c.post(f"/messages/{it['id']}/speak", json={"index": 5})).status_code == 400
        assert (await c.post(f"/messages/{mine['id']}/speak", json={"index": 0})).status_code == 400
        audio = await c.get(f"/voice/clips/{r.json()['id']}")
        assert audio.status_code == 200 and audio.headers["content-type"] == "audio/mpeg"
        q = (await c.get("/voice/quota")).json()
        assert q["chars_left"] == 2000 - len("[warm, relaxed, natural] 明天见") and q["own_key"] is False
    t2 = await e.login("mia@example.com")
    async with e.client(t2) as c2:
        assert (await c2.get(f"/voice/clips/{r.json()['id']}")).status_code == 404
        assert (await c2.post(f"/messages/{it['id']}/speak", json={"index": 0})).status_code == 400


async def test_design_gate_and_choose(pool, tmp_path):
    e, fake = await _env(pool, tmp_path, FakeTTS(slots=(30, 30)))
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        assert (await c.post("/voice/design", json={"description": "低一点、懒洋洋的、带点气声"})).status_code == 403
        ok = await c.post(f"/companions/{comp['id']}/voice", json={"voice_id": "v_preset", "name": "Aria"})
        assert ok.json() == {"voice_id": "v_preset", "voice_name": "Aria", "provider": "elevenlabs"}
        got = (await c.get(f"/companions/{comp['id']}")).json()["settings"]
        assert got["voice_id"] == "v_preset" and got["voice_name"] == "Aria"
        assert (await c.post("/keys/elevenlabs", json={"api_key": "sk_mine_12345678"})).status_code == 201
        prev = await c.post("/voice/design", json={"description": "低一点、懒洋洋的、带点气声"})
        assert prev.status_code == 200 and len(prev.json()) == 3
        full = await c.post(f"/companions/{comp['id']}/voice",
                            json={"generated_voice_id": "g1", "name": "懒懒", "description": "低一点"})
        assert full.status_code == 409                                                   # 声音位满了
        fake._slots = (3, 30)
        saved = await c.post(f"/companions/{comp['id']}/voice",
                             json={"generated_voice_id": "g1", "name": "懒懒", "description": "低一点"})
        assert saved.json()["voice_id"] == "v_g1"
        assert (await c.get("/voice/quota")).json()["own_key"] is True


async def test_presets(pool, tmp_path):
    e, _ = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        ps = (await c.get("/voice/presets")).json()
        assert [p["name"] for p in ps] == ["Lauren", "Hope", "Andrew", "Jon"] and ps[0]["about"] == "温柔、让人安心"
        r = await c.get("/" + ps[0]["preview"], params={"lang": "en"})
        assert r.status_code == 200 and r.headers["content-type"] == "audio/mpeg"
        assert (await c.get("/voice/presets/nope/preview")).status_code == 404


async def test_library_needs_own_key(pool, tmp_path):
    e, fake = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        assert (await c.get("/voice/library")).status_code == 403                # 花我们 key 的人不能列我们账号里的嗓子
        assert not any(call[0] == "voices" for call in fake.calls)
        await c.post("/keys/elevenlabs", json={"api_key": "sk_mine_12345678"})
        got = (await c.get("/voice/library")).json()
        assert [v["voice_id"] for v in got] == ["v_mine_clone", "v_demo_preset"]
        assert got[0]["category"] == "cloned" and got[1]["preview"].startswith("https://")
        fake.fail = "missing_permissions"
        r = await c.get("/voice/library")
        assert r.status_code == 400 and "Voices" in r.json()["detail"]


async def test_choose_by_pasted_id(pool, tmp_path):
    e, fake = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        comp, _ = await e.first_window(c)
        path = f"/companions/{comp['id']}/voice"
        for bad in ["有中文的音色id在这里", "abc", "abcdefgh/../../v1/user", "abc def ghi jkl"]:
            assert (await c.post(path, json={"voice_id": bad})).status_code == 400
        ok = await c.post(path, json={"voice_id": " o22kMsJiTnoh4MMiZemc "})
        assert ok.json() == {"voice_id": "o22kMsJiTnoh4MMiZemc", "voice_name": "Found Voice", "provider": "elevenlabs"}
        long = await c.post(path, json={"voice_id": "v_preset_1", "name": "Adam - Distinct, Deep and Engaging"})
        assert long.json()["voice_name"] == "Adam"
        fake.fail = "voice_not_found"                                            # 查不到名字也存：公共音色查不到但念得出来
        ok = await c.post(path, json={"voice_id": "o22kMsJiTnoh4MMiZemc"})
        assert ok.json()["voice_name"] == "o22kMsJi…"


async def test_models_list_falls_back(pool, tmp_path):
    e, fake = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        plain = (await c.get("/voice/models")).json()                            # 没自带 key：出厂表
        assert plain[0]["id"] == "eleven_v4" and plain[0]["tags"] is True
        assert {m["id"]: m["tags"] for m in plain}["eleven_flash_v2_5"] is False
        await c.post("/keys/elevenlabs", json={"api_key": "sk_mine_12345678"})
        got = (await c.get("/voice/models")).json()
        assert got[0]["name"] == "Eleven v4 (from API)" and got[-1]["id"] == "eleven_new_x"
        fake.fail = "missing_permissions"                                        # 没开「看模型」权限也有的选
        assert (await c.get("/voice/models")).json()[0]["id"] == "eleven_v4"


async def test_picked_model_and_tags(pool, tmp_path):
    e, fake = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0, "voice_id": "v1", "voice_model": "eleven_flash_v2_5"}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "嗨"})
        await e.rooms.idle(UUID(conv["id"]))
        it = [m for m in (await c.get(f"/conversations/{conv['id']}/messages")).json()["messages"] if m["role"] == "assistant"][0]
        await c.post(f"/messages/{it['id']}/speak", json={"index": 1})
        assert fake.calls[-1][3] == "eleven_v4"                                  # 花我们额度的不听选的模型
        await c.post("/keys/elevenlabs", json={"api_key": "sk_mine_12345678"})
        await c.post(f"/messages/{it['id']}/speak", json={"index": 1})
        assert fake.calls[-1][3] == "eleven_flash_v2_5" and fake.calls[-1][1] == "明天见"   # 不认标签的不垫标签
        bad = await c.patch(f"/companions/{comp['id']}", json={"settings": {"voice_model": "a/b"}})
        assert bad.status_code in (400, 422)


def test_script_for_model():
    from brain.voice import DEFAULT_TAG, script
    assert script("[soft] 晚安", "eleven_flash_v2_5") == "晚安"
    assert script("[soft] 晚安", "eleven_multilingual_v2") == "晚安"
    assert script("[soft] 晚安", "eleven_v4_turbo") == "[soft] 晚安"
    assert script("晚安", "eleven_v3") == DEFAULT_TAG + "晚安"


async def test_v3_drops_context():
    import httpx
    from llm.tts import ElevenLabs
    seen = []

    async def handler(request):
        import json
        seen.append(json.loads(request.content))
        return httpx.Response(200, content=b"ID3")
    el = ElevenLabs("k", client=httpx.AsyncClient(transport=httpx.MockTransport(handler)))
    await el.synth("a", "v", model="eleven_v3", previous_text="p", next_text="n")
    await el.synth("a", "v", model="eleven_v4", previous_text="p", next_text="n")
    assert "previous_text" not in seen[0] and "next_text" not in seen[0]
    assert seen[1]["previous_text"] == "p" and seen[1]["next_text"] == "n"


async def test_speak_refuses_empty_script(pool, tmp_path):
    """只有 🎤 没有字：不把垫的标签送去念（11-07）"""
    from brain import voice as V
    e, fake = await _env(pool, tmp_path)
    t = await e.login()
    async with e.client(t):
        acc = (await pool.fetchrow("SELECT id FROM accounts ORDER BY created_at DESC LIMIT 1"))["id"]
    import pytest
    with pytest.raises(V.VoiceError):
        await V.speak(e.deps, acc, text="  ", voice_id="v1", purpose="note")
    assert not any(c[0] == "synth" for c in fake.calls)
