"""一个 TA 一段脑子（10-11 Aporia：私聊和群聊合在一起，「不然不太像一个人」）：
TA 在哪个房间说话，都把它待过的别的房间最近 N 条按真实时间插进来，前面标房间和说话人。
只按条数截、不限时间（「太久之前才显得真」）。跟 Lite 的 MeleLiteCore/Chat/RoomTimeline.swift 同一份意思。"""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime

from .archive import StoredMsg


@dataclass(frozen=True)
class Item:
    id: str
    room: str              # 排好的房间名：群「三人行」/ 私聊
    who: str | None        # 说话人名字；None = 就是这个 TA 自己说的
    text: str
    at: datetime


def group_room(name: str, zh: bool) -> str:
    return f"群「{name}」" if zh else f'group "{name}"'


def private_room(zh: bool) -> str:
    return "私聊" if zh else "DM"


ROOM_NOTE = {
    "zh": "〔房间〕你现在在{here}。历史里开头标着〔群「…」〕〔私聊〕的，是你在别的房间听到、说过的话，放进来只是让你知道那边聊过什么。"
          "这里只回这个房间里的话：别接那边的话头，回话开头也不写房间标签。",
    "en": "[Room] You're in the {here} right now. Lines in the history that start with a room tag like 〔group \"…\"〕 or 〔DM〕 "
          "are things you heard or said in other rooms — they're there so you know what was said over there. Here, only answer "
          "what's said in this room: don't pick up threads from over there, and don't start your reply with a room tag.",
}
_TAG = re.compile(r'^〔(群「[^」]*」|私聊|group "[^"]*"|DM)( · [^〕]*)?〕\s*')


def room_note(here: str, lang: str) -> str:
    """合了别的房间时放进系统提示（10-31 内测：群里的话被它接到私聊里回）"""
    return ROOM_NOTE.get(lang, ROOM_NOTE["en"]).format(here=here)


def strip_tag(text: str) -> str:
    """回话开头学着历史垫的房间标签（〔群「三人行」〕、〔私聊〕…）去掉"""
    return _TAG.sub("", text.strip(), count=1)


def merge(current: list[StoredMsg], others: list[Item], limit: int) -> list[StoredMsg]:
    """别的房间最近 limit 条按时间插进当前历史：TA 自己说的 = assistant「〔房间〕…」，别人说的 = user「〔房间 · 名字〕…」。
    同一时刻当前房间的在前；limit ≤ 0 原样返回。插进来的那几条 id = -1（不是这个窗口的消息）"""
    if limit <= 0 or not others:
        return current
    picked = sorted(others, key=lambda o: o.at)[-limit:]
    extra = [StoredMsg(-1, "assistant" if o.who is None else "user",
                       f"〔{o.room}{'' if o.who is None else ' · ' + o.who}〕{o.text}", "", o.at) for o in picked]
    out: list[StoredMsg] = []
    i = j = 0
    while i < len(current) or j < len(extra):
        if j >= len(extra) or (i < len(current) and current[i].created_at <= extra[j].created_at):
            out.append(current[i]); i += 1
        else:
            out.append(extra[j]); j += 1
    return out
