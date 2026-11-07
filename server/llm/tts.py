"""ElevenLabs 接头（10-03，声音第一块；设计 docs/specs/2026-10-03-voice-notes-design.md）。

合成（语音条 / 念给我听用 eleven_v4）、列官方嗓子、用文字描述设计嗓子、把设计出来的那把存进账号、查声音位。
v4 只认 stability 0 / 0.5 / 1（用 0.5），不认 speed；previous_text / next_text 让前后句语气接得上（之前自用的 App 10-01 实测）。
价格（每千字美元，10-03 核对官网 elevenlabs.io/pricing/api）：v4 0.08、v4 turbo 0.04；10/12 前打 72% 折，按原价记账，宁可估高。
FakeTTS 给测试和演示服务器用，不联网。"""
from __future__ import annotations

import re

import httpx

PRICE_PER_K = {"eleven_v4": 0.08, "eleven_v4_turbo": 0.04}
NOTE_MODEL = "eleven_v4"
STT_MODEL = "scribe_v2"
DESIGN_MODEL = "eleven_ttv_v3"
# 语音条能选的模型（11-07，内测）。key 没开「看模型」权限时就给这张表，开了就用 ElevenLabs 给的、这张表排前面
MODELS = [("eleven_v4", "Eleven v4"), ("eleven_v4_turbo", "Eleven v4 Turbo"), ("eleven_v3", "Eleven v3"),
          ("eleven_v3_conversational", "Eleven v3 Conversational"), ("eleven_multilingual_v2", "Multilingual v2"),
          ("eleven_flash_v2_5", "Flash v2.5"), ("eleven_turbo_v2_5", "Turbo v2.5")]


def takes_tags(model: str) -> bool:
    """这个模型认不认 [soft, tired] 这种音频标签（v3 起才认；别的模型会把标签照字念出来）。"""
    return re.match(r"eleven_v\d", model) is not None


def takes_context(model: str) -> bool:
    """v3 不收 previous_text / next_text（11-07 实测 400 unsupported_model），带了整句念不了。"""
    return not model.startswith("eleven_v3")


def models_public(rows: list[tuple[str, str]] | None = None) -> list[dict]:
    """给设置页的模型表：出厂那几个排前面，ElevenLabs 那边多出来的跟在后面。"""
    got = dict(rows or [])
    order = [m for m, _ in MODELS] + [m for m in got if m not in dict(MODELS)]
    names = {**dict(MODELS), **got}
    return [{"id": m, "name": names[m], "tags": takes_tags(m)} for m in order]


def tts_cost(chars: int, model: str) -> float:
    return chars / 1000 * PRICE_PER_K.get(model, 0.08)


class TTSError(Exception):
    """kind：auth（key 不对或没权限）/ quota（ElevenLabs 那边额度用完、限流）/ bad_request / server / network"""

    def __init__(self, kind: str, message: str = ""):
        super().__init__(message or kind)
        self.kind = kind


def _kind(status: int) -> str:
    if status in (401, 403):
        return "auth"
    if status in (402, 429):
        return "quota"
    if 400 <= status < 500:
        return "bad_request"
    return "server"


def _fail(status: int, body: str) -> "TTSError":
    """这几种 ElevenLabs 说得清楚，单独归一类，提示才说得准（missing_permissions：10-04 实测，只开了部分权限的 key）。"""
    for kind in ("missing_permissions", "voice_not_found", "model_not_found"):
        if kind in body:
            return TTSError(kind, body[:300])
    return TTSError(_kind(status), body[:300])


