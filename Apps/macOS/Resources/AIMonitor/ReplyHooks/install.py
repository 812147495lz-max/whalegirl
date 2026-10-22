#!/usr/bin/env python3
"""Install only reply observers for locally present tools; preserve settings and native trust."""
from pathlib import Path
import datetime
import json
import shutil
import shlex
import argparse


def save(path, value):
    text=json.dumps(value,indent=2,ensure_ascii=False)+'\n'
    if path.exists() and path.read_text()==text:return
    path.parent.mkdir(parents=True,exist_ok=True)
    if path.exists():shutil.copy2(path,path.with_name(path.name+'.whalegirl-backup-'+datetime.datetime.now().strftime('%Y%m%d%H%M%S')+'.bak'))
    tmp=path.with_name(path.name+'.whalegirl-tmp');tmp.write_text(text);tmp.chmod(0o600);tmp.replace(path)


def install(only=None):
    home=Path.home();source=Path(__file__).parent
    folder=home/'Library/Application Support/WhaleGirl/integrations/reply-hooks';folder.mkdir(parents=True,exist_ok=True)
    script=folder/'whale_reply_hook.py';shutil.copy2(source/'whale_reply_hook.py',script)
    def command(provider,stage):return shlex.join(['/usr/bin/python3',str(script),'--provider',{'gemini':'gemini-cli','grok':'grok-cli'}.get(provider,provider),'--event',stage])
    def nested(provider,event,stage):return {'hooks':[{'type':'command','command':command(provider,stage),'timeout':2}]}
    targets=[
      ('cursor', home/'.cursor/hooks.json', [('beforeSubmitPrompt','working'),('stop','completed'),('subagentStart','child-start'),('subagentStop','child-end')]),
      ('gemini', home/'.gemini/settings.json', [('BeforeAgent','working'),('AfterAgent','completed')]),
      ('claude', home/'.claude/settings.json', [('UserPromptSubmit','working'),('Stop','completed'),('SubagentStart','child-start'),('SubagentStop','child-end')]),
      ('grok', home/'.grok/hooks/whalegirl-replies.json', [('UserPromptSubmit','working'),('Stop','completed')]),
      ('copilot', home/'.copilot/hooks/whalegirl-replies.json', [('userPromptSubmitted','working'),('agentStop','completed'),('subagentStart','child-start'),('subagentStop','child-end')])]
    failures=0
    for provider,path,events in targets:
        if only and only!=provider:continue
        marker=home/('.'+provider)
        if not marker.is_dir():print(provider+': not present; observer not installed');continue
        try:
            value=json.loads(path.read_text()) if path.exists() else {}
            if not isinstance(value,dict):raise ValueError()
            hooks=value.setdefault('hooks',{})
            if not isinstance(hooks,dict):raise ValueError()
            if provider in ['cursor','copilot']:value.setdefault('version',1)
            for event,stage in events:
                rows=hooks.setdefault(event,[])
                if not isinstance(rows,list):raise ValueError()
                rows[:]=[row for row in rows if 'whale_reply_hook.py' not in json.dumps(row)]
                if provider=='cursor':row={'command':command(provider,stage)}
                elif provider=='copilot':row={'type':'command','exec':'/usr/bin/python3','args':[str(script),'--provider',provider,'--event',stage],'timeoutSec':2}
                else:row=nested(provider,event,stage)
                rows.append(row)
            save(path,value);print(provider+': reply observer configured')
        except (OSError,ValueError,TypeError):
            failures+=1;print(provider+': settings unchanged; format or permission needs review')
    if (not only or only=='opencode') and ((home/'.config/opencode').is_dir() or Path('/Applications/OpenCode.app').exists()):
        target=home/'.config/opencode/plugins/whalegirl-replies.js';target.parent.mkdir(parents=True,exist_ok=True)
        if target.exists():shutil.copy2(target,target.with_name(target.name+'.backup'))
        shutil.copy2(source/'whalegirl-opencode.mjs',target);print('opencode: reply observer configured')
    print('Restart affected tools or use their native hook reload/review when required. No trust settings changed.')
    return 1 if failures else 0

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--provider',choices=['cursor','gemini','claude','grok','copilot','opencode'])
    raise SystemExit(install(parser.parse_args().provider))
