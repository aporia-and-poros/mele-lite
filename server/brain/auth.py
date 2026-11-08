"""登录、钥匙串、试用（2026-09-27，第二块中第 3 步；设计见 specs/2026-09-27-accounts-contacts-api-design.md）。

- 邮箱验证码：6 位数字，只存哈希（带服务器的秘钥），10 分钟过期，最多试 5 次，60 秒内不重发。
- 登录凭证：随机 32 字节，手机上存原文，服务器只存哈希；丢了就重新登录。
- Apple 登录：app 那边拿到 Apple 的身份令牌，服务器要用 Apple 公开的钥匙验签、核对 app 的标识——
  等 iOS app 有了标识再接（apple_login 现在收的是已经验过的 sub / email）。
- 钥匙串：用户的 key 用主密钥加密后存（cryptography 的 Fernet），主密钥只在服务器环境变量里；app 只看得到最后 4 位。
- 试用：新账号 30 轮，用我们的 key + DeepSeek flash；一台手机只给一次（设备标记等 app 接上，先存哈希）。"""
from __future__ import annotations

import logging
import hashlib
import hmac
import re
import secrets
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo
from uuid import UUID

from cryptography.fernet import Fernet

from llm.catalog import lookup
from llm.router import PROVIDERS, Route

from . import accounts, archive

log = logging.getLogger(__name__)

CODE_TTL = timedelta(minutes=10)
CODE_RESEND = timedelta(seconds=60)
CODE_TRIES = 5
_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


class AuthError(Exception):
    """登录出错：message 是可以直接给用户看的人话。"""


def _hash(secret: str, *parts: str) -> str:
    return hmac.new(secret.encode(), "\x00".join(parts).encode(), hashlib.sha256).hexdigest()


def normalize_email(email: str) -> str:
    e = (email or "").strip().lower()
    if not _EMAIL.match(e):
        raise AuthError("邮箱格式不对")
    return e


async def request_code(pool, email: str, *, secret: str, now: datetime) -> str:
    """生成一个验证码并存下哈希，返回原文（交给发信的去发；本机测试直接打印）。"""
    email = normalize_email(email)
    last = await pool.fetchval("SELECT sent_at FROM login_codes WHERE email = $1", email)
    if last is not None and now - last < CODE_RESEND:
        raise AuthError("验证码刚发过，等一分钟再试")
    code = f"{secrets.randbelow(10 ** 6):06d}"
    await pool.execute(
        """INSERT INTO login_codes (email, code_hash, expires_at, sent_at, attempts) VALUES ($1, $2, $3, $4, 0)
           ON CONFLICT (email) DO UPDATE SET code_hash = $2, expires_at = $3, sent_at = $4, attempts = 0""",
        email, _hash(secret, email, code), now + CODE_TTL, now)
    return code


async def verify_code(pool, email: str, code: str, *, secret: str, now: datetime) -> UUID:
    """验证码对了就返回账号（新邮箱就开个新账号，送一个 Lumi）。"""
    email = normalize_email(email)
    row = await pool.fetchrow("SELECT * FROM login_codes WHERE email = $1", email)
    if row is None or row["expires_at"] < now:
        raise AuthError("验证码过期了，重新发一个")
    if row["attempts"] >= CODE_TRIES:
        raise AuthError("试错太多次了，重新发一个")
    if not hmac.compare_digest(row["code_hash"], _hash(secret, email, (code or "").strip())):
        await pool.execute("UPDATE login_codes SET attempts = attempts + 1 WHERE email = $1", email)
        raise AuthError("验证码不对")
    await pool.execute("DELETE FROM login_codes WHERE email = $1", email)
    acc = await pool.fetchval("SELECT id FROM accounts WHERE email = $1", email)
    return acc or await new_account(pool, email=email)


