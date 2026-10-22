#!/usr/bin/env python3
"""Read-only quota adapters. Never print credentials, conversations or raw server errors."""
import concurrent.futures
import datetime as dt
import decimal
import json
import math
import os
from pathlib import Path
import re
import selectors
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request


def timestamp():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')


def reading(provider, state='unavailable', windows=None, balances=None):
    return dict(providerId=provider, state=state, fetchedAt=timestamp(), windows=windows or [], balances=balances or [])


def cli_environment(base=None):
    # Finder/LaunchServices omit Homebrew from PATH. npm CLI launchers need `env node`.
    env = dict(os.environ if base is None else base)
    paths = [part for part in env.get('PATH', '').split(os.pathsep) if part]
    for path in ['/opt/homebrew/bin', '/usr/local/bin', str(Path.home() / '.local/bin'), '/usr/bin', '/bin']:
        if path not in paths:
            paths.append(path)
    env['PATH'] = os.pathsep.join(paths)
    return env


def codex_quota():
    environment = cli_environment()
    executable = shutil.which('codex', path=environment['PATH'])
    if not executable:
        executable = next((p for p in ['/opt/homebrew/bin/codex', '/usr/local/bin/codex',
            '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex',
            '/Applications/Codex.app/Contents/Resources/codex'] if os.access(p, os.X_OK)), None)
    if not executable:
        return reading('codex', 'notInstalled')
    process, selector = None, None
    try:
        process = subprocess.Popen([executable, 'app-server', '--stdio'], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=environment)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        def send(value):
            process.stdin.write((json.dumps(value) + '\n').encode()); process.stdin.flush()
        send(dict(id=1, method='initialize', params=dict(clientInfo=dict(name='whalegirl_usage', version='0.2.0'),
            capabilities=dict(experimentalApi=True))))
        buffer = b''
        deadline = time.monotonic() + 18
        while time.monotonic() < deadline:
            if not selector.select(0.3):
                continue
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                return reading('codex', 'unavailable')
            buffer += chunk
            if len(buffer) > 2 * 1024 * 1024:
                return reading('codex', 'invalidData')
            while b'\n' in buffer:
                raw, buffer = buffer.split(b'\n', 1)
                try:
                    value = json.loads(raw)
                except (ValueError, UnicodeError):
                    continue
                if value.get('id') == 1:
                    if 'error' in value:
                        return reading('codex', 'unavailable')
                    send(dict(method='initialized'))
                    send(dict(id=2, method='account/rateLimits/read'))
                elif value.get('id') == 2:
                    if 'error' in value:
                        return reading('codex', 'signInRequired')
                    return normalize_codex(value.get('result', {}))
        return reading('codex', 'timeout')
    except (OSError, ValueError, TypeError, KeyError):
        return reading('codex', 'unavailable')
    finally:
        if selector is not None:
            selector.close()
        if process is not None:
            if process.stdin:
                try:
                    process.stdin.close()
                except OSError:
                    pass
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
            if process.stdout:
                process.stdout.close()


def normalize_codex(result):
    buckets = result.get('rateLimitsByLimitId') or {'codex': result.get('rateLimits')}
    windows = []
    for key, bucket in buckets.items():
        if not isinstance(bucket, dict):
            continue
        for slot in ['primary', 'secondary']:
            window = bucket.get(slot)
            if not isinstance(window, dict):
                continue
            used, minutes = window.get('usedPercent'), window.get('windowDurationMins')
            if isinstance(used, (int, float)) and isinstance(minutes, int) and minutes > 0 and 0 <= used <= 100:
                item = dict(durationSeconds=minutes * 60, remainingPercent=100 - used)
                reset = window.get('resetsAt')
                if isinstance(reset, (int, float)):
                    item['resetsAt'] = dt.datetime.fromtimestamp(reset, dt.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
                if len(buckets) > 1:
                    item['bucket'] = str(bucket.get('limitName') or key)[:50]
                windows.append(item)
    return reading('codex', 'ready' if windows else 'unsupported', windows)


def yaml_scalar(raw):
    raw = raw.strip()
    if raw.startswith('"'):
        return json.loads(raw)
    if raw.startswith("'") and raw.endswith("'"):
        return raw[1:-1].replace("''", "'")
    if not raw or raw[0] in '|>&*!{[':
        raise ValueError('unsupported scalar')
    return raw


def dsh_grant(home=None):
    path = (home or Path.home()) / '.dsh' / '.credentials.yaml'
    if not path.exists() or path.stat().st_size > 256 * 1024:
        return None
    # Deliberately read only the known grant record, not arbitrary YAML objects/tags.
    lines = path.read_text(encoding='utf-8').splitlines()
    active, indent, result = False, 0, {}
    for line in lines:
        stripped = line.strip()
        current_indent = len(line) - len(line.lstrip())
        if stripped.rstrip(':').strip('"\'') == 'deepseek-account-platform/default':
            active, indent = True, current_indent
            continue
        if not active:
            continue
        if stripped and current_indent <= indent:
            break
        match = re.fullmatch(r'\s*(token|issuer):\s*(.*?)\s*', line)
        if match:
            result[match[1]] = yaml_scalar(match[2])
    if result.get('issuer') != 'https://platform.deepseek.com' or not result.get('token'):
        return None
    if not isinstance(result['token'], str) or not re.fullmatch(r'[\x21-\x7e]{1,16384}', result['token']):
        return None
    return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, 'Redirect rejected', headers, fp)


