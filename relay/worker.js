// Mele 推送中转（10-04，Mele Host 第四步）。跑在Aporia的 Cloudflare Workers 上；苹果推送钥匙（.p8）只在这里。
//
// POST /register {token, sandbox}  手机登记自己的苹果设备号 → {relay_id, relay_secret}
//                                   （存 KV：relay_id → 设备号 + 口令的哈希；口令原文只给手机，手机交给自己的 Host）
// POST /push {relay_id, sealed, sound, urgent, collapse}  Host 带着口令来推 → 照原样转给苹果
//      collapse（10-13，可选）：同一条气泡每次都带同一个，转成 apns-collapse-id——Host 不小心又推一遍，手机上还是一条。
//      sealed 是 Host 用手机给的钥匙加密的推送内容，这里解不开；手机的通知扩展解开再显示。
//      苹果说这个设备没了（410）→ 删掉登记，回 410，Host 那边也删。
// 来电（10-31，TA 打给你）：手机另外登记一个 VoIP 设备号（/register 带 voip: true）。推给它的走 VoIP 推送
//      （apns-push-type: voip，topic 加 .voip，60 秒过期——没接到的来电过会儿别再响）。苹果规定 App 收到就得马上报来电，
//      所以 VoIP 设备只收 Host 明说 voip: true 的推送，普通消息推不到它身上（推错了 App 会被系统罚）。
//
// 机密（wrangler secret put）：APNS_KEY（.p8 全文）、APNS_KEY_ID、APNS_TEAM_ID。普通变量 TOPIC（包名）。
// KV 绑定：DEVICES。

const enc = new TextEncoder();
const b64url = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const rand = (n) => b64url(crypto.getRandomValues(new Uint8Array(n)));
const sha256 = async (s) => b64url(await crypto.subtle.digest("SHA-256", enc.encode(s)));
const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });

let cachedJwt = null; // [token, issuedAtSeconds]

async function apnsJwt(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwt[1] < 50 * 60) return cachedJwt[0]; // 苹果要 20～60 分钟内换一次，别太勤
  const pem = env.APNS_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = b64url(enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${head}.${claims}`));
  cachedJwt = [`${head}.${claims}.${b64url(sig)}`, now];
  return cachedJwt[0];
}

async function register(req, env) {
  const body = await req.json().catch(() => ({}));
  const token = String(body.token || "");
  if (!/^[0-9a-f]{32,200}$/i.test(token)) return json({ detail: "设备号不对" }, 400);
  const relayId = rand(16);
  const secret = rand(32);
  await env.DEVICES.put(relayId, JSON.stringify({ token, sandbox: !!body.sandbox, voip: !!body.voip, secret: await sha256(secret) }));
  return json({ relay_id: relayId, relay_secret: secret });
}

async function push(req, env) {
  const body = await req.json().catch(() => ({}));
  const raw = await env.DEVICES.get(String(body.relay_id || ""));
  // 找不到不回 410：KV 是最终一致的，刚登记的设备在别的机房可能一分钟内还查不到，回 410 会让 Host 把它删了
  if (!raw) return json({ detail: "没有这个设备" }, 404);
  const dev = JSON.parse(raw);
  const auth = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!auth || (await sha256(auth)) !== dev.secret) return json({ detail: "口令不对" }, 403);
  if (typeof body.sealed !== "string" || body.sealed.length > 3500) return json({ detail: "内容不对" }, 400);
  if (!!dev.voip !== !!body.voip) return json({ detail: dev.voip ? "这是来电设备，只收来电" : "这不是来电设备" }, 400);

  // 锁屏上先放一句占位，通知扩展解开以后换成真的名字和话；解不开就显示这句
  const aps = { alert: { title: "Mele", body: "有一条新消息" }, "mutable-content": 1 };
  if (body.sound) aps.sound = "default";
  if (body.urgent) aps["interruption-level"] = "time-sensitive";
  const host = dev.sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  const headers = dev.voip
    ? {
        authorization: `bearer ${await apnsJwt(env)}`,
        "apns-topic": `${env.TOPIC}.voip`,
        "apns-push-type": "voip",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor(Date.now() / 1000) + 60),
      }
    : {
        authorization: `bearer ${await apnsJwt(env)}`,
        "apns-topic": env.TOPIC,
        "apns-push-type": "alert",
        "apns-priority": "10",
      };
  if (typeof body.collapse === "string" && /^[\w.-]{1,64}$/.test(body.collapse)) headers["apns-collapse-id"] = body.collapse;
  const res = await fetch(`${host}/3/device/${dev.token}`, {
    method: "POST",
    headers,
    body: JSON.stringify(dev.voip ? { sealed: body.sealed } : { aps, sealed: body.sealed }),
  });
  if (res.status === 200) return json({ ok: true });
  const reason = (await res.json().catch(() => ({}))).reason || "";
  if (res.status === 410 || ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].includes(reason)) {
    await env.DEVICES.delete(String(body.relay_id));
    return json({ reason: reason || "Unregistered" }, 410);
  }
  return json({ reason }, res.status >= 500 ? 502 : res.status);
}

// 内测反馈（11-03 Aporia）：App 里用满三天弹的小卡片交上来的。存在同一个 KV 里，键 fb:<时间>:<随机>，
// 读：tools/read_feedback.sh。不带任何能认出人的东西（称呼是用户自己选填的）；同一台手机一小时只收一份（防连点）
async function feedback(req, env) {
  const b = await req.json().catch(() => null);
  if (!b || typeof b.answers !== "object" || !b.answers) return json({ detail: "内容不对" }, 400);
  const s = (v, n) => String(v ?? "").trim().slice(0, n);
  const a = b.answers;
  const item = {
    at: new Date().toISOString(), round: s(b.round, 20), version: s(b.version, 30), mode: s(b.mode, 12),
    days: Math.max(0, Math.min(999, Number(b.days) || 0)), name: s(b.name, 40),
    answers: {
      problems: s(a.problems, 40), problems_note: s(a.problems_note, 2000),
      memory: s(a.memory, 40), memory_note: s(a.memory_note, 2000),
      one_thing: s(a.one_thing, 60), one_thing_note: s(a.one_thing_note, 2000),
      recommend: s(a.recommend, 20),
    },
  };
  if (!item.answers.problems || !item.answers.memory || !(item.answers.one_thing || item.answers.one_thing_note)) {
    return json({ detail: "前三题要答" }, 400);
  }
  const install = s(b.install, 64);
  if (install) {
    const k = `fbi:${install}`;
    if (await env.DEVICES.get(k)) return json({ ok: true, again: true });
    await env.DEVICES.put(k, "1", { expirationTtl: 3600 });
  }
  await env.DEVICES.put(`fb:${item.at}:${rand(4)}`, JSON.stringify(item));
  return json({ ok: true });
}

export default {
  async fetch(req, env) {
    const { pathname } = new URL(req.url);
    if (req.method === "POST" && pathname === "/register") return register(req, env);
    if (req.method === "POST" && pathname === "/push") return push(req, env);
    if (req.method === "POST" && pathname === "/feedback") return feedback(req, env);
    if (req.method === "GET" && pathname === "/") return new Response("Mele push relay\n");
    return json({ detail: "not found" }, 404);
  },
};
