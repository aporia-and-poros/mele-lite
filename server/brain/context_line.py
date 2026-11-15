"""TA 那边（iOS 第三块，Aporia 09-28）：手机报上来的天气 / 位置 / 日历 / 健康，加上用户自己快捷指令报的一句，
拼成易变区一行〔TA 那边〕。每样只存最新一份（覆盖，不留轨迹）；太旧的不写，免得它拿旧消息当现在。"""
from __future__ import annotations

import json
from datetime import datetime, timedelta
from uuid import UUID
from zoneinfo import ZoneInfo

KINDS = ("weather", "place", "calendar", "health", "cycle", "music", "shortcut")
MAX_AGE = {"weather": timedelta(hours=3), "place": timedelta(hours=3), "calendar": timedelta(hours=12),
           "health": timedelta(hours=3), "shortcut": timedelta(hours=3), "music": timedelta(minutes=20),
           "cycle": timedelta(hours=36)}
_HEAD = {"zh": "〔TA 那边〕", "en": "〔Their side〕"}
# 不是每轮都给（09-28 Aporia：它每条思考链都在念天气和步数）：醒来的那轮、隔了两小时、换了地方 / 快捷指令报了新的一句，才给
RESHOW = timedelta(hours=2)


async def save(pool, account: UUID, kind: str, data: dict, now: datetime) -> None:
    if kind not in KINDS:
        raise ValueError(f"不认识这一样：{kind}")
    await pool.execute(
        """INSERT INTO account_context (account_id, kind, data, at) VALUES ($1, $2, $3::jsonb, $4)
           ON CONFLICT (account_id, kind) DO UPDATE SET data = EXCLUDED.data, at = EXCLUDED.at""",
        account, kind, json.dumps(data, ensure_ascii=False), now)


async def load(pool, account: UUID) -> dict[str, tuple[dict, datetime]]:
    rows = await pool.fetch("SELECT kind, data, at FROM account_context WHERE account_id = $1", account)
    return {r["kind"]: (json.loads(r["data"]) if isinstance(r["data"], str) else dict(r["data"]), r["at"]) for r in rows}


