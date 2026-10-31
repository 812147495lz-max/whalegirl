import http.server
import os
from pathlib import Path
import subprocess
import sys
import threading
import unittest

CLIENT = Path(__file__).resolve().parents[2] / 'Scripts/send_whale_message.py'


class MessageClientTests(unittest.TestCase):
    def test_remote_http_is_rejected_before_sending_credentials(self):
        result = subprocess.run([sys.executable, str(CLIENT), '--url', 'http://example.invalid', 'pull'], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('HTTPS', result.stderr)

    def test_redirect_does_not_forward_api_credential(self):
        visited = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                visited.append(self.path)
                self.send_response(302 if self.path.startswith('/v1/') else 200)
                if self.path.startswith('/v1/'):
                    self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/leak')
                self.end_headers()
                self.wfile.write(b'{}')

            def log_message(self, *_args):
                pass

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            result = subprocess.run([sys.executable, str(CLIENT), '--url', f'http://127.0.0.1:{server.server_port}', 'pull'],
                env=dict(os.environ, WHALEGIRL_API_TOKEN='a' * 64), capture_output=True, text=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('/leak', visited)
            self.assertEqual(len(visited), 1)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)


if __name__ == '__main__':
    unittest.main()
