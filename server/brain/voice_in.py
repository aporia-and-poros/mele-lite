"""TA 发语音条（10-03，声音第二块；设计 docs/specs/2026-10-03-voice-input-design.md）。

- 录音存成附件（kind = voice），交给 ElevenLabs Scribe v2：转文字 + 标声音事件（笑、叹气）+ 每个词的起止时间。
- 用词的时间量三样：语速、停顿几次、最长停多久。只写听到的事实，不替 TA 下「你很难过」的结论。
- 跟 TA 自己比（Aporia 10-03：不跟个人比会不准）：最近 20 条的中位数当基线，攒够 5 条才说「比你平时」；
  之前跟一般人比（说话人归一化是通用做法）。
- 钱：扣声音额度，1 秒 = 1 字；自带 ElevenLabs key 不扣。转写失败照常发（正文写没转出来），录音留着。"""
from __future__ import annotations

import hashlib
import json
import re
import statistics
import uuid
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

from llm.tts import MM_STT_MODEL, STT_MODEL, TTSError

from . import attachments as files
from . import voice as V

MAX_SECONDS = 120
MAX_BYTES = 8 * 1024 * 1024
STT_PER_HOUR = 0.22               # Scribe v2 官网价（10-03）
PAUSE_GAP = 0.7                   # 词和词之间空这么久算停顿（秒）
KEEP = 20                         # 基线留最近几条
TRUST = 5                         # 攒够几条才跟 TA 自己比
EVENTS = {"zh": {"laugh": "笑了一下", "chuckle": "轻笑了一下", "giggle": "咯咯笑了", "sigh": "叹了口气",
                 "cry": "带着哭腔", "sob": "抽泣", "sniff": "吸了吸鼻子", "cough": "咳了一声", "yawn": "打了个哈欠",
                 "breath": "深吸了一口气"},
          "en": {"laugh": "laughed", "chuckle": "chuckled", "giggle": "giggled", "sigh": "sighed", "cry": "sounded tearful",
                 "sob": "sobbed", "sniff": "sniffed", "cough": "coughed", "yawn": "yawned", "breath": "took a deep breath"}}


@dataclass
class Measure:
    seconds: float
    units: float                  # 说了多少（中文按字，英文按词 × 2 折算成字）
    rate: float                   # 每秒几「字」
    pauses: int
    longest: float
    events: list[str]

    @property
    def pause_per_min(self) -> float:
        return self.pauses / max(self.seconds / 60, 0.25)


def _units(text: str) -> float:
    cjk = len(re.findall(r"[一-鿿]", text))
    words = len(re.findall(r"[A-Za-z']+", text))
    return cjk + words * 2


def measure(words: list[dict], seconds_hint: float = 0) -> Measure:
    spoken = [w for w in words if w.get("type") == "word"]
    events = [w.get("text", "") for w in words if w.get("type") == "audio_event"]
    if spoken:
        start, end = float(spoken[0].get("start", 0)), float(spoken[-1].get("end", 0))
        talk = max(end - start, 0.3)
    else:
        talk = max(seconds_hint, 0.3)
    gaps = [float(b.get("start", 0)) - float(a.get("end", 0)) for a, b in zip(spoken, spoken[1:])]
    pauses = [g for g in gaps if g >= PAUSE_GAP]
    units = _units("".join(w.get("text", "") + " " for w in spoken))
    total = max(seconds_hint, float(words[-1].get("end", 0)) if words else 0, talk)
    return Measure(round(total, 1), units, units / talk if units else 0, len(pauses), round(max(pauses, default=0), 1),
                   events)


def _event_words(events: list[str], lang: str) -> list[str]:
    """认得的人声（笑、叹气……）照写；别的（提示音、敲门声）是背景，写成「背景里有……」，别让它以为是 TA 发出来的。"""
    out, background = [], []
    for e in events:
        key = re.sub(r"[^a-z]", "", e.lower())
        hit = next((v for k, v in EVENTS[lang].items() if key.startswith(k)), None)
        if hit:
            out.append(hit)
        elif e.strip("()[] "):
            background.append(e.strip("()[] "))
    if background:
        out.append(("背景里有" if lang == "zh" else "background: ") + ("、" if lang == "zh" else ", ").join(dict.fromkeys(background)))
    return list(dict.fromkeys(out))