def normalize_dsh(payload):
    if payload.get('code') == 40003:
        return reading('dsh', 'signInRequired')
    envelope = payload.get('data', {})
    if payload.get('code') != 0 or envelope.get('biz_code') != 0:
        return reading('dsh', 'unavailable')
    data = envelope.get('biz_data', {})
    wallets, bonus = {}, {}
    if not all(isinstance(data.get(name), list) for name in ['normal_wallets', 'bonus_wallets']):
        return reading('dsh', 'invalidData')
    for name, destination in [('normal_wallets', wallets), ('bonus_wallets', bonus)]:
        for row in data[name]:
            currency = row.get('currency')
            if currency not in ['CNY', 'USD']:
                continue
            amount = decimal.Decimal(str(row.get('balance', 'NaN')))
            if not amount.is_finite() or abs(amount) > decimal.Decimal('1e15'):
                return reading('dsh', 'invalidData')
            destination[currency] = destination.get(currency, decimal.Decimal(0)) + amount
    balances = [dict(currency=currency, amount=str(wallets.get(currency, 0) + bonus.get(currency, 0)),
        bonusAmount=str(bonus.get(currency, 0))) for currency in sorted(set(wallets) | set(bonus))]
    return reading('dsh', 'ready' if balances else 'unsupported', balances=balances)


def dsh_balance():
    try:
        grant = dsh_grant()
        if not grant:
            return reading('dsh', 'signInRequired')
        request = urllib.request.Request('https://platform.deepseek.com/api/v0/users/get_user_summary', headers={
            'x-dsh-auth-token': grant['token'], 'x-client-platform': 'web', 'x-client-version': '0.2.0',
            'x-client-bundle-id': '', 'x-client-locale': 'zh_CN', 'x-client-timezone-offset': '28800',
            'User-Agent': 'WhaleGirl/0.2.0'}, method='GET')
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=15) as response:
            raw = response.read(65537)
            if len(raw) > 65536:
                return reading('dsh', 'invalidData')
            return normalize_dsh(json.loads(raw))
    except urllib.error.HTTPError as error:
        return reading('dsh', 'signInRequired' if error.code in [401, 403] else 'unavailable')
    except (OSError, ValueError, TypeError, decimal.InvalidOperation):
        return reading('dsh', 'unavailable')


def normalize_codexbar(provider, payload):
    # Whitelist quota fields; account identifiers, diagnostics, costs and history never leave this adapter.
    if not isinstance(payload, list):
        return reading(provider, 'invalidData')
    row = next((item for item in payload if isinstance(item, dict) and isinstance(item.get('usage'), dict)), None)
    if not row:
        # Static diagnostic classification only; never forward raw server/account text.
        messages = ' '.join(str(item.get('error', {}).get('message', '')) for item in payload
            if isinstance(item, dict) and isinstance(item.get('error'), dict)).lower()
        state = 'unavailable'
        if any(word in messages for word in ['keychain', 'cookie', 'browser session']): state = 'browserConnectionRequired'
        elif 'no available fetch strategy' in messages: state = 'unsupported'
        elif any(word in messages for word in ['unauthorized', '401', 'expired', 'invalid token']): state = 'authenticationFailed'
        elif any(word in messages for word in ['sign in', 'login', 'credentials', 'not logged']): state = 'signInRequired'
        return reading(provider, state)
    usage, windows = row['usage'], []
    labels = row.get('rateWindowLabels') or {}
    slots = [(usage.get(key), labels.get(key) or '额度') for key in ['primary', 'secondary', 'tertiary']]
    slots += [(item.get('window'), item.get('title') or '额度') for item in usage.get('extraRateWindows', [])
              if isinstance(item, dict) and item.get('usageKnown', True)]
    for window, label in slots:
        if not isinstance(window, dict) or window.get('isSyntheticPlaceholder', False):
            continue
        used, minutes = window.get('usedPercent'), window.get('windowMinutes')
        if not isinstance(used, (int, float)) or not math.isfinite(used) or used < 0:
            continue
        seconds = int(minutes * 60) if isinstance(minutes, (int, float)) and math.isfinite(minutes) and minutes > 0 else 0
        if seconds > 366 * 86400:
            continue
        item = dict(durationSeconds=seconds, remainingPercent=max(0, 100-used))
        if not seconds:
            item['periodLabel'] = str(label)[:60]
        if isinstance(window.get('resetsAt'), str):
            item['resetsAt'] = window['resetsAt']
        windows.append(item)
    value = reading(provider, 'ready' if windows else 'unsupported', windows[:30])
    if isinstance(usage.get('updatedAt'), str):
        value['fetchedAt'] = usage['updatedAt']
    return value


