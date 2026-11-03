"""模型路由对外的统一样子。大脑只认这些，不认任何一家的格式。"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Callable, Literal


@dataclass(frozen=True)
class Block:
    """system 里的一段。cache=True：缓存书签挂在这一段末尾（从头到这里都算稳定）。"""
    text: str
    cache: bool = False


@dataclass(frozen=True)
class ImagePart:
    """一张图（base64）。只在发图那一轮跟着 TA 那句走；历史里用描述代替（iOS 第一块，09-27）。"""
    mime: str
    data_b64: str


@dataclass(frozen=True)
class Msg:
    role: Literal["user", "assistant"]
    text: str
    cache: bool = False          # 滚动书签挂在这条上
    images: tuple[ImagePart, ...] = ()


@dataclass(frozen=True)
class ToolSpec:
    name: str
    description: str
    params: dict                 # JSON Schema


@dataclass(frozen=True)
class ToolCall:
    id: str
    name: str
    args: dict


@dataclass
class ToolRound:
    """一轮里调工具的一个来回：模型那一半原样留着（接着调时要原样还回去，里面可能有思考签名），
    加上我们执行完的结果（跟 calls 一一对应）。"""
    raw_assistant: Any
    calls: list[ToolCall]
    results: list[str]


@dataclass
class Usage:
    input: int = 0               # 没走缓存、按全价算的输入
    cache_read: int = 0          # 从缓存读的输入（便宜）
    cache_write: int = 0         # 写进缓存的输入（Claude 要多收一点）
    output: int = 0
    cache_known: bool = True     # False = 对方没报缓存用量，这一轮的缓存数不作数
    cache_write_1h: int = 0      # cache_write 里按 1 小时档写的那部分（Claude 收 2 倍，5 分钟档 1.25 倍）

    @property
    def prompt_total(self) -> int:
        """这次请求整个上下文有多大——判断要不要卷账本就看它。"""
        return self.input + self.cache_read + self.cache_write

    def __add__(self, other: "Usage") -> "Usage":
        return Usage(self.input + other.input, self.cache_read + other.cache_read,
                     self.cache_write + other.cache_write, self.output + other.output,
                     self.cache_known and other.cache_known, self.cache_write_1h + other.cache_write_1h)


@dataclass
class ChatRequest:
    model: str
    system: list[Block]
    messages: list[Msg]
    tools: list[ToolSpec] = field(default_factory=list)
    rounds: list[ToolRound] = field(default_factory=list)   # 这一轮已经发生的工具来回
    max_tokens: int = 8000
    thinking: bool = False
    user_tag: str = ""           # 固定的用户标记（哈希）：同一个人的请求尽量落在同一处
    # 电话（10-31）：正文每来一小段就递一下（边写边念）；平时是 None。抛出的异常会一路传出去（她开口打断时用）
    on_text: Callable[[str], None] | None = field(default=None, compare=False, repr=False)

    def estimated_prompt(self) -> int:
        """对方没报用量时（有的兼容中转不回 usage）按字数估这次上下文多大，好让账本照样到点就卷（10-13 内测）。"""
        parts = [b.text for b in self.system] + [m.text for m in self.messages]
        parts += [t.name + t.description + str(t.params) for t in self.tools]
        parts += [r for rd in self.rounds for r in rd.results]
        return sum(estimate_tokens(p) for p in parts)


def estimate_tokens(text: str) -> int:
    """粗估 token：中日韩一个字算一个，别的大约 3 个字符一个（宁可估高一点，别估低到永远卷不动）。"""
    wide = sum(1 for ch in text if ord(ch) >= 0x2E80)
    return wide + (len(text) - wide + 2) // 3


@dataclass
class Reply:
    text: str
    thinking: str
    tool_calls: list[ToolCall]
    usage: Usage
    stop: str                    # 各家原样的停下原因——只记日志，不拿来做判断
    raw_assistant: Any = None    # 接着调工具时原样还回去
