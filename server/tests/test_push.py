"""推送真发（iOS 第三块第 2 步）：没人在看这个窗口时它回的话排进推送队列；发给账号所有设备；410 删设备；JWT 的样子。测试用小满。"""
import base64
import json
from uuid import UUID

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from push.apns import ApnsConfig, make_jwt, send_pending
from test_api import Env


def cfg():
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    return ApnsConfig(pem, "KEY123", "TEAM456", "com.lingxi.companion")


def test_jwt_shape_and_reuse():
    c = cfg()
    t = make_jwt(c, 1000.0)
    head, claims, sig = t.split(".")
    pad = lambda s: s + "=" * (-len(s) % 4)       # noqa: E731
    assert json.loads(base64.urlsafe_b64decode(pad(head))) == {"alg": "ES256", "kid": "KEY123"}
    assert json.loads(base64.urlsafe_b64decode(pad(claims))) == {"iss": "TEAM456", "iat": 1000}
    assert len(base64.urlsafe_b64decode(pad(sig))) == 64
    assert make_jwt(c, 1000.0 + 60) == t and make_jwt(c, 1000.0 + 3600) != t


async def test_unwatched_reply_is_queued_and_sent(pool):
    e = Env(pool, ["诶你回来啦\n\n今天怎么样"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        await c.post("/me/devices", json={"apns_token": "tok-a"})
        await c.post("/me/devices", json={"apns_token": "tok-dead"})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "我回来了"})
        await e.rooms.idle(UUID(conv["id"]))                # 没人连事件流 = 没人在看
    assert await pool.fetchval("SELECT text FROM push_queue WHERE conversation_id = $1", UUID(conv["id"])) \
        == "诶你回来啦\n\n今天怎么样"
    sent = []

    async def transport(url, headers, body):
        sent.append((url, headers, json.loads(body)))
        return (410, "Unregistered") if url.endswith("tok-dead") else (200, "")
    import push.apns as A
    A.GAP = 0
    assert await send_pending(pool, cfg(), transport) == 1
    # 两条气泡各推一条：第一条两台都试（死的那台删掉；新登记的先推），第二条只剩活的那台
    assert [u.rsplit("/", 1)[1] for u, _, _ in sent] == ["tok-dead", "tok-a", "tok-a"]
    _, headers, body = sent[1]
    assert headers["apns-topic"] == "com.lingxi.companion" and headers["authorization"].startswith("bearer ")
    assert body["aps"]["alert"] == {"title": "Lumi", "body": "诶你回来啦"} and body["conversation"] == conv["id"]
    assert sent[2][2]["aps"]["alert"]["body"] == "今天怎么样"
    assert await pool.fetchval("SELECT count(*) FROM devices") == 1                  # 死掉的那台删了
    assert await send_pending(pool, cfg(), transport) == 0                            # 发过的不再发
    await pool.execute("INSERT INTO push_queue (account_id, companion_id, conversation_id, text, created_at) "
                       "SELECT account_id, companion_id, conversation_id, '昨天的话', now() - interval '2 hours' "
                       "FROM push_queue LIMIT 1")
    assert await send_pending(pool, cfg(), transport) == 0                            # 排太久的不推


async def test_watched_reply_is_not_queued(pool):
    e = Env(pool, ["在呢"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        q = e.rooms.listen(UUID(conv["id"]))                # 聊天页开着
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "在吗"})
        await e.rooms.idle(UUID(conv["id"]))
        e.rooms.unlisten(UUID(conv["id"]), q)
    assert await pool.fetchval("SELECT count(*) FROM push_queue") == 0


async def _send_all(pool):
    sent = []

    async def transport(url, headers, body):
        sent.append((url, headers, json.loads(body)))
        return 200, ""
    import push.apns as A
    A.GAP = 0
    await send_pending(pool, cfg(), transport)
    return sent


