"""用户设置。存成 JSON；读的时候认不得的键丢掉、缺的补默认、非法的值报错。

以后 app 的设置页分两层（设计文档「记给以后几块的」）：
外层 = 名字、性格、联想强弱、记性长度；里层「高级」= 细读、注入、哨兵、最多几条。"""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field, fields
from datetime import time
from zoneinfo import ZoneInfo

SENTINELS = ("thinking_style", "tool_reminder", "remembered")
# 出厂关着的哨兵。remembered（〔记住了〕）09-27 Aporia定关掉：DeepSeek 本来就勤用工具，这条反倒让它
# 自我怀疑「我到底记没记」；留着开关，碰上嘴上说记住却不调工具的模型，用户可以自己打开。
SENTINELS_OFF: tuple[str, ...] = ()        # 09-27 下午又打开了：它看得见自己用过的工具以后，这条不会再让它乱怀疑
INJECTION_MODES = ("every", "every_n", "chance", "keywords")
RECALL_LEVELS = ("off", "light", "medium", "rich")
TONE_LEVELS = ("low", "mid", "high")
PRONOUNS = ("she", "he", "they")
PATROL_LEVELS = ("low", "mid", "high", "max")      # 「多久来找你」四档（巡逻，09-27 Aporia定；数字在 patrol/clocks.py）
DIARY_CHARS = (300, 1500)                           # 日记长短滑块的范围（中文字；英文按 2/3 折成词）
PATROL_OVERRIDES = {                                # 高级设置里能单独改的数字：键 → (最小, 最大)
    "day_gap_min": (10, 1440),                      # 白天间隔（分钟）
    "night_awake_max": (0, 20),                     # 深夜 TA 醒着，一晚最多找几次
    "asleep_gap_min": (0, 1440),                    # TA 睡着时间隔（分钟）；0 = 不叫醒；不是 0 就至少 15
    "daily_cap": (1, 100),                          # 一天最多醒几次（防 bug 白扣钱）
}


# 「高级」里的项：「同步到全部联系人」只抄这些（09-28 Aporia要的一键同步），不碰名字、性格、关系、钥匙这些外层的
ADVANCED_KEYS = ("careful_read", "recall_probe", "reply_wait", "max_bubbles", "thinking", "thinking_mode",
                 "thinking_style_text", "monologue_examples", "ledger_same_as_chat", "sentinels", "injections", "patrol_overrides",
                 "heartbeat_on", "tool_reminder_every", "thinking_style_every", "inner_voice", "inner_voice_style",
                 "monologue_retry")


def parse_hm(s: str):
    """「HH:MM」→ datetime.time；不对就 ValueError。"""
    try:
        h, m = str(s).split(":")
        return time(int(h), int(m))
    except (ValueError, TypeError) as e:
        raise ValueError(f"time must be HH:MM, got {s!r}") from e


@dataclass
class Injection:
    """用户自己写的一段「每轮悄悄塞给它的话」。"""
    id: str
    name: str
    text: str
    enabled: bool = True
    mode: str = "every"          # every 每轮 / every_n 每 N 轮 / chance 按概率 / keywords 话里有这些词才出现
    n: int = 3
    chance: float = 0.3
    keywords: list[str] = field(default_factory=list)