def describe(m: Measure, samples: list[dict], lang: str) -> str:
    zh = lang == "zh"
    bits: list[str] = []
    mine = len(samples) >= TRUST
    if m.units >= 4 and m.rate:
        if mine:
            base = statistics.median(s["rate"] for s in samples)
            r = m.rate / base if base else 1
            if r <= 0.8:
                bits.append("说得比你平时慢不少" if zh else "much slower than you usually talk")
            elif r <= 0.9:
                bits.append("比平时慢一点" if zh else "a bit slower than usual")
            elif r >= 1.25:
                bits.append("说得比你平时快不少" if zh else "much faster than you usually talk")
            elif r >= 1.1:
                bits.append("比平时快一点" if zh else "a bit faster than usual")
        elif m.rate < 3:
            bits.append("说得偏慢" if zh else "on the slow side")
        elif m.rate > 6:
            bits.append("说得偏快" if zh else "on the fast side")
    if m.pauses:
        many = (mine and m.pause_per_min >= 1.5 * max(statistics.median(s["pause_per_min"] for s in samples), 1)) \
            or (not mine and m.pauses >= 3)
        if many:
            bits.append((f"中间停了 {m.pauses} 次（最长 {m.longest:g} 秒）" + ("，比平时多" if mine else "")) if zh
                        else f"paused {m.pauses} times (longest {m.longest:g}s)" + (", more than usual" if mine else ""))
    bits += _event_words(m.events, lang)
    secs = max(1, round(m.seconds))
    head = f"语音 {secs} 秒" if zh else f"voice message, {secs}s"
    return f"〔{head}：{'，'.join(bits)}〕" if zh and bits else (f"〔{head}: {', '.join(bits)}〕" if bits else f"〔{head}〕")


async def _samples(pool, account: UUID) -> list[dict]:
    raw = await pool.fetchval("SELECT samples FROM voice_baseline WHERE account_id = $1", account)
    return json.loads(raw) if isinstance(raw, str) else (raw or [])


async def _remember(pool, account: UUID, m: Measure) -> None:
    if m.units < 4:
        return
    s = (await _samples(pool, account) + [{"rate": round(m.rate, 3), "pause_per_min": round(m.pause_per_min, 3)}])[-KEEP:]
    await pool.execute("""INSERT INTO voice_baseline (account_id, samples) VALUES ($1, $2::jsonb)
                          ON CONFLICT (account_id) DO UPDATE SET samples = $2::jsonb""", account, json.dumps(s))


async def receive(deps, account: UUID, conversation: UUID, audio: bytes, mime: str, seconds_hint: float,
                  lang: str, provider: str = "elevenlabs") -> tuple[files.Attachment, str]:
    """存录音、转文字、量语气。返回 (附件, 正文)。额度不够 / 没钥匙 → VoiceError。
    转文字先用这个 TA 那家的 key（11-08 MiniMax 也能转），没有就用另一家的。"""
    if not audio:
        raise V.VoiceError("bad_request")
    if len(audio) > MAX_BYTES or seconds_hint > MAX_SECONDS + 5:
        raise V.VoiceError("too_long")
    pool = deps.pool
    tts, own, used = await V.listen_engine(deps, account, provider)
    charge = max(1, round(seconds_hint))
    if not own and await V.quota(pool, account) < charge:
        raise V.VoiceError("quota")
    folder = (deps.files_dir or Path(".local/files"))
    folder.mkdir(parents=True, exist_ok=True)
    aid = uuid.uuid4()
    path = folder / f"{aid}.m4a"
    path.write_bytes(audio)
    try:
        got = await tts.transcribe(audio, mime)
        text = (got.get("text") or "").strip()
        text = re.sub(r"\s*[(\[][^)\]]{1,30}[)\]]\s*", " ", text).strip()     # 正文里去掉 (laughter) 这类标注
        m = measure(got.get("words") or [], seconds_hint)
        note = describe(m, await _samples(pool, account), lang)
        await _remember(pool, account, m)
    except TTSError:
        text = ""
        m = Measure(seconds_hint, 0, 0, 0, 0, [])
        note = describe(m, [], lang)
    if not text:
        text = "（语音没转出文字）" if lang == "zh" else "(couldn't transcribe the voice message)"
    secs = max(1, round(m.seconds or seconds_hint))
    async with pool.acquire() as con, con.transaction():
        if not own:
            await con.execute("UPDATE voice_quota SET chars_left = GREATEST(chars_left - $2, 0) WHERE account_id = $1",
                              account, secs)
        await con.execute("INSERT INTO voice_usage (account_id, purpose, model, chars, cost_usd, own_key) "
                          "VALUES ($1, 'listen', $2, $3, $4, $5)", account, MM_STT_MODEL if used == "minimax" else STT_MODEL, secs, secs / 3600 * STT_PER_HOUR, own)
        r = await con.fetchrow(
            f"""INSERT INTO attachments (id, account_id, conversation_id, kind, name, mime, size, path, text, caption, sha)
                VALUES ($1, $2, $3, 'voice', $10, $4, $5, $6, $7, $8, $9) RETURNING {files._COLS}""",
            aid, account, conversation, mime or "audio/mp4", len(audio), str(path), text, note,
            hashlib.sha256(audio).hexdigest(), f"voice-{secs}s.m4a")
    return files._row(r), text
