"""跑正式接口：
    cd server && NEWAPP_DSN=… NEWAPP_MASTER_KEY=… NEWAPP_SECRET=… .venv/bin/python -m api --port 8080

环境变量（部署时配，都不进仓库）：
- NEWAPP_DSN：数据库地址
- NEWAPP_MASTER_KEY：钥匙串的主密钥，Fernet.generate_key() 生成。**丢了所有人存的 key 都解不开，要备份。**
- NEWAPP_SECRET：验证码、登录凭证、设备标记的哈希秘钥（随机长字符串）。换了所有人要重新登录。
- NEWAPP_TRIAL_DEEPSEEK_KEY：试用走的 DeepSeek key（模型 deepseek-flash）；不配 = 没有试用，没加 key 的人会被提示加 key。
- NEWAPP_TRIAL_FIRST_USD / NEWAPP_TRIAL_DAILY_USD：免费额度（按 token 折成美元扣）——第一次给多少、之后每天早上 5 点补到多少（不累加）；默认 0.05 / 0.01，上线前再定。
- NEWAPP_APNS_KEY_PATH / NEWAPP_APNS_KEY_ID / NEWAPP_APNS_TEAM_ID（/ NEWAPP_APNS_TOPIC、NEWAPP_APNS_SANDBOX=1）：推送真发；不配只排队。
- NEWAPP_FAKE_EMBED=1：本机只看接口时用假向量，不加载 bge-m3。
- NEWAPP_PATROL=0：不起巡逻（它不会自己醒来找人）；默认起。
- NEWAPP_FILES_DIR：照片和文件存哪；默认 server/.local/files/（上线后换对象存储）。
- 加 --demo：演示模型（复述你的话，不联网、不花钱），只看 app 界面用。
- NEWAPP_CAPTION_GEMINI_KEY / NEWAPP_CAPTION_MODEL：我们的看图模型（用户的模型看不见图时写描述）；不配 = 那种情况图片只写「还没看清」。
- NEWAPP_ELEVENLABS_KEY：我们的 ElevenLabs key（语音条、念给我听，10-03）；不配 = 只有自带 key 的人有声音。演示模式用假合成。
- NEWAPP_HOST=1：Mele Host 单人模式（10-04）：不注册、不发验证码，扫配对码绑定唯一主人；不带试用。
- NEWAPP_PUBLIC_URL：Host 的公网地址（https://…），只用来打印配对链接。
- NEWAPP_PUSH_RELAY：推送中转的地址（Mele Host，10-04）；Host 默认用官方那个，设成 off 关掉。
- NEWAPP_LYRICS=1/0：一起听时去 lrclib 取歌词（只给 Lumi 看）；不设 = 正式版开、Host 关（10-05）。
- NEWAPP_RERANK=1：加载精排模型 bge-reranker（约 2GB 内存）；不设 = 不加载（Host 默认不加载）。
- NEWAPP_MUSICKIT_KEY_PATH / NEWAPP_MUSICKIT_KEY_ID / NEWAPP_MUSICKIT_TEAM_ID：Apple Music（音乐房间，09-30）；不配 = 找歌走 iTunes 公开搜索（10-05，Host 都是这样），没有相似歌手和「最近在听」。"""
from __future__ import annotations

import argparse
import asyncio
import os
import sys
from pathlib import Path

import uvicorn

import memory as M
from brain import archive, auth
from brain.turn import Deps
from llm.router import Route

from .app import create_app
from .deps import ApiConfig


DEFAULT_PUSH_RELAY = "https://mele-push.meleapp.workers.dev"   # Aporia的推送中转（relay/worker.js）；苹果推送钥匙只在那


def env(name: str) -> str:
    v = os.environ.get(name, "").strip()
    if not v:
        sys.exit(f"缺环境变量 {name}（见 api/__main__.py 开头）")
    return v


def load_env_file(path: Path) -> None:
    """开发用：server/.local/api.env 里的 KEY=VALUE 读进环境变量（已经设了的不覆盖）。这个文件不进仓库。"""
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


