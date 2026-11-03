"""假模型：按剧本回话，不联网、不花钱。测试大脑用。

剧本每一项是一次调用的回复：str = 只说话；dict 可带 text / thinking / calls=[(name, args)] / usage；
LLMError 实例 = 这次调用抛这个错。每次收到的请求都深拷贝存进 .requests，测试可以检查拼得对不对。"""
import copy

from .errors import LLMError
from .types import ChatRequest, Reply, ToolCall, Usage


class FakeModel:
    def __init__(self, script):
        self.script = list(script)
        self.requests: list[ChatRequest] = []

    async def stream(self, req: ChatRequest) -> Reply:
        self.requests.append(copy.deepcopy(req))
        if not self.script:
            raise AssertionError("FakeModel 的剧本用完了")
        item = self.script.pop(0)
        if isinstance(item, LLMError):
            raise item
        if isinstance(item, str):
            item = {"text": item}
        n = len(self.requests)
        calls = [ToolCall(id=f"call_{n}_{i}", name=name, args=args)
                 for i, (name, args) in enumerate(item.get("calls", []))]
        prompt = sum(len(b.text) for b in req.system) + sum(len(m.text) for m in req.messages)
        text = item.get("text", "")
        if req.on_text and text:                     # 电话（10-31）：假装一个字一个字地推
            for ch in text:
                req.on_text(ch)
        usage = item.get("usage") or Usage(input=prompt, output=len(text))
        return Reply(text=text, thinking=item.get("thinking", ""), tool_calls=calls, usage=usage,
                     stop="tool_use" if calls else "end_turn",
                     raw_assistant={"text": text, "calls": [c.name for c in calls]})
