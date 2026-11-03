"""TA 打给你（10-31 第 4 步，Host）。设计 docs/superpowers/specs/2026-10-31-call-design.md「TA 主动打来」。

TA 用 phone_call 工具决定打 → 这里记下一通「在响」的电话，经推送中转发一条 VoIP 推送叫醒手机（锁屏也响，系统来电横幅）。
苹果规定收到 VoIP 推送必须马上报来电，所以推送里只放谁打来、通话编号（照样加密，中转看不懂）。
- 你接了：手机 POST ring/answer，再照常走 call/turn（answered=true，TA 先开口）
- 你拒绝：手机 POST ring/decline → 「📞 已拒绝」
- 60 秒没人接 → 「📞 未接来电」；TA 还没等你接就撤回 → 「📞 对方已取消」
三种都在聊天里留一行灰字（call={id, ring, line}），正文是给 TA 的纸条，它下一轮看得到。
响铃只记在内存里：Host 重启了，正在响的那通就算没了（手机那边每 3 秒问一次，问不到就收起横幅）。"""
from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from uuid import UUID

from . import archive, call_speech
from .monologue import _ZH_PRONOUN
from .settings import Settings

log = logging.getLogger(__name__)
RING_SECONDS = 60.0


@dataclass
class Ring:
    id: str
    account: UUID
    companion: UUID
    conversation: UUID
    reason: str
    at: float
    state: str = "ringing"          # ringing / answered / missed / declined / withdrawn
    timer: asyncio.Task | None = field(default=None, repr=False)


class Ringer:
    """send(url, headers, body_bytes) -> (status, reason)，跟 push.apns 的传输一个样子；测试里换假的。
    publish(conv, event)：聊天页开着的话跟着刷新。"""

    def __init__(self, pool, relay_url: str | None, publish=None, send=None, ring_seconds: float = RING_SECONDS,
                 now=None):
        self.pool = pool
        self.relay_url = relay_url
        self.publish = publish
        self.send = send
        self.ring_seconds = ring_seconds
        self.now = now
        self.rings: dict[str, Ring] = {}

    async def devices(self, acc: UUID) -> list:
        return await self.pool.fetch("SELECT relay_id, relay_secret, push_key FROM voip_devices WHERE account_id = $1 "
                                     "ORDER BY updated_at DESC", acc)

    async def can_ring(self, acc: UUID) -> bool:
        """给不给 TA 打电话的工具：这个账号有手机登记过来电（新版 App + 推送中转开着）"""
        return bool(self.relay_url) and bool(await self.devices(acc))

    def ringing_in(self, conv: UUID) -> Ring | None:
        return next((r for r in self.rings.values() if r.conversation == conv and r.state == "ringing"), None)

    async def place(self, acc: UUID, comp: UUID, conv: UUID, reason: str, name: str) -> str:
        """打出去：ringing / busy（这个账号已经有一通在响）/ no_device / failed（推送没送出去）"""
        if any(r.account == acc and r.state == "ringing" for r in self.rings.values()):
            return "busy"
        devs = await self.devices(acc) if self.relay_url else []
        if not devs:
            return "no_device"
        ring = Ring(uuid.uuid4().hex, acc, comp, conv, reason.strip()[:200], time.monotonic())
        payload = {"call": ring.id, "conversation": str(conv), "companion": str(comp), "name": name, "reason": ring.reason}
        sent = False
        seen: set[str] = set()
        for d in devs:
            if d["push_key"] in seen:            # 同一部手机只推最新登记的那个
                continue
            seen.add(d["push_key"])
            sent = await self._push(d, payload) or sent
        if not sent:
            return "failed"
        self.rings[ring.id] = ring
        ring.timer = asyncio.create_task(self._timeout(ring))
        return "ringing"

    async def _push(self, d, payload: dict) -> bool:
        from push.apns import httpx_transport, seal
        send = self.send or httpx_transport()
        self.send = send
        url = f"{self.relay_url.rstrip('/')}/push"
        h = {"authorization": f"Bearer {d['relay_secret']}", "content-type": "application/json"}
        body = json.dumps({"relay_id": d["relay_id"], "sealed": seal(d["push_key"], payload), "voip": True}).encode()
        try:
            status, reason = await send(url, h, body)
        except Exception as e:                   # noqa: BLE001
            log.warning("voip push failed: %s", e)
            return False
        if status == 410:
            await self.pool.execute("DELETE FROM voip_devices WHERE relay_id = $1", d["relay_id"])
        if status != 200:
            log.warning("voip push %s %s", status, reason)
        return status == 200

    async def _timeout(self, ring: Ring) -> None:
        await asyncio.sleep(self.ring_seconds)
        if ring.state == "ringing":
            await self._end(ring, "missed")

    async def answer(self, call_id: str) -> bool:
        ring = self.rings.get(call_id)
        if ring is None or ring.state != "ringing":
            return False
        ring.state = "answered"
        if ring.timer is not None:
            ring.timer.cancel()
        asyncio.get_running_loop().call_later(120, lambda: self.rings.pop(ring.id, None))
        return True

    async def decline(self, call_id: str) -> bool:
        ring = self.rings.get(call_id)
        if ring is None or ring.state != "ringing":
            return False
        await self._end(ring, "declined")
        return True

    async def withdraw(self, conv: UUID) -> bool:
        ring = self.ringing_in(conv)
        if ring is None:
            return False
        await self._end(ring, "withdrawn")
        return True

    async def _end(self, ring: Ring, kind: str) -> None:
        ring.state = kind
        if ring.timer is not None and ring.timer is not asyncio.current_task():
            ring.timer.cancel()
        settings = Settings.from_dict(await archive.get_settings(self.pool, ring.companion))
        lang = settings.lang
        pronoun = _ZH_PRONOUN.get(settings.user_pronoun, "TA") if lang == "zh" else settings.user_pronoun
        now: datetime | None = self.now() if self.now else None
        await archive.add_message(self.pool, ring.conversation, "user", call_speech.ring_note(kind, lang, pronoun), now=now,
                                  call={"id": ring.id, "ring": kind, "line": call_speech.ring_line(kind, lang)})
        if self.publish is not None:
            await self.publish(ring.conversation, {"type": "done"})
        # 留一会儿给手机来问（它每 3 秒问一次，问到结束了才收起横幅），过后清掉
        asyncio.get_running_loop().call_later(120, lambda: self.rings.pop(ring.id, None))
