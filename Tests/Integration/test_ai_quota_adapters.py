import importlib.util
from pathlib import Path
import unittest
from unittest import mock

path = Path(__file__).parents[2] / 'Apps/macOS/Resources/AIMonitor/whale_ai_usage.py'
spec = importlib.util.spec_from_file_location('usage', path)
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)

class QuotaAdapterTests(unittest.TestCase):
    def test_finder_environment_can_launch_homebrew_cli_dependencies(self):
        original = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'KEEP': 'unchanged'}
        env = usage.cli_environment(original)
        self.assertIn('/opt/homebrew/bin', env['PATH'].split(':'))
        self.assertIn('/usr/local/bin', env['PATH'].split(':'))
        self.assertEqual(env['KEEP'], 'unchanged')
        self.assertEqual(original['PATH'], '/usr/bin:/bin:/usr/sbin:/sbin')
        self.assertEqual(usage.cli_environment(env)['PATH'], env['PATH'])

    def test_cli_exiting_without_response_is_unavailable_not_timeout(self):
        with mock.patch.object(usage.shutil, 'which', return_value='/usr/bin/true'):
            result = usage.codex_quota()
        self.assertEqual(result['state'], 'unavailable')

    def test_codexbar_windows_placeholder_unknown_period_privacy(self):
        data = [dict(account='PRIVATE', diagnostic='SECRET', usage=dict(updatedAt='2026-10-21T01:00:00Z',
            primary=dict(usedPercent=0, windowMinutes=300, isSyntheticPlaceholder=True),
            secondary=dict(usedPercent=12, windowMinutes=10080),
            tertiary=dict(usedPercent=105), extraRateWindows=[dict(usageKnown=False, window=dict(usedPercent=100))]),
            rateWindowLabels=dict(tertiary='月额度'))]
        result = usage.normalize_codexbar('fixture', data)
        self.assertEqual(result['state'], 'ready')
        self.assertEqual(len(result['windows']), 2)
        self.assertEqual(result['windows'][0]['durationSeconds'], 604800)
        self.assertEqual(result['windows'][0]['remainingPercent'], 88)
        self.assertEqual(result['windows'][1]['periodLabel'], '月额度')
        self.assertEqual(result['windows'][1]['remainingPercent'], 0)
        self.assertNotIn('PRIVATE', str(result)); self.assertNotIn('SECRET', str(result))
        self.assertEqual(result['fetchedAt'], '2026-10-21T01:00:00Z')
    def test_missing_usage_not_full_quota(self):
        self.assertNotEqual(usage.normalize_codexbar('fixture', [dict(error={})])['state'], 'ready')
        result = usage.normalize_codex(dict(rateLimits=dict(primary=dict(usedPercent=25, windowDurationMins=300))))
        self.assertEqual(result['windows'][0]['remainingPercent'], 75)
    def test_money_uses_decimal_and_bonus_is_not_lost(self):
        result = usage.normalize_dsh(dict(code=0, data=dict(biz_code=0, biz_data=dict(
            normal_wallets=[dict(currency='CNY', balance='0.1')], bonus_wallets=[dict(currency='CNY', balance='0.2')]))))
        self.assertEqual(result['balances'][0]['amount'], '0.3')
        self.assertEqual(result['balances'][0]['bonusAmount'], '0.2')

    def test_opencode_direct_percent_is_not_fraction_or_browser_data(self):
        payload = dict(email='PRIVATE', usage=dict(rolling=dict(percent=0.5, resetInSec=3600), weekly=dict(percent=24), monthly=dict(percent=110)))
        result = usage.normalize_opencode_go(payload)
        self.assertEqual(result['state'], 'ready')
        self.assertEqual([w['remainingPercent'] for w in result['windows']], [99.5, 76, 0])
        self.assertEqual(result['windows'][2]['durationSeconds'], 0)
        self.assertEqual(result['windows'][2]['periodLabel'], '月额度')
        self.assertNotIn('PRIVATE', str(result))
        self.assertEqual(usage.normalize_opencode_go(dict(usage=dict(rolling=dict(percent=True))))['state'], 'invalidData')
        self.assertEqual(usage.normalize_opencode_go(dict(usage={}))['state'], 'unsupported')

    def test_opencode_401_is_authentication_failure_not_full_quota(self):
        import tempfile, json, urllib.error
        with tempfile.TemporaryDirectory() as folder:
            home=Path(folder); target=home/'.local/share/opencode';target.mkdir(parents=True)
            (target/'auth.json').write_text(json.dumps({'opencode-go':{'type':'api','key':'TEST-KEY'}}))
            opener=mock.Mock();opener.open.side_effect=urllib.error.HTTPError('https://opencode.ai/zen/go/v1/usage',401,'denied',{},None)
            with mock.patch.object(usage.urllib.request,'build_opener',return_value=opener):
                result=usage.opencode_go_quota(home)
            self.assertEqual(result['state'],'authenticationFailed');self.assertEqual(result['windows'],[])
            request=opener.open.call_args.args[0]
            self.assertEqual(request.full_url,'https://opencode.ai/zen/go/v1/usage')
            self.assertEqual(request.get_method(),'GET')
            self.assertNotIn('TEST-KEY',str(result))

    def test_backend_error_categories_do_not_claim_native_apps_signed_out(self):
        for message,state in [('Keychain cookie access blocked','browserConnectionRequired'),('No available fetch strategy for grok.','unsupported'),('HTTP 401','authenticationFailed')]:
            self.assertEqual(usage.normalize_codexbar('fixture',[dict(error=dict(message=message))])['state'],state)

if __name__ == '__main__': unittest.main()
