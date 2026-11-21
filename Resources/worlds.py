"""Lantern's stopped-world file operations. The caller holds the server profile lock."""
import ctypes
import gzip
import json
import os
import shutil
import stat
import sys
import tempfile
import uuid
import zipfile
from datetime import datetime
from pathlib import Path

def member(name):
    if not name or name in ('.', '..') or any(c in name for c in '/\\\r\n\0'):
        raise ValueError("Choose a simple folder name.")
    return name

def world_path(profile):
    name = 'world'
    properties = profile / 'server.properties'
    if properties.exists():
        for line in properties.read_text().splitlines():
            if line.startswith('level-name='):
                name = line[11:]
    return profile / member(name)

def tree_files(root):
    if root.is_symlink():
        raise ValueError("Choose the original folder instead of a symbolic link.")
    for base, dirs, files in os.walk(root):
        for name in dirs + files:
            p = Path(base) / name
            if p.is_symlink() or not (p.is_dir() or p.is_file()):
                raise ValueError("Unsupported linked or special file: " + name)
        for name in files:
            yield Path(base) / name

def unzip(source, dest):
    with zipfile.ZipFile(source) as archive:
        if sum(i.file_size for i in archive.infolist()) > shutil.disk_usage(dest).free:
            raise ValueError("The selected drive needs more free space for this ZIP.")
        for item in archive.infolist():
            parts = item.filename.rstrip('/').split('/')
            for part in parts:
                member(part)
            kind = stat.S_IFMT(item.external_attr >> 16)
            if kind not in (0, stat.S_IFDIR, stat.S_IFREG):
                raise ValueError("This ZIP contains a link or special file.")
            if '__MACOSX' in parts: continue
            target = dest.joinpath(*parts)
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open('xb') as out, archive.open(item) as inp:
                    shutil.copyfileobj(inp, out)

def validate_level(root):
    with gzip.open(root/'level.dat','rb') as f:
        if f.read(1) != b'\x0a':
            raise ValueError("Invalid Java world level.dat.")

def locate(root, preferred):
    if (root/'level.dat').is_file(): return root
    if (root/preferred/'level.dat').is_file(): return root/preferred
    matches = [p.parent for p in root.rglob('level.dat') if '__MACOSX' not in p.parts]
    if len(matches) != 1: raise ValueError("Choose one Java world folder containing level.dat.")
    return matches[0]

def archive_items(items, dest, metadata=None):
    dest.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=dest.parent, suffix='.partial', delete=False) as tmp:
        stage = Path(tmp.name)
    try:
        with zipfile.ZipFile(stage, 'w', zipfile.ZIP_DEFLATED, compresslevel=1) as out:
            for source, name in items:
                if source.is_symlink(): raise ValueError("Cannot archive a symbolic link.")
                files = tree_files(source) if source.is_dir() else [source]
                for p in files:
                    if p.name in ('session.lock','.DS_Store'): continue
                    out.write(p, Path(name)/p.relative_to(source) if source.is_dir() else name)
            if metadata is not None: out.writestr('lantern-profile.json', json.dumps(metadata))
        os.replace(stage, dest)
    finally:
        stage.unlink(missing_ok=True)

def snapshot(profile, folder, reason, settings):
    if not folder.is_dir(): raise ValueError("Reconnect or choose your backup folder.")
    if profile == folder or profile in folder.parents:
        raise ValueError("Choose a backup folder outside the server folder.")
    excluded = {'libraries','logs','cache','versions','crash-reports','tmp','server.jar','.fabric'}
    items = [(p,p.name) for p in profile.iterdir() if p.name not in excluded and not p.name.startswith('.')]
    name = 'Lantern-' + profile.name + '-' + reason + '-' + datetime.now().strftime('%Y%m%d-%H%M%S') + '-' + uuid.uuid4().hex[:6] + '.zip'
    path = folder/name
    archive_items(items,path,{'version':profile.name,'options':settings})
    return path

def prune(folder,version,limit):
    unpinned = [p for p in folder.glob('Lantern-'+version+'-auto-*.zip') if not p.with_suffix('.pin').exists()]
    newest_first = sorted(unpinned, key=lambda p: (p.stat().st_mtime_ns, p.name), reverse=True)
    for p in newest_first[max(1,limit):]:
        p.unlink()

def swap(stage, dest):
    if not dest.exists():
        stage.rename(dest)
        return
    lib = ctypes.CDLL(None,use_errno=True)
    if lib.renamex_np(os.fsencode(stage), os.fsencode(dest), 2):
        err=ctypes.get_errno()
        raise OSError(err, os.strerror(err))

def import_world(profile, source, backups, settings):
    world=world_path(profile)
    with tempfile.TemporaryDirectory(dir=profile.parent) as tmp:
        root=Path(tmp)
        if source.is_file():
            unzip(source,root)
            source=root
        source=locate(source,world.name)
        validate_level(source)
        if source==world: raise ValueError("This world is already active.")
        if source==root or root in source.parents:
            stage=source
            if stage==root:
                with tempfile.TemporaryDirectory(dir=profile.parent) as tmp2:
                    stage=Path(tmp2)/'world'
                    shutil.copytree(source,stage)
                    from playerdata import materialize_owner
                    materialize_owner(stage)
                    if world.exists(): snapshot(profile,backups,'before-import',settings)
                    swap(stage,world)
                return
        else:
            if source in root.parents: raise ValueError("Select the world folder itself.")
            for _ in tree_files(source): pass
            stage=root/'incoming'
            shutil.copytree(source,stage)
        from playerdata import materialize_owner
        materialize_owner(stage)
        if world.exists(): snapshot(profile,backups,'before-import',settings)
        swap(stage,world)

