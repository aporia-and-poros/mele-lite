-- 对话存档的表。重复执行安全（IF NOT EXISTS）。每张表都带 user_id。

CREATE TABLE IF NOT EXISTS chat_messages (
  id         BIGSERIAL PRIMARY KEY,
  user_id    UUID        NOT NULL,
  role       TEXT        NOT NULL CHECK (role IN ('user', 'assistant')),
  text       TEXT        NOT NULL,
  thinking   TEXT        NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  rolled     BOOLEAN     NOT NULL DEFAULT FALSE      -- 已卷进账本，不再原样进上下文
);
CREATE INDEX IF NOT EXISTS chat_messages_live_idx ON chat_messages (user_id, id) WHERE NOT rolled;
-- 它这一轮用过的工具，一行一个（09-27：历史里只有说出口的话，它看不见自己调过工具，每轮都以为没记、重记一遍）
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS tools TEXT NOT NULL DEFAULT '';
-- TA 连发的几句（等候区拼成一句给它看）原来是怎么分的，app 按这个还原成几个气泡（09-27 iOS 第 7 步）
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS parts JSONB;
-- 这一轮挂出来的动作卡片（不含不挂的），app 刷新之后还在它那句上面
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS cards JSONB;
-- 这一轮想了多久（毫秒，从开口到说完；10-05 Aporia：App 写「思考了 x 秒」）。早先的消息是 NULL
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS thinking_ms INT;
-- 回复后的心声（10-11）：说完以后它最后写的那几行心里话，App 画成这一轮最后一张小卡片；下一轮接在它那句后面进历史
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS inner_voice TEXT NOT NULL DEFAULT '';
-- 双语气泡（10-15）：跟气泡一一对应的译文（null = 那泡没有）；你的话是翻成 TA 那种语言的版本
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS translations JSONB;
-- 电话（10-31）：{id 通话编号, cut 念到一半被打断, end 挂断那条, seconds, line「📞 通话时长」}；不是电话里的话是 null
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS call JSONB;

CREATE TABLE IF NOT EXISTS ledger_days (           -- 账本：按天存，近的清楚、远的模糊
  user_id    UUID        NOT NULL,
  day        DATE        NOT NULL,
  text       TEXT        NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, day)
);

