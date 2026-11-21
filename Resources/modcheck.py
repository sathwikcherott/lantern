"""Read loader declarations without running third-party add-ons."""
import io
import json
import re
import zipfile

def accepts(expression,game):
    if isinstance(expression,list):return any(accepts(s,game) for s in expression)
    if expression in ('','*'):return True
    def ver(s):
        parts=s.split('.')
        if not all(x.isdigit() for x in parts):return None
        return tuple((list(map(int,parts))+[0]*4)[:4])
    v=ver(game)
    if not v:return True
    for condition in expression.split():
        m=re.fullmatch(r'(>=|<=|>|<|=|~|\^)?(\d+(?:\.(?:\d+|x|\*))*)',condition)
        if not m:continue
        op,need=m.groups()
        if need.endswith(('.x','.*')):
            if not (game+'.').startswith(need[:-1]):return False
            continue
        b=ver(need)
        if not b:continue
        if op in ('~','^'):
            if v<b:return False
            if op=='~' and v[:2]!=b[:2]:return False
            if op=='^' and v[0]!=b[0]:return False
        elif not {None:v==b,'=':v==b,'>':v>b,'<':v<b,'>=':v>=b,'<=':v<=b}[op]:return False
    return True

def check(profile,loader,options=None):
    if loader in ('Paper','NeoForge'):
        from loadercheck import check_loader
        return check_loader(profile, loader, options or {})
    if loader=='Vanilla':return []
    folder=profile/('plugins' if loader=='Paper' else 'mods')
    declared={}
    issues=[]
    def fabric(z,depth=0):
        if depth>5:raise ValueError("Nested mod metadata is too deep")
        meta=json.loads(z.read('fabric.mod.json'))
        if depth and not accepts(meta.get('depends',{}).get('minecraft','*'),profile.name):return
        declared[meta['id']]=meta
        for name in meta.get('provides',[]):declared.setdefault(name,{})
        for entry in meta.get('jars',[]):
            nested=z.getinfo(entry['file'])
            if nested.file_size>64*1024*1024:continue
            with zipfile.ZipFile(io.BytesIO(z.read(nested))) as inner:
                if 'fabric.mod.json' in inner.namelist():fabric(inner,depth+1)
    for jar in sorted(folder.glob('*.jar')):
        try:
            with zipfile.ZipFile(jar) as z:
                names=set(z.namelist())
                if loader=='Fabric' and 'fabric.mod.json' in names:fabric(z)
                else:issues.append(jar.name+' has no '+loader+' metadata')
        except (KeyError,ValueError,zipfile.BadZipFile) as e:issues.append(jar.name+': '+str(e))
    for name,meta in declared.items():
        deps=meta.get('depends',{})
        if not accepts(deps.get('minecraft','*'),profile.name):issues.append(name+' needs Minecraft '+str(deps['minecraft']))
        for key in deps:
            if key not in declared and key not in ('java','fabricloader','minecraft'):issues.append(name+' needs '+key)
    return issues