async def apple_login(pool, sub: str, email: str | None = None) -> UUID:
    """sub / email 是验过签的 Apple 身份令牌里的（验签等 app 有了标识再接）。"""
    acc = await pool.fetchval("SELECT id FROM accounts WHERE apple_sub = $1", sub)
    return acc or await new_account(pool, apple_sub=sub, email=email)


async def new_account(pool, *, email: str | None = None, apple_sub: str | None = None,
                      tz: str = "UTC") -> UUID:
    """新账号：试用档 + 送一个 Lumi（它的设置、第一个窗口）。"""
    acc = uuid.uuid4()
    await pool.execute("INSERT INTO accounts (id, email, apple_sub) VALUES ($1, $2, $3)", acc, email, apple_sub)
    lumi = await accounts.create_companion(pool, acc)
    await archive.save_settings(pool, lumi, {"tz": tz})
    await accounts.new_conversation(pool, acc, lumi)
    return acc


async def new_session(pool, account: UUID, *, secret: str, now: datetime) -> str:
    token = secrets.token_urlsafe(32)
    await pool.execute("INSERT INTO sessions (token_hash, account_id, created_at, last_seen) VALUES ($1, $2, $3, $3)",
                       _hash(secret, token), account, now)
    return token


async def account_for(pool, token: str, *, secret: str, now: datetime) -> UUID | None:
    acc = await pool.fetchval("UPDATE sessions SET last_seen = $2 WHERE token_hash = $1 RETURNING account_id",
                              _hash(secret, token or ""), now)
    return acc


async def logout(pool, token: str, *, secret: str) -> None:
    await pool.execute("DELETE FROM sessions WHERE token_hash = $1", _hash(secret, token or ""))


# ── 钥匙串 ──

class KeyBox:
    """主密钥来自服务器环境变量（Fernet 的 32 字节 base64 钥匙：Fernet.generate_key() 生成）。"""

    def __init__(self, master_key: str | bytes):
        self._f = Fernet(master_key)

    def lock(self, api_key: str) -> bytes:
        return self._f.encrypt(api_key.encode())

    def unlock(self, blob: bytes) -> str:
        return self._f.decrypt(bytes(blob)).decode()


@dataclass
class KeyInfo:
    id: UUID
    provider: str
    chat_model: str
    base_url: str | None
    last4: str
    ledger_model: str | None = None   # 用户自己指定的后台模型（10-13）；None = 照清单


def check_key_input(provider: str, api_key: str, chat_model: str) -> str:
    """不用联网就能看出来的毛病；返回去掉空白的 key。"""
    if provider not in PROVIDERS:
        raise AuthError(f"不认识这家：{provider}")
    api_key = (api_key or "").strip()
    if len(api_key) < 8:
        raise AuthError("这个 key 太短了，是不是没贴全")
    if not (chat_model or "").strip():
        raise AuthError("要选一个聊天用的模型")
    return api_key


async def add_key(pool, box: KeyBox, account: UUID, *, provider: str, api_key: str, chat_model: str,
                  base_url: str | None = None, ledger_model: str | None = None) -> UUID:
    api_key = check_key_input(provider, api_key, chat_model)
    kid = uuid.uuid4()
    await pool.execute(
        "INSERT INTO keyring (id, account_id, provider, chat_model, base_url, secret, last4, ledger_model) "
        "VALUES ($1,$2,$3,$4,$5,$6,$7,$8)",
        kid, account, provider, chat_model, base_url, box.lock(api_key), api_key[-4:], _model_or_none(ledger_model))
    await pool.execute("UPDATE accounts SET plan = 'byok' WHERE id = $1 AND plan = 'trial'", account)
    return kid


VOICE_PROVIDERS = ("elevenlabs", "minimax")      # 只管声音的钥匙（不聊天、不过模型检查、一家只留一把）
_NOT_VOICE = "provider NOT IN ('elevenlabs', 'minimax')"


