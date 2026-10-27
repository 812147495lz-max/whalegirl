#!/usr/bin/env python3
"""Bounded, read-only local usage metadata collector (no API or price-table calls).

Codex usage includes cache/reasoning. DSH's five usage buckets are disjoint.
DeepSeek token fees use the verified official CNY price snapshot; never invoices.
Unsupported metadata may retain cost-meter plugin USD estimates.
Only allowlisted metadata is persisted. File cursors and session IDs are hashed.
"""
import argparse
import ctypes
import ctypes.util
import datetime as dt
from decimal import Decimal, InvalidOperation
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile

MAX_RECORDS = 10000
MAX_STATE = 16 * 1024 * 1024
MAX_FILES = 1024
MAX_ENTRIES = 12000
MAX_READ = 24 * 1024 * 1024
MAX_PLAIN = 32 * 1024 * 1024
MAX_LINE = 1024 * 1024
MAX_FRAME = 8 * 1024 * 1024
TOKEN_MAP = {'input_tokens': 'inputTokens', 'output_tokens': 'outputTokens',
             'cached_input_tokens': 'cachedInputTokens', 'cache_write_input_tokens': 'cacheWriteTokens',
             'reasoning_output_tokens': 'reasoningTokens'}
DSH_MAP = {'inputTokens': 'uncachedInputTokens', 'outputTokens': 'outputTokens',
           'cacheReadTokens': 'cachedInputTokens', 'cacheWriteTokens': 'cacheWriteTokens',
           'reasoningTokens': 'reasoningTokens'}
PUBLIC_KEYS = {'id', 'source', 'session', 'occurredAt', 'model', 'inputTokens', 'outputTokens',
               'cachedInputTokens', 'uncachedInputTokens', 'cacheWriteTokens', 'reasoningTokens',
               'costAmount', 'currency', 'costKind', 'costBasis', 'granularity'}