@dataclass
class Settings:
    lang: str = "zh"
    tz: str = "UTC"
    user_name: str = ""                    # 用户自己的名字；账本里写对方就用它（空 = 中文「TA」、英文 they）
    user_pronoun: str = "they"             # 怎么指代用户：she / he / they（出厂思考风格里用）
    warmth: str = "mid"                    # 三个滑块：温暖 / 主动 / 幽默，各 low / mid / high（09-27 Aporia定）
    initiative: str = "mid"
    humor: str = "mid"
    recall_level: str = "medium"           # 联想强弱
    careful_read: bool = True              # 细读：灰区交给大模型判读器（09-28 Aporia提议，评测 medium 对13/错0/漏3；本地精排修好后净亏）
    recall_probe: bool = True              # 召回哨兵：先让便宜模型听懂这句再去搜（09-28，每句约 0.0003 美元）
    memory_length: int | None = None       # 记性长度（token）；None = 用模型的默认值
    reply_wait: int = 10                   # 等 TA 说完再回（秒）：连着发几条，安静满这么久才打包成一轮；0 = 马上回（照之前自用的 App，十秒是Poros定的）
    max_bubbles: int | None = 6            # 每次最多几条；None = 不限
    long_mode: bool = False                # 长文模式
    thinking: bool = True                  # 想不想事（关了就没有思考链）
    thinking_mode: str | None = None       # 怎么想：native 原生思考 / monologue 手写独白；None = 看模型（DeepSeek 独白、Claude 原生）
    monologue_retry: bool = False          # 手写独白没打 [独白] 标记就重写一次（10-26 Aporia：多花一次钱，默认关）
    ledger_same_as_chat: bool = False      # 账本用聊天那个模型写（默认用同一家便宜的）
    sentinels: dict[str, bool] = field(default_factory=lambda: {k: k not in SENTINELS_OFF for k in SENTINELS})
    tool_reminder_every: int = 5
    thinking_style_text: str = ""          # 自己改写的思考风格；空 = 用出厂的
    monologue_examples: str = ""           # 自己写的独白范文（11-03 Aporia）；空 = 用出厂那两段，本体化时也照放
    thinking_style_every: int = 3          # 思考风格隔几轮在尾巴贴一次全文（10-11 Aporia：滑块 1…12，默认 3；两种模式都按它）
    inner_voice: bool = False              # 回复后的心声（10-11）：说完以后最后写 [心声]…[/心声]，App 画成小卡片
    inner_voice_style: str = ""            # 自己写的心声写法；空 = 出厂
    injections: list[Injection] = field(default_factory=list)
    patrol_level: str = "mid"              # 「多久来找你」：low / mid / high / max
    heartbeat_on: bool = True              # 心跳（它自己醒来想想要不要找你），默认开
    morning_on: bool = True                # 起床前醒来准备（10-01 Aporia：单独一个开关，跟心跳分开），默认开；只看主联系人的
    sleep_from: str = "00:00"              # TA 一般几点睡、几点起（注册时问）；这一段算深夜
    sleep_to: str = "08:00"
    patrol_overrides: dict[str, int] = field(default_factory=dict)   # 高级设置里单独改的数字，空 = 跟档位
    relationship: str = ""              # 你们是什么关系（09-28）：friend / partner / family / buddy，或用户自己写的；空 = 没说
    cache_keepalive: bool = False       # 缓存保活（09-29，只对 Claude）：隔很久才聊也不怕缓存过期，TA 睡觉时停
    diary_on: bool = True               # 日记开关（10-01 Aporia：付费用户可以关）；只看主联系人的
    diary_also: bool = False            # 别的联系人也写日记（10-27，Host 照 Lite 本机 10-12）；只看非主联系人的，默认关
    diary_chars: int = 600              # 日记最多写多少字（10-01 Aporia）：自己 key / 会员的滑块；免费固定 300（brain/diary_write.FREE_CHARS）
    voice_mode: str = "sometimes"       # 语音条（10-03）：off 不发 / sometimes 偶尔 / often 常常
    voice_id: str = ""                  # 它的嗓子（ElevenLabs voice_id）；空 = 用出厂那把（brain/voice.PRESETS 第一把）
    voice_name: str = ""                # 嗓子的名字（设置页显示）
    voice_model: str = ""               # 语音条 / 念给我听 / 电话「有表情」用哪个 ElevenLabs 模型（11-07）；空 = 默认（llm/tts.NOTE_MODEL）
    voice_provider: str = "elevenlabs"  # 声音用哪家（11-08）：elevenlabs / minimax。两家的嗓子和模型各存各的，换回来还是原来那把
    mm_voice_id: str = ""               # MiniMax 的嗓子；空 = 出厂那把（brain/voice.MM_PRESETS，按 TA 的语言）
    mm_voice_name: str = ""
    mm_voice_model: str = ""            # MiniMax 的模型；空 = 默认（llm/tts.MM_NOTE_MODEL）
    mcp_servers: list[str] = field(default_factory=list)   # 这个 TA 能用的 MCP 服务（10-05，Host；brain/mcp.py）
    talk_rules: str = ""                # 说话规矩（10-05）：用户写了就换掉说明书里出厂的两条（一两句就够 / 直接说）；空 = 出厂
    offline_life: bool = False          # 线下生活（10-05）：关着 = 说明书里没有「你有自己的一天」、没有地图 / 它的一天
    scene_place: int | None = None      # 从地图上找过去的那场线下在哪（world_places.id）；回线上清掉（11-11，brain/world.py）
    other_rooms_count: int = 30         # 一段脑子（10-11 群聊）：别的房间（群 / 私聊）最近几条按时间穿插进来；0 = 不合
    bilingual: bool = False             # 双语气泡（10-15）：TA 的泡原文在上、译文在下（brain/bilingual.py）
    bilingual_lang: str = "English"     # TA 说什么话
    bilingual_to: str = ""              # 译成什么；空 = App 语言
    bilingual_by: str = "key"           # 译文谁写：key = 钥匙串「翻译」那把（便宜）；self = TA 每泡自己写〔译〕
    call_voice: str = "fast"            # 电话里的声音（10-31）：fast 低延迟那档 / expressive 跟语音条一样 / system 手机自带（Host 不合成）
    bare_mode: bool = False             # 本体化（11-03）：不加 Mele 的口气——不写独白 / 心声、不贴思考风格和人设锚、出厂性格不放，思考用模型自己的

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict | None) -> "Settings":
        known = {f.name for f in fields(cls)}
        data = {k: v for k, v in (d or {}).items() if k in known}
        inj_known = {f.name for f in fields(Injection)}
        data["injections"] = [Injection(**{k: v for k, v in i.items() if k in inj_known})
                              for i in data.get("injections") or []]
        sentinels = {k: k not in SENTINELS_OFF for k in SENTINELS}
        sentinels.update({k: bool(v) for k, v in (data.get("sentinels") or {}).items() if k in SENTINELS})
        data["sentinels"] = sentinels
        s = cls(**data)
        s._validate()
        return s

    def _validate(self) -> None:
        if self.lang not in ("zh", "en"):
            raise ValueError(f"lang must be zh or en, got {self.lang!r}")
        if self.recall_level not in RECALL_LEVELS:
            raise ValueError(f"recall_level must be one of {RECALL_LEVELS}")
        if self.max_bubbles is not None and self.max_bubbles < 1:
            raise ValueError("max_bubbles must be >= 1 or None")
        if self.memory_length is not None and self.memory_length < 1:
            raise ValueError("memory_length must be >= 1 or None")
        if not isinstance(self.mcp_servers, list) or len(self.mcp_servers) > 20:
            raise ValueError("mcp_servers must be a list of at most 20 ids")
        self.mcp_servers = [str(x) for x in self.mcp_servers]
        self.other_rooms_count = max(0, min(100, int(self.other_rooms_count)))
        if self.bilingual_by not in ("key", "self"):
            raise ValueError("bilingual_by must be key or self")
        self.bilingual_lang = str(self.bilingual_lang or "").strip()[:30]
        self.bilingual_to = str(self.bilingual_to or "").strip()[:30]
        if len(self.talk_rules or "") > 2000:
            raise ValueError("talk_rules must be at most 2000 characters")
        self.user_name = (self.user_name or "").strip()
        if len(self.user_name) > 20:
            raise ValueError("user_name must be at most 20 characters")
        for k in ("warmth", "initiative", "humor"):
            if getattr(self, k) not in TONE_LEVELS:
                raise ValueError(f"{k} must be one of {TONE_LEVELS}")
        self.relationship = (self.relationship or "").strip()
        if len(self.relationship) > 20:
            raise ValueError("relationship must be at most 20 characters")
        if self.user_pronoun not in PRONOUNS:
            raise ValueError(f"user_pronoun must be one of {PRONOUNS}")
        if self.thinking_mode not in (None, "native", "monologue"):
            raise ValueError("thinking_mode must be native, monologue or empty")
        if not 0 <= self.reply_wait <= 60:
            raise ValueError("reply_wait must be 0..60 seconds")
        if self.call_voice not in ("fast", "expressive", "system"):
            raise ValueError("call_voice must be fast, expressive or system")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{0,64}", self.voice_model):
            raise ValueError("voice_model looks wrong")
        if not re.fullmatch(r"[A-Za-z0-9_.-]{0,64}", self.mm_voice_model):
            raise ValueError("mm_voice_model looks wrong")
        if self.voice_provider not in ("elevenlabs", "minimax"):
            raise ValueError("voice_provider must be elevenlabs or minimax")
        if self.voice_mode not in ("off", "sometimes", "often"):
            raise ValueError("voice_mode must be off, sometimes or often")
        if self.tool_reminder_every < 1:
            raise ValueError("tool_reminder_every must be >= 1")
        if not 1 <= self.thinking_style_every <= 12:
            raise ValueError("thinking_style_every must be 1..12")
        try:
            ZoneInfo(self.tz)
        except Exception as e:
            raise ValueError(f"unknown time zone {self.tz!r}") from e
        if self.patrol_level not in PATROL_LEVELS:
            raise ValueError(f"patrol_level must be one of {PATROL_LEVELS}")
        parse_hm(self.sleep_from)
        parse_hm(self.sleep_to)
        if not DIARY_CHARS[0] <= self.diary_chars <= DIARY_CHARS[1]:
            raise ValueError(f"diary_chars must be {DIARY_CHARS[0]}..{DIARY_CHARS[1]}")
        for k, v in (self.patrol_overrides or {}).items():
            if k not in PATROL_OVERRIDES:
                raise ValueError(f"unknown patrol override {k!r}")
            lo, hi = PATROL_OVERRIDES[k]
            if not isinstance(v, int) or not lo <= v <= hi or (k == "asleep_gap_min" and 0 < v < 15):
                raise ValueError(f"patrol override {k} out of range")
        for i in self.injections:
            if i.mode not in INJECTION_MODES:
                raise ValueError(f"injection mode must be one of {INJECTION_MODES}, got {i.mode!r}")
