"""Anthropic 接头：Claude，也能填地址接 Anthropic 格式的中转站。

- 缓存书签（cache_control）我们亲手挂：system 里 cache=True 的段末尾、历史最后一条上。最多 4 个，我们用 3 个。
- 请求带固定的 metadata.user_id（用户 id 的哈希）：同一个人的请求尽量落在同一处，缓存才接得上。
- 书签用 1 小时档（Aporia 09-28：默认 5 分钟，TA 隔 5 分钟以上回话就整段全价重写）。1 小时档写入贵一点（2 倍，5 分钟档 1.25 倍），
  读照样 0.1 倍、读一次续一小时。不做定时保活——TA 不在的时候不替 TA 花钱。
- 某个地址对 ttl 报 400，就退回 5 分钟档；对 cache_control 报 400，就记住它、以后对它不挂。都是去掉再重发一遍。
- 思考：模型支持的才开，用 adaptive + summarized（能看到思考摘要）；思考块原样留在 raw_assistant 里，
  调工具接着调时要原样还回去。
"""
from __future__ import annotations

import anthropic

from .catalog import lookup
from .errors import LLMError, from_status
from .types import ChatRequest, Reply, ToolCall, Usage


class AnthropicAdapter:
    def __init__(self, api_key: str, base_url: str | None = None, *, client=None):
        self.client = client or anthropic.AsyncAnthropic(api_key=api_key, base_url=base_url,
                                                         max_retries=0, timeout=300)
        self.cache_ok = True
        self.ttl_ok = True

    def _text(self, text: str, cache: bool) -> dict:
        block = {"type": "text", "text": text}
        if cache and self.cache_ok:
            block["cache_control"] = {"type": "ephemeral", "ttl": "1h"} if self.ttl_ok else {"type": "ephemeral"}
        return block

    def build(self, req: ChatRequest) -> dict:
        messages = [{"role": m.role, "content": [
            *({"type": "image", "source": {"type": "base64", "media_type": i.mime, "data": i.data_b64}} for i in m.images),
            self._text(m.text, m.cache)]} for m in req.messages]
        for r in req.rounds:
            messages.append({"role": "assistant", "content": r.raw_assistant})
            messages.append({"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": c.id, "content": res}
                for c, res in zip(r.calls, r.results)]})
        kw: dict = {"model": req.model, "max_tokens": req.max_tokens,
                    "system": [self._text(b.text, b.cache) for b in req.system], "messages": messages}
        if req.tools:
            kw["tools"] = [{"name": t.name, "description": t.description, "input_schema": t.params}
                           for t in req.tools]
        if req.user_tag:
            kw["metadata"] = {"user_id": req.user_tag}
        info = lookup(req.model)
        if req.thinking and info is not None and info.thinking:
            kw["thinking"] = {"type": "adaptive", "display": "summarized"}
        return kw

    async def stream(self, req: ChatRequest) -> Reply:
        kw = self.build(req)
        try:
            async with self.client.messages.stream(**kw) as s:
                if req.on_text:                      # 电话：边写边念（10-31）
                    async for t in s.text_stream:
                        req.on_text(t)
                final = await s.get_final_message()
        except anthropic.APIStatusError as e:
            msg = str(getattr(e, "message", e))
            if e.status_code == 400 and "ttl" in msg and self.cache_ok and self.ttl_ok:
                self.ttl_ok = False
                return await self.stream(req)
            if e.status_code == 400 and "cache_control" in msg and self.cache_ok:
                self.cache_ok = False
                return await self.stream(req)
            raise from_status(e.status_code, msg) from e
        except anthropic.APIConnectionError as e:
            raise LLMError("network", str(e), retryable=True) from e

        text: list[str] = []
        thinking: list[str] = []
        calls: list[ToolCall] = []
        for b in final.content:
            if b.type == "text":
                text.append(b.text)
            elif b.type == "thinking" and b.thinking:
                thinking.append(b.thinking)
            elif b.type == "tool_use":
                calls.append(ToolCall(b.id, b.name, dict(b.input or {})))
        u = final.usage
        split = getattr(u, "cache_creation", None)          # 写入按档分开报（中转站可能不报：那就当 5 分钟档算）
        usage = Usage(input=u.input_tokens or 0, cache_read=u.cache_read_input_tokens or 0,
                      cache_write=u.cache_creation_input_tokens or 0, output=u.output_tokens or 0,
                      cache_known=u.cache_read_input_tokens is not None,
                      cache_write_1h=(getattr(split, "ephemeral_1h_input_tokens", 0) or 0) if split else 0)
        raw = [b.model_dump(exclude_none=True) for b in final.content]
        return Reply("".join(text), "\n".join(thinking), calls, usage, final.stop_reason or "", raw)

    async def keepalive(self, req: ChatRequest) -> Usage:
        """保活（09-29）：把这一轮缓存过的前缀原样再发一遍，max_tokens=0——只续缓存的命、不生成回复。
        最后一个书签之后的（易变区、TA 这句、工具来回）不发，换成一个「.」，免得按全价付那一截。不走流式（max_tokens=0 不许流式）。"""
        kw = self.build(req)
        msgs = kw["messages"]
        last = max((i for i, m in enumerate(msgs)
                    if any(isinstance(b, dict) and "cache_control" in b for b in m["content"])), default=-1)
        kw["messages"] = msgs[:last + 1] + [{"role": "user", "content": [{"type": "text", "text": "."}]}]
        kw["max_tokens"] = 0
        try:
            final = await self.client.messages.create(**kw)
        except anthropic.APIStatusError as e:
            raise from_status(e.status_code, str(getattr(e, "message", e))) from e
        except anthropic.APIConnectionError as e:
            raise LLMError("network", str(e), retryable=True) from e
        u = final.usage
        split = getattr(u, "cache_creation", None)
        return Usage(input=u.input_tokens or 0, cache_read=u.cache_read_input_tokens or 0,
                     cache_write=u.cache_creation_input_tokens or 0, output=u.output_tokens or 0,
                     cache_known=u.cache_read_input_tokens is not None,
                     cache_write_1h=(getattr(split, "ephemeral_1h_input_tokens", 0) or 0) if split else 0)