def test_urgent_only_for_their_own_clocks_and_the_day_itself():
    from patrol.wake import urgent
    assert urgent("user", {}) and urgent("date", {"phase": "day"})
    assert not any([urgent("date", {"phase": "eve"}), urgent("date", {"phase": "after"}), urgent("self", {}),
                    urgent("heartbeat", {}), urgent("meal", {}), urgent("picks", {})])


async def test_urgent_push_is_time_sensitive(pool):
    from patrol import store
    e = Env(pool, [])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.post("/me/devices", json={"apns_token": "tok-a"})
        me = UUID((await c.get("/me")).json()["id"])
    await store.queue_push(pool, account=me, companion=UUID(comp["id"]), conversation=UUID(conv["id"]), text="该出门了", urgent=True)
    await store.queue_push(pool, account=me, companion=UUID(comp["id"]), conversation=UUID(conv["id"]), text="在干嘛")
    sent = []

    async def transport(url, headers, body):
        sent.append(json.loads(body))
        return 200, ""
    assert await send_pending(pool, cfg(), transport) == 2
    assert sent[0]["aps"]["interruption-level"] == "time-sensitive" and "interruption-level" not in sent[1]["aps"]


# ── Mele Host 推送中转（10-04 第四步）：内容加密交给中转站，中转站看不见说了什么 ──

async def test_relay_device_gets_sealed_push(pool):
    import os
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    key = AESGCM.generate_key(bit_length=256)
    e = Env(pool, ["晚安小满"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        r = await c.post("/me/devices", json={"apns_token": "relay:abc123", "relay_secret": "s3cret",
                                              "push_key": base64.b64encode(key).decode()})
        assert r.status_code == 204
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "我睡了"})
        await e.rooms.idle(UUID(conv["id"]))
    sent = []

    async def transport(url, headers, body):
        sent.append((url, headers, json.loads(body)))
        return 200, ""
    import push.apns as A
    A.GAP = 0
    assert await send_pending(pool, None, transport, relay_url="https://relay.test") == 1
    url, headers, body = sent[0]
    assert url == "https://relay.test/push" and headers["authorization"] == "Bearer s3cret"
    assert body["relay_id"] == "abc123" and "晚安" not in json.dumps(body, ensure_ascii=False)   # 中转看不见
    raw = base64.b64decode(body["sealed"])
    inner = json.loads(AESGCM(key).decrypt(raw[:12], raw[12:], None))
    assert inner["aps"]["alert"] == {"title": "Lumi", "body": "晚安小满"} and inner["conversation"] == conv["id"]
    assert body["sound"] is True and body["urgent"] is False


async def test_relay_gone_deletes_device_and_no_apns_without_cfg(pool):
    e = Env(pool, ["在吗"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        await c.post("/me/devices", json={"apns_token": "relay:gone", "relay_secret": "x",
                                          "push_key": base64.b64encode(b"k" * 32).decode()})
        await c.post("/me/devices", json={"apns_token": "direct-tok"})     # Host 没有苹果钥匙：直连的那台跳过
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "hi"})
        await e.rooms.idle(UUID(conv["id"]))
    sent = []

    async def transport(url, headers, body):
        sent.append(url)
        return 410, "Unregistered"
    assert await send_pending(pool, None, transport, relay_url="https://relay.test") == 1
    assert sent == ["https://relay.test/push"]
    assert await pool.fetchval("SELECT count(*) FROM devices WHERE apns_token = 'relay:gone'") == 0


