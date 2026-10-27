"""Synthetic metadata fixtures only; never access user profiles or paid APIs."""
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'Apps/macOS/Resources/AIMonitor/whale_usage_report.py'
spec = importlib.util.spec_from_file_location('usage_report', SOURCE)
u = importlib.util.module_from_spec(spec)
spec.loader.exec_module(u)
TIME = '2026-10-23T06:00:00Z'
MS = 1792735200000


def usage(i=100, o=20, cache=60, reasoning=5):
    return dict(input_tokens=i, output_tokens=o, cached_input_tokens=cache,
                cache_write_input_tokens=0, reasoning_output_tokens=reasoning, total_tokens=i + o)


def token_event(total, last=None, time=TIME):
    return dict(type='event_msg', timestamp=time,
                payload=dict(type='token_count', info=dict(total_token_usage=total, last_token_usage=last or total)))


def direct(total, last=None, response='response-1'):
    return dict(type='token_usage_record', timestamp=TIME,
                payload=dict(thread_id='thread-1', response_id=response, usage=last or total, thread_token_usage=total))


def codex_header(sid='thread-1'):
    return dict(type='session_meta', payload=dict(id=sid, base_instructions='SECRET_PROMPT'))


def dsh_header(sid='dsh-1', created=MS - 100):
    return dict(type='session', id=sid, createdAt=created)


def dsh_event(step=1, time=MS, kind='assistant/message', seq=4):
    values = dict(inputTokens=30, cacheReadTokens=50, cacheWriteTokens=10, outputTokens=7, reasoningTokens=3, totalTokens=100)
    data = dict(turn=1, step=step, usage=values, message=dict(content='SECRET_PROMPT'))
    if kind == 'assistant/chunk':
        data = dict(turn=1, step=step, chunk=dict(type='usage', usage=values))
    return dict(type=kind, seq=seq, time=time, data=data)


def lines(events):
    return ''.join(json.dumps(e) + '\n' for e in events).encode()


