"""模型清单。每个模型记 API 名 + 供应商报的版本名（label），价格是每百万 token 美元（DeepSeek 记的是高峰价，cost() 平峰减半；预估类照高峰价，宁可估高）。
供应商悄悄换了模型，exams/check_versions.py 会发现 label 对不上。
清单外的模型（用户自填的）也能用，只是算不出钱、用默认的「记性长度」。
价格来源（2026-09-26 查）：DeepSeek 官网 pricing 页；Claude 用 claude-api 参考表（缓存读 0.1×、5 分钟缓存写 1.25×、1 小时缓存写 2×——09-28 起 Claude 用 1 小时档）。"""
from dataclasses import dataclass

from .types import Usage


@dataclass(frozen=True)
class ModelInfo:
    id: str
    provider: str                # anthropic / deepseek / openai / gemini
    label: str                   # 供应商那边的版本名
    price_in: float
    price_cache_read: float
    price_cache_write: float
    price_out: float
    thinking: bool               # 能不能开思考（开了才有思考链）
    ledger_model: str            # 同一家便宜的，写账本用
    age_model: str               # 压旧天用（之前自用的 App 09-23：flash 碰到现成摘要常原样交回，Claude 系用 haiku）
    high_water: int              # 「记性长度」默认：上下文涨到这么多 token 就卷账本
    tools_ok: bool | None = None  # 工具考试结果；None = 还没考
    age_piece: int | None = None  # 当压旧天的模型时，长的一天先切成这么长的小块分别压（None = 整天一起压）
    drafts_in_thinking: bool = False  # 思考链里爱列计划、打草稿、排练回复（出厂思考风格多贴一句「想完就说」）
    default_thinking: str = "monologue"  # 用户没选时怎么想：monologue 手写独白 / native 原生思考（10-04 Aporia：一律默认独白——Claude / Gemini 只给第三人称摘要、GPT 不给思考、DeepSeek 原生管不住）


CATALOG: dict[str, ModelInfo] = {m.id: m for m in [
    # 2026-09-27 账本考试：flash 整天压 2415 字只能压到 1500～1800（配额 1000），v4-pro 更差还贵 3.5 倍；
    # 切成 600 字的小块各压各的，压到 1217～1379。所以 DeepSeek 用户压旧天 = flash + 切块。
    ModelInfo("deepseek-flash", "deepseek", "DeepSeek-V4.1-Flash", 0.30, 0.006, 0.30, 1.20,
              thinking=True, ledger_model="deepseek-flash", age_model="deepseek-flash", high_water=120_000,
              tools_ok=True, age_piece=600, drafts_in_thinking=True, default_thinking="monologue"),   # 2026-09-26 工具考试 5/5、账本考试过（exams/results/）
    ModelInfo("deepseek-v4-pro", "deepseek", "DeepSeek-V4-Pro", 1.32, 0.044, 1.32, 3.96,
              thinking=True, ledger_model="deepseek-flash", age_model="deepseek-flash", high_water=80_000,
              age_piece=600, drafts_in_thinking=True, default_thinking="monologue"),
    ModelInfo("claude-sonnet-5", "anthropic", "claude-sonnet-5", 2.00, 0.20, 2.50, 10.00,
              thinking=True, ledger_model="claude-haiku-4-5", age_model="claude-haiku-4-5", high_water=40_000),
    ModelInfo("claude-opus-5", "anthropic", "claude-opus-5", 5.00, 0.50, 6.25, 25.00,
              thinking=True, ledger_model="claude-haiku-4-5", age_model="claude-haiku-4-5", high_water=30_000),
    ModelInfo("claude-haiku-4-5", "anthropic", "claude-haiku-4-5", 1.00, 0.10, 1.25, 5.00,
              thinking=False, ledger_model="claude-haiku-4-5", age_model="claude-haiku-4-5", high_water=60_000,
              default_thinking="monologue"),
]}

DEFAULT_HIGH_WATER = 60_000


SEES_IMAGES = ("anthropic", "openai", "gemini")     # 这几家的聊天模型都能直接看图；DeepSeek 不算


def text_only_model(model: str | None) -> bool:
    """中转站上的 DeepSeek（11-20 内测：硅基流动 deepseek-ai/DeepSeek-V3.2）只认字，发图过去直接报错；DeepSeek 的 VL / OCR 才看得见"""
    m = (model or "").lower()
    return "deepseek" in m and not any(t in m for t in ("vl", "ocr", "janus"))


def sees_images(provider: str, base_url: str | None = None, model: str | None = None) -> bool:
    """中转站（10-26 内测「Lite 里 GPT 能看图、搬到 Host 看不了」）：跟 Lite 一样默认当它看得见，地址是 DeepSeek 的、模型是 DeepSeek 的才不算"""
    if provider == "openai-compatible":
        return "deepseek" not in (base_url or "").lower() and not text_only_model(model)
    return provider in SEES_IMAGES


def lookup(model_id: str) -> ModelInfo | None:
    return CATALOG.get(model_id)


def _clock():
    from datetime import datetime, timezone
    return datetime.now(timezone.utc)


def cost(usage: Usage, model_id: str, at=None) -> float | None:
    """这次用量折成美元；清单外的模型返回 None（算不出就说算不出，不瞎猜）。
    at = 什么时候调的（默认现在）：DeepSeek 平峰半价（10-02 起按时间算，之前一律按高峰价，试用额度平峰时多扣了一倍）。"""
    m = lookup(model_id)
    if m is None:
        return None
    one_hour = min(usage.cache_write_1h, usage.cache_write)
    usd = (usage.input * m.price_in + usage.cache_read * m.price_cache_read
           + (usage.cache_write - one_hour) * m.price_cache_write + one_hour * 2 * m.price_in   # 1 小时档写入 = 2 倍输入价
           + usage.output * m.price_out) / 1_000_000
    if m.provider == "deepseek" and deepseek_peak_until(at or _clock()) is None:
        usd /= 2
    return usd


# DeepSeek 高峰（10-01 查官网 pricing）：工作日 UTC 01:00–04:00、06:00–10:00 是原价，别的时候（含周末）半价。
# 不急的后台活（免费用户的朋友圈来刷）碰上高峰就挪到高峰结束（Aporia 10-01：还没开始一个月就要白搭几百）。中国法定假日也算平峰，这里不认，最多多等一会儿。
DEEPSEEK_PEAK_UTC = ((1, 4), (6, 10))


def deepseek_peak_until(now):
    """现在是 DeepSeek 高峰的话，返回高峰结束的时刻（UTC）；平峰返回 None。"""
    from datetime import timezone
    t = now.astimezone(timezone.utc)
    if t.weekday() >= 5:
        return None
    for lo, hi in DEEPSEEK_PEAK_UTC:
        if lo <= t.hour < hi:
            return t.replace(hour=hi, minute=0, second=0, microsecond=0)
    return None
