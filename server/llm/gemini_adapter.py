"""Gemini 接头。

- 缓存是自动的（开头一样就命中），这里不用挂书签；命中数在 usage_metadata.cached_content_token_count。
- 思考：thinking_config.include_thoughts=True 时，part.thought=True 的那些文字是思考摘要。
- 工具：只给函数声明、关掉 SDK 的「自动替你调函数」——工具由大脑执行。
- 接着调工具时，模型那一半（带 thought_signature）要原样还回去，所以把整段 Content 留在 raw_assistant。
"""
from __future__ import annotations

import base64

import inspect

import httpx
from google import genai
from google.genai import errors as gerrors
from google.genai import types

from .errors import LLMError, from_status
from .types import ChatRequest, Reply, ToolCall, Usage


class GeminiAdapter:
    def __init__(self, api_key: str, *, client=None):
        self.client = client or genai.Client(api_key=api_key)

    def build(self, req: ChatRequest):
        contents = [types.Content(role="user" if m.role == "user" else "model", parts=[
            *(types.Part.from_bytes(data=base64.b64decode(i.data_b64), mime_type=i.mime) for i in m.images),
            types.Part(text=m.text)]) for m in req.messages]
        for r in req.rounds:
            contents.append(r.raw_assistant)
            contents.append(types.Content(role="user", parts=[
                types.Part.from_function_response(name=c.name, response={"result": res})
                for c, res in zip(r.calls, r.results)]))
        cfg: dict = {"max_output_tokens": req.max_tokens}
        system = "\n\n".join(b.text for b in req.system)
        if system:
            cfg["system_instruction"] = system
        if req.tools:
            cfg["tools"] = [types.Tool(function_declarations=[
                types.FunctionDeclaration(name=t.name, description=t.description, parameters_json_schema=t.params)
                for t in req.tools])]
            cfg["automatic_function_calling"] = types.AutomaticFunctionCallingConfig(disable=True)
        if req.thinking:
            cfg["thinking_config"] = types.ThinkingConfig(include_thoughts=True)
        return contents, types.GenerateContentConfig(**cfg)

    async def stream(self, req: ChatRequest) -> Reply:
        contents, config = self.build(req)
        text: list[str] = []
        thinking: list[str] = []
        calls: list[ToolCall] = []
        parts: list = []
        usage = None
        finish = ""
        try:
            it = self.client.aio.models.generate_content_stream(model=req.model, contents=contents, config=config)
            if inspect.isawaitable(it):
                it = await it
            async for chunk in it:
                if chunk.usage_metadata is not None:
                    usage = chunk.usage_metadata
                for cand in chunk.candidates or []:
                    if cand.finish_reason:
                        finish = str(getattr(cand.finish_reason, "value", cand.finish_reason))
                    for p in (cand.content.parts or []) if cand.content else []:
                        parts.append(p)
                        if p.function_call is not None:
                            fc = p.function_call
                            calls.append(ToolCall(fc.id or f"call_{len(calls)}", fc.name, dict(fc.args or {})))
                        elif p.text:
                            (thinking if p.thought else text).append(p.text)
                            if req.on_text and not p.thought:
                                req.on_text(p.text)
        except gerrors.APIError as e:
            raise from_status(e.code or 0, e.message or "") from e
        except httpx.TransportError as e:
            raise LLMError("network", str(e), retryable=True) from e

        if usage is None:
            u = Usage(cache_known=False)
        else:
            cached = usage.cached_content_token_count or 0
            u = Usage(input=(usage.prompt_token_count or 0) - cached, cache_read=cached,
                      output=(usage.candidates_token_count or 0) + (usage.thoughts_token_count or 0))
        return Reply("".join(text), "".join(thinking), calls, u, finish,
                     types.Content(role="model", parts=parts))