async def add_voice_key(pool, box: KeyBox, account: UUID, api_key: str, provider: str = "elevenlabs",
                        base_url: str | None = None) -> UUID:
    """声音的 key（10-03 ElevenLabs；11-08 加 MiniMax，base_url 记它是国内版还是国际版的地址）：
    不是聊天模型，不过模型检查、不改套餐；一家一个账号只留一把（新的顶掉旧的）。"""
    if provider not in VOICE_PROVIDERS:
        raise AuthError("不认得这家")
    api_key = (api_key or "").strip()
    if len(api_key) < 8:
        raise AuthError("这个 key 太短了，是不是没贴全")
    kid = uuid.uuid4()
    async with pool.acquire() as con, con.transaction():
        await con.execute("DELETE FROM keyring WHERE account_id = $1 AND provider = $2", account, provider)
        await con.execute("INSERT INTO keyring (id, account_id, provider, chat_model, base_url, secret, last4) "
                          "VALUES ($1, $2, $3, '', $4, $5, $6)", kid, account, provider, base_url, box.lock(api_key), api_key[-4:])
    return kid


async def voice_key(pool, box: KeyBox, account: UUID, provider: str = "elevenlabs") -> str | None:
    got = await voice_key_full(pool, box, account, provider)
    return got[0] if got else None


async def voice_key_full(pool, box: KeyBox, account: UUID, provider: str = "elevenlabs") -> tuple[str, str | None] | None:
    """（key，接口地址）。ElevenLabs 的地址是空的。"""
    row = await pool.fetchrow("SELECT secret, base_url FROM keyring WHERE account_id = $1 AND provider = $2", account, provider)
    return (box.unlock(row["secret"]), row["base_url"]) if row else None


async def list_keys(pool, account: UUID) -> list[KeyInfo]:
    rows = await pool.fetch("SELECT id, provider, chat_model, base_url, last4, ledger_model FROM keyring WHERE account_id = $1 "
                            "ORDER BY created_at", account)
    return [KeyInfo(**dict(r)) for r in rows]


def _model_or_none(name: str | None) -> str | None:
    name = (name or "").strip()
    return name or None


async def set_ledger_model(pool, account: UUID, key_id: UUID, ledger_model: str | None) -> bool:
    """改一把钥匙的后台模型（不用删了重加，联系人绑着的钥匙不动）；空 = 回到照清单。
    不试打：写账失败本来就会换聊天那个模型兜底，填错了只是多花点，不会卡住。"""
    done = await pool.execute("UPDATE keyring SET ledger_model = $3 WHERE id = $1 AND account_id = $2 "
                              f"AND {_NOT_VOICE}", key_id, account, _model_or_none(ledger_model))
    return done.endswith("1")


async def set_chat_model(pool, account: UUID, key_id: UUID, chat_model: str) -> bool:
    """换一把钥匙的聊天模型（10-29 内测：同一把 key 想切模型得再加一把）。不试打：填错了聊不上，改回来就好。"""
    chat_model = (chat_model or "").strip()[:100]
    if not chat_model:
        raise AuthError("要填一个聊天用的模型")
    done = await pool.execute("UPDATE keyring SET chat_model = $3 WHERE id = $1 AND account_id = $2 "
                              f"AND {_NOT_VOICE}", key_id, account, chat_model)
    return done.endswith("1")


async def delete_key(pool, account: UUID, key_id: UUID) -> bool:
    return (await pool.execute("DELETE FROM keyring WHERE id = $1 AND account_id = $2", key_id, account)).endswith("1")


async def use_key(pool, account: UUID, companion: UUID, key_id: UUID | None) -> None:
    """这个联系人用哪把钥匙（空 = 不用，走试用或提示加 key）。钥匙和联系人都得是这个账号的。"""
    if key_id is not None and not await pool.fetchval(
            f"SELECT 1 FROM keyring WHERE id = $1 AND account_id = $2 AND {_NOT_VOICE}", key_id, account):
        raise AuthError("没有这把钥匙")
    done = await pool.execute("UPDATE companions SET key_id = $3 WHERE id = $1 AND account_id = $2",
                              companion, account, key_id)
    if not done.endswith("1"):
        raise AuthError("没有这个联系人")