def digest(*parts):
    return hashlib.sha256(json.dumps(parts, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def session_hash(source, value):
    return hashlib.sha256((source + ':' + str(value)).encode()).hexdigest()[:24]


def number(value):
    return value if type(value) is int and 0 <= value <= 10**15 else None


def stamp(value):
    try:
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            value = dt.datetime.fromtimestamp(value / 1000, dt.timezone.utc)
        elif isinstance(value, str) and len(value) <= 40:
            value = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        else:
            return None
        if value.tzinfo is None:
            return None
        return value.astimezone(dt.timezone.utc).isoformat(timespec='milliseconds').replace('+00:00', 'Z')
    except (ValueError, OverflowError, OSError):
        return None


def model_name(value):
    if isinstance(value, str) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:/-]{0,95}', value):
        if not re.search(r'sk-|bearer|secret|password|token|api.?key', value, re.I):
            return value
    return None


def tokens(usage, source):
    if not isinstance(usage, dict):
        return {}
    mapping = TOKEN_MAP if source == 'codex' else DSH_MAP
    result = {out: number(usage[key]) for key, out in mapping.items() if number(usage.get(key)) is not None}
    if source == 'codex':
        if 'inputTokens' in result and 'cachedInputTokens' in result:
            if result['cachedInputTokens'] > result['inputTokens']:
                return {}
            result['uncachedInputTokens'] = result['inputTokens'] - result['cachedInputTokens']
        if result.get('reasoningTokens', 0) > result.get('outputTokens', 10**15):
            return {}
    else:
        # DSH Usage has disjoint buckets. An omitted bucket is unknown,
        # never a synthetic zero. Derive totals only from all constituents or
        # the producer's explicit totalTokens and the known opposite total.
        raw_output = result.pop('outputTokens', None)
        total = number(usage.get('totalTokens'))
        if all(k in result for k in ('uncachedInputTokens', 'cachedInputTokens', 'cacheWriteTokens')):
            result['inputTokens'] = sum(result[k] for k in ('uncachedInputTokens', 'cachedInputTokens', 'cacheWriteTokens'))
        if raw_output is not None and 'reasoningTokens' in result:
            result['outputTokens'] = raw_output + result['reasoningTokens']
        if total is not None:
            if 'inputTokens' in result and total >= result['inputTokens']:
                candidate = total - result['inputTokens']
                if candidate >= (raw_output or 0) + result.get('reasoningTokens', 0):
                    result['outputTokens'] = candidate
            elif 'outputTokens' in result and total >= result['outputTokens']:
                candidate = total - result['outputTokens']
                if candidate >= sum(result.get(k, 0) for k in ('uncachedInputTokens', 'cachedInputTokens', 'cacheWriteTokens')):
                    result['inputTokens'] = candidate
    return result


# Official CNY / 1M tokens, verified 2026-10-23:
# https://api-docs.deepseek.com/zh-cn/quick_start/pricing/
# https://api-docs.deepseek.com/updates/ (Sep10 price change; Oct17 unchanged)
# Conservative coverage starts after the bundled holiday-policy effective date.
OFFICIAL_RATES = {
    'deepseek-flash': ('Flash', '0.02', '1', '4'),
    'deepseek-v4-flash': ('Flash', '0.02', '1', '4'),
    'deepseek-v4-flash-vision-exp': ('Flash', '0.02', '1', '4'),
    'deepseek-v4-pro': ('Pro', '0.15', '4.5', '13.5'),
}


def official_deepseek_cost(record, calendar):
    """Price normalized inclusive buckets once, using request time, never poll time."""
    if record.get('costKind') == 'reported' or record.get('model') not in OFFICIAL_RATES:
        return None
    timestamp = stamp(record.get('occurredAt'))
    if not timestamp or not isinstance(calendar, dict):
        return None
    at = dt.datetime.fromisoformat(timestamp.replace('Z', '+00:00'))
    local = at.astimezone(dt.timezone(dt.timedelta(hours=8)))
    # Do not apply today's price to unverified older tariffs or future holiday years.
    if not dt.date(2026, 9, 19) <= local.date() <= dt.date(2026, 12, 31):
        return None
    holidays = calendar.get('holidays')
    if not isinstance(holidays, list) or not all(isinstance(day, str) for day in holidays):
        return None
    i, hit, out = (number(record.get(k)) for k in ('inputTokens', 'cachedInputTokens', 'outputTokens'))
    if i is None or hit is None or out is None or hit > i:
        return None
    if record.get('source') == 'dsh':
        miss, write = (number(record.get(k)) for k in ('uncachedInputTokens', 'cacheWriteTokens'))
        if miss is None or write is None or i != hit + miss + write:
            return None
    elif record.get('source') != 'codex':
        return None
    minute = local.hour * 60 + local.minute
    peak = (local.weekday() < 5 and local.date().isoformat() not in holidays
            and (540 <= minute < 720 or 840 <= minute < 1080))
    model, hit_rate, miss_rate, output_rate = OFFICIAL_RATES[record['model']]
    multiplier = 2 if peak else 1
    amount = (Decimal(hit) * Decimal(hit_rate) + Decimal(i - hit) * Decimal(miss_rate)
              + Decimal(out) * Decimal(output_rate)) * multiplier / Decimal(1000000)
    phase = '高峰' if peak else '空闲'
    rates = [format(Decimal(rate) * multiplier, 'f') for rate in (hit_rate, miss_rate, output_rate)]
    basis = ('DeepSeek官方价2026-10-23 · ' + model + ' · ' + phase
             + ' · 缓存命中/未命中/输出 ¥' + '/'.join(rates) + ' 每百万Token')
    return dict(costKind='estimated', costAmount=format(amount, 'f'), currency='CNY', costBasis=basis)


def official_price_calendar():
    try:
        return json.loads(Path(__file__).with_name('WhaleBalanceWidgetReference.json').read_bytes())
    except (OSError, ValueError):
        return None


class Zstd:
    """Read independent append frames with a fixed maximum decompressed size."""
    def __init__(self):
        self.lib = None
        candidates = ['/opt/homebrew/lib/libzstd.dylib', '/usr/local/lib/libzstd.dylib',
                      ctypes.util.find_library('zstd')]
        for candidate in candidates:
            if not candidate:
                continue
            try:
                lib = ctypes.CDLL(candidate)
                for name, args, result in [
                    ('ZSTD_findFrameCompressedSize', [ctypes.c_void_p, ctypes.c_size_t], ctypes.c_size_t),
                    ('ZSTD_decompress', [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t], ctypes.c_size_t),
                    ('ZSTD_isError', [ctypes.c_size_t], ctypes.c_uint)]:
                    fn = getattr(lib, name); fn.argtypes = args; fn.restype = result
                self.lib = lib
                break
            except (OSError, AttributeError):
                continue

    def frame(self, raw):
        if not self.lib:
            raise RuntimeError('decoderUnavailable')
        src = ctypes.create_string_buffer(raw)
        size = self.lib.ZSTD_findFrameCompressedSize(src, len(raw))
        if self.lib.ZSTD_isError(size):
            return None  # Incomplete append; leave cursor before this frame.
        dst = ctypes.create_string_buffer(MAX_FRAME)
        count = self.lib.ZSTD_decompress(dst, MAX_FRAME, src, size)
        if self.lib.ZSTD_isError(count):
            raise RuntimeError('frameLimitOrInvalidData')
        return int(size), dst.raw[:count]


class Collector:
    def __init__(self, state=None):
        state = state if isinstance(state, dict) and state.get('version') == 1 else {}
        self.files = state.get('files', {})
        self.records = {r['id']: r for r in state.get('records', [])
                        if isinstance(r, dict) and isinstance(r.get('id'), str)}
        self.aliases = state.get('aliases', {})
        self.strong = state.get('strong', {})
        self.read_left, self.plain_left = MAX_READ, MAX_PLAIN
        self.status = {'codex': 'unavailable', 'dsh': 'unavailable'}
        self.decoder = None

    def add(self, record, aliases=(), strong=None):
        aliases = list(aliases)
        if strong:
            # Known distinct provider response IDs override weak token/time
            # fingerprints. Equal usage can be two concurrent real requests.
            aliases = [a for a in aliases if self.strong.get(self.aliases.get(a)) in (None, strong)]
        old_id = next((self.aliases[a] for a in aliases if self.aliases.get(a) in self.records), record['id'])
        old = self.records.get(old_id, {})
        record['id'] = old_id
        # Later log reads must preserve a cached plugin estimate already attached.
        if record.get('costKind') == 'unavailable' and old.get('costKind') != 'unavailable':
            for key in ('costKind', 'costAmount', 'currency', 'costBasis'):
                if key in old:
                    record[key] = old[key]
        if old.get('session') and not strong:
            record['session'] = old['session']
        self.records[old_id] = {**old, **record}
        if strong:
            self.strong[old_id] = strong
        for alias in aliases:
            self.aliases[alias] = old_id

    def base(self, source, session, time, identity, model=None):
        time = stamp(time)
        if not time or not session:
            return None
        rec = dict(id=identity, source=source, session=session, occurredAt=time,
                   costKind='unavailable', granularity='request')
        model = model_name(model)
        if model:
            rec['model'] = model
        return rec

    def codex_event(self, event, ctx):
        kind, payload = event.get('type'), event.get('payload')
        if not isinstance(payload, dict):
            return
        if kind == 'session_meta':
            sid = payload.get('id') or payload.get('session_id')
            if isinstance(sid, str):
                ctx['session'] = session_hash('codex', sid)
            return
        if kind == 'turn_context':
            model = model_name(payload.get('model'))
            if model:
                ctx['model'] = model
            return
        direct = kind == 'token_usage_record'
        if direct:
            usage, total = payload.get('usage'), payload.get('thread_token_usage')
            sid = payload.get('thread_id')
            session = session_hash('codex', sid) if isinstance(sid, str) else ctx.get('session')
        elif kind == 'event_msg' and payload.get('type') == 'token_count':
            info = payload.get('info')
            if not isinstance(info, dict):
                return
            usage, total = info.get('last_token_usage'), info.get('total_token_usage')
            session = ctx.get('session')
        else:
            return
        if not session or not isinstance(total, dict):
            return
        normalized_total = {k: number(v) for k, v in total.items() if k in TOKEN_MAP or k == 'total_tokens'}
        normalized_total = {k: v for k, v in normalized_total.items() if v is not None}
        if not normalized_total:
            return
        previous = ctx.get('total')
        if isinstance(previous, dict) and any(normalized_total[k] < previous.get(k, 0) for k in normalized_total):
            ctx['epoch'] = ctx.get('epoch', 0) + 1
        cumulative = digest('codex-cumulative', session, ctx.get('epoch', 0), normalized_total)
        values = tokens(usage, 'codex')
        previous = ctx.get('total')
        unchanged = previous == normalized_total
        ctx['total'] = normalized_total
        # A notification may repeat the same totals indefinitely. Direct records
        # can enrich/replace the mirror, but may never add another usage amount.
        if unchanged and not direct:
            return
        if not values or (not direct and not any(values.values())):
            return  # Never emit cumulative usage or empty notifications as a request.
        aliases = [cumulative]
        response = payload.get('response_id') if direct else None
        if isinstance(response, str) and response:
            aliases.append(digest('codex-response', response))
        # Inherited JSONL lines retain the original timestamp; this identity also
        # deduplicates legacy fork/replay files whose session_meta has changed.
        replay = digest('codex-replay', event.get('timestamp'), normalized_total, values)
        aliases.append(replay)
        identity = digest('codex-request', response) if response else replay
        rec = self.base('codex', session, event.get('timestamp'), identity, ctx.get('model'))
        if rec:
            rec.update(values)
            self.add(rec, aliases, digest('codex-response', response) if response else None)

    @staticmethod
    def dsh_identity(session, kind, turn, step, seq=None):
        return digest('dsh-request', session, kind, seq if kind != 'model' else [turn, step])

    def dsh_event(self, event, ctx):
        kind, data = event.get('type'), event.get('data')
        if kind == 'session':
            if isinstance(event.get('id'), str):
                ctx['session'] = session_hash('dsh', event['id'])
            created = event.get('createdAt')
            if isinstance(created, (int, float)):
                ctx['created'] = created
            return
        if not isinstance(data, dict):
            return
        if kind == 'request/header':
            config = (data.get('header') or {}).get('config') or {}
            model = model_name(config.get('model'))
            if model:
                ctx['model'] = model
            return
        if not ctx.get('session'):
            return
        when = event.get('time')
        if isinstance(when, (int, float)) and when < ctx.get('created', 0):
            return  # Fork seed history belongs to the parent, not a new call.
        usage, request_kind = None, 'model'
        if kind == 'assistant/message':
            usage = data.get('usage')
        elif kind == 'assistant/chunk' and isinstance(data.get('chunk'), dict) and data['chunk'].get('type') == 'usage':
            usage = data['chunk'].get('usage')
        elif kind == 'compaction/summary':
            usage, request_kind = data.get('usage'), 'compaction'
        else:
            return
        values = tokens(usage, 'dsh')
        if not values:
            return
        turn, step = number(data.get('turn')), number(data.get('step'))
        seq = number(event.get('seq'))
        if request_kind == 'model' and (turn is None or step is None):
            return  # No reliable request identity; do not fabricate one.
        identity = self.dsh_identity(ctx['session'], request_kind, turn, step, seq)
        source = (data.get('message') or {}).get('source') or {}
        model = source.get('model') if isinstance(source, dict) else None
        rec = self.base('dsh', ctx['session'], when, identity, model or ctx.get('model'))
        if rec:
            rec.update(values)
            self.add(rec)

    def scan_paths(self, root, source):
        """Bound directory entries and refuse symlinks, including source roots."""
        if root.is_symlink() or not root.is_dir():
            return []
        stack, paths, visited = [(root, 0)], [], 0
        while stack and visited < MAX_ENTRIES:
            directory, depth = stack.pop()
            try:
                with os.scandir(directory) as entries:
                    for entry in entries:
                        visited += 1
                        if visited >= MAX_ENTRIES:
                            self.status[source] = 'partial'
                            break
                        if entry.is_symlink():
                            continue
                        if entry.is_dir(follow_symlinks=False) and depth < 4:
                            stack.append((Path(entry.path), depth + 1))
                        elif entry.is_file(follow_symlinks=False):
                            name = entry.name
                            eligible = name.endswith('.jsonl') if source == 'codex' else bool(re.fullmatch(r'session(?:\.v\d+)?\.jsonl(?:\.zstd)?', name))
                            if eligible:
                                paths.append((entry.stat(follow_symlinks=False).st_mtime_ns, Path(entry.path)))
            except OSError:
                self.status[source] = 'partial'
        if stack or len(paths) > MAX_FILES:
            self.status[source] = 'partial'
        # Select latest numeric session generation, not a copy of every migration.
        if source == 'dsh':
            generations = {}
            for item in paths:
                match = re.search(r'\.v(\d+)\.', item[1].name)
                generation = int(match[1]) if match else 0
                previous = generations.get(item[1].parent)
                if previous is None or generation > previous[0]:
                    generations[item[1].parent] = (generation, item)
            paths = [v[1] for v in generations.values()]
        return [p for _, p in sorted(paths, reverse=True)[:MAX_FILES]]

    def consume(self, raw, source, ctx):
        for line in raw.splitlines():
            if not line or len(line) > MAX_LINE:
                if len(line) > MAX_LINE:
                    self.status[source] = 'partial'
                continue
            try:
                event = json.loads(line)
                if isinstance(event, dict):
                    (self.codex_event if source == 'codex' else self.dsh_event)(event, ctx)
            except (ValueError, TypeError, AttributeError, OverflowError):
                self.status[source] = 'partial'

    def read_file(self, path, source):
        key = digest('file', str(path))
        try:
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode):
                return
            inode = digest(info.st_dev, info.st_ino)
            saved = self.files.get(key, {})
            offset = saved.get('offset', 0)
            ctx = saved.get('context', {})
            if saved.get('inode') != inode or offset > info.st_size:
                offset, ctx = 0, {}
            if self.read_left <= 0 or self.plain_left <= 0:
                self.status[source] = 'partial'
                return
            with path.open('rb') as stream:
                if offset and saved.get('boundary'):
                    stream.seek(max(0, offset - 64))
                    if digest(stream.read(min(64, offset)).hex()) != saved['boundary']:
                        offset, ctx = 0, {}
                if info.st_size == offset:
                    return
                stream.seek(offset)
                limit = min(self.read_left, MAX_FRAME)
                raw = stream.read(limit)
                self.read_left -= len(raw)
                if path.suffix == '.zstd':
                    if self.decoder is None:
                        self.decoder = Zstd()
                    consumed = 0
                    while consumed < len(raw):
                        result = self.decoder.frame(raw[consumed:])
                        if result is None:
                            break
                        size, plain = result
                        if len(plain) > self.plain_left:
                            break
                        # Each DSH append batch is a complete independent frame.
                        # An incomplete final JSON line is retried with its frame.
                        if plain and not plain.endswith(b'\n'):
                            self.status[source] = 'partial'
                            break
                        self.plain_left -= len(plain)
                        self.consume(plain, source, ctx)
                        consumed += size
                    offset += consumed
                else:
                    # Do not persist raw tails (they may contain messages).
                    end = raw.rfind(b'\n') + 1
                    if end:
                        start = raw.find(b'\n') + 1 if ctx.pop('skipLine', False) else 0
                        self.consume(raw[start:end], source, ctx)
                        offset += end
                    elif len(raw) == limit:
                        # Skip a giant non-metadata line, maintaining no raw tail.
                        ctx['skipLine'] = True
                        offset += len(raw)
                if offset < info.st_size:
                    self.status[source] = 'partial'
                stream.seek(max(0, offset - 64))
                boundary = digest(stream.read(min(64, offset)).hex())
            self.files[key] = dict(inode=inode, offset=offset, context=ctx, boundary=boundary)
        except RuntimeError as error:
            self.status[source] = str(error)
        except (OSError, ValueError):
            self.status[source] = 'partial'

    def collect_source(self, root, source):
        sessions = root / 'sessions'
        if not sessions.is_dir() or sessions.is_symlink():
            return
        self.status[source] = 'ready'
        for path in self.scan_paths(sessions, source):
            self.read_file(path, source)

    def dsh_costs(self, root):
        # Never read aggregate ledger.json. Cache queries can overlap; stable
        # turn/step identity merges them and subsequent source-log enrichments.
        directory = root / 'storages' / 'cost-meter' / 'ledger.json.details-cache'
        if not directory.is_dir() or directory.is_symlink():
            return
        try:
            candidates = []
            with os.scandir(directory) as entries:
                for count, entry in enumerate(entries):
                    if count >= MAX_ENTRIES:
                        self.status['dsh'] = 'partial'
                        break
                    if entry.is_file(follow_symlinks=False) and not entry.is_symlink() and entry.name.endswith('.json'):
                        candidates.append((entry.stat(follow_symlinks=False).st_mtime_ns, Path(entry.path)))
            if len(candidates) > 32:
                self.status['dsh'] = 'partial'
            paths = [p for _, p in sorted(candidates, reverse=True)[:32]]
            for path in paths:
                size = path.stat().st_size
                if size > MAX_FRAME or size > self.read_left:
                    self.status['dsh'] = 'partial'
                    continue
                signature = digest(path.stat().st_mtime_ns, size)
                key = digest('cost-cache', str(path))
                if self.files.get(key, {}).get('signature') == signature:
                    continue
                self.read_left -= size
                with path.open() as stream:
                    value = json.load(stream, parse_float=Decimal)
                if value.get('version') != 2:
                    continue
                for step in value.get('value', {}).get('steps', []):
                    for call in step.get('callRefs', []):
                        self.dsh_cost_call(call)
                self.files[key] = {'signature': signature}
        except (OSError, ValueError, TypeError, AttributeError, InvalidOperation):
            self.status['dsh'] = 'partial'

    def dsh_cost_call(self, call):
        if not isinstance(call, dict) or not isinstance(call.get('sessionId'), str):
            return
        session = session_hash('dsh', call['sessionId'])
        kind = call.get('kind')
        if kind not in ('model', 'compaction'):
            return
        turn, step, seq = number(call.get('turn')), number(call.get('step')), number(call.get('logSeq'))
        if (kind == 'model' and (turn is None or step is None)) or (kind == 'compaction' and seq is None):
            return
        identity = self.dsh_identity(session, kind, turn, step, seq)
        rec = self.base('dsh', session, call.get('atMs'), identity, call.get('model'))
        if not rec:
            return
        usage = {}
        mapping = {'input': 'inputTokens', 'output': 'outputTokens', 'cacheRead': 'cacheReadTokens',
                   'cacheWrite': 'cacheWriteTokens', 'reasoning': 'reasoningTokens'}
        for row in call.get('rows', []):
            if row.get('bucket') in mapping and number(row.get('tokens')) is not None:
                key = mapping[row['bucket']]
                usage[key] = usage.get(key, 0) + row['tokens']
        if identity not in self.records:
            rec.update(tokens(usage, 'dsh'))
        if call.get('priced') is True and call.get('plan') is not True:
            try:
                amount = Decimal(str(call.get('cost')))
                if amount.is_finite() and 0 <= amount <= Decimal('1e9'):
                    rec.update(costKind='estimated', costAmount=format(amount, 'f'), currency='USD', costBasis='DSH插件估算')
            except InvalidOperation:
                pass
        self.add(rec)

    def result(self):
        records = sorted(self.records.values(), key=lambda r: (r.get('occurredAt', ''), r['id']))[-MAX_RECORDS:]
        calendar = official_price_calendar()
        for record in records:
            price = official_deepseek_cost(record, calendar)
            if price:
                record.update(price)
        records = [{k: v for k, v in r.items() if k in PUBLIC_KEYS} for r in records]
        self.records = {r['id']: r for r in records}
        aliases = {k: v for k, v in self.aliases.items() if v in self.records}
        self.aliases = dict(list(aliases.items())[-MAX_RECORDS * 3:])
        self.files = dict(list(self.files.items())[-MAX_FILES * 2:])
        self.strong = {k: v for k, v in self.strong.items() if k in self.records}
        return dict(schemaVersion=1, records=records, status=self.status)

    def state(self):
        return dict(version=1, records=list(self.records.values()), files=self.files, aliases=self.aliases, strong=self.strong)


