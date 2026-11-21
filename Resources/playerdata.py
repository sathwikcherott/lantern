"""Replace only the inventory NBT tags, preserving raw bytes for other player fields."""
import gzip
import os
from pathlib import Path
from struct import unpack_from
import tempfile

class Reader:
    def __init__(self,data):
        self.b=data
        self.pos=0

    def take(self,n):
        if n<0 or self.pos+n>len(self.b): raise ValueError("Invalid player data length")
        cur=self.pos
        self.pos+=n
        return self.b[cur:self.pos]

    def size(self,n):
        return int.from_bytes(self.take(n),'big',signed=(n==4))

    def skip(self,kind,depth):
        if depth>128:raise ValueError("Player data is too deeply nested")
        sizes={1:1,2:2,3:4,4:8,5:4,6:8}
        if kind in sizes: self.take(sizes[kind])
        elif kind in (7,11,12):self.take(self.size(4)*{7:1,11:4,12:8}[kind])
        elif kind==8:self.take(self.size(2))
        elif kind==9:
            subtype=self.size(1)
            count=self.size(4)
            if count<0 or count>len(self.b):raise ValueError("Invalid player list")
            for _ in range(count):self.skip(subtype,depth+1)
        elif kind==10:
            while True:
                subtype=self.size(1)
                if subtype==0:break
                self.take(self.size(2));self.skip(subtype,depth+1)
        else:raise ValueError("Unknown player data tag")

def tags(blob):
    r=Reader(blob)
    if r.size(1)!=10:raise ValueError("Invalid player record")
    r.take(r.size(2));header=blob[:r.pos];fields={}
    while True:
        start=r.pos
        ty=r.size(1)
        if ty==0:break
        name=r.take(r.size(2))
        r.skip(ty,0)
        fields[name]=blob[start:r.pos]
    return header,fields

def recover(target,saved):
    with gzip.open(target,'rb') as f:header,current=tags(f.read(32*1024*1024))
    with gzip.GzipFile(fileobj=saved) as f:_,old=tags(f.read(32*1024*1024))
    keys=(b'Inventory',b'EnderItems')
    if b'Inventory' not in current or b'Inventory' not in old:raise ValueError("This record has an unsupported inventory layout.")
    for k in keys:
        if k in old:current[k]=old[k]
        else:current.pop(k,None)
    with tempfile.NamedTemporaryFile(dir=target.parent,delete=False) as f: stage=Path(f.name)
    try:
        with gzip.open(stage,'wb') as f:f.write(header+b''.join(current.values())+b'\0')
        os.replace(stage,target)
    finally:stage.unlink(missing_ok=True)

def materialize_owner(world):
    """Preserve the embedded single-player record when a dedicated server first reads the copy."""
    import uuid
    with gzip.open(world/'level.dat','rb') as src:_,root=tags(src.read(64*1024*1024))
    if b'Data' not in root:return
    _,data=tags(root[b'Data'])
    if b'Player' not in data:return
    _,player=tags(data[b'Player'])
    entry=player.get(b'UUID')
    if entry and len(entry)>=20 and entry[-20:-16]==b'\0\0\0\4':
        key=uuid.UUID(bytes=entry[-16:])
    elif b'UUIDMost' in player and b'UUIDLeast' in player:
        key=uuid.UUID(bytes=player[b'UUIDMost'][-8:]+player[b'UUIDLeast'][-8:])
    else:return
    directory=world/'players/data' if (world/'players').exists() else world/'playerdata'
    directory.mkdir(parents=True,exist_ok=True)
    if b'DataVersion' not in player and b'DataVersion' in data:player[b'DataVersion']=data[b'DataVersion']
    target=directory/(str(key)+'.dat')
    with gzip.open(target,'wb') as f:f.write(b'\x0a\0\0'+b''.join(player.values())+b'\0')