class DbKeys:
    """大脑用的「这一轮走哪把钥匙」：联系人配了钥匙就用它的；没配、还在试用期就走我们的试用钥匙；
    试用用完了就告诉用户（它说一句人话，记忆和聊天都留着）。"""

    def __init__(self, pool, box: KeyBox, trial_route: Route | None, policy: "TrialPolicy | None" = None, now=None):
        self.pool, self.box, self.trial = pool, box, trial_route
        self.policy = policy or TrialPolicy()
        self.now = now or (lambda: datetime.now(ZoneInfo("UTC")))

    async def route_for_scope(self, scope) -> Route:
        row = await self.pool.fetchrow(
            """SELECT k.* FROM companions c JOIN keyring k ON k.id = c.key_id
               WHERE c.id = $1 AND c.account_id = $2""", scope.companion, scope.account)
        if row is not None:
            info = lookup(row["chat_model"])
            mine = row["ledger_model"]          # 用户自己指定的后台模型（10-13 内测）：写账、压旧天都用它，压不动照样换聊天那个兜底
            return Route(provider=row["provider"], api_key=self.box.unlock(row["secret"]), chat_model=row["chat_model"],
                         ledger_model=mine or (info.ledger_model if info else row["chat_model"]), base_url=row["base_url"],
                         age_model=mine or (info.age_model if info else None))
        if self.trial is None:
            raise TrialOver()
        tz = (await archive.get_settings(self.pool, scope.companion)).get("tz") or "UTC"
        if await trial_balance(self.pool, scope.account, self.now(), tz, self.policy) <= 0:
            raise TrialOver()
        return self.trial

    async def route_for_chore(self, scope, chore: str) -> Route | None:
        """钥匙串里勾了这样活的那把（10-15）；没勾 / 删了 / 那家干不了 = None（照旧走聊天那把）"""
        from . import chores as CH
        t = await CH.get_table(self.pool, scope.account)
        kid = CH.pick(t["chores"], chore, await CH.live_keys(self.pool, scope.account))
        if kid is None:
            return None
        row = await self.pool.fetchrow("SELECT * FROM keyring WHERE id = $1 AND account_id = $2", UUID(kid), scope.account)
        if row is None:
            return None
        m = row["chat_model"]
        return Route(provider=row["provider"], api_key=self.box.unlock(row["secret"]), chat_model=m,
                     ledger_model=m, base_url=row["base_url"], age_model=m)


class TrialOver(Exception):
    pass


# ── 免费额度（09-28 Aporia：按 token 折成钱扣，不按轮数——防有人拿来一口气问 30 个学术问题）──
# 单位是微美元（百万分之一美元）。第一次给得多（新手礼包），之后每天早上 5 点（用户时区）补到每日份，不累加。
# 老的 trial_left 栏只剩一个用处：> 0 = 还没领过礼包的新账号；这台手机领过的账号被清成 0，只有每日份。

@dataclass(frozen=True)
class TrialPolicy:
    first_micro: int = 50_000        # 0.05 美元（DeepSeek Flash 上大约 30~50 轮日常聊天）；上线前再定（NEWAPP_TRIAL_FIRST_USD）
    daily_micro: int = 10_000        # 0.01 美元（NEWAPP_TRIAL_DAILY_USD）
    refill_hour: int = 5             # 用户时区几点换日

    @property
    def full(self) -> int:
        return max(self.first_micro, self.daily_micro)


def trial_day(now: datetime, tz: str, policy: TrialPolicy) -> date:
    return (now.astimezone(ZoneInfo(tz)) - timedelta(hours=policy.refill_hour)).date()