def run(state_path, codex_root, dsh_root):
    state_path = Path(state_path)
    state_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Serialize overlapping invocations so cursor advancement cannot lose records.
    lock_fd = os.open(str(state_path) + '.lock', os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(lock_fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = None
        try:
            if not state_path.is_symlink() and state_path.stat().st_size <= MAX_STATE:
                state = json.loads(state_path.read_bytes())
        except (OSError, ValueError):
            pass
        collector = Collector(state)
        # Reserve independent shares: a large Codex backfill must never starve
        # live DSH usage or its cached cost enrichment (24 MiB total per poll).
        collector.read_left = MAX_READ // 3
        collector.collect_source(Path(codex_root), 'codex')
        collector.read_left = MAX_READ // 3
        collector.collect_source(Path(dsh_root), 'dsh')
        collector.read_left = MAX_READ // 3
        collector.dsh_costs(Path(dsh_root))
        snapshot = collector.result()
        encoded = json.dumps(collector.state(), separators=(',', ':')).encode()
        if len(encoded) > MAX_STATE:
            raise RuntimeError('stateLimit')
        fd, temporary = tempfile.mkstemp(prefix=state_path.name + '.', dir=state_path.parent)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(encoded); stream.flush(); os.fsync(stream.fileno())
            os.replace(temporary, state_path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        return snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state-path', required=True)
    parser.add_argument('--codex-root', default=os.environ.get('CODEX_HOME', str(Path.home() / '.codex')))
    parser.add_argument('--dsh-root', default=os.environ.get('DSH_HOME', str(Path.home() / '.dsh')))
    args = parser.parse_args()
    try:
        snapshot = run(args.state_path, args.codex_root, args.dsh_root)
    except Exception:
        # Do not let source/state parse failures print a traceback or raw data.
        snapshot = dict(schemaVersion=1, records=[], status=dict(codex='collectorUnavailable', dsh='collectorUnavailable'))
    print(json.dumps(snapshot, separators=(',', ':'), ensure_ascii=True))


if __name__ == '__main__':
    main()