async def test_host_registers_with_relay_for_the_phone(pool, monkeypatch):
    """手机连不上中转站（10-12：国内打不开 workers.dev）：设备号交给 Host，Host 替它登记"""
    import api.routes_patrol as R
    calls = []

    async def fake(relay, token, sandbox):
        calls.append((relay, token, sandbox))
        return "rid9", "sec9"
    monkeypatch.setattr(R, "_relay_register", fake)
    e = Env(pool, [])
    t = await e.login()
    key = base64.b64encode(b"k" * 32).decode()
    async with e.client(t) as c:
        assert (await c.post("/me/devices/relay", json={"token": "apns-tok", "push_key": key})).status_code == 409   # 没开中转
        e.app.state.api.cfg.push_relay = "https://relay.test"
        r = await c.post("/me/devices/relay", json={"token": "apns-tok", "sandbox": False, "push_key": key})
        assert r.status_code == 200 and r.json() == {"relay_id": "rid9"}
        assert (await c.post("/me/devices/relay", json={"token": "apns-tok"})).status_code == 400
    assert calls == [("https://relay.test", "apns-tok", False)]
    row = await pool.fetchrow("SELECT apns_token, relay_secret, push_key FROM devices")
    assert dict(row) == {"apns_token": "relay:rid9", "relay_secret": "sec9", "push_key": key}


async def test_host_forwards_feedback_to_relay(pool, monkeypatch):
    """内测反馈（11-05：国内打不开 workers.dev，卡片一直交不上）：连 Host 的交给 Host，Host 原样转给中转站"""
    import api.routes_patrol as R
    sent = []

    async def fake(relay, body):
        sent.append((relay, body))
        return 400 if body.get("bad") else 200
    monkeypatch.setattr(R, "_relay_feedback", fake)
    e = Env(pool, [])
    t = await e.login()
    async with e.client(t) as c:
        assert (await c.post("/me/feedback", json={"answers": {}})).status_code == 409        # 没开中转
        e.app.state.api.cfg.push_relay = "https://relay.test"
        r = await c.post("/me/feedback", json={"answers": {"problems": "有一点"}})
        assert r.status_code == 200 and r.json() == {"ok": True}
        assert (await c.post("/me/feedback", json={"bad": True})).status_code == 400
    assert sent[0] == ("https://relay.test", {"answers": {"problems": "有一点"}})


async def test_same_phone_keeps_only_newest_relay_device(pool, monkeypatch):
    """每次打开 App 都会再登记一次：同一把加密钥匙只留最新的，不然一条消息推好几遍（10-12）"""
    import api.routes_patrol as R
    n = iter(range(100))

    async def fake(relay, token, sandbox):
        return f"rid{next(n)}", "sec"
    monkeypatch.setattr(R, "_relay_register", fake)
    e = Env(pool, [])
    t = await e.login()
    phone = base64.b64encode(b"k" * 32).decode()
    other = base64.b64encode(b"j" * 32).decode()
    e.app.state.api.cfg.push_relay = "https://relay.test"
    async with e.client(t) as c:
        for _ in range(3):
            await c.post("/me/devices/relay", json={"token": "apns-tok", "push_key": phone})
        await c.post("/me/devices", json={"apns_token": "relay:direct", "relay_secret": "s", "push_key": phone})
        await c.post("/me/devices/relay", json={"token": "ipad-tok", "push_key": other})      # 另一台设备留着
    rows = await pool.fetch("SELECT apns_token, push_key FROM devices ORDER BY apns_token")
    assert [(r["apns_token"], r["push_key"] == phone) for r in rows] == [("relay:direct", True), ("relay:rid3", False)]


async def test_stale_duplicate_devices_get_one_push_and_midway_failure_does_not_resend(pool):
    """10-12 内测「推送还是好几条重复」：①旧版登记出来的同一部手机好几个编号，推的时候只推最新的；
    ②推到一半中转断了，已经推出去的气泡不再整条重推"""
    key = base64.b64encode(b"k" * 32).decode()
    e = Env(pool, ["早呀\n\n醒了没"])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "早"})
        await e.rooms.idle(UUID(conv["id"]))
    acc = await pool.fetchval("SELECT account_id FROM push_queue LIMIT 1")
    for i, rid in enumerate(["old1", "old2", "new"]):          # 绕过登记接口，直接摆出旧版留下的样子
        await pool.execute("INSERT INTO devices (account_id, apns_token, updated_at, relay_secret, push_key) "
                           "VALUES ($1, $2, now() - make_interval(mins => $3), 's', $4)", acc, f"relay:{rid}", 10 - i, key)
    sent = []

    async def transport(url, headers, body):
        if len(sent) == 1:
            raise OSError("relay hiccup")                        # 第二个气泡推的时候断了
        sent.append(json.loads(body)["relay_id"])
        return 200, ""
    import push.apns as A
    A.GAP = 0
    assert await send_pending(pool, None, transport, relay_url="https://relay.test") == 1
    assert sent == ["new"]                                       # 只推最新的那个编号
    assert await send_pending(pool, None, transport, relay_url="https://relay.test") == 0   # 不整条重来


