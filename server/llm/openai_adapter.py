"""OpenAI 兼容接头：OpenAI、DeepSeek，以及用户自填地址的中转 / OpenRouter / 自部署。

- 缓存是自动的：开头一样就命中，这里不用挂书签。system 几段按顺序用空行连起来，稳定的在前。
- DeepSeek：思考链在 delta.reasoning_content；开关在 extra_body={"thinking": {...}}；
  缓存命中数在 usage.prompt_cache_hit_tokens。思考模式下调工具，接着调时要把 reasoning_content 原样还回去。
- OpenAI：新模型用 max_completion_tokens；带 prompt_cache_key 让同一个人的请求落到同一台机器、多命中缓存。
- 对方没报缓存用量时标 cache_known=False：用量那边记「不知道」，不记成 0。
"""
from __future__ import annotations

import json

import openai

from .errors import LLMError, from_status
from .types import ChatRequest, Reply, ToolCall, Usage


class OpenAIAdapter:
    def __init__(self, api_key: str, base_url: str | None = None, *, flavor: str = "openai", client=None):
        self.flavor = flavor
        self.client = client or openai.AsyncOpenAI(api_key=api_key, base_url=base_url,
                                                   max_retries=0, timeout=300)

    def build(self, req: ChatRequest) -> dict:
        messages: list[dict] = []
        system = "\n\n".join(b.text for b in req.system)
        if system:
            messages.append({"role": "system", "content": system})
        messages += [{"role": m.role, "content": m.text if not m.images else [
            {"type": "text", "text": m.text},
            *({"type": "image_url", "image_url": {"url": f"data:{i.mime};base64,{i.data_b64}"}} for i in m.images)]}
            for m in req.messages]
        for r in req.rounds:
            messages.append(r.raw_assistant)
            messages += [{"role": "tool", "tool_call_id": c.id, "content": res}
                         for c, res in zip(r.calls, r.results)]
        kw: dict = {"model": req.model, "messages": messages, "stream": True,
                    "stream_options": {"include_usage": True}}
        kw["max_completion_tokens" if self.flavor == "openai" else "max_tokens"] = req.max_tokens
        if req.tools:
            kw["tools"] = [{"type": "function", "function": {
                "name": t.name, "description": t.description, "parameters": t.params}} for t in req.tools]
        if self.flavor == "deepseek":
            kw["extra_body"] = {"thinking": {"type": "enabled" if req.thinking else "disabled"}}
        elif self.flavor == "openai" and req.user_tag:
            kw["prompt_cache_key"] = req.user_tag
        return kw

    async def stream(self, req: ChatRequest) -> Reply:
        kw = self.build(req)
        text: list[str] = []
        thinking: list[str] = []
        slots: dict[int, dict] = {}
        usage = None
        finish = ""
        try:
            stream = await self.client.chat.completions.create(**kw)
            async for chunk in stream:
                if chunk.usage is not None:
                    usage = chunk.usage
                if not chunk.choices:
                    continue
                choice = chunk.choices[0]
                d = choice.delta
                if d is not None:
                    if d.content:
                        text.append(d.content)
                        if req.on_text:
                            req.on_text(d.content)
                    rc = getattr(d, "reasoning_content", None)
                    if rc:
                        thinking.append(rc)
                    for tc in d.tool_calls or []:
                        slot = slots.setdefault(tc.index, {"id": "", "name": "", "args": ""})
                        if tc.id:
                            slot["id"] = tc.id
                        if tc.function is not None:
                            slot["name"] += tc.function.name or ""
                            slot["args"] += tc.function.arguments or ""
                if choice.finish_reason:
                    finish = choice.finish_reason
        except openai.APIStatusError as e:
            raise from_status(e.status_code, str(e.message)) from e
        except openai.APIConnectionError as e:
            raise LLMError("network", str(e), retryable=True) from e

        calls: list[ToolCall] = []
        raw_calls: list[dict] = []
        for i in sorted(slots):
            s = slots[i]
            try:
                args = json.loads(s["args"] or "{}")
            except json.JSONDecodeError:
                args = {"_raw": s["args"]}
            call_id = s["id"] or f"call_{i}"
            calls.append(ToolCall(call_id, s["name"], args if isinstance(args, dict) else {"_raw": args}))
            raw_calls.append({"id": call_id, "type": "function",
                              "function": {"name": s["name"], "arguments": s["args"] or "{}"}})
        full_text = "".join(text)
        raw: dict = {"role": "assistant", "content": full_text or None}
        if raw_calls:
            raw["tool_calls"] = raw_calls
        if thinking and self.flavor == "deepseek":
            raw["reasoning_content"] = "".join(thinking)
        return Reply(full_text, "".join(thinking), calls, _usage(usage), finish, raw)


def _usage(u) -> Usage:
    if u is None:
        return Usage(cache_known=False)
    prompt = u.prompt_tokens or 0
    extra = getattr(u, "model_extra", None) or {}
    hit = extra.get("prompt_cache_hit_tokens")          # DeepSeek
    if hit is None and u.prompt_tokens_details is not None:
        hit = u.prompt_tokens_details.cached_tokens     # OpenAI
    known = hit is not None
    hit = int(hit or 0)
    return Usage(input=prompt - hit, cache_read=hit, output=u.completion_tokens or 0, cache_known=known)
