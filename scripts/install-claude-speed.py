#!/usr/bin/env python3
"""Install the passive observer while preserving all other Claude settings."""
import json
from pathlib import Path
import shlex
import shutil
import sys

home=Path.home()
settings=home/'.claude/settings.json'
config=json.loads(settings.read_text())
root=home/'.config/howmanyusage'
root.mkdir(parents=True, exist_ok=True)
observer=root/'claude-speed-statusline.py'
command='/usr/bin/python3 '+shlex.quote(str(observer))
original=config.get('statusLine')
if not original or original.get('type')!='command':
    sys.exit('Expected an existing command statusline; no configuration changed.')
if original.get('command') != command:
    backup=root/'claude-statusline-original.json'
    if backup.exists():
        sys.exit('Existing observer backup found with a different active statusline; no configuration changed.')
    backup.write_text(json.dumps(original,indent=2)+'\n')
    backup.chmod(0o600)
    shutil.copy2(settings,root/'claude-settings-before-speed.json')
    config['statusLine']={**original,'command':command}
shutil.copy2(Path(__file__).with_name('claude-speed-statusline.py'),observer)
if original.get('command') != command:
    temp=settings.with_name('settings.howmanyusage.tmp')
    temp.write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')
    temp.chmod(settings.stat().st_mode & 0o777)
    temp.replace(settings)
print('Passive observer installed; previous HUD preserved. No model requests.')
