"""Boot a private copy and stop it after the dedicated server reports ready."""
import os
import selectors
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from worlds import unzip,locate,validate_level,world_path,tree_files
import shutil

def boot(profile,source,java,args,disabled):
    with tempfile.TemporaryDirectory(prefix='lantern-world-test-') as tmp:
        root=Path(tmp)
        if source:
            unzip(source,root)
            validate_level(world_path(root))
        else:
            for p in profile.iterdir():
                if p.name.startswith('.') or p.name in ('logs','crash-reports','libraries','versions','tmp','cache'):continue
                if p.is_symlink():raise ValueError('Cannot use a linked server directory for a trial.')
                if p.is_dir():
                    for _ in tree_files(p):pass
                    shutil.copytree(p,root/p.name)
                else:shutil.copy2(p,root/p.name)
        for name in ('versions','libraries'):
            if (profile/name).is_dir() and not (root/name).exists():
                shutil.copytree(profile/name,root/name)
        for rel in disabled:
            for folder in ('mods','plugins'):
                p=root/folder/rel
                if p.is_file():p.rename(p.with_suffix('.jar.disabled'))
        prop=root/'server.properties'
        with socket.socket() as sock:
            sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
        overrides={'server-ip':'127.0.0.1','server-port':str(port),'enable-query':'false','enable-rcon':'false','management-server-enabled':'false','white-list':'true','view-distance':'3','simulation-distance':'3'}
        lines=(prop.read_text() if prop.exists() else '').splitlines()
        prop.write_text('\n'.join([l for l in lines if l.split('=',1)[0] not in overrides]+[k+'='+v for k,v in overrides.items()])+'\n')
        (root/'eula.txt').write_text('eula=true\n')
        command=[java,'-Xms256M','-Xmx1G']+args
        proc=subprocess.Popen(command,cwd=root,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        try:
            last=b'';deadline=time.monotonic()+140
            with selectors.DefaultSelector() as sel:
                sel.register(proc.stdout,selectors.EVENT_READ)
                while time.monotonic()<deadline:
                    for key,_ in sel.select(0.5):
                        chunk=os.read(key.fd,8192)
                        if not chunk:raise ValueError('Trial exited: '+last[-1600:].decode(errors='replace'))
                        last=(last+chunk)[-16384:]
                        if b'Done (' in last and b'For help' in last:
                            proc.communicate(b'stop\n',timeout=60)
                            if proc.returncode:raise ValueError('The trial did not stop cleanly.')
                            return 'Test copy loaded and stopped cleanly.'
            raise ValueError('Test world did not finish loading: '+last[-1000:].decode(errors='replace'))
        finally:
            if proc.poll() is None:
                proc.kill();proc.wait()