def next_refill(now: datetime, tz: str, policy: TrialPolicy) -> datetime:
    local = now.astimezone(ZoneInfo(tz))
    at = local.replace(hour=policy.refill_hour, minute=0, second=0, microsecond=0)
    return at if at > local else at + timedelta(days=1)


async def trial_balance(pool, account: UUID, now: datetime, tz: str, policy: TrialPolicy) -> int:
    """现在还剩多少（微美元）。懒算：第一次看时发礼包；过了换日点就补到每日份（比每日份多的留着，不累加）。"""
    today = trial_day(now, tz, policy)
    async with pool.acquire() as con, con.transaction():
        r = await con.fetchrow("SELECT trial_left, trial_micro, trial_day FROM accounts WHERE id = $1 FOR UPDATE", account)
        bal, day = r["trial_micro"], r["trial_day"]
        if bal is None:
            bal = policy.first_micro if r["trial_left"] > 0 else policy.daily_micro
        elif day is None or day < today:
            bal = max(bal, policy.daily_micro)
        if bal != r["trial_micro"] or day != today:
            await con.execute("UPDATE accounts SET trial_micro = $2, trial_day = $3 WHERE id = $1", account, bal, today)
    return bal


async def charge_trial(pool, account: UUID, micro: int) -> None:
    await pool.execute("UPDATE accounts SET trial_micro = GREATEST(COALESCE(trial_micro, 0) - $2, 0) WHERE id = $1",
                       account, max(0, int(micro)))


async def claim_trial_device(pool, account: UUID, device_id: str, *, secret: str) -> bool:
    """这台手机用过试用了吗：用过（算在别的账号上）就把这个账号的试用清零，返回 False。"""
    h = _hash(secret, "device", device_id)
    owner = await pool.fetchval(
        "INSERT INTO trial_devices (device_hash, account_id) VALUES ($1, $2) ON CONFLICT (device_hash) DO UPDATE "
        "SET device_hash = EXCLUDED.device_hash RETURNING account_id", h, account)
    if owner != account:
        await pool.execute("UPDATE accounts SET trial_left = 0 WHERE id = $1", account)   # 没礼包，只有每日份
        return False
    return True


# ── 加钥匙前试打一次（09-28）──

_PROBE_ERRORS = {
    "auth": "这个 key 不对，或者没开通这个模型",
    "balance": "这把 key 余额不足，充值以后再加",
    "model": "这家没有这个模型，换一个试试",
    "network": "连不上 {who}，过一会儿再试",
    "overloaded": "{who} 那边太忙了，过一会儿再试",
    "rate": "{who} 那边太忙了，过一会儿再试",
}
_WHO = {"anthropic": "Anthropic", "deepseek": "DeepSeek", "openai": "OpenAI", "openai-compatible": "这个地址",
        "gemini": "Gemini"}


async def probe_key(adapter_for, provider: str, api_key: str, chat_model: str, base_url: str | None) -> None:
    """发最短的一次请求（一句 hi、最多 1 个 token、不开思考），通了什么都不做，不通抛 AuthError（人话）。"""
    from llm.errors import LLMError
    from llm.types import ChatRequest, Msg
    route = Route(provider, api_key.strip(), chat_model, chat_model, base_url=base_url)
    try:
        await adapter_for(route).stream(ChatRequest(model=chat_model, system=[], messages=[Msg("user", "hi")],
                                                    max_tokens=1, thinking=False))
    except LLMError as e:
        text = _PROBE_ERRORS.get(e.kind)
        raise AuthError(text.format(who=_WHO.get(provider, provider)) if text
                        else f"试了一下没通：{e.message or e.kind}") from e
    except Exception as e:          # noqa: BLE001 —— 接头没归类的（DNS、证书……）
        log.warning("probe_key %s %s failed: %r", provider, chat_model, e)     # 09-28：之前全吞了，看不出是什么错
        raise AuthError(f"连不上 {_WHO.get(provider, provider)}，过一会儿再试") from e