class ElevenLabs:
    def __init__(self, api_key: str, base: str = "https://api.elevenlabs.io", client: httpx.AsyncClient | None = None):
        self.key, self.base = api_key, base.rstrip("/")
        self._client = client

    async def _req(self, method: str, path: str, **kw) -> httpx.Response:
        client = self._client or httpx.AsyncClient(timeout=60)
        try:
            r = await client.request(method, self.base + path, headers={"xi-api-key": self.key}, **kw)
        except httpx.HTTPError as e:
            raise TTSError("network", str(e)) from e
        finally:
            if self._client is None:
                await client.aclose()
        if r.status_code >= 400:
            raise _fail(r.status_code, r.text)
        return r

    async def synth(self, text: str, voice_id: str, model: str = NOTE_MODEL,
                    previous_text: str | None = None, next_text: str | None = None) -> bytes:
        body: dict = {"text": text, "model_id": model, "voice_settings": {"stability": 0.5}}
        if previous_text and takes_context(model):
            body["previous_text"] = previous_text
        if next_text and takes_context(model):
            body["next_text"] = next_text
        r = await self._req("POST", f"/v1/text-to-speech/{voice_id}", params={"output_format": "mp3_44100_128"}, json=body)
        return r.content

    async def stream_pcm(self, text: str, voice_id: str, model: str, previous_text: str | None = None):
        """电话（10-31）：流式合成，边合成边吐 24k 16 位单声道 PCM。第一块到了就往手机推，不等整句。
        这个模型不收流式（400）就退回整句合成，切块照样吐。"""
        body: dict = {"text": text, "model_id": model, "voice_settings": {"stability": 0.5}}
        if previous_text and takes_context(model):
            body["previous_text"] = previous_text
        client = self._client or httpx.AsyncClient(timeout=httpx.Timeout(20, read=30))
        try:
            for path in (f"/v1/text-to-speech/{voice_id}/stream", f"/v1/text-to-speech/{voice_id}"):
                try:
                    async with client.stream("POST", self.base + path, params={"output_format": "pcm_24000"},
                                             headers={"xi-api-key": self.key}, json=body) as r:
                        if r.status_code >= 400:
                            err = (await r.aread()).decode(errors="ignore")
                            if r.status_code == 400 and path.endswith("/stream"):
                                continue
                            raise _fail(r.status_code, err)
                        async for chunk in r.aiter_bytes():
                            yield chunk
                        return
                except httpx.HTTPError as e:
                    raise TTSError("network", str(e)) from e
            raise TTSError("bad_request", "stream refused")
        finally:
            if self._client is None:
                await client.aclose()

    async def premade(self) -> list[dict]:
        r = await self._req("GET", "/v1/voices")
        return [{"voice_id": v["voice_id"], "name": v.get("name", ""), "labels": v.get("labels") or {},
                 "preview_url": v.get("preview_url") or ""}
                for v in r.json().get("voices", []) if v.get("category") == "premade"]

    async def voices(self) -> list[dict]:
        """这把 key 账号里所有的嗓子（自己克隆的、设计的、收藏的、官方的）：音色库（11-07）。"""
        r = await self._req("GET", "/v1/voices")
        return [{"voice_id": v["voice_id"], "name": v.get("name", ""), "category": v.get("category") or "",
                 "about": v.get("description") or "", "preview": v.get("preview_url") or ""}
                for v in r.json().get("voices", [])]

    async def voice_name(self, voice_id: str) -> str:
        """填音色 ID 时查个名字。没加进账号的公共音色这里查不到，但念得出来（11-07 实测），所以查不到不算错。"""
        r = await self._req("GET", f"/v1/voices/{voice_id}")
        return r.json().get("name", "")

    async def models(self) -> list[tuple[str, str]]:
        """（模型 id，名字）。只要能合成的。"""
        r = await self._req("GET", "/v1/models")
        return [(m["model_id"], m.get("name") or m["model_id"]) for m in r.json() if m.get("can_do_text_to_speech")]

    async def design(self, description: str, text: str | None = None) -> list[dict]:
        body: dict = {"voice_description": description, "model_id": DESIGN_MODEL}
        if text:
            body["text"] = text
        else:
            body["auto_generate_text"] = True
        r = await self._req("POST", "/v1/text-to-voice/design", json=body)
        return [{"generated_voice_id": p["generated_voice_id"], "audio_base_64": p["audio_base_64"],
                 "duration_secs": p.get("duration_secs", 0)} for p in r.json().get("previews", [])]

    async def save_design(self, name: str, description: str, generated_voice_id: str) -> str:
        r = await self._req("POST", "/v1/text-to-voice", json={"voice_name": name, "voice_description": description,
                                                                "generated_voice_id": generated_voice_id})
        return r.json()["voice_id"]

    async def slots(self) -> tuple[int, int]:
        """（用了几个声音位，上限几个）"""
        d = (await self._req("GET", "/v1/user/subscription")).json()
        return int(d.get("voice_slots_used", 0)), int(d.get("voice_limit", 0))

    async def transcribe(self, audio: bytes, mime: str, name: str = "voice.m4a") -> dict:
        """Scribe v2：转文字 + 标声音事件（笑、叹气）+ 每个词的起止时间。返回 {text, words:[{text,type,start,end}]}。"""
        r = await self._req("POST", "/v1/speech-to-text",
                            data={"model_id": STT_MODEL, "tag_audio_events": "true", "timestamps_granularity": "word"},
                            files={"file": (name, audio, mime or "audio/mp4")})
        d = r.json()
        return {"text": d.get("text", ""), "words": d.get("words") or []}

    async def check(self) -> None:
        """填 key 时轻探一下（不花钱）。认得这把 key、只是没开「看模型」权限的照收。"""
        try:
            await self._req("GET", "/v1/models")
        except TTSError as e:
            if e.kind != "missing_permissions":
                raise


