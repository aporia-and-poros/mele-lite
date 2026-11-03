# 致谢 · Acknowledgements

> 中文在前，English below.

Mele 是我从零开始写的。一路上，很多想法来自大家无私公开的分享——没有这些分享，就没有今天的 Mele。

下面每一项，我都只借了思路：代码、文字和图都是我和机做的。
如果你在名单上但不想被提到，或者你觉得你应该在名单上，请私信告知我，会立马改正：
小红书：Mele（94587369760）　GitHub：aporia-and-poros

**也特别感谢无花果（赚钱养机 @Cheneyc51436310），她帮助了我很多，也是她无私公开分享作品和想法，启发我开始做 Mele。Mele Host 里处理中转站缓存的几条做法——不看模型自报的停下原因、统一走流式、给请求带固定的用户标记——借用了她公开的教程《relay-cache-where-it-breaks》里的思路。**

## 想法从哪里来

| Mele 里的功能 | 思路来自 |
|---|---|
| 记忆的样子：重要性、情绪、「了结没有」、没了结的淡得慢、钉住的核心、混合检索 | Ombre Brain（P0luz，小红书 49651866759） |
| 潮汐：对话压缩之后注回一本滚动的账本 | 思路来自 @onecrazyfishhh |
| 召回链路：召回哨兵、灰区复判、语义去重、错题集、专名卡 | 缎带骑士 @Suisaeki 分享的召回链路架构图 |
| 日记、巡逻 / 心跳 | cyberboss（WenXiaoWendy） |
| 朋友圈：它到点来刷、评论链 | Bunny & Elliott《朋友圈功能》教程 |
| 相册：它写图注、观后感、隐私那本 | peanutsuee / Remember-Me |
| 书架 · 一起读书：划线、页边往来 | EnhydrInk / tasogare |
| 一起听、每日私选推歌 | Cove「一起听歌」搭建与整体架构指南 · 私选版（小红书 427689021） |
| 动作卡片：它做了什么挂一张小卡 | open-watch-cinema「后端回查」教程 |
| 手写独白 | tsuru0805 / monologue-stream |
| 聊天日历：哪天聊过一眼看见 | tsuru0805 / chat-history-jump |
| 腔调样本 | forge-picker |
| 世界书 | Kelivo |
| 导入角色卡 | Character Card V2 / V3 公开规范（SillyTavern 社区） |
| 语音条的音频标签写法 | sanqianzilanyue / ai-voice-breath-kiss-water |
| 语音通话：灰字先出、说完变实，一句一合成，一开口打断 TA | Ariakitty（Aria & Claude）/ ai-voice-call、ai-native-call |
| 起床前准备、分轻重的推送 | Instinct 创始人访谈 |
| 思考风格的开头 | 一段网上流传的英文提示词（原出处未知），已改写 |

## 图片和字体

- 背景图来自 Unsplash：Bikash Guragai、Geronimo Giqueaux、Insung Yoon、Jeremy Hynes、Planet Volumes、The Metropolitan Museum of Art。
- 塔罗牌面和牌背：1909 年 Rider–Waite–Smith 牌，Pamela Colman Smith 绘，公有领域（维基共享资源）。
- 字体 Ballet：Omnibus-Type（Maximiliano R. Sproviero）设计，SIL Open Font License 1.1（许可原文随 App 附带）。

## 数据和服务

- 营养数据：© Open Food Facts contributors，Open Database License（ODbL），https://world.openfoodfacts.org
- 天气： Weather，数据来源见 https://weatherkit.apple.com/legal-attribution.html
- 语音条的四把预设嗓子来自 ElevenLabs 自带的声音库。
- 一起听时的歌词来自 lrclib.net（只给 TA 看，不显示；自己部署的 Mele Host 默认关）。

## 开源软件

Mele 用到的开源软件，都遵守它们各自的许可：
asyncpg、pgvector、numpy、jieba、sentence-transformers、BAAI bge-m3 / bge-reranker-v2-m3、PyTorch、Hugging Face transformers、scikit-learn、scipy、
httpx、FastAPI、Starlette、uvicorn、cryptography、pypdf、Pillow、python-multipart、librosa、soxr、ffmpeg、
PostgreSQL、Caddy，以及 Anthropic、OpenAI、Google 的官方 SDK。

