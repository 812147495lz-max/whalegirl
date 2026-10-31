# 消息与双向对话 API

在菜单中打开 **消息 API 设置…** 可启停服务、修改监听地址、端口、停留时间和音量、复制或更换接入密钥。**消息与对话…** 可以查看会话、回复，也可以输入会话 ID 主动发文字。收到的气泡也有回复输入框及“对话”按钮。

## 本机使用

默认接口为 `http://127.0.0.1:38473`，所有接口都需要 `Authorization: Bearer <TOKEN>`。密钥从软件设置中复制，不放在 URL 里。

外置设置：`~/Library/Application Support/WhaleGirl/UserData/消息API.json`。
对话及未确认回复：同目录的 `消息对话.json`。这两份文件不会随应用更新重置。配置保存后约2秒自动读取；格式错误时不会覆盖原设置。密钥和文件权限为0600。

客户端会自动放在设置文件旁的`消息API客户端-2.1.1.py`，可直接用Python3运行；源码中的同一脚本为`Scripts/send_whale_message.py`。默认直接读取本机配置，无需在命令里填写密钥：

```sh
python3 Scripts/send_whale_message.py send --text '你好，今天的任务完成了' --conversation agent_a
python3 Scripts/send_whale_message.py send --file picture.png --text '图片说明' --conversation agent_a
python3 Scripts/send_whale_message.py send --file sound.wav --conversation agent_a
python3 Scripts/send_whale_message.py send --file clip.mp4 --conversation agent_a
python3 Scripts/send_whale_message.py pull --conversation agent_a
python3 Scripts/send_whale_message.py ack REPLY_UUID
```

## 接口

|方法与路径|作用|
|---|---|
|GET `/v1/health`|服务状态|
|POST `/v1/uploads`|上传图片、音频或视频，返回`upload_id`和`type`|
|POST `/v1/messages`|接收消息并排队，返回消息`id`|
|GET `/v1/messages/{id}`|查看本次运行内的展示状态|
|GET `/v1/conversations`|列出会话ID|
|GET `/v1/conversations/{conversation_id}`|查看该会话的文字和媒体说明记录|
|GET `/v1/outbox?conversation_id=agent_a&after=0`|拉取该会话尚未确认的本机回复，最多100条|
|POST `/v1/outbox/ack`|确认回复已被对方接收|
|GET `/v1/settings`|读取设置，永不返回密钥|
|PATCH `/v1/settings`|修改允许远程调整的展示设置|

### 发送文字

```json
{
  "type": "text",
  "text": "你好，方便确认一下吗？",
  "title": "消息标题",
  "sender": "助手",
  "conversation_id": "agent_a"
}
```

`type`支持`text`、`image`、`audio`、`video`。文字最长8000字符，标题120字符。`conversation_id`默认为`default`，限1–80个英文字母、数字、下划线或短横线；对话双方沿用同一ID。

### 发送媒体

先把原文件作为`POST /v1/uploads`的请求体发送，设置正确的`Content-Type`，如`image/png`、`audio/wav`或`video/mp4`。然后发送：

```json
{"type":"image","upload_id":"UPLOAD_UUID","text":"可选说明","conversation_id":"agent_a"}
```

支持PNG/JPEG/WebP/GIF首帧、MP3/M4A/WAV/AAC/FLAC、MP4/MOV/M4V，实际音视频编码需被本机AVFoundation支持。每个上传ID只能用于一条消息。不接受本机文件路径或远程URL，避免隐式读取其他文件/网站。媒体加载失败时状态为`failed`。

返回202表示已进入队列，不代表已经播放。消息状态包括`queued`、`deferred`、`playing`、`completed`、`dismissed`、`failed`、`cancelled`、`expired`。安静模式、全屏自动避让、正在阅读绳索信息卡或其他完成提醒时，会延迟展示。队列默认20条，等待超过10分钟过期。

气泡支持滚动文字、图片、音视频播放控制、关闭和文字回复。阅读/输入时可保持气泡；切换桌面或手动关闭会停止本条播放。音视频默认最多自动播放180秒。原始媒体在展示完成后删除，未使用上传10分钟后清理，总媒体缓存上限256MiB。对话记录保存文字和媒体说明，最多1000条；未确认回复不会因历史整理被删。

### 接收回复和主动消息

气泡内发送的回复会带上`reply_to`（原消息的UUID）。对话窗口主动发出的消息没有`reply_to`。两者都进入持久化发件箱，重启后仍能读取。

```json
{
  "messages":[{
    "id":"REPLY_UUID",
    "conversation_id":"agent_a",
    "direction":"outgoing",
    "type":"text",
    "text":"收到了，稍后处理",
    "reply_to":"ORIGINAL_MESSAGE_UUID",
    "sequence":1,
    "acknowledged":false
  }],
  "next_cursor":1
}
```

对方处理成功后，`POST /v1/outbox/ack`，正文为`{"ids":["REPLY_UUID"]}`。读取本身不会清除回复；处理方应按`id`去重，确认后再记录游标。可不指定`after`反复读取未确认项，避免掉线漏取。未确认发件箱上限500条，满后本机会提示发送失败，原有回复保留。

### 修改设置

```json
{"textSeconds":15,"imageSeconds":12,"volume":0.5,"bubbleWidth":360}
```

PATCH还允许`maxPlaybackSeconds`、`maxWaitSeconds`、`respectQuietMode`。网络地址、端口、开关、上传上限和密钥只在本机设置窗口或外置JSON中改，避免远程请求意外关闭自身入口。

主要范围：文字/图片停留1–120秒，自动播放1–600秒，音量0–1，气泡宽度240–600，上传1–64MiB，队列1–50，等待10–3600秒。JSON里保留其他现有字段。

## 以后接公网

目前默认仅本机监听，没有配置公网入口。以后可通过你自己的HTTPS反向代理或安全隧道转发到本机端口，继续使用同一Bearer密钥。客户端用`--url https://your-domain.example`并通过环境变量`WHALEGIRL_API_TOKEN`提供密钥。无需把API密钥放进网页、链接或日志。客户端不会将认证头跟随重定向转发。接口无Cookie认证、不开放任意跨域网页调用。

监听地址可选`127.0.0.1`、`::1`、`0.0.0.0`。选择`0.0.0.0`才会开启局域网监听；这不自动建立公网转发。HTTP采用单请求连接、Content-Length正文，支持`Expect: 100-continue`，不支持分块上传。错误配置、超限、无效密钥和队列满会明确返回4xx/5xx，不执行命令或打开附件中的外部引用。
