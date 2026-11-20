"""看图（iOS 第一块第 4 步）：会看图的模型发图那轮看原图、以后只看描述；看不见的请描述模型写；自带 key 的每天限量。测试用小满。"""
import io
from uuid import UUID

from PIL import Image

from llm.fake import FakeModel
from llm.router import Route
from test_api import Env


def png() -> bytes:
    out = io.BytesIO()
    Image.new("RGB", (64, 64), (30, 90, 160)).save(out, "PNG")
    return out.getvalue()


async def go(e, t, tmp_path, texts):
    e.app.state.api.cfg.files_dir = tmp_path
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        img = (await c.post(f"/conversations/{conv['id']}/attachments", files={"file": ("sea.png", png(), "image/png")})).json()
        for i, text in enumerate(texts):
            body = {"text": text, **({"attachments": [img["id"]]} if i == 0 else {})}
            await c.post(f"/conversations/{conv['id']}/messages", json=body)
            await e.rooms.idle(UUID(conv["id"]))
    return UUID(conv["id"])


async def test_vision_model_sees_the_photo_once(pool, tmp_path):
    e = Env(pool, ["一片傍晚的海，天是橘粉色的。", "好美", "嗯"])
    e.deps.keys.trial = Route("anthropic", "ours", "fake-chat", "fake-ledger", trial=True)     # 会看图的一家
    t = await e.login()
    await go(e, t, tmp_path, ["今天拍的", "你觉得呢"])
    caption_req, turn1, turn2 = e.model.requests
    assert len(caption_req.messages[0].images) == 1                              # 先让它自己写描述
    assert len(turn1.messages[-1].images) == 1 and "〔TA 发了一张图片：一片傍晚的海" in turn1.messages[-1].text
    assert all(not m.images for m in turn2.messages) and "一片傍晚的海" in turn2.messages[0].text   # 以后只有描述


async def test_blind_model_gets_a_caption_from_ours(pool, tmp_path):
    e = Env(pool, ["看到海了", "嗯"])
    eye = FakeModel(["一张蓝色的方图。"])
    e.deps.caption_route = Route("gemini", "ours-caption", "gemini-flash", "gemini-flash")
    chat = e.deps.adapter_for
    e.deps.adapter_for = lambda r: eye if r.provider == "gemini" else chat(r)
    t = await e.login()
    conv = await go(e, t, tmp_path, ["今天拍的"])
    assert len(eye.requests) == 1 and eye.requests[0].messages[0].images
    assert not e.model.requests[0].messages[-1].images and "一张蓝色的方图" in e.model.requests[0].messages[-1].text
    assert await pool.fetchval("SELECT caption_source FROM attachments WHERE conversation_id = $1", conv) == "ours"


async def test_byok_daily_limit_on_our_captions(pool, tmp_path):
    e = Env(pool, ["嗯"])
    eye = FakeModel([])
    e.deps.caption_route = Route("gemini", "ours-caption", "gemini-flash", "gemini-flash")
    chat = e.deps.adapter_for
    e.deps.adapter_for = lambda r: eye if r.provider == "gemini" else chat(r)
    t = await e.login()
    acc = await pool.fetchval("SELECT id FROM accounts")
    await pool.execute("UPDATE accounts SET plan = 'byok' WHERE id = $1", acc)
    conv = await pool.fetchval("SELECT id FROM conversations")
    for i in range(20):
        await pool.execute("INSERT INTO attachments (id, account_id, conversation_id, kind, mime, size, path, caption_source) "
                           "VALUES (gen_random_uuid(), $1, $2, 'image', 'image/jpeg', 1, '/nope', 'ours')", acc, conv)
    await go(e, t, tmp_path, ["又一张"])
    assert eye.requests == [] and "还没看清是什么" in e.model.requests[0].messages[-1].text


async def test_same_photo_is_read_once(pool, tmp_path):
    """10-01 Aporia：同一张图只读一次——按原始字节的指纹认，第二次直接用上次的描述。"""
    e = Env(pool, ["看到海了", "又是这张", "嗯"])
    eye = FakeModel(["一张蓝色的方图。"])
    e.deps.caption_route = Route("gemini", "ours-caption", "gemini-flash", "gemini-flash")
    chat = e.deps.adapter_for
    e.deps.adapter_for = lambda r: eye if r.provider == "gemini" else chat(r)
    t = await e.login()
    e.app.state.api.cfg.files_dir = tmp_path
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        for text in ("今天拍的", "再发一次"):
            img = (await c.post(f"/conversations/{conv['id']}/attachments",
                                files={"file": ("sea.png", png(), "image/png")})).json()
            await c.post(f"/conversations/{conv['id']}/messages", json={"text": text, "attachments": [img["id"]]})
            await e.rooms.idle(UUID(conv["id"]))
    assert len(eye.requests) == 1                                                       # 只看了一次
    assert "一张蓝色的方图" in e.model.requests[1].messages[-1].text
    assert await pool.fetchval("SELECT count(*) FROM attachments WHERE caption_source = 'seen'") == 1


def test_relay_sees_images_unless_deepseek():
    """中转站跟 Lite 一样默认看得见图；地址是 DeepSeek 的不算（10-26 内测）"""
    from llm.catalog import sees_images
    assert sees_images("openai-compatible", "https://api.some-relay.com/v1")
    assert not sees_images("openai-compatible", "https://api.deepseek.com/v1")
    assert sees_images("openai-compatible", None)   # 没填地址也当看得见
    assert sees_images("openai") and not sees_images("deepseek")
    assert not sees_images("openai-compatible", "https://api.siliconflow.cn/v1", "deepseek-ai/DeepSeek-V3.2")   # 11-20
    assert sees_images("openai-compatible", "https://api.siliconflow.cn/v1", "deepseek-ai/deepseek-vl2")
    assert sees_images("openai-compatible", "https://api.siliconflow.cn/v1", "Qwen/Qwen3-VL-32B-Instruct")