async def main(args) -> None:
    load_env_file(Path(__file__).resolve().parent.parent / ".local" / "api.env")
    from .host import announce, ensure_code, flags
    hf = flags(os.environ)
    dsn = env("NEWAPP_DSN")
    cfg = ApiConfig(secret=env("NEWAPP_SECRET"), box=auth.KeyBox(env("NEWAPP_MASTER_KEY")),
                    patrol=os.environ.get("NEWAPP_PATROL", "1") != "0", host_mode=hf.host)
    if os.environ.get("NEWAPP_APNS_KEY_PATH"):          # 推送真发（09-28）；.p8 在 server/.local/，不进仓库
        from push.apns import ApnsConfig
        cfg.apns = ApnsConfig(Path(os.environ["NEWAPP_APNS_KEY_PATH"]).expanduser().read_bytes(),
                              env("NEWAPP_APNS_KEY_ID"), env("NEWAPP_APNS_TEAM_ID"),
                              os.environ.get("NEWAPP_APNS_TOPIC", "chat.mele.app"),
                              sandbox=os.environ.get("NEWAPP_APNS_SANDBOX", "1") == "1")
    relay = os.environ.get("NEWAPP_PUSH_RELAY", "").strip() or (DEFAULT_PUSH_RELAY if hf.host else "")
    cfg.push_relay = relay if relay and relay != "off" else None
    if os.environ.get("NEWAPP_FILES_DIR"):
        cfg.files_dir = Path(os.environ["NEWAPP_FILES_DIR"])
    trial_key = "" if hf.host else os.environ.get("NEWAPP_TRIAL_DEEPSEEK_KEY", "").strip()   # Host 不带试用
    trial = Route("deepseek", trial_key, "deepseek-flash", "deepseek-flash", age_model="deepseek-flash",
                  trial=True) if trial_key else None
    policy = auth.TrialPolicy(
        first_micro=round(float(os.environ.get("NEWAPP_TRIAL_FIRST_USD", "0.05")) * 1_000_000),
        daily_micro=round(float(os.environ.get("NEWAPP_TRIAL_DAILY_USD", "0.01")) * 1_000_000))
    await M.apply_schema(dsn)
    await archive.apply_brain_schema(dsn)
    pool = await M.create_pool(dsn)
    if hf.host:                                    # 新服务器（没主人也没码）出一张配对码，打在日志里
        code = await ensure_code(pool, secret=cfg.secret)
        if code:
            announce(hf.public_url, code)
    fake = os.environ.get("NEWAPP_FAKE_EMBED") == "1"
    cap_key = os.environ.get("NEWAPP_CAPTION_GEMINI_KEY", "").strip()
    cap_model = os.environ.get("NEWAPP_CAPTION_MODEL", "gemini-3.5-flash-lite")   # 09-28：2.5-flash 新用户已停；3.8-flash 被思考吃掉 600 token 写不完。上线前按官网核对价格
    caption = Route("gemini", cap_key, cap_model, cap_model) if cap_key else None
    deps = Deps(pool=pool, embedder=M.FakeEmbedder() if fake else M.BgeM3Embedder(),
                keys=auth.DbKeys(pool, cfg.box, trial, policy=policy), reranker=M.BgeReranker() if (hf.rerank and not fake) else None,
                caption_route=caption, sentinel=not args.demo, probe_keys=not args.demo)     # 演示模型不会吐 JSON，哨兵就不跑了
    if os.environ.get("NEWAPP_MUSICKIT_KEY_PATH"):      # Apple Music（09-30）；.p8 在 server/.local/，不进仓库
        from music.apple import AppleMusic
        deps.music = AppleMusic(Path(os.environ["NEWAPP_MUSICKIT_KEY_PATH"]).expanduser().read_bytes(),
                                env("NEWAPP_MUSICKIT_KEY_ID"), env("NEWAPP_MUSICKIT_TEAM_ID"))
        from music.ears import Transport          # 耳朵（09-30）：在放、没听过的歌后台去听；演示模式不开
        deps.ears = None if args.demo else Transport()
    else:                                                # 没钥匙（Mele Host 的用户都没有，10-05）：找歌走 iTunes 公开搜索
        from music.itunes import ITunesMusic
        deps.music = ITunesMusic()
        from music.ears import Transport
        deps.ears = None if args.demo else Transport()   # 试听片段一样拿得到；没有 Gemini 钥匙就只量数，不写听感
    from llm.tts import ElevenLabs, FakeTTS              # 声音（10-03）
    if args.demo:
        fake_tts = FakeTTS()
        deps.tts_for, deps.tts_key = (lambda k: fake_tts), "demo"
        deps.minimax_for = lambda k, base: fake_tts       # MiniMax（11-08）演示也用假合成
    else:
        deps.tts_for, deps.tts_key = ElevenLabs, os.environ.get("NEWAPP_ELEVENLABS_KEY", "").strip()
    if args.demo:
        from web.__main__ import DemoKeys, DemoModel
        demo = DemoModel()
        deps.keys, deps.adapter_for = DemoKeys(), (lambda route: demo)
    server = uvicorn.Server(uvicorn.Config(create_app(deps, cfg), host=args.host, port=args.port, log_level="info"))
    try:
        await server.serve()
    finally:
        await pool.close()


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--demo", action="store_true")
    asyncio.run(main(ap.parse_args()))