async def _one_queued(pool, reply="好的"):
    key = base64.b64encode(b"k" * 32).decode()
    e = Env(pool, [reply])
    t = await e.login()
    async with e.client(t) as c:
        comp, conv = await e.first_window(c)
        await c.patch(f"/companions/{comp['id']}", json={"settings": {"reply_wait": 0}})
        await c.post("/me/devices", json={"apns_token": "relay:r1", "relay_secret": "s", "push_key": key})
        await c.post(f"/conversations/{conv['id']}/messages", json={"text": "嗯"})
        await e.rooms.idle(UUID(conv["id"]))


async def test_no_reply_from_relay_is_not_resent(pool):
    """10-13 内测「重复了一整个屏幕，还在重复」：请求到了中转、回话没等到（超时）→ 原来整条留着每 3 秒再推一遍。
    现在当它送到了：下一轮不再推"""
    import httpx
    import push.apns as A
    A.GAP = 0
    await _one_queued(pool)
    calls = []

    async def timeout(url, headers, body):
        calls.append(url)
        raise httpx.ReadTimeout("no answer")
    assert await send_pending(pool, None, timeout, relay_url="https://relay.test") == 1
    assert await send_pending(pool, None, timeout, relay_url="https://relay.test") == 0
    assert len(calls) == 1


async def test_cannot_connect_is_retried(pool):
    """连都没连上（请求没出去）：留着下一轮再推，不会重复"""
    import httpx
    import push.apns as A
    A.GAP = 0
    await _one_queued(pool)
    down = True
    calls = []

    async def flaky(url, headers, body):
        calls.append(url)
        if down:
            raise httpx.ConnectError("refused")
        return 200, ""
    assert await send_pending(pool, None, flaky, relay_url="https://relay.test") == 0
    down = False
    assert await send_pending(pool, None, flaky, relay_url="https://relay.test") == 1
    assert len(calls) == 2


async def test_every_bubble_carries_a_collapse_id(pool):
    """10-13 内测「改了好多版还是重复」：不管 Host 为什么又推了一遍（没更新、重启到一半、回话没等到），
    同一条气泡带同一个 apns-collapse-id，手机上只显示一条。中转走 collapse 字段，直连走请求头。"""
    import push.apns as A
    A.GAP = 0
    await _one_queued(pool, "早呀\n\n醒了没")
    qid = await pool.fetchval("SELECT id FROM push_queue")
    await pool.execute("INSERT INTO devices (account_id, apns_token, updated_at) SELECT account_id, 'direct-tok', now() FROM devices")
    sent = []

    async def transport(url, headers, body):
        sent.append((url, headers, json.loads(body)))
        return 200, ""
    assert await send_pending(pool, cfg(), transport, relay_url="https://relay.test") == 1
    relay = [(h, b) for u, h, b in sent if u.endswith("/push")]
    direct = [(h, b) for u, h, b in sent if "/3/device/" in u]
    assert [b["collapse"] for _, b in relay] == [f"{qid}-0", f"{qid}-1"]
    assert [h["apns-collapse-id"] for h, _ in direct] == [f"{qid}-0", f"{qid}-1"]
    assert all("apns-collapse-id" not in h for h, _ in relay)          # 中转那边自己加请求头