def main():
    op,profile,folder,settings,*args=sys.argv[1:]
    profile=Path(profile).resolve()
    folder=Path(folder).resolve()
    settings=json.loads(settings)
    profile.mkdir(parents=True,exist_ok=True)
    world=world_path(profile)
    if op=='trial':
        from trial import boot
        print(boot(profile,Path(args[0]) if args[0] else None,args[1],json.loads(args[2]),[member(n) for n in json.loads(args[3])]))
    elif op=='check':
        from modcheck import check
        opts=settings.get('profileOptions',{}).get(profile.name,{})
        issues=check(profile,opts.get('software','Vanilla'),opts)
        if issues:raise ValueError('Add-on compatibility: '+'; '.join(issues))
        print('Add-on declarations checked.')
    elif op=='upgrade':
        dest=profile.parent/member(args[0])
        if dest.exists():raise ValueError("That version already has a server folder. It was left in place.")
        path=snapshot(profile,folder,'before-update',settings)
        with tempfile.TemporaryDirectory(dir=profile.parent) as tmp:
            stage=Path(tmp)/'server';stage.mkdir()
            unzip(path,stage)
            (stage/'lantern-profile.json').unlink()
            for name in ['version.json','lantern-fabric.jar']:
                (stage/name).unlink(missing_ok=True)
            stage.rename(dest)
        print(path.name)
    elif op=='inventory':
        from playerdata import recover
        from uuid import UUID
        key=str(UUID(args[1]))+'.dat'
        choices=[world/'playerdata'/key,world/'players/data'/key]
        target=next((p for p in choices if p.is_file()),None)
        if not target:raise ValueError('The current world has no data for that player.')
        with zipfile.ZipFile(args[0]) as z:
            found=[i for i in z.namelist() if i in [str(t.relative_to(profile)) for t in choices]]
            if len(found)!=1:raise ValueError('One matching player record could not be found in this backup.')
            snapshot(profile,folder,'before-inventory',settings)
            with z.open(found[0]) as f:recover(target,f)
        print('Inventory and Ender Chest restored.')
    elif op=='disk':
        for p in [world,folder,profile/'mods',profile/'plugins',profile/'logs']:
            if not p.is_dir():continue
            size=sum(x.stat().st_size for x in p.rglob('*') if x.is_file() and not x.is_symlink())
            print('%s: %.1f MB (%d GB free)'%(p.name,size/1048576,shutil.disk_usage(p).free//1073741824))
    elif op=='migration':
        dest=Path(args[0]).resolve()
        if dest.parent==profile or profile in dest.parents:raise ValueError("Choose a destination outside the server folder.")
        with tempfile.TemporaryDirectory(dir=dest.parent) as folder:
            src=snapshot(profile,Path(folder),'migration',settings)
            os.replace(src,dest)
        print('Server exported.')
    elif op in ('backup','auto'):
        result=snapshot(profile,folder,op,settings)
        if op=='auto': prune(folder,profile.name,int(args[0]))
        print(result.name)
    elif op=='import':
        import_world(profile,Path(args[0]).resolve(),folder,settings)
        print("World imported.")
    elif op=='export':
        validate_level(world)
        dest=Path(args[0]).resolve()
        if world in dest.parents: raise ValueError("Choose a location outside your world.")
        archive_items([(world,world.name)],dest)
        print("World exported.")
    elif op=='restore':
        source=Path(args[0])
        with tempfile.TemporaryDirectory(dir=profile.parent) as tmp:
            stage=Path(tmp)/'profile'
            stage.mkdir()
            unzip(source,stage)
            meta=stage/'lantern-profile.json'
            if not meta.exists():
                import_world(profile,stage,folder,settings)
                print("World restored from legacy backup.")
                return
            info=json.loads(meta.read_text())
            if info['version']!=profile.name: raise ValueError("Select Minecraft "+info['version']+" before restoring this backup.")
            validate_level(world_path(stage))
            opts=info.get('options',{})
            if not isinstance(opts,dict) or opts.get('version')!=profile.name:raise ValueError('Backup settings are invalid.')
            # Native settings from a migration must not start external programs automatically.
            profiles=opts.get('profileOptions') or {}
            local=profiles.get(profile.name) or {}
            for key in ('javaPath','playitPath','tunnelAuto','resume','login','javaFlags','serverArgs'):
                local.pop(key,None)
            info['options']['profileOptions']={profile.name:local}
            meta.unlink()
            snapshot(profile,folder,'before-restore',settings)
            swap(stage,profile)
            print(json.dumps(info['options']))
    elif op=='pack':
        src=Path(args[0])
        if not world.exists(): raise ValueError("Create or import your world first.")
        if src.is_dir():
            for _ in tree_files(src): pass
            if not (src/'pack.mcmeta').is_file(): raise ValueError("Select the folder containing pack.mcmeta.")
        else:
            with zipfile.ZipFile(src) as z:
                json.loads(z.read('pack.mcmeta'))
        dest=world/'datapacks'/member(src.name)
        if dest.exists(): raise ValueError("A pack with that name is already installed.")
        dest.parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=profile.parent) as tmp:
            stage=Path(tmp)/'pack'
            (shutil.copytree if src.is_dir() else shutil.copy2)(src,stage)
            stage.rename(dest)
        print("Datapack installed.")
    else: raise ValueError("Unknown world operation.")

if __name__=='__main__':
    try: main()
    except Exception as e:
        sys.exit(str(e))
