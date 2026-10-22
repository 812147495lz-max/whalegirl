#!/usr/bin/env python3
"""Install the metadata-only observer into an existing DSH desktop profile; keep a rollback copy."""
from pathlib import Path
import datetime
import json
import hashlib
import re
import shutil

home = Path.home()
profile = home / '.dsh/profiles/desktop'
patch = profile / 'cordis.patch.yml'
if not profile.is_dir():
    raise SystemExit('DSH desktop profile not found; start DSH once before installing.')
source = Path(__file__).with_name('whalegirl-status.mjs')
digest = hashlib.sha256(source.read_bytes()).hexdigest()[:12]
target = home / 'Library/Application Support/WhaleGirl/integrations' / ('whalegirl-status-' + digest + '.mjs')
text = patch.read_text() if patch.exists() else ''
if 'whalegirl-dsh-status' in text:
    pattern = r'(^    - id: whalegirl-dsh-status(?:-v[0-9]+|-[a-f0-9]{12})?\n      name: )[^\n]+'
    updated, count = re.subn(pattern, lambda match: '    - id: whalegirl-dsh-status-' + digest + '\n      name: ' + json.dumps(target.as_uri()), text, flags=re.MULTILINE)
    if count != 1: raise SystemExit('Observer entry format changed; refusing to alter unrelated settings.')
    if updated == text and target.is_file(): raise SystemExit('Current observer already configured; no changes made.')
else:
    updated = None
backup = profile / ('cordis.patch.whalegirl-backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S') + '.yml')
if patch.exists(): shutil.copy2(patch, backup)
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(source, target)
addition = '\n- insert:\n    - id: whalegirl-dsh-status-' + digest + '\n      name: ' + json.dumps(target.as_uri()) + '\n      config: {}\n'
if text.strip() == '[]': text = ''
temporary = patch.with_name('cordis.patch.whalegirl-tmp.yml')
temporary.write_text(updated if updated is not None else text.rstrip() + '\n' + addition)
temporary.replace(patch)
patch.chmod(0o600)
print('DSH desktop observer installed; existing profile preserved and backup created. Restart DSH if hot reload does not apply.')