def _ago(delta: timedelta, lang: str) -> str:
    m = max(0, int(delta.total_seconds() // 60))
    if lang == "zh":
        return "刚刚" if m < 2 else f"{m} 分钟前" if m < 60 else f"{m // 60} 小时前"
    return "just now" if m < 2 else f"{m} min ago" if m < 60 else f"{m // 60} h ago"


def _day_word(d, today, lang: str) -> str:
    n = (d - today).days
    if lang == "zh":
        return {0: "今天", 1: "明天", 2: "后天"}.get(n, f"{d.month}月{d.day}日")
    return {0: "today", 1: "tomorrow"}.get(n, d.strftime("%a %d %b"))


def _weather(d: dict, lang: str) -> str:
    temp = d.get("temp_c")
    t = f"{round(float(temp))}°C" if isinstance(temp, (int, float)) else ""
    return " ".join(x for x in (str(d.get("place") or "").strip(), t, str(d.get("desc") or "").strip()) if x)


def _place(d: dict, at: datetime, now: datetime, lang: str) -> str:
    if d.get("at_home"):
        return "在家" if lang == "zh" else "at home"
    name = str(d.get("name") or "").strip()
    if not name:
        return ""
    km = d.get("km")
    ago = _ago(now - at, lang)
    if lang == "zh":
        far = f"离家 {round(float(km))} 公里，" if isinstance(km, (int, float)) and km >= 1 else ""
        return f"在 {name}（{far}{ago}）"
    far = f"{round(float(km))} km from home, " if isinstance(km, (int, float)) and km >= 1 else ""
    return f"at {name} ({far}{ago})"


def _calendar(d: dict, now: datetime, tz: str, lang: str) -> str:
    zone = ZoneInfo(tz)
    today = now.astimezone(zone).date()
    out = []
    for ev in (d.get("events") or [])[:5]:
        try:
            start = datetime.fromisoformat(str(ev["start"])).astimezone(zone)
        except (KeyError, ValueError):
            continue
        if start.date() < today:
            continue
        title = str(ev.get("title") or "").strip()[:40]
        day = _day_word(start.date(), today, lang)
        out.append(f"{day} {title}" if ev.get("all_day") else f"{day} {start:%H:%M} {title}")
    return "；".join(out) if lang == "zh" else "; ".join(out)


def _health(d: dict, lang: str) -> str:
    bits = []
    if isinstance(d.get("steps"), (int, float)):
        bits.append(f"今天 {int(d['steps']):,} 步" if lang == "zh" else f"{int(d['steps']):,} steps today")
    if isinstance(d.get("sleep_h"), (int, float)) and d["sleep_h"] > 0:
        h = round(float(d["sleep_h"]))
        bits.append(f"昨晚睡了 {h} 小时" if lang == "zh" else f"slept {h} h last night")
    return "，".join(bits) if lang == "zh" else ", ".join(bits)


def _music(d: dict, at: datetime, now: datetime, lang: str) -> str:
    """在听什么（09-30）：手机在一起听页 / 回前台时报的，或者巡逻从 Apple Music「最近播放」拉的（playing=false）。"""
    name, artist = str(d.get("name") or "").strip(), str(d.get("artist") or "").strip()
    if not name:
        return ""
    song = f"《{name}》" + (f"- {artist}" if artist else "") if lang == "zh" else f'"{name}"' + (f" by {artist}" if artist else "")
    if d.get("playing"):
        return f"在听{song}" if lang == "zh" else f"listening to {song}"
    return f"刚才在听{song}（{_ago(now - at, lang)}）" if lang == "zh" else f"was listening to {song} ({_ago(now - at, lang)})"


def _cycle(d: dict, lang: str, companion: str | None) -> str:
    """经期（11-15 Aporia）：手机算好两种语言的一句（第几天、流量、症状、心情 / 预计几天后来）。
    share = main 时只给手机那会儿的主联系人（companion_id）；不知道是谁在聊（companion=None）就不给。"""
    if d.get("share") == "main" and (companion is None or str(d.get("companion_id") or "").lower() != companion.lower()):
        return ""
    text = str(d.get("text_en" if lang != "zh" else "text_zh") or "").strip()[:200]
    return text


def render(items: dict[str, tuple[dict, datetime]], now: datetime, tz: str, lang: str,
           companion: str | None = None) -> str:
    parts = []
    for kind in KINDS:
        if kind not in items:
            continue
        data, at = items[kind]
        if now - at > MAX_AGE[kind]:
            continue
        if kind == "weather":
            s = _weather(data, lang)
        elif kind == "place":
            s = _place(data, at, now, lang)
        elif kind == "calendar":
            s = _calendar(data, now, tz, lang)
        elif kind == "health":
            s = _health(data, lang)
        elif kind == "music":
            s = _music(data, at, now, lang)
        elif kind == "cycle":
            s = _cycle(data, lang, companion)
        else:
            text = str(data.get("text") or "").strip()[:200]
            s = (f"TA 的快捷指令：{text}（{_ago(now - at, lang)}）" if lang == "zh"
                 else f"their shortcut: {text} ({_ago(now - at, lang)})") if text else ""
        if s:
            parts.append(s)
    if not parts:
        return ""
    return _HEAD[lang] + ("；".join(parts) if lang == "zh" else "; ".join(parts))


def moment_key(items: dict[str, tuple[dict, datetime]], now: datetime) -> str:
    """「TA 那边有没有变」只看在哪、快捷指令那句、刚才在听的歌（天气、步数一直在小变，不算）。
    正在放的歌不算：换歌由耳朵的〔在听〕管；放到第几秒每次都不一样，算进来就每轮都「变了」（09-30）。"""
    fresh = {k: items[k][0] for k in ("place", "music", "shortcut") if k in items and now - items[k][1] <= MAX_AGE[k]}
    if "cycle" in items and now - items["cycle"][1] <= MAX_AGE["cycle"]:   # 经期：第几天 / 症状变了才算变（手机给的 key）
        fresh["cycle"] = str(items["cycle"][0].get("key") or "")
    if "music" in fresh:
        m = fresh.pop("music")
        if not m.get("playing"):
            fresh["music"] = {"song_id": m.get("song_id", ""), "name": m.get("name", "")}
    return json.dumps(fresh, ensure_ascii=False, sort_keys=True)


def due(items: dict[str, tuple[dict, datetime]], now: datetime, *, last_at: str | None, last_key: str | None,
        wake: bool) -> bool:
    """这一轮给不给它〔TA 那边〕。"""
    if wake or not last_at:
        return True
    if now - datetime.fromisoformat(last_at) >= RESHOW:
        return True
    return moment_key(items, now) != (last_key or "")