CREATE TABLE IF NOT EXISTS user_settings (
  user_id    UUID PRIMARY KEY,
  data       JSONB       NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS user_state (             -- 大脑自己记的小账：第几轮、上一轮调了什么、腔调样本……
  user_id    UUID PRIMARY KEY,
  data       JSONB       NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS personas (               -- 每改一次人设存一行，最新的一行就是现在的
  id         BIGSERIAL PRIMARY KEY,
  user_id    UUID        NOT NULL,
  data       JSONB       NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS personas_user_idx ON personas (user_id, id);

CREATE TABLE IF NOT EXISTS turn_logs (              -- 每一轮贴了什么、调了什么、花了多少（调参数用）
  id         BIGSERIAL PRIMARY KEY,
  user_id    UUID        NOT NULL,
  data       JSONB       NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS turn_logs_user_idx ON turn_logs (user_id, id);

CREATE TABLE IF NOT EXISTS usage_daily (            -- 用量账：按人、按天、按模型
  user_id            UUID   NOT NULL,
  day                DATE   NOT NULL,
  model              TEXT   NOT NULL,
  calls              INT    NOT NULL DEFAULT 0,
  input              BIGINT NOT NULL DEFAULT 0,
  cache_read         BIGINT NOT NULL DEFAULT 0,
  cache_write        BIGINT NOT NULL DEFAULT 0,
  output             BIGINT NOT NULL DEFAULT 0,
  cost_usd           DOUBLE PRECISION NOT NULL DEFAULT 0,
  unknown_cost_calls INT    NOT NULL DEFAULT 0,        -- 清单外的模型算不出钱的次数
  PRIMARY KEY (user_id, day, model)
);

-- 账号 + 联系人 + 窗口（2026-09-27）。上面那些表的 user_id 栏现在当「主人」用，见 brain/scope.py：
-- 人物卡、钥匙串、用量归账号；记忆、关于 TA、便利贴、人设、设置归联系人；聊天、账本、状态、每轮日志归窗口。
CREATE TABLE IF NOT EXISTS accounts (
  id         UUID        PRIMARY KEY,
  plan       TEXT        NOT NULL DEFAULT 'trial' CHECK (plan IN ('trial', 'byok', 'member')),
  trial_left INT         NOT NULL DEFAULT 30,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS companions (          -- 联系人：一个 AI
  id         UUID        PRIMARY KEY,
  account_id UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  sort       INT         NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS companions_account_idx ON companions (account_id);
ALTER TABLE companions ADD COLUMN IF NOT EXISTS avatar_ver INT NOT NULL DEFAULT 0;  -- 头像版本号（手机按它缓存；0 = 没传过）

CREATE TABLE IF NOT EXISTS conversations (       -- 窗口：一个联系人底下的一段对话
  id           UUID        PRIMARY KEY,
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  incognito    BOOLEAN     NOT NULL DEFAULT FALSE,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS conversations_companion_idx ON conversations (companion_id, last_at DESC);
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS title TEXT NOT NULL DEFAULT '';   -- 窗口名（空 = app 用第一句）

-- 倒回用的记账（2026-09-27）：它每次写记忆 / 关于 TA / 人物卡 / 便利贴，记一笔「哪个窗口的哪一轮、改之前是什么」。
-- before 为空 = 这一轮新建的，倒回时删掉；有值 = 恢复成这个样子。
CREATE TABLE IF NOT EXISTS memory_edits (
  id              BIGSERIAL   PRIMARY KEY,
  conversation_id UUID        NOT NULL,
  turn_msg        BIGINT      NOT NULL,            -- 这一轮用户那句的消息 id
  kind            TEXT        NOT NULL CHECK (kind IN ('memory', 'person', 'sticky')),
  owner           UUID        NOT NULL,            -- 记在谁名下（联系人或账号）
  memory_id       BIGINT,
  before          JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS memory_edits_conv_idx ON memory_edits (conversation_id, turn_msg);

-- 登录、钥匙串、试用（2026-09-27，第二块中第 3 步）
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS email TEXT UNIQUE;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS apple_sub TEXT UNIQUE;

CREATE TABLE IF NOT EXISTS login_codes (            -- 邮箱验证码：只存哈希，10 分钟过期，最多试 5 次
  email      TEXT        PRIMARY KEY,
  code_hash  TEXT        NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  sent_at    TIMESTAMPTZ NOT NULL,
  attempts   INT         NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS sessions (               -- 登录凭证：只存哈希，手机上存原文
  token_hash TEXT        PRIMARY KEY,
  account_id UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS keyring (                -- 钥匙串：用户的 key 加密后存，主密钥只在服务器环境变量里
  id         UUID        PRIMARY KEY,
  account_id UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  provider   TEXT        NOT NULL,
  chat_model TEXT        NOT NULL,
  base_url   TEXT,
  secret     BYTEA       NOT NULL,
  last4      TEXT        NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS trial_micro BIGINT;   -- 免费额度剩多少（微美元）；NULL = 还没发过礼包（09-28）
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS trial_day DATE;        -- 上次按天补的那天（用户时区、早上 5 点换日）
ALTER TABLE companions ADD COLUMN IF NOT EXISTS key_id UUID REFERENCES keyring(id) ON DELETE SET NULL;
ALTER TABLE keyring ADD COLUMN IF NOT EXISTS ledger_model TEXT;   -- 后台模型（写账本、压旧天）；空 = 照模型清单，清单里没有就用聊天那个（10-13 内测）

CREATE TABLE IF NOT EXISTS trial_devices (          -- 一台手机只给一次试用（存设备标记的哈希）
  device_hash TEXT        PRIMARY KEY,
  account_id  UUID        NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 我的设定（2026-09-27，第 4 步）：用户自己的名字、指代、外貌，先存账号级一份，改的时候写进每个联系人的设置
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS profile JSONB NOT NULL DEFAULT '{}'::jsonb;

-- 巡逻（2026-09-27，第二块下）：钟、醒来账、推送队列、设备、专注。设计见 specs/2026-09-27-patrol-design.md
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS last_active_at TIMESTAMPTZ;   -- app 上次报「在」

CREATE TABLE IF NOT EXISTS clocks (                 -- 你定的（user）/ 它约的（self，TA 看不见）/ 心跳（heartbeat，每个联系人一行）
  id           BIGSERIAL   PRIMARY KEY,
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  kind         TEXT        NOT NULL CHECK (kind IN ('user', 'self', 'heartbeat')),
  shape        TEXT        NOT NULL CHECK (shape IN ('at', 'once', 'every', 'window', 'heartbeat')),
  spec         JSONB       NOT NULL DEFAULT '{}'::jsonb,
  note         TEXT        NOT NULL DEFAULT '',
  next_at      TIMESTAMPTZ,                          -- 下次响 / 下次看门；空 = 不响了
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS clocks_due_idx ON clocks (next_at) WHERE next_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS clocks_companion_idx ON clocks (companion_id, kind);
CREATE UNIQUE INDEX IF NOT EXISTS clocks_one_heartbeat ON clocks (companion_id) WHERE kind = 'heartbeat';

CREATE TABLE IF NOT EXISTS wake_log (               -- 醒来账：每次醒（或该醒没醒成）一行
  id              BIGSERIAL   PRIMARY KEY,
  account_id      UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id    UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  conversation_id UUID,
  at              TIMESTAMPTZ NOT NULL,
  reason          TEXT        NOT NULL,              -- whim / night_awake / asleep / user / self
  clock_id        BIGINT,
  outcome         TEXT        NOT NULL CHECK (outcome IN ('said', 'silent', 'skipped_cap', 'skipped_busy', 'error', 'no_key')),
  cost_usd        DOUBLE PRECISION NOT NULL DEFAULT 0,
  detail          JSONB       NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS wake_log_companion_idx ON wake_log (companion_id, at DESC);
ALTER TABLE wake_log ADD COLUMN IF NOT EXISTS message_id BIGINT;   -- 开口那次它那句的消息号（自唤醒页放原话，09-28）

CREATE TABLE IF NOT EXISTS push_queue (             -- 要推给手机的（真发等 app 接上 APNs）
  id              BIGSERIAL   PRIMARY KEY,
  account_id      UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id    UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  conversation_id UUID        NOT NULL,
  text            TEXT        NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at         TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS devices (                -- 推送用的设备号
  account_id  UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  apns_token  TEXT        NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, apns_token)
);

CREATE TABLE IF NOT EXISTS focus_sessions (         -- 哨兵：一次专注（手机那半等 app）
  id                 UUID        PRIMARY KEY,
  account_id         UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id       UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  conversation_id    UUID        NOT NULL,
  label              TEXT        NOT NULL DEFAULT '',
  minutes            INT         NOT NULL,
  lines              JSONB       NOT NULL DEFAULT '[]'::jsonb,
  started_at         TIMESTAMPTZ NOT NULL,
  ended_at           TIMESTAMPTZ,
  distracted_times   INT,
  distracted_minutes INT,
  told               BOOLEAN     NOT NULL DEFAULT FALSE   -- 结果已经在聊天里告诉它了
);

-- 巡逻（09-27）：聊天记录多一种角色 wake（叫醒它的〔醒来〕小字，app 不显示，历史里当用户那侧）；
-- 倒回记账多一种 clock（这一轮它定的提醒 / 自己约的，倒回时一起撤）
ALTER TABLE chat_messages DROP CONSTRAINT IF EXISTS chat_messages_role_check;
ALTER TABLE chat_messages ADD CONSTRAINT chat_messages_role_check CHECK (role IN ('user', 'assistant', 'wake'));
ALTER TABLE memory_edits DROP CONSTRAINT IF EXISTS memory_edits_kind_check;
ALTER TABLE memory_edits ADD CONSTRAINT memory_edits_kind_check CHECK (kind IN ('memory', 'person', 'sticky', 'clock', 'far_date', 'drawer', 'lore', 'todo', 'milestone'));  -- 09-30：每处都写全，旧写法遇到新类型的行会整份建表失败

-- 标记表情（2026-09-27，iOS 第一块）：TA 给它的一句点个 ❤️；下一轮易变区告诉它一次（told）
CREATE TABLE IF NOT EXISTS reactions (
  message_id      BIGINT      PRIMARY KEY REFERENCES chat_messages(id) ON DELETE CASCADE,
  conversation_id UUID        NOT NULL,
  emoji           TEXT        NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  told            BOOLEAN     NOT NULL DEFAULT FALSE
);
CREATE INDEX IF NOT EXISTS reactions_conv_idx ON reactions (conversation_id) WHERE NOT told;
-- 10-11：一条拆成几个气泡，表情按气泡记（bubble = 第几泡；-1 = 老的整条记的，画在最后一泡）；quote = 点的那泡原话（告诉它用）
ALTER TABLE reactions ADD COLUMN IF NOT EXISTS bubble INT NOT NULL DEFAULT -1;
ALTER TABLE reactions ADD COLUMN IF NOT EXISTS quote TEXT NOT NULL DEFAULT '';
ALTER TABLE reactions DROP CONSTRAINT IF EXISTS reactions_pkey;
ALTER TABLE reactions ADD CONSTRAINT reactions_pkey PRIMARY KEY (message_id, bubble);

-- 附件（2026-09-27，iOS 第一块）：TA 发的照片和文件。上传时 message_id 空，发消息那一轮挂到 TA 那句上
CREATE TABLE IF NOT EXISTS attachments (
  id              UUID        PRIMARY KEY,
  account_id      UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  conversation_id UUID        NOT NULL,
  message_id      BIGINT,
  kind            TEXT        NOT NULL CHECK (kind IN ('image', 'file')),
  name            TEXT        NOT NULL DEFAULT '',
  mime            TEXT        NOT NULL,
  size            INT         NOT NULL,
  path            TEXT        NOT NULL,
  text            TEXT        NOT NULL DEFAULT '',     -- 文件抽出的字
  caption         TEXT        NOT NULL DEFAULT '',     -- 图片的描述
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS attachments_message_idx ON attachments (message_id);
ALTER TABLE attachments ADD COLUMN IF NOT EXISTS caption_source TEXT NOT NULL DEFAULT '';   -- chat / key / ours：谁写的描述（ours 按天限量）

-- TA 那边（09-28）：手机报上来的天气 / 位置 / 日历 / 健康 + 快捷指令，每样只存最新一份
CREATE TABLE IF NOT EXISTS account_context (
  account_id UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind       TEXT        NOT NULL,
  data       JSONB       NOT NULL,
  at         TIMESTAMPTZ NOT NULL,
  PRIMARY KEY (account_id, kind)
);
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS hook_hash TEXT UNIQUE;   -- 快捷指令口令的哈希（按它认人）
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS hook_box BYTEA;          -- 口令加密存一份，Me 里能再看到
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS lore_every INT;
ALTER TABLE accounts ADD COLUMN IF NOT EXISTS media JSONB NOT NULL DEFAULT '{}'::jsonb;   -- 看图 / 画图挑哪把钥匙（brain/media.py，10-15）            -- 世界书「偶尔想起」隔几轮抽一条（NULL = 缺省 4，10-15）

-- 记着的远事（09-28）：有日子、还远、要一路惦记着的事。TA 看得见能改；了结了存成一条记忆、从清单拿掉
CREATE TABLE IF NOT EXISTS far_dates (
  id           BIGSERIAL   PRIMARY KEY,
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  day          DATE        NOT NULL,
  at_time      TEXT        NOT NULL DEFAULT '',        -- 'HH:MM' 或空
  title        TEXT        NOT NULL,
  note         TEXT        NOT NULL DEFAULT '',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at  TIMESTAMPTZ,
  result       TEXT        NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS far_dates_open_idx ON far_dates (companion_id, day) WHERE resolved_at IS NULL;
-- 远事的三次醒来存成 kind='date' 的一次性钟（spec 带 date_id、phase）
ALTER TABLE clocks DROP CONSTRAINT IF EXISTS clocks_kind_check;
ALTER TABLE clocks ADD CONSTRAINT clocks_kind_check CHECK (kind IN ('user', 'self', 'heartbeat', 'date', 'meal', 'picks', 'morning', 'diary', 'todo'));   -- meal：记一餐说一句；picks：每日私选（09-30）；morning：起床前（10-01）
-- 倒回记账：加远事、抽屉的信（09-28）
ALTER TABLE memory_edits DROP CONSTRAINT IF EXISTS memory_edits_kind_check;
ALTER TABLE memory_edits ADD CONSTRAINT memory_edits_kind_check
  CHECK (kind IN ('memory', 'person', 'sticky', 'clock', 'far_date', 'drawer', 'lore', 'todo', 'milestone'));

-- 抽屉（09-28）：一个账号一个抽屉，装着所有联系人写给 TA 的信。TA 只看得见信封；到日子或者输对它给的 4 位密码才能拆
CREATE TABLE IF NOT EXISTS drawer_letters (
  id                BIGSERIAL   PRIMARY KEY,
  account_id        UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id      UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  title             TEXT        NOT NULL DEFAULT '',
  content           TEXT        NOT NULL,
  unlock_at         DATE,                                -- 空 = 只能靠钥匙开
  code              TEXT        NOT NULL DEFAULT '',     -- 它第一次给钥匙时生成
  code_fails        INT         NOT NULL DEFAULT 0,
  code_locked_until TIMESTAMPTZ,
  keyed_at          TIMESTAMPTZ,
  opened_at         TIMESTAMPTZ,
  notified_at       TIMESTAMPTZ,                         -- 解锁日推送排过了
  told_opened       BOOLEAN     NOT NULL DEFAULT FALSE,  -- 「TA 拆了」告诉过它了
  burned_at         TIMESTAMPTZ,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS drawer_letters_account_idx ON drawer_letters (account_id, created_at DESC) WHERE burned_at IS NULL;
CREATE INDEX IF NOT EXISTS drawer_letters_companion_idx ON drawer_letters (companion_id) WHERE burned_at IS NULL;
ALTER TABLE push_queue ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'chat';   -- chat / drawer（09-28）
ALTER TABLE focus_sessions ADD COLUMN IF NOT EXISTS early BOOLEAN NOT NULL DEFAULT FALSE;   -- 提前结束的（09-29）
CREATE TABLE IF NOT EXISTS focus_said (             -- 专注时手机替它弹过的话（提醒 / 「我就看一下」那句），回到 app 报上来进聊天（09-29）
  focus_id   UUID NOT NULL REFERENCES focus_sessions(id) ON DELETE CASCADE,
  key        TEXT NOT NULL,                          -- 手机给的：t1..t5 / peek-<时间>；同一条只存一次
  message_id BIGINT,
  PRIMARY KEY (focus_id, key)
);
DROP TABLE IF EXISTS live_activities;          -- 灵动岛 10-02 拿掉了（Aporia决定不用）

-- 饮食（09-29）：记在账号名下，不分联系人
ALTER TABLE attachments ALTER COLUMN conversation_id DROP NOT NULL;   -- 饮食照片不挂在哪个窗口
CREATE TABLE IF NOT EXISTS food_entries (
  id          BIGSERIAL   PRIMARY KEY,
  account_id  UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  day         DATE        NOT NULL,
  meal        TEXT        NOT NULL,                     -- 早餐 / 午餐 / 晚餐 / 加餐 / 运动
  text        TEXT        NOT NULL,
  detail      TEXT        NOT NULL DEFAULT '',
  portion     TEXT        NOT NULL DEFAULT '',
  kcal        REAL, protein REAL, carbs REAL, fat REAL,
  status      TEXT        NOT NULL DEFAULT 'pending',   -- pending 待估 / estimated 估好 / manual 手填 / failed 没估出来
  note        TEXT        NOT NULL DEFAULT '',          -- 估算的一句话，或者为什么还没估
  source      TEXT        NOT NULL DEFAULT 'app',       -- app / lumi / watch
  ext_id      TEXT,                                     -- 手表导入的去重号
  told        BOOLEAN     NOT NULL DEFAULT TRUE,        -- 〔饮食〕告诉过它了（刚记 / 刚估好时置 false）
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS food_entries_day_idx ON food_entries (account_id, day);
ALTER TABLE food_entries ADD COLUMN IF NOT EXISTS est_kcal REAL;                        -- TA 手改之前模型估的数（09-30：下次估算当参考）
ALTER TABLE food_entries ADD COLUMN IF NOT EXISTS est_portion TEXT NOT NULL DEFAULT '';
ALTER TABLE food_entries ADD COLUMN IF NOT EXISTS remarked BOOLEAN NOT NULL DEFAULT TRUE;     -- FALSE = TA 在饮食页刚记、Lumi 还没说那一句（09-30）
CREATE UNIQUE INDEX IF NOT EXISTS food_entries_ext_idx ON food_entries (account_id, ext_id) WHERE ext_id IS NOT NULL;
CREATE TABLE IF NOT EXISTS food_photos (              -- 一餐的照片不限张数（Aporia 09-29）
  entry_id      BIGINT NOT NULL REFERENCES food_entries(id) ON DELETE CASCADE,
  attachment_id UUID   NOT NULL,
  pos           INT    NOT NULL,
  PRIMARY KEY (entry_id, attachment_id)
);
CREATE TABLE IF NOT EXISTS food_settings (
  account_id UUID  PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  data       JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE TABLE IF NOT EXISTS food_covers (
  account_id    UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  day           DATE NOT NULL,
  attachment_id UUID NOT NULL,
  PRIMARY KEY (account_id, day)
);
CREATE TABLE IF NOT EXISTS food_deleted_ext (         -- 删掉的手表条目不再导回
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  ext_id     TEXT NOT NULL,
  PRIMARY KEY (account_id, ext_id)
);

-- 音乐（09-30，plans/2026-09-30-music.md 第 3 步）。用户凭证用钥匙串主密钥加密（KeyBox），不导出。
CREATE TABLE IF NOT EXISTS music_links (
  account_id UUID        PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  platform   TEXT        NOT NULL DEFAULT 'apple',        -- apple / netease / qq / spotify / other
  user_token BYTEA,                                       -- Apple Music 用户凭证（加密）；别的平台为空
  storefront TEXT        NOT NULL DEFAULT '',
  linked_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS music_shelf (                -- 歌单：它分享过的、私选里的
  id         BIGSERIAL   PRIMARY KEY,
  account_id UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  song_id    TEXT        NOT NULL,
  name       TEXT        NOT NULL, artist TEXT NOT NULL DEFAULT '', artwork TEXT NOT NULL DEFAULT '',
  preview    TEXT        NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '',
  source     TEXT        NOT NULL DEFAULT 'share',        -- share / pick
  why        TEXT        NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, song_id)
);
CREATE TABLE IF NOT EXISTS music_picks (                -- 每日私选
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  day        DATE NOT NULL,
  pos        INT  NOT NULL,
  song_id    TEXT NOT NULL,
  name       TEXT NOT NULL, artist TEXT NOT NULL DEFAULT '', artwork TEXT NOT NULL DEFAULT '',
  preview    TEXT NOT NULL DEFAULT '', url TEXT NOT NULL DEFAULT '',
  why        TEXT NOT NULL DEFAULT '',
  vote       TEXT NOT NULL DEFAULT '',                    -- up / meh / down / 空
  stars      INT  NOT NULL DEFAULT 0,
  reason     TEXT NOT NULL DEFAULT '',
  PRIMARY KEY (account_id, day, pos)
);
CREATE TABLE IF NOT EXISTS music_votes (                -- 歌手净分（照之前自用的 App：5 星加倍、一首歌拉黑不了歌手）
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  artist     TEXT NOT NULL,                             -- 小写
  score      INT  NOT NULL,
  PRIMARY KEY (account_id, artist)
);
CREATE TABLE IF NOT EXISTS music_heard (                -- 听过的（私选不推）
  account_id UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  song_key   TEXT        NOT NULL,
  last_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, song_key)
);
CREATE TABLE IF NOT EXISTS music_pools (                -- 每日私选的候选池（程序找的真歌，Lumi 只能从这里挑）
  account_id UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  day        DATE        NOT NULL,
  pool       JSONB       NOT NULL,
  seeds      JSONB       NOT NULL DEFAULT '{}'::jsonb,
  built_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, day)
);
ALTER TABLE music_links ADD COLUMN IF NOT EXISTS picks_n  INT  NOT NULL DEFAULT 3;    -- 每天几首（0 = 不推）
ALTER TABLE music_links ADD COLUMN IF NOT EXISTS picks_at TEXT NOT NULL DEFAULT '';   -- 几点推（空 = 起床后半小时）
ALTER TABLE music_links ADD COLUMN IF NOT EXISTS lyrics   BOOLEAN NOT NULL DEFAULT FALSE; -- Host 上要不要去 lrclib 拿歌词（10-05，主人自己开）

-- 耳朵（09-30，plans/2026-09-30-ears.md）：一首歌只听一次，全服务器共用（不是谁的私人数据，只有歌本身的信息）。
CREATE TABLE IF NOT EXISTS song_ears (
  song_id       TEXT        PRIMARY KEY,                -- Apple Music 歌曲编号
  name          TEXT        NOT NULL DEFAULT '',
  artist        TEXT        NOT NULL DEFAULT '',
  duration_s    INT         NOT NULL DEFAULT 0,
  numbers       JSONB,                                  -- librosa 量出来的（music/ears_numbers.py）
  impression    JSONB       NOT NULL DEFAULT '{}'::jsonb, -- Gemini 的听感，按语言 {"zh": "…"}
  lyrics        JSONB       NOT NULL DEFAULT '[]'::jsonb, -- 带时间的歌词 [{t, line}]，只给 Lumi，不给用户看
  lyrics_source TEXT        NOT NULL DEFAULT '',
  status        TEXT        NOT NULL DEFAULT 'ok',      -- ok / failed（失败 6 小时后再放再试）
  heard_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 世界书（09-30，plans/2026-09-30-worldbook.md）：提到了才翻开的小词典——密语、网络梗、世界观。按账号存；
-- companion_id 空 = 所有联系人都知道。TA 和它都能写（created_by），它改不动 TA 写的。
CREATE TABLE IF NOT EXISTS lore (
  id           BIGSERIAL   PRIMARY KEY,
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id UUID        REFERENCES companions(id) ON DELETE CASCADE,
  name         TEXT        NOT NULL,
  keywords     TEXT[]      NOT NULL,
  content      TEXT        NOT NULL,
  created_by   TEXT        NOT NULL CHECK (created_by IN ('user', 'ai')),
  enabled      BOOLEAN     NOT NULL DEFAULT true,
  constant     BOOLEAN     NOT NULL DEFAULT false,     -- 常驻：每轮都在、进底子吃缓存（导入的角色卡用）
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS lore_account_idx ON lore (account_id);
-- 世界书也能倒回（09-30）
ALTER TABLE memory_edits DROP CONSTRAINT IF EXISTS memory_edits_kind_check;
ALTER TABLE memory_edits ADD CONSTRAINT memory_edits_kind_check
  CHECK (kind IN ('memory', 'person', 'sticky', 'clock', 'far_date', 'drawer', 'lore', 'todo', 'milestone'));

-- 分轻重的推送（09-30，Instinct 借的，Aporia要）：TA 定的钟、远事当天那次用 iOS「时效性通知」，开了勿扰也能收到
ALTER TABLE push_queue ADD COLUMN IF NOT EXISTS urgent BOOLEAN NOT NULL DEFAULT false;

-- 起床前醒来准备（10-01）：早上的钟；静音推送（不吵醒 TA）
ALTER TABLE clocks DROP CONSTRAINT IF EXISTS clocks_kind_check;
ALTER TABLE clocks ADD CONSTRAINT clocks_kind_check CHECK (kind IN ('user', 'self', 'heartbeat', 'date', 'meal', 'picks', 'morning', 'diary', 'todo'));
ALTER TABLE push_queue ADD COLUMN IF NOT EXISTS quiet BOOLEAN NOT NULL DEFAULT false;

-- 人物卡「对谁隐藏」（10-01，Aporia 09-29 提的）：选中的联系人翻不到这张卡，也不自动递给它。卡本身在 memories（kind='person'，账号名下）
CREATE TABLE IF NOT EXISTS person_hidden (
  person_id    BIGINT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
  companion_id UUID   NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  PRIMARY KEY (person_id, companion_id)
);

-- 日记（10-01，Aporia点头，设计 specs/2026-10-01-diary-design.md）：两本。Ta 的（author=companion，一天一篇，正文 + 锁着的一段，
-- 锁着那段 TA 拿钥匙才看得到）；TA 的（author=user，能整篇锁起来不给 Ta 读，Ta 在页边留一句批注）。TA 的永远不进记忆库。
CREATE TABLE IF NOT EXISTS diaries (
  id                BIGSERIAL   PRIMARY KEY,
  account_id        UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id      UUID        REFERENCES companions(id) ON DELETE CASCADE,       -- Ta 写的才有
  author            TEXT        NOT NULL CHECK (author IN ('companion', 'user')),
  day               DATE        NOT NULL,
  body              TEXT        NOT NULL,
  locked            TEXT        NOT NULL DEFAULT '',     -- Ta 的：还不想让 TA 看的那一段
  private           BOOLEAN     NOT NULL DEFAULT FALSE,  -- TA 的：锁起来，Ta 读不到
  margin            TEXT        NOT NULL DEFAULT '',     -- TA 的：Ta 的页边批注
  margin_by         UUID        REFERENCES companions(id) ON DELETE SET NULL,
  margin_at         TIMESTAMPTZ,
  code              TEXT        NOT NULL DEFAULT '',     -- 锁着那段的钥匙，Ta 第一次给时生成
  code_fails        INT         NOT NULL DEFAULT 0,
  code_locked_until TIMESTAMPTZ,
  keyed_at          TIMESTAMPTZ,
  unlocked_at       TIMESTAMPTZ,
  told_unlocked     BOOLEAN     NOT NULL DEFAULT FALSE,  -- 「TA 用钥匙打开了」告诉过 Ta 了
  memory_id         BIGINT      REFERENCES memories(id) ON DELETE SET NULL,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- 日记的钟（kind='diary'）：clocks_kind_check 上面两处都加了 diary
CREATE UNIQUE INDEX IF NOT EXISTS diaries_one_a_day ON diaries (companion_id, day) WHERE author = 'companion';
CREATE INDEX IF NOT EXISTS diaries_account_idx ON diaries (account_id, day DESC, id DESC);

-- 待办（10-01 Aporia，设计 specs/2026-10-01-todo-design.md）：做什么 / 什么时候 / 在哪（到了或离开）。
-- 有时间的挂一行 clocks（kind='todo'，todo_id）；地点进出时插一行一次性的 todo 钟。「你定的钟」收编进来（kind 'user' → 'todo'）。
CREATE TABLE IF NOT EXISTS places (                  -- 常去的地方（每个账号最多 20 个：iOS 同时只盯得住 20 个围栏）
  id          BIGSERIAL   PRIMARY KEY,
  account_id  UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name        TEXT        NOT NULL,
  lat         DOUBLE PRECISION NOT NULL,
  lon         DOUBLE PRECISION NOT NULL,
  radius      INT         NOT NULL DEFAULT 150,      -- 米
  inside      BOOLEAN,                               -- 手机最后报的：在不在里面（空 = 还不知道）
  state_at    TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS places_account_idx ON places (account_id);
CREATE TABLE IF NOT EXISTS todos (
  id            BIGSERIAL   PRIMARY KEY,
  account_id    UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id  UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,   -- 谁来提醒
  what          TEXT        NOT NULL,
  shape         TEXT,                                -- 空 = 没填时间；once / at（每天或每周几）；收编的老钟可能是 every / window
  spec          JSONB       NOT NULL DEFAULT '{}',
  place_id      BIGINT      REFERENCES places(id) ON DELETE SET NULL,
  place_on      TEXT        CHECK (place_on IN ('arrive', 'leave')),
  done_on       DATE,                                -- 打勾那天（TA 的时区）：一次性 = 做完；每天 = 今天；每周 = 这周
  waiting_until TIMESTAMPTZ,                         -- 到点了人不在那儿：等进出到这个时候（当天结束）
  reminded_at   TIMESTAMPTZ,                         -- 上次提醒（地点触发 30 分钟内不重复）
  created_by    TEXT        NOT NULL DEFAULT 'user', -- user / ai
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS todos_account_idx ON todos (account_id);
CREATE INDEX IF NOT EXISTS todos_place_idx ON todos (place_id) WHERE place_id IS NOT NULL;
ALTER TABLE clocks ADD COLUMN IF NOT EXISTS todo_id BIGINT REFERENCES todos(id) ON DELETE CASCADE;

-- 同一张图只读一次（10-01 Aporia）：附件记原始字节的指纹；描述按账号 + 指纹 + 语言存一份，重发 / 转发同一张直接用（不跨账号）
ALTER TABLE attachments ADD COLUMN IF NOT EXISTS sha TEXT NOT NULL DEFAULT '';
CREATE TABLE IF NOT EXISTS image_captions (
  account_id  UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  sha         TEXT        NOT NULL,
  lang        TEXT        NOT NULL,
  caption     TEXT        NOT NULL,
  source      TEXT        NOT NULL DEFAULT '',
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, sha, lang)
);

-- 表情包库（10-01 Aporia，设计 specs/2026-10-01-stickers-design.md）：一个账号一个库，所有联系人共用，only_for 空 = 都能用
CREATE TABLE IF NOT EXISTS stickers (
  id           BIGSERIAL   PRIMARY KEY,
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  sha          TEXT        NOT NULL,                  -- 原始字节的指纹：同一张不重复收
  path         TEXT        NOT NULL,
  mime         TEXT        NOT NULL,
  size         INT         NOT NULL,
  caption      TEXT        NOT NULL DEFAULT '',       -- 看图模型写的，TA 能改
  name         TEXT        NOT NULL DEFAULT '',       -- TA 起的名字
  only_for     UUID[]      NOT NULL DEFAULT '{}',     -- 只给这几个联系人用；空 = 都行
  embedding    vector(1024),
  use_count    INT         NOT NULL DEFAULT 0,
  last_used_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, sha)
);
ALTER TABLE attachments ADD COLUMN IF NOT EXISTS sticker_id BIGINT;      -- TA 从面板发的表情包（复制出来的那份附件）

-- 思考链翻译（10-01 Aporia：Claude 用英文想，App 上点「翻译」）：一条消息翻一次存一份
CREATE TABLE IF NOT EXISTS thinking_translations (
  message_id  BIGINT      NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  lang        TEXT        NOT NULL,
  text        TEXT        NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (message_id, lang)
);

-- 朋友圈（10-01 Aporia，设计 specs/2026-10-01-moments-design.md，移植自之前自用的 App）。author / who：'user' = TA，否则是联系人编号（文本）
CREATE TABLE IF NOT EXISTS moments (
  id            BIGSERIAL   PRIMARY KEY,
  account_id    UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  author        TEXT        NOT NULL,
  content       TEXT        NOT NULL DEFAULT '',
  context_note  TEXT        NOT NULL DEFAULT '',     -- 它发的时候 TA 看不到的备注：为什么发、当时在聊什么
  images        JSONB       NOT NULL DEFAULT '[]',   -- [{path, mime, sha}]
  image_desc    TEXT        NOT NULL DEFAULT '',     -- 图只看一次：描述
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS moments_account_idx ON moments (account_id, id DESC);
CREATE TABLE IF NOT EXISTS moment_likes (
  moment_id   BIGINT      NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
  who         TEXT        NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (moment_id, who)
);
CREATE TABLE IF NOT EXISTS moment_comments (
  id          BIGSERIAL   PRIMARY KEY,
  moment_id   BIGINT      NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
  author      TEXT        NOT NULL,
  content     TEXT        NOT NULL,
  reply_to    BIGINT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS moment_comments_moment_idx ON moment_comments (moment_id, id);
-- 长按「翻译」（10-23 内测，像微信）：{译成什么: 译文}，翻一次存一份
ALTER TABLE moments ADD COLUMN IF NOT EXISTS translations JSONB;
ALTER TABLE moment_comments ADD COLUMN IF NOT EXISTS translations JSONB;
CREATE TABLE IF NOT EXISTS moment_visits (            -- 到点让某个联系人来刷一条 / 回一条评论
  id            BIGSERIAL   PRIMARY KEY,
  account_id    UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id  UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  moment_id     BIGINT      NOT NULL REFERENCES moments(id) ON DELETE CASCADE,
  comment_id    BIGINT,                              -- 空 = 刷到这条新动态；有 = 回这条评论
  peer          BOOLEAN     NOT NULL DEFAULT FALSE,  -- 联系人之间引出来的（只给付费用户）
  round         INT         NOT NULL DEFAULT 0,      -- 联系人之间来回第几轮（最多 2）
  due_at        TIMESTAMPTZ NOT NULL,
  status        TEXT        NOT NULL DEFAULT 'pending',   -- pending / done / skipped / error
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS moment_visits_due_idx ON moment_visits (due_at) WHERE status = 'pending';
CREATE TABLE IF NOT EXISTS moment_profiles (          -- 签名、封面（TA 的和每个联系人的）
  account_id  UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  who         TEXT        NOT NULL,
  signature   TEXT        NOT NULL DEFAULT '',
  cover_path  TEXT        NOT NULL DEFAULT '',
  PRIMARY KEY (account_id, who)
);

-- 收藏夹（10-02，移植自之前自用的 App）：长按一个气泡收藏、多选收成一组。原话整个存一份——窗口删了、倒回了，收藏还在
CREATE TABLE IF NOT EXISTS favorites (
  id              BIGSERIAL   PRIMARY KEY,
  account_id      UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id    UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  conversation_id UUID        NOT NULL,                -- 不挂外键：窗口删了收藏留着，只是跳不回去
  message_id      BIGINT      NOT NULL,
  slot            INT         NOT NULL,                -- 那条消息的第几个气泡（app 的行号槽位）
  mine            BOOLEAN     NOT NULL,                -- TA 说的 / 它说的
  text            TEXT        NOT NULL DEFAULT '',
  files           JSONB       NOT NULL DEFAULT '[]',   -- 那条带的图 / 文件（public() 那份）
  group_id        UUID,                                -- 多选收成一组的共用一个
  said_at         TIMESTAMPTZ NOT NULL,
  saved_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, message_id, slot)
);
CREATE INDEX IF NOT EXISTS favorites_account_idx ON favorites (account_id, saved_at DESC);

-- 相册（10-02，照之前自用的 App photo_memories）：进相册要经它的手——聊天里的图它收了才进；TA 自己加的进来就在，它一小轮看完写字。
-- 照片单独存一份（files_dir/album/），聊天倒回、窗口删了也还在
CREATE TABLE IF NOT EXISTS album_photos (
  id           BIGSERIAL   PRIMARY KEY,
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,   -- 谁收的 / 给谁看的
  sha          TEXT        NOT NULL,
  path         TEXT        NOT NULL,
  source       TEXT        NOT NULL DEFAULT 'chat',     -- chat：它从聊天里收的；mine：TA 自己加的
  taken_at     TIMESTAMPTZ NOT NULL,                    -- 按它分月：聊天里那张 = TA 发的时候；TA 加的 = 加的时候
  caption      TEXT        NOT NULL DEFAULT '',         -- 这是哪一刻（它写）
  felt         TEXT        NOT NULL DEFAULT '',         -- 看见的第一下
  why          TEXT        NOT NULL DEFAULT '',         -- 为什么留
  thoughts     TEXT        NOT NULL DEFAULT '',         -- 观后感
  note         TEXT        NOT NULL DEFAULT '',         -- TA 加照片时写的话
  batch        TEXT        NOT NULL DEFAULT '',         -- TA 一次加的一组
  starred      BOOLEAN     NOT NULL DEFAULT FALSE,
  secret       BOOLEAN     NOT NULL DEFAULT FALSE,      -- 隐私那本：默认一律不给，要明着要才给
  look_status  TEXT        NOT NULL DEFAULT '',         -- '' / pending（等它看）/ asked（看着）/ done
  look_due     TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (account_id, companion_id, sha)
);
CREATE INDEX IF NOT EXISTS album_photos_account_idx ON album_photos (account_id, taken_at DESC);
CREATE INDEX IF NOT EXISTS album_photos_look_idx ON album_photos (look_due) WHERE look_status = 'pending';

-- 书架 · 一起读书（10-02，照之前自用的 App共读书房；设计 docs/specs/2026-10-02-bookshelf-design.md）。正文是文件（files_dir/books/），切好的章放 chapters
CREATE TABLE IF NOT EXISTS books (
  id           BIGSERIAL   PRIMARY KEY,
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  title        TEXT        NOT NULL,
  path         TEXT        NOT NULL,
  chapters     JSONB       NOT NULL DEFAULT '[]',      -- [[章名, 起, 止]]，按字符位置
  cover_path   TEXT        NOT NULL DEFAULT '',
  at_chapter   INT         NOT NULL DEFAULT 0,         -- 读到哪：章 / 那一章第几页 / 共几页（页是手机排的）
  at_page      INT         NOT NULL DEFAULT 0,
  page_count   INT         NOT NULL DEFAULT 0,
  furthest     INT         NOT NULL DEFAULT 0,         -- 读到过最远的章（它只能翻到这儿，不剧透）
  read_at      TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS books_account_idx ON books (account_id, created_at);
ALTER TABLE books ADD COLUMN IF NOT EXISTS companion_id UUID REFERENCES companions(id) ON DELETE SET NULL;  -- 只给这个 TA 看（NULL = 所有 TA，10-15）
CREATE TABLE IF NOT EXISTS book_marks (               -- 页边：划线（只有 quote）/ 批注（quote + note）/ 往来（parent_id）
  id           BIGSERIAL   PRIMARY KEY,
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  book_id      BIGINT      NOT NULL REFERENCES books(id) ON DELETE CASCADE,
  chapter      INT         NOT NULL,
  quote        TEXT        NOT NULL DEFAULT '',
  note         TEXT        NOT NULL DEFAULT '',
  pos          INT         NOT NULL DEFAULT -1,        -- 这句在那一章里的字符起点（-1 = 不知道，按第一处铺）
  author       TEXT        NOT NULL,                   -- 'user' 或联系人编号
  companion_id UUID,                                   -- 这一条是跟哪个联系人的往来
  parent_id    BIGINT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS book_marks_book_idx ON book_marks (book_id, chapter, id);
CREATE TABLE IF NOT EXISTS book_reading (             -- 每天每本读了多久
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  book_id      BIGINT      NOT NULL REFERENCES books(id) ON DELETE CASCADE,
  day          DATE        NOT NULL,
  seconds      INT         NOT NULL DEFAULT 0,
  PRIMARY KEY (account_id, book_id, day)
);
CREATE TABLE IF NOT EXISTS book_threads (             -- 「划线说两句」挂着的线头：它这窗口接下来半小时的回话抄一份进页边
  conversation_id UUID       PRIMARY KEY,
  mark_id         BIGINT     NOT NULL REFERENCES book_marks(id) ON DELETE CASCADE,
  armed_at        TIMESTAMPTZ NOT NULL
);

-- 钱包记账（10-02，Aporia没力气想，按默认：澳元、只记支出、它不主动提，TA 问才说）。金额存「分」，避免小数
CREATE TABLE IF NOT EXISTS wallet_entries (
  id          BIGSERIAL   PRIMARY KEY,
  account_id  UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  amount      INT         NOT NULL CHECK (amount > 0),   -- 分
  category    TEXT        NOT NULL,
  note        TEXT        NOT NULL DEFAULT '',
  day         DATE        NOT NULL,
  author      TEXT        NOT NULL DEFAULT 'user',       -- 'user' 或替 TA 记的联系人编号
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS wallet_entries_day_idx ON wallet_entries (account_id, day DESC, id DESC);
CREATE TABLE IF NOT EXISTS wallet_settings (
  account_id  UUID        PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  currency    TEXT        NOT NULL DEFAULT 'AUD',
  budget      INT         NOT NULL DEFAULT 0,             -- 一个月的预算（分）；0 = 不设
  categories  JSONB       NOT NULL DEFAULT '[]'           -- TA 自己加的分类（默认的那几个不用存）
);
-- 钱包 10-02 晚Aporia补的：也记收入；标签自己写、写过的存下来；它偶尔提一句（TA 记的、它还没听说的）
ALTER TABLE wallet_entries ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'out';     -- out 支出 / in 收入
ALTER TABLE wallet_entries ADD COLUMN IF NOT EXISTS told BOOLEAN NOT NULL DEFAULT TRUE;  -- 它听说过了没（TA 新记的是 FALSE）
ALTER TABLE wallet_settings ADD COLUMN IF NOT EXISTS told_at TIMESTAMPTZ;                -- 上次跟它提钱包是什么时候

-- 塔罗（10-03，设计 docs/specs/2026-10-03-tarot-design.md）：洗好的牌先存着（30 分钟有效），手机交「第几张」，服务器按牌序取牌
CREATE TABLE IF NOT EXISTS tarot_decks (
  id          BIGSERIAL   PRIMARY KEY,
  account_id  UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  seed        TEXT        NOT NULL,
  deck        JSONB       NOT NULL,                       -- [{card, reversed}] × 78
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS tarot_readings (
  id             BIGSERIAL   PRIMARY KEY,
  account_id     UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id   UUID        REFERENCES companions(id) ON DELETE CASCADE,   -- 谁来解；NULL = 解牌人（中立，不带人设和记忆）
  route_from     UUID,                                   -- 解牌人用谁的钥匙和模型（问牌时所在的联系人）
  asker          TEXT        NOT NULL DEFAULT 'user',    -- user / contact（它问自己的事）
  drawn_by       TEXT        NOT NULL DEFAULT 'user',    -- user / contact（聊天里它替 TA 抽的）
  question       TEXT        NOT NULL,
  spread         TEXT        NOT NULL,
  cards          JSONB       NOT NULL,                   -- [{position, card, reversed}]
  seed           TEXT        NOT NULL,
  mode           TEXT        NOT NULL,                   -- hand 自己抽 / auto 帮我抽 / tool 它用工具抽
  interpretation TEXT        NOT NULL DEFAULT '',
  status         TEXT        NOT NULL DEFAULT 'pending', -- pending / asked / done / failed
  tries          INT         NOT NULL DEFAULT 0,
  told           BOOLEAN     NOT NULL DEFAULT TRUE,      -- 〔塔罗〕递过没（联系人解完置 FALSE，递一次置回）
  followups      JSONB       NOT NULL DEFAULT '[]',      -- [{question, card:{position,card,reversed}, seed, mode, interpretation, status, tries, ts}]
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS tarot_readings_acc_idx ON tarot_readings (account_id, created_at DESC);

-- 声音（10-03，设计 docs/specs/2026-10-03-voice-notes-design.md）：声音额度按字算；念过的按「文字 + 嗓子 + 模型」指纹存，同一句再念不花钱
CREATE TABLE IF NOT EXISTS voice_quota (
  account_id  UUID        PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  chars_left  INT         NOT NULL
);
CREATE TABLE IF NOT EXISTS voice_clips (
  id           UUID        PRIMARY KEY,
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  fingerprint  TEXT        NOT NULL,
  message_id   BIGINT,
  path         TEXT        NOT NULL,
  chars        INT         NOT NULL,
  duration_ms  INT         NOT NULL DEFAULT 0,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS voice_clips_fp_idx ON voice_clips (account_id, fingerprint);
ALTER TABLE voice_clips ADD COLUMN IF NOT EXISTS text_sha TEXT NOT NULL DEFAULT '';   -- 只按文字算：换了嗓子以后历史里的语音条还找得到
CREATE INDEX IF NOT EXISTS voice_clips_msg_idx ON voice_clips (message_id);
CREATE TABLE IF NOT EXISTS voice_usage (
  id          BIGSERIAL   PRIMARY KEY,
  account_id  UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  purpose     TEXT        NOT NULL,                  -- note 它发的 / speak 念给我听 / design 设计嗓子
  model       TEXT        NOT NULL,
  chars       INT         NOT NULL,
  cost_usd    DOUBLE PRECISION NOT NULL,
  own_key     BOOLEAN     NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- TA 发语音条（10-03，声音第二块）：附件多一类 voice；语速和停顿的个人基线（最近 20 条）
ALTER TABLE attachments DROP CONSTRAINT IF EXISTS attachments_kind_check;
ALTER TABLE attachments ADD CONSTRAINT attachments_kind_check CHECK (kind IN ('image', 'file', 'voice'));
CREATE TABLE IF NOT EXISTS voice_baseline (
  account_id  UUID        PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
  samples     JSONB       NOT NULL DEFAULT '[]'
);

-- Mele Host 配对码（10-04）：单人服务器，主人扫码进来；只存哈希，用一次就作废；重置 = 作废旧的、出一张新的
CREATE TABLE IF NOT EXISTS host_pairing (
  code_hash  TEXT        PRIMARY KEY,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  used_at    TIMESTAMPTZ
);

-- Mele Host 推送中转（10-04）：apns_token 写成 relay:<编号> 的设备走Aporia的中转站；内容用手机给的钥匙加密，中转看不见
ALTER TABLE devices ADD COLUMN IF NOT EXISTS relay_secret TEXT;
ALTER TABLE devices ADD COLUMN IF NOT EXISTS push_key TEXT;

CREATE TABLE IF NOT EXISTS voip_devices (           -- TA 打给你（10-31）：手机的 VoIP 推送登记（经推送中转），一部手机一行
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  push_key     TEXT        NOT NULL,                -- 跟普通推送同一把加密钥匙：认得是哪部手机
  relay_id     TEXT        NOT NULL,
  relay_secret TEXT        NOT NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, push_key)
);

-- Mele Host 搬家（10-05）：手机里哪些房间条目已经搬过（kind + 手机里的编号），再点「搬过去」只补新的
CREATE TABLE IF NOT EXISTS host_imported (
  account_id UUID NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL,
  local_id   TEXT NOT NULL,
  PRIMARY KEY (account_id, kind, local_id)
);
ALTER TABLE host_imported ADD COLUMN IF NOT EXISTS host_id TEXT;   -- 搬过来后在 Host 上的编号（书、划线、饮食照片：后面的条目要接回去）

-- 里程碑（10-05 上服务器；Lite 早有）：它觉得值得记住的一刻立一座，TA 在 Record 的大事记里看
CREATE TABLE IF NOT EXISTS milestones (
  id           BIGSERIAL   PRIMARY KEY,
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  title        TEXT        NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS milestones_account_idx ON milestones (account_id, created_at);

CREATE TABLE IF NOT EXISTS mcp_servers (          -- 用户自己的 MCP 服务（10-05，Host 才有；brain/mcp.py）：钥匙用主密钥加密
  id         UUID        PRIMARY KEY,
  account_id UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  name       TEXT        NOT NULL,
  url        TEXT        NOT NULL,
  slug       TEXT        NOT NULL,
  secret     BYTEA,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS mcp_servers_account_idx ON mcp_servers (account_id);

-- 群聊（10-11，跟 Lite 一套）：群是一种窗口（kind = group），不挂在哪个联系人名下（companion_id 空），
-- 成员在 group_members；TA 说的话记下是谁说的（speaker_id + 名字，TA 删了也认得）
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'dm';
ALTER TABLE conversations ALTER COLUMN companion_id DROP NOT NULL;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS name TEXT NOT NULL DEFAULT '';
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS avatar_ver INT NOT NULL DEFAULT 0;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS max_rounds INT NOT NULL DEFAULT 6;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS new_member_sees_history BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE conversations ADD COLUMN IF NOT EXISTS last_speaker UUID;
CREATE TABLE IF NOT EXISTS group_members (
  conversation_id UUID        NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  companion_id    UUID        NOT NULL,                    -- 不挂外键：TA 删了，它在群里说过的话还认得是谁
  position        INT         NOT NULL DEFAULT 0,
  joined_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  left_at         TIMESTAMPTZ,                             -- 不空 = 被踢了 / 删掉了（以前的成员）
  PRIMARY KEY (conversation_id, companion_id)
);
CREATE INDEX IF NOT EXISTS group_members_companion_idx ON group_members (companion_id);
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS variants JSONB;      -- 重新回留下的几版（11-07）：含现在这版
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS variant INT;         -- 现在显示第几版
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS speaker_id UUID;
ALTER TABLE chat_messages ADD COLUMN IF NOT EXISTS speaker_name TEXT NOT NULL DEFAULT '';
-- 世界书分组 + 偶尔想起（10-14 内测：一百多条的梗清单 txt）：source = 从哪个文件导进来的（同一个文件一组）；
-- occasional = 不等说到关键词，隔几轮随手抽一条递给它，让它自己也会用
ALTER TABLE lore ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT '';
ALTER TABLE lore ADD COLUMN IF NOT EXISTS occasional BOOLEAN NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS memory_links (          -- 让别的 AI 连上 TA 的记忆（10-16 Aporia：像 OB 那样一份记忆、几家一起连；brain/memory_link.py）
  companion_id UUID        PRIMARY KEY REFERENCES companions(id) ON DELETE CASCADE,
  token_hash   TEXT        NOT NULL UNIQUE,          -- 查的时候用（sha256）
  secret       BYTEA       NOT NULL,                 -- 主密钥加密的原文：App 里随时能再看、再复制
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- 地图 + 它的一天（11-11 Aporia：连 Host 也要有；brain/world.py，跟 Lite 的 LocalMap 同一套）
CREATE TABLE IF NOT EXISTS world_places (
  id           SERIAL      PRIMARY KEY,
  account_id   UUID        NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
  companion_id UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  name         TEXT        NOT NULL,
  descr        TEXT        NOT NULL DEFAULT '',
  icon         TEXT        NOT NULL DEFAULT 'park',
  slot         INT         NOT NULL DEFAULT 0,             -- 地图上第几个空位
  home         BOOLEAN     NOT NULL DEFAULT false,         -- 家：永远有一个，不能删
  by_who       TEXT        NOT NULL DEFAULT 'ai'           -- ai = 它起的（重起世界时换掉）/ user = 你加的（留着）
);
CREATE INDEX IF NOT EXISTS world_places_companion_idx ON world_places (companion_id);
CREATE TABLE IF NOT EXISTS world_days (            -- 每人每天一份行程：[{time HH:MM, place_id, doing}]，留 14 天
  companion_id UUID        NOT NULL REFERENCES companions(id) ON DELETE CASCADE,
  day          DATE        NOT NULL,
  items        JSONB       NOT NULL DEFAULT '[]',
  PRIMARY KEY (companion_id, day)
);