def normalize_opencode_go(payload):
    if not isinstance(payload, dict): return reading('opencode', 'invalidData')
    usage = payload.get('usage')
    if not isinstance(usage, dict): return reading('opencode', 'unsupported')
    windows = []
    for name, duration, label in [('rolling', 18000, None), ('weekly', 604800, None), ('monthly', 0, '月额度')]:
        window = usage.get(name)
        if window is None: continue
        if not isinstance(window, dict): return reading('opencode', 'invalidData')
        used = window.get('percent')
        if isinstance(used, bool) or not isinstance(used, (float, int)) or not math.isfinite(used) or used < 0:
            return reading('opencode', 'invalidData')
        item = dict(durationSeconds=duration, remainingPercent=max(0, 100-used))
        if label: item['periodLabel'] = label
        reset = window.get('resetInSec')
        if not isinstance(reset, bool) and isinstance(reset, (int, float)) and math.isfinite(reset) and 0 <= reset <= 366*86400:
            item['resetsAt'] = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=reset)).replace(microsecond=0).isoformat().replace('+00:00', 'Z')
        windows.append(item)
    return reading('opencode', 'ready' if windows else 'unsupported', windows=windows)


def opencode_go_quota(home=None):
    # OpenCode Desktop and CLI share this documented auth store. Do not require a CLI binary or browser cookies.
    path = (home or Path.home()) / '.local/share/opencode/auth.json'
    try:
        if not path.is_file(): return reading('opencode', 'signInRequired')
        if path.stat().st_size > 262144: return reading('opencode', 'invalidData')
        record = json.loads(path.read_text()).get('opencode-go', {})
        key = record.get('key') if record.get('type') == 'api' else None
        if not isinstance(key, str) or not re.fullmatch(r'[\x21-\x7e]{1,16384}', key):
            return reading('opencode', 'signInRequired')
        request = urllib.request.Request('https://opencode.ai/zen/go/v1/usage', method='GET', headers={
            'Authorization': 'Bearer ' + key, 'Accept': 'application/json', 'User-Agent': 'WhaleGirl/0.2.0'})
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=12) as response:
            raw = response.read(262145)
            if len(raw) > 262144: return reading('opencode', 'invalidData')
            return normalize_opencode_go(json.loads(raw))
    except urllib.error.HTTPError as error:
        return reading('opencode', 'authenticationFailed' if error.code in [401, 403] else 'unavailable')
    except (TimeoutError,): return reading('opencode', 'timeout')
    except (OSError, ValueError, TypeError, AttributeError): return reading('opencode', 'unavailable')


def codexbar_quota(provider, backend):
    if provider in ['gemini-cli', 'grok-cli']:
        command = 'gemini' if provider == 'gemini-cli' else 'grok'
        if not shutil.which(command, path=cli_environment()['PATH']): return reading(provider, 'notInstalled')
    executable = Path(__file__).resolve().parent / 'CodexBarCLI'
    if not executable.is_file():
        return reading(provider, 'notInstalled')
    if not re.fullmatch(r'[a-z0-9-]{1,60}', backend) or backend in ['all', 'both']:
        return reading(provider, 'invalidData')
    # Gemini web has 5-hour/week windows; Gemini CLI is a different product/account.
    source = 'cli' if provider == 'grok-cli' else 'auto' if provider == 'gemini-cli' else 'web' if backend == 'gemini' else 'oauth' if backend == 'claude' else 'auto'
    try:
        result = subprocess.run([str(executable), 'usage', '--provider', backend, '--source', source,
            '--json', '--no-credits', '--web-timeout', '8', '--log-level', 'error'],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=12, env=cli_environment())
        if len(result.stdout) > 2 * 1024 * 1024:
            return reading(provider, 'invalidData')
        return normalize_codexbar(provider, json.loads(result.stdout))
    except subprocess.TimeoutExpired:
        return reading(provider, 'timeout')
    except (OSError, ValueError, TypeError):
        return reading(provider, 'unavailable')


def main():
    try:
        request = json.loads(sys.stdin.buffer.read(65537))
        selected = request.get('providers', [])[:100]
        def fetch(item):
            if isinstance(item, str):
                item = dict(id=item, adapter=item)
            provider, adapter = item.get('id'), item.get('adapter')
            if adapter == 'codex':
                result = codex_quota()
            elif adapter == 'dsh':
                result = dsh_balance()
            elif adapter == 'opencode':
                result = opencode_go_quota()
            elif adapter == 'codexbar':
                result = codexbar_quota(provider, item.get('backendProvider', provider))
            else:
                result = reading(provider, 'unsupported')
            result['providerId'] = provider
            return result
        with concurrent.futures.ThreadPoolExecutor(max_workers=3) as executor:
            futures = [executor.submit(fetch, item) for item in selected]
            for future in concurrent.futures.as_completed(futures):
                try:
                    value = future.result()
                    print(json.dumps(dict(readings=[value]), ensure_ascii=False, allow_nan=False), flush=True)
                except Exception:
                    continue
    except Exception:
        print('{"readings":[]}')


if __name__ == '__main__':
    main()
