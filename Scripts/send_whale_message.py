#!/usr/bin/env python3
"""WhaleGirl messages: upload/send, pull replies, acknowledge delivery. Stdlib only."""
import argparse
import json
import mimetypes
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward the API credential to a redirect destination.
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--url', help='Base URL; remote endpoints must use HTTPS')
    parser.add_argument('--config', type=Path, help='Local API JSON configuration')
    parser.add_argument('--timeout', type=float, default=90)
    commands = parser.add_subparsers(dest='command', required=True)
    send = commands.add_parser('send')
    send.add_argument('--text', default='')
    send.add_argument('--file', type=Path)
    send.add_argument('--type', choices=['text', 'image', 'audio', 'video'])
    send.add_argument('--title')
    send.add_argument('--sender')
    send.add_argument('--conversation', default='default')
    pull = commands.add_parser('pull')
    pull.add_argument('--after', type=int, default=0)
    pull.add_argument('--conversation')
    ack = commands.add_parser('ack')
    ack.add_argument('ids', nargs='+')
    args = parser.parse_args()
    config = {}
    path = args.config or Path.home() / 'Library/Application Support/WhaleGirl/UserData/消息API.json'
    if args.config or not args.url:
        try:
            if path.stat().st_size > 65536:
                raise ValueError('configuration too large')
            config = json.loads(path.read_text(encoding='utf-8'))
        except (OSError, ValueError):
            parser.error('无法读取本机消息 API 配置，请在软件菜单中打开“消息 API 设置”。')
    host = config.get('listenHost', '127.0.0.1')
    if host == '0.0.0.0':
        host = '127.0.0.1'
    base = (args.url or f"http://{'[::1]' if host == '::1' else host}:{config.get('port', 38473)}").rstrip('/')
    url = urllib.parse.urlsplit(base)
    local = url.hostname in ['127.0.0.1', '::1', 'localhost']
    if not url.hostname or url.username or url.password or url.query or url.fragment or url.path not in ['', '/'] or (url.scheme != 'https' and not (url.scheme == 'http' and local)):
        parser.error('远程地址必须是 HTTPS；密钥不能写进 URL。')
    token = os.environ.get('WHALEGIRL_API_TOKEN') or config.get('token', '')
    if len(token) != 64 or any(c not in '0123456789abcdef' for c in token):
        parser.error('缺少接入密钥，请设置 WHALEGIRL_API_TOKEN 或指定本机配置文件。')
    if not 1 <= args.timeout <= 300:
        parser.error('timeout 必须在 1–300 秒之间')
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.ProxyHandler({})) if local else urllib.request.build_opener(NoRedirect())

    def request(method, route, body=None, content_type='application/json'):
        if isinstance(body, dict):
            body = json.dumps(body, ensure_ascii=False).encode('utf-8')
        req = urllib.request.Request(base + route, data=body, method=method,
            headers={'Authorization': 'Bearer ' + token, 'Content-Type': content_type})
        with opener.open(req, timeout=args.timeout) as response:
            return json.load(response)

    if args.command == 'send':
        kind = args.type or 'text'
        payload = {'type': kind, 'text': args.text, 'conversation_id': args.conversation}
        if args.title:
            payload['title'] = args.title
        if args.sender:
            payload['sender'] = args.sender
        if args.file:
            size = args.file.stat().st_size
            if not args.file.is_file() or not 0 < size <= min(config.get('maxUploadMiB', 64), 64) * 1048576:
                parser.error('文件为空或超过允许大小（最多 64 MiB，以服务器设置为准）。')
            mime = mimetypes.guess_type(args.file.name)[0] or 'application/octet-stream'
            if args.file.suffix.lower() == '.m4a':
                mime = 'audio/mp4'
            if not args.type:
                kind = mime.split('/')[0]
            if kind not in ['image', 'audio', 'video']:
                parser.error('请选择图片、音频或视频文件。')
            uploaded = request('POST', '/v1/uploads', args.file.read_bytes(), mime)
            payload.update(type=kind, upload_id=uploaded['upload_id'])
        elif kind != 'text' or not args.text.strip():
            parser.error('文字消息需要 --text；媒体消息需要 --file。')
        result = request('POST', '/v1/messages', payload)
    elif args.command == 'pull':
        query = {'after': args.after}
        if args.conversation:
            query['conversation_id'] = args.conversation
        result = request('GET', '/v1/outbox?' + urllib.parse.urlencode(query))
    else:
        result = request('POST', '/v1/outbox/ack', {'ids': args.ids})
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    try:
        main()
    except urllib.error.HTTPError as error:
        try:
            reason = json.load(error).get('error', 'request_failed')
        except (ValueError, OSError):
            reason = 'request_failed'
        sys.exit(f'HTTP {error.code}: {reason}')
    except (OSError, ValueError, KeyError) as error:
        sys.exit(f'请求失败：{type(error).__name__}')