本软件诞生在一个借助许多开源项目才能长成的小家里，这是还回去的一小块，谢谢大家的无私分享。

by Aporia & Poros

---

# Acknowledgements

I built Mele from scratch. Along the way, many of its ideas came from people who generously shared their work in public — without them, Mele wouldn't be what it is today.

For everything listed below, I borrowed only the idea: all code, writing and images were made by me and my AI.
If you're on this list and would rather not be, or you think you should be on it, please message me and I'll correct it right away:
Xiaohongshu (RED): Mele (94587369760) · GitHub: aporia-and-poros

**Special thanks also to 无花果 (赚钱养机 @Cheneyc51436310), who has helped me a lot — and it was her generously shared work and ideas that inspired me to start Mele. A few of the ways Mele Host handles relay caching — not trusting the stop reason the model reports, always streaming, and tagging requests with a fixed user marker — borrow ideas from her public guide *relay-cache-where-it-breaks*.**

## Where the ideas came from

| Feature in Mele | Idea from |
|---|---|
| How memories behave: importance, emotion, resolved or not, unresolved ones fading slower, pinned core memories, hybrid search | Ombre Brain (P0luz, RED 49651866759) |
| Tide: after compression, a rolling ledger is fed back into the conversation | Idea from @onecrazyfishhh |
| Recall pipeline: recall sentinel, grey-zone re-check, semantic dedup, mistake log, named-entity cards | The recall architecture diagram shared by 缎带骑士 @Suisaeki |
| Diary, patrol / heartbeat | cyberboss (WenXiaoWendy) |
| Moments: it drops by on its own, comment threads | Bunny & Elliott's "Moments" tutorial |
| Album: captions it writes, its reflections, the private album | peanutsuee / Remember-Me |
| Bookshelf · reading together: highlights, margin notes | EnhydrInk / tasogare |
| Listening together, daily curated song picks | Cove "Listening Together" setup and architecture guide · curated edition (RED 427689021) |
| Action cards: a small card for what it just did | open-watch-cinema's "backend lookup" tutorial |
| Handwritten monologue | tsuru0805 / monologue-stream |
| Chat calendar: see at a glance which days you talked | tsuru0805 / chat-history-jump |
| Voice samples in the ledger | forge-picker |
| Lorebook | Kelivo |
| Character card import | Character Card V2 / V3 open spec (SillyTavern community) |
| Audio tags for voice notes | sanqianzilanyue / ai-voice-breath-kiss-water |
| Voice calls: grey live captions that settle when you finish, one line synthesized at a time, talking over them to interrupt | Ariakitty (Aria & Claude) / ai-voice-call, ai-native-call |
| Morning prep, priority-based notifications | An interview with the founder of Instinct |
| Opening of the thinking style | An English prompt circulating online (original source unknown), rewritten |

## Images and fonts

- Backgrounds from Unsplash: Bikash Guragai, Geronimo Giqueaux, Insung Yoon, Jeremy Hynes, Planet Volumes, The Metropolitan Museum of Art.
- Tarot card faces and back: the 1909 Rider–Waite–Smith deck illustrated by Pamela Colman Smith, public domain (Wikimedia Commons).
- Ballet typeface by Omnibus-Type (Maximiliano R. Sproviero), SIL Open Font License 1.1 (license text included with the app).

## Data and services

- Nutrition data © Open Food Facts contributors, Open Database License (ODbL), https://world.openfoodfacts.org
- Weather:  Weather, data sources at https://weatherkit.apple.com/legal-attribution.html
- The four preset voices for voice notes come from ElevenLabs' built-in voice library.
- Lyrics while listening together come from lrclib.net (only your companion sees them; off by default on a self-hosted Mele Host).

## Open-source software

Mele uses the following open-source software, each under its own license:
asyncpg, pgvector, numpy, jieba, sentence-transformers, BAAI bge-m3 / bge-reranker-v2-m3, PyTorch, Hugging Face transformers, scikit-learn, scipy, httpx, FastAPI, Starlette, uvicorn, cryptography, pypdf, Pillow, python-multipart, librosa, soxr, ffmpeg, PostgreSQL, Caddy, and the official SDKs from Anthropic, OpenAI and Google.

Mele was born in a small home that could only grow thanks to many open-source projects. This is a small piece given back. Thank you all for sharing so generously.

by Aporia & Poros