class FakeTTS:
    """不联网：合成返回一小段假字节；记下每次调用，测试里看。"""

    def __init__(self, fail: str | None = None, slots: tuple[int, int] = (0, 30)):
        self.calls: list[tuple] = []
        self.fail, self._slots = fail, slots
        self.transcript = {"text": "今天好累", "words": [
            {"text": "今天", "type": "word", "start": 0.0, "end": 0.6}, {"text": " ", "type": "spacing", "start": 0.6, "end": 1.6},
            {"text": "好累", "type": "word", "start": 1.6, "end": 2.2},
            {"text": "(sighs)", "type": "audio_event", "start": 2.3, "end": 2.9}]}

    def _maybe_fail(self):
        if self.fail:
            raise TTSError(self.fail)

    async def synth(self, text, voice_id, model=NOTE_MODEL, previous_text=None, next_text=None) -> bytes:
        self.calls.append(("synth", text, voice_id, model, previous_text, next_text))
        self._maybe_fail()
        return b"ID3fake" + text.encode()

    async def stream_pcm(self, text, voice_id, model, previous_text=None):
        self.calls.append(("stream", text, voice_id, model, previous_text))
        self._maybe_fail()
        for i in range(0, 9600, 4800):           # 0.2 秒的安静，分两块吐
            yield bytes(4800)

    async def premade(self) -> list[dict]:
        self.calls.append(("premade",))
        return [{"voice_id": "v_demo", "name": "Demo", "labels": {}, "preview_url": ""}]

    async def voices(self) -> list[dict]:
        self.calls.append(("voices",))
        self._maybe_fail()
        return [{"voice_id": "v_mine_clone", "name": "My clone", "category": "cloned", "about": "", "preview": ""},
                {"voice_id": "v_demo_preset", "name": "Demo", "category": "premade", "about": "calm", "preview": "https://x/p.mp3"}]

    async def voice_name(self, voice_id) -> str:
        self.calls.append(("voice_name", voice_id))
        self._maybe_fail()
        return "Found Voice"

    async def models(self) -> list[tuple[str, str]]:
        self.calls.append(("models",))
        self._maybe_fail()
        return [("eleven_v4", "Eleven v4 (from API)"), ("eleven_new_x", "New X")]

    async def design(self, description, text=None) -> list[dict]:
        self.calls.append(("design", description))
        self._maybe_fail()
        return [{"generated_voice_id": f"g{i}", "audio_base_64": "", "duration_secs": 3} for i in range(3)]

    async def save_design(self, name, description, generated_voice_id) -> str:
        self.calls.append(("save_design", name, generated_voice_id))
        return f"v_{generated_voice_id}"

    async def slots(self) -> tuple[int, int]:
        return self._slots

    async def transcribe(self, audio, mime, name="voice.m4a") -> dict:
        self.calls.append(("transcribe", len(audio)))
        self._maybe_fail()
        return self.transcript

    async def check(self) -> None:
        self._maybe_fail()
