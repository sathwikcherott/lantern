"""Answer Minecraft Java status requests while the Java process sleeps."""
import asyncio
import json
import struct
import sys

def vi(n):
    n &= 0xffffffff
    result=bytearray()
    while n>127:
        result.append(n & 127 | 128)
        n >>= 7
    result.append(n)
    return bytes(result)

def decode(data,pos):
    total=0
    for shift in range(0,35,7):
        b=data[pos]
        pos+=1
        total|=(b & 127)<<shift
        if b<128: return total,pos
    raise ValueError("Invalid integer")

async def packet(reader):
    length=bytearray()
    for _ in range(5):
        b=await reader.readexactly(1)
        length.extend(b)
        if b[0]<128: break
    n,_=decode(length,0)
    if n>2048: raise ValueError("Oversized handshake")
    return await reader.readexactly(n)

def send(writer,kind,body):
    frame=vi(kind)+body
    writer.write(vi(len(frame))+frame)

def json_text(value):
    b=json.dumps(value).encode()
    return vi(len(b))+b

async def serve(host,port,version,cap,sleep_message,wake_message):
    wake=asyncio.Event()
    async def handle(reader,writer):
        try:
            handshake=await packet(reader)
            ident,pos=decode(handshake,0)
            if ident!=0: return
            protocol,pos=decode(handshake,pos)
            size,pos=decode(handshake,pos)
            state,pos=decode(handshake,pos+size+2)
            if state==1:
                if await packet(reader)!=b'\0': return
                send(writer,0,json_text({'version':{'name':version,'protocol':protocol},'players':{'online':0,'max':int(cap)},'description':{'text':sleep_message}}))
                await writer.drain()
                ping=await packet(reader)
                if len(ping)==9 and ping[0]==1:send(writer,1,ping[1:])
                await writer.drain()
            elif state in (2,3):
                login=await packet(reader)
                if login and login[0]==0:
                    send(writer,0,json_text({'text':wake_message}))
                    await writer.drain()
                    wake.set()
        except (asyncio.IncompleteReadError,ValueError,IndexError,ConnectionError):
            pass
    async def connection(reader,writer):
        try: await asyncio.wait_for(handle(reader,writer),4)
        except asyncio.TimeoutError: pass
        finally: writer.close()
    async with await asyncio.start_server(connection,host,int(port),limit=4096):
        await wake.wait()
    print('WAKE',flush=True)

if __name__=='__main__':
    asyncio.run(serve(*sys.argv[1:]))