class UsageFixtures(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.codex, self.dsh = self.root / 'codex', self.root / 'dsh'
        self.codex.mkdir(); self.dsh.mkdir()
        self.state = self.root / 'private/state.json'

    def tearDown(self):
        self.temp.cleanup()

    def logfile(self, root, name, events):
        path = root / 'sessions' / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(lines(events))
        return path

    def collect(self):
        return u.run(self.state, self.codex, self.dsh)

    def test_codex_inclusive_buckets_and_missing_cache(self):
        self.assertEqual(u.tokens(usage(), 'codex'), dict(inputTokens=100, outputTokens=20,
            cachedInputTokens=60, uncachedInputTokens=40, cacheWriteTokens=0, reasoningTokens=5))
        self.assertEqual(u.tokens(dict(input_tokens=10, output_tokens=3), 'codex'), dict(inputTokens=10, outputTokens=3))
        self.assertEqual(u.tokens(usage(cache=101), 'codex'), {})

    def test_dsh_disjoint_buckets_normalize_total(self):
        norm = u.tokens(dsh_event()['data']['usage'], 'dsh')
        self.assertEqual(norm['inputTokens'], 90)
        self.assertEqual(norm['outputTokens'], 10)
        self.assertEqual(norm['inputTokens'] + norm['outputTokens'], 100)
        self.assertEqual(norm['uncachedInputTokens'], 30)
        unknown = u.tokens(dict(inputTokens=30, outputTokens=7), 'dsh')
        self.assertNotIn('cachedInputTokens', unknown)
        self.assertNotIn('inputTokens', unknown)
        self.assertNotIn('outputTokens', unknown)
        missing_write = u.tokens(dict(inputTokens=30, cacheReadTokens=50, outputTokens=7, reasoningTokens=3), 'dsh')
        self.assertNotIn('inputTokens', missing_write)
        self.assertNotIn('cacheWriteTokens', missing_write)

    def test_codex_mirror_repeated_totals_restart_and_next_request(self):
        first, second = usage(), usage(210, 45, 130, 11)
        last = usage(110, 25, 70, 6)
        path = self.logfile(self.codex, '2026/10/23/rollout.jsonl', [codex_header(), direct(first), token_event(first), token_event(first)])
        initial = self.collect(); self.assertEqual(len(initial['records']), 1)
        rec = initial['records'][0]
        self.assertEqual(rec['session'], u.session_hash('codex', 'thread-1'))
        self.assertEqual(rec['costKind'], 'unavailable'); self.assertNotIn('costAmount', rec)
        self.assertEqual(initial, self.collect())
        with path.open('ab') as stream:
            stream.write(lines([direct(second, last, 'response-2'), token_event(second, last)]))
        result = self.collect()['records']; self.assertEqual(len(result), 2)
        self.assertEqual(sorted(r['inputTokens'] for r in result), [100, 110])

    def test_reverse_mirror_order_keeps_stable_id(self):
        path = self.logfile(self.codex, 'rollout.jsonl', [codex_header(), token_event(usage())])
        first = self.collect()['records'][0]
        with path.open('ab') as stream:
            stream.write(lines([direct(usage())]))
        records = self.collect()['records']
        self.assertEqual(len(records), 1); self.assertEqual(first['id'], records[0]['id'])

    def test_legacy_fork_copy_and_direct_replay_dedup(self):
        self.logfile(self.codex, 'original.jsonl', [codex_header(), token_event(usage()), direct(usage())])
        self.logfile(self.codex, 'fork.jsonl', [codex_header('fork-session'), token_event(usage()), direct(usage())])
        self.assertEqual(len(self.collect()['records']), 1)

    def test_distinct_strong_responses_never_merge_on_equal_usage_time(self):
        a = direct(usage(), response='response-a')
        b = direct(usage(), response='response-b'); b['payload']['thread_id'] = 'thread-2'
        self.logfile(self.codex, 'a.jsonl', [codex_header(), a])
        self.logfile(self.codex, 'b.jsonl', [codex_header('thread-2'), b])
        records = self.collect()['records']
        self.assertEqual(len(records), 2)
        self.assertEqual(len({r['session'] for r in records}), 2)
        self.assertEqual(len(self.collect()['records']), 2)  # Persist strong identity.
        self.logfile(self.codex, 'fork.jsonl', [codex_header('fork'), a])
        self.assertEqual(len(self.collect()['records']), 2)

    def test_missing_last_usage_never_reemits_cumulative(self):
        event = token_event(usage()); event['payload']['info'].pop('last_token_usage')
        self.logfile(self.codex, 'rollout.jsonl', [codex_header(), event])
        self.assertEqual(self.collect()['records'], [])

    def test_partial_line_append_and_atomic_replacement_rotation(self):
        path = self.logfile(self.codex, 'rollout.jsonl', [codex_header()])
        raw = lines([token_event(usage())]); cut = len(raw) // 2
        with path.open('ab') as stream: stream.write(raw[:cut])
        self.assertEqual(self.collect()['records'], [])
        with path.open('ab') as stream: stream.write(raw[cut:])
        self.assertEqual(len(self.collect()['records']), 1)
        replacement = path.with_suffix('.tmp')
        replacement.write_bytes(lines([codex_header(), token_event(usage()), direct(usage(150, 30), response='new-response')]))
        os.replace(replacement, path)
        self.assertEqual(len(self.collect()['records']), 2)

    def test_dsh_chunk_final_message_seed_and_repeat(self):
        self.logfile(self.dsh, 'project/session/session.v4.jsonl', [dsh_header(),
            dsh_event(step=0, time=MS - 1000), dsh_event(kind='assistant/chunk'), dsh_event()])
        records = self.collect()['records']; self.assertEqual(len(records), 1)
        self.assertEqual(records[0]['inputTokens'], 90)
        self.assertEqual(len(self.collect()['records']), 1)

    def test_only_highest_dsh_generation(self):
        self.logfile(self.dsh, 'p/s/session.v3.jsonl', [dsh_header(), dsh_event(step=2)])
        self.logfile(self.dsh, 'p/s/session.v4.jsonl', [dsh_header(), dsh_event(step=1)])
        self.assertEqual(len(self.collect()['records']), 1)

    def test_cache_plugin_estimate_enriches_same_record_without_rebroadcast(self):
        self.logfile(self.dsh, 'p/s/session.jsonl', [dsh_header(), dsh_event()])
        first = self.collect()['records'][0]
        directory = self.dsh / 'storages/cost-meter/ledger.json.details-cache'
        directory.mkdir(parents=True)
        # Aggregate ledger is deliberately invalid: collector must never open it.
        (directory.parent / 'ledger.json').write_text('FORBIDDEN_AGGREGATE')
        call = dict(sessionId='dsh-1', kind='model', turn=1, step=1, logSeq=4, atMs=MS,
                    model='deepseek-flash', priced=True, plan=False, cost=0.000123456789012345,
                    rows=[dict(bucket='input', tokens=30), dict(bucket='cacheRead', tokens=50)])
        (directory / 'fixture.json').write_text(json.dumps(dict(version=2, value=dict(steps=[dict(callRefs=[call, call])]))))
        records = self.collect()['records']; self.assertEqual(len(records), 1)
        self.assertEqual(records[0]['id'], first['id']); self.assertEqual(records[0]['costKind'], 'estimated')
        self.assertEqual(records[0]['costAmount'], '0.000162')
        self.assertEqual(records[0]['currency'], 'CNY')
        self.assertIn('DeepSeek官方价', records[0]['costBasis'])
        self.assertEqual(records[0]['inputTokens'], 90)  # Preserve complete source usage over partial display rows.

    def price_record(self, model='deepseek-flash', time=TIME, **extra):
        return dict(source='dsh', model=model, occurredAt=time, costKind='unavailable',
                    inputTokens=354082, outputTokens=157, cachedInputTokens=353920,
                    uncachedInputTokens=162, cacheWriteTokens=0, **extra)

    def test_official_price_screenshot_peak_offpeak_pro_and_aliases(self):
        calendar = u.official_price_calendar()
        self.assertEqual(u.official_deepseek_cost(self.price_record(), calendar)['costAmount'], '0.0157368')
        self.assertEqual(u.official_deepseek_cost(self.price_record(time='2026-10-23T04:00:00Z'), calendar)['costAmount'], '0.0078684')
        self.assertEqual(u.official_deepseek_cost(self.price_record(model='deepseek-v4-pro'), calendar)['costAmount'], '0.111873')
        for alias in ['deepseek-v4-flash', 'deepseek-v4-flash-vision-exp']:
            self.assertEqual(u.official_deepseek_cost(self.price_record(model=alias), calendar)['costAmount'], '0.0157368')

    def test_official_price_boundaries_weekend_and_holiday(self):
        calendar = u.official_price_calendar()
        for time, phase in [('2026-10-23T00:59:59Z', '空闲'), ('2026-10-23T01:00:00Z', '高峰'),
                            ('2026-10-23T04:00:00Z', '空闲'), ('2026-10-23T06:00:00Z', '高峰'),
                            ('2026-10-23T10:00:00Z', '空闲'), ('2026-10-24T06:00:00Z', '空闲'),
                            ('2026-10-01T06:00:00Z', '空闲')]:
            self.assertIn(phase, u.official_deepseek_cost(self.price_record(time=time), calendar)['costBasis'])

    def test_official_price_inclusive_reasoning_write_and_unknowns(self):
        calendar = u.official_price_calendar()
        rec = self.price_record(); rec.update(inputTokens=90, cachedInputTokens=50,
            uncachedInputTokens=30, cacheWriteTokens=10, outputTokens=10, reasoningTokens=3)
        # Cache writes use cache-miss rate; reasoning is already included in output.
        self.assertEqual(u.official_deepseek_cost(rec, calendar)['costAmount'], '0.000162')
        codex = dict(rec, source='codex'); codex.pop('cacheWriteTokens')
        self.assertEqual(u.official_deepseek_cost(codex, calendar)['costAmount'], '0.000162')
        for patch in [dict(model='gpt-5'), dict(model=None), dict(cachedInputTokens=None),
                      dict(outputTokens=None), dict(inputTokens=1), dict(costKind='reported'),
                      dict(cacheWriteTokens=None), dict(occurredAt='2026-09-01T06:00:00Z'),
                      dict(occurredAt='2027-01-04T06:00:00Z')]:
            self.assertIsNone(u.official_deepseek_cost(dict(rec, **patch), calendar))
        self.assertIsNone(u.official_deepseek_cost(rec, None))
        zero = dict(rec, inputTokens=0, outputTokens=0, cachedInputTokens=0,
                    uncachedInputTokens=0, cacheWriteTokens=0)
        self.assertEqual(u.official_deepseek_cost(zero, calendar)['costAmount'], '0.00')

    def test_official_price_backfills_saved_records_without_changing_identity(self):
        rec = self.price_record(); rec.update(id='stable', session='opaque')
        collector = u.Collector(dict(version=1, records=[rec]))
        result = collector.result()['records'][0]
        self.assertEqual(result['id'], 'stable'); self.assertEqual(result['currency'], 'CNY')
        self.assertEqual(result['costKind'], 'estimated')
        replay = u.Collector(collector.state()).result()['records'][0]
        self.assertEqual(result, replay)

    def test_newest_cost_cache_is_not_starved_by_directory_order(self):
        directory = self.dsh / 'storages/cost-meter/ledger.json.details-cache'
        directory.mkdir(parents=True)
        for index in range(35):
            path = directory / ('old-%02d.json' % index)
            path.write_text(json.dumps(dict(version=2, value=dict(steps=[]))))
            os.utime(path, (100, 100))
        call = dict(sessionId='dsh-1', kind='model', turn=1, step=1, logSeq=4, atMs=MS,
                    priced=True, plan=False, cost='0.0123', rows=[])
        (directory / 'latest.json').write_text(json.dumps(dict(version=2, value=dict(steps=[dict(callRefs=[call])]))))
        snapshot = self.collect()
        self.assertEqual(snapshot['status']['dsh'], 'partial')
        self.assertEqual(len(snapshot['records']), 1)
        self.assertEqual(snapshot['records'][0]['costAmount'], '0.0123')

    def test_in_place_truncation_same_size_detected(self):
        first = usage(100, 20)
        path = self.logfile(self.codex, 'rollout.jsonl', [codex_header(), direct(first)])
        self.collect()
        replacement = lines([codex_header(), direct(usage(110, 20), response='response-2')])
        self.assertEqual(len(replacement), path.stat().st_size)
        path.write_bytes(replacement)
        self.assertEqual(len(self.collect()['records']), 2)

    def test_metadata_privacy_private_state_and_no_broadcast_contract(self):
        self.logfile(self.codex, 'rollout.jsonl', [codex_header(), token_event(usage())])
        snapshot = self.collect()
        saved = self.state.read_text()
        self.assertNotIn('SECRET_PROMPT', saved); self.assertNotIn('thread-1', saved)
        self.assertNotIn(str(self.codex), saved); self.assertNotIn('broadcast', json.dumps(snapshot))
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertLess(self.state.stat().st_size, u.MAX_STATE)

    def test_limits_and_source_symlink(self):
        self.logfile(self.codex, 'a.jsonl', [codex_header(), token_event(usage())])
        old = u.MAX_READ
        try:
            u.MAX_READ = 1
            self.assertEqual(self.collect()['status']['codex'], 'partial')
        finally:
            u.MAX_READ = old
        external = self.root / 'external'; external.mkdir()
        (self.dsh / 'sessions').symlink_to(external, target_is_directory=True)
        self.assertEqual(self.collect()['status']['dsh'], 'unavailable')

    def compress(self, raw):
        decoder = u.Zstd()
        if not decoder.lib:
            self.skipTest('libzstd unavailable; runtime reports decoderUnavailable honestly')
        lib = decoder.lib
        lib.ZSTD_compressBound.argtypes = [ctypes.c_size_t]; lib.ZSTD_compressBound.restype = ctypes.c_size_t
        lib.ZSTD_compress.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int]
        lib.ZSTD_compress.restype = ctypes.c_size_t
        capacity = lib.ZSTD_compressBound(len(raw)); out = ctypes.create_string_buffer(capacity)
        src = ctypes.create_string_buffer(raw); count = lib.ZSTD_compress(out, capacity, src, len(raw), 1)
        self.assertFalse(lib.ZSTD_isError(count))
        return out.raw[:count]

    def test_compressed_independent_frames_incremental_partial_frame(self):
        path = self.dsh / 'sessions/p/s/session.v4.jsonl.zstd'; path.parent.mkdir(parents=True)
        path.write_bytes(self.compress(lines([dsh_header(), dsh_event()])))
        first = self.collect(); self.assertEqual(len(first['records']), 1)
        first_state = json.loads(self.state.read_text())
        offset = next(v['offset'] for v in first_state['files'].values() if 'offset' in v)
        self.assertEqual(offset, path.stat().st_size)
        append = self.compress(lines([dsh_event(step=2)])); cut = len(append) // 2
        with path.open('ab') as stream: stream.write(append[:cut])
        self.assertEqual(len(self.collect()['records']), 1)
        with path.open('ab') as stream: stream.write(append[cut:])
        result = self.collect(); self.assertEqual(len(result['records']), 2)
        self.assertEqual(result['status']['dsh'], 'ready')


if __name__ == '__main__':
    unittest.main(verbosity=2)
