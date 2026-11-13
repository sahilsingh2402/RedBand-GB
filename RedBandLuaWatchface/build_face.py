"""Band 10 watchface packer (EasyFace Gen2 ".face" container), 4.2.0.

Two outputs:
  RedBand_GB_4_6_0.bin        main screen (Lua) + a Poketch AOD screen (always-on display)
  RedBand_GB_4_6_0_noAOD.bin  main screen only: the exact container layout already proven on
                              the band by 3.x-4.1.0 (install this one if the AOD version is refused)
The main-screen packer below is RedBand's own (from 3.x). The AOD container is written with
tools/facebin_mb11.py, vendored unchanged from AIR-pixel/miband11-watchface-maker (MIT,
https://github.com/AIR-pixel/miband11-watchface-maker); before packing, that packer is checked to
produce byte-identical output to ours for the main-screen-only case.
AOD widgets (the AOD cannot run Lua): Shape 30 = static image, Shape 32 = digits from a data
source (0811 hour, 1011 minute, 1012 month, 1812 day; IDs from the same project / Mi Create).
"""
import sys
from pathlib import Path
import struct
from PIL import Image

BASE=Path(__file__).resolve().parent
OUT=BASE.parent/'output'
W,H=212,520
import os
ID=os.environ.get('RB_ID','781209300')  # unique project-local watchface ID; adjust if it conflicts
TITLE=os.environ.get('RB_TITLE','REDBAND GB 4.6.0')
NAME=os.environ.get('RB_NAME','RedBand_GB_4_6_0')

def align4(n):return (n+3)&~3

def encode_preview(img):
    pix=bytearray(Image.open(img).convert('RGBA').tobytes())
    if len(pix)!=W*H*4:raise ValueError('Preview must be 212x520')
    for i in range(0,len(pix),4):pix[i],pix[i+2]=pix[i+2],pix[i]
    return bytes(pix)

def fixed(s,n):
    b=s.encode('ascii')[:n]
    return b+bytes(n-len(b))

def pack(files,preview):
    files=sorted(files,key=lambda x:x[0]); n=len(files)
    idx=272; desc=idx+n*16; cur=desc+16
    listing=[]
    for name,data in files:
        nb=name.encode('ascii'); length=20+len(nb)+len(data)
        listing.append((nb,data,cur,length))
        cur=align4(cur+length)
    # Main-screen metadata. Layout matches the documented EasyFace Gen2 container.
    out=bytearray(b'\x5a\xa5\x34\x12')
    out+=bytes([0,10])+bytes(10)+struct.pack('<I',0x800)+bytes(8)
    out+=struct.pack('<HH',1,0)+struct.pack('<I',cur)+bytes(4)
    out+=fixed(ID,10)+bytes(14)
    out+=bytes(40)+fixed(TITLE,16)+bytes(52)
    meta=[cur,1,idx-16,0,idx,0,idx,0,idx,0,idx,n,idx,0]+[desc,0]*4
    out+=struct.pack('<'+'I'*22,*meta)
    out+=struct.pack('<III',0,desc,16)
    assert len(out)==272,len(out)
    for i,(nb,data,off,size) in enumerate(listing):
        out+=struct.pack('<HHIII',i,0x0500,0,off,size)
    # Band 10 hardware-confirmed: entrypoint sentinel points to lua/main.lua.
    main_index=next((i for i,(name,_) in enumerate(files) if name=='lua/main.lua'),None)
    if main_index is None: raise ValueError('lua/main.lua missing from watchface package')
    out+=struct.pack('<HHIII',main_index,0x0500,0,0,0)
    for nb,data,off,size in listing:
        assert len(out)==off,(len(out),off)
        out+=len(data).to_bytes(3,'little')+bytes([len(nb)])+bytes(16)+nb+data
        out+=bytes(align4(off+size)-(off+size))
    assert len(out)==cur
    out+=struct.pack('<IHHI',0,W,H,len(preview))+preview
    return bytes(out)

def unpack_check(blob, expected_paths):
    assert blob[:4]==bytes.fromhex('5aa53412')
    aod=struct.unpack_from('<HH',blob,28)==(2,4)
    assert aod or struct.unpack_from('<HH',blob,28)==(1,0)
    idx=360 if aod else 272
    n=struct.unpack_from('<I',blob,216)[0]
    assert n==len(expected_paths),(n,len(expected_paths))
    main_index=sorted(expected_paths).index('lua/main.lua')
    if not aod:
        assert struct.unpack_from('<H',blob,272+n*16)[0]==main_index, 'entrypoint sentinel mismatch: watchface may boot black'
    found={}
    for i in range(n):
        _,tag,_,off,size=struct.unpack_from('<HHIII',blob,idx+i*16)
        assert tag==0x0500
        assert 0 <= off < len(blob) and 0 < size <= len(blob)-off
        content_len=int.from_bytes(blob[off:off+3],'little')
        namelen=blob[off+3]
        name=blob[off+20:off+20+namelen].decode()
        payload=blob[off+20+namelen:off+20+namelen+content_len]
        assert len(payload)==content_len
        found[name]=payload
    assert set(found)==set(expected_paths),(found.keys(),expected_paths)
    assert b'create_core_module' in found['lua/main.lua'] and b"VERSION='4.6.0" in found['lua/main.lua']
    if NO_ROM:
        assert not any(k.startswith('lua/gbank') for k in found), 'the ROM-free package must not carry ROM banks'
        return len(found),{}
    banks=[found['lua/gbank%02d.dat'%n] for n in range(64)]
    assert all(len(b)==16384 for b in banks) and banks[0][0x134:0x13f]==b'POKEMON RED'
    assert b'return M' in found['lua/gbcore.lua'] and b'create_core_module' in found['lua/main.lua']
    import hashlib
    assert hashlib.sha256(b''.join(banks)).hexdigest()=='5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b'
    assert len(blob)-struct.unpack_from('<I',blob,32)[0]==12+W*H*4 or aod
    assert struct.unpack_from('<IHHI',blob,len(blob)-(12+W*H*4))==(0,W,H,W*H*4)
    return n, {key:len(val) for key,val in found.items()}

def aod_screen():
    """Poketch AOD: trainer on the left, hours over minutes on the right, month.day below,
    light Poketch green on black (black pixels are off on AMOLED)."""
    A=BASE.parent/'assets'/'aod'
    def rgba(name):
        im=Image.open(A/name).convert('RGBA'); return (im.size[0],im.size[1],im.tobytes())
    big=['big%d.png'%d for d in range(10)]+['big0.png']        # 11 images, like Xiaomi's own lists
    small=['small%d.png'%d for d in range(10)]+['small0.png']
    widgets=[
        {'kind':32,'name':'aod_hour','x':84,'y':140,'dw':56,'dh':124,'digits':2,'src':'0811','list':big},
        {'kind':32,'name':'aod_min','x':84,'y':276,'dw':56,'dh':124,'digits':2,'src':'1011','list':big},
        {'kind':30,'name':'aod_red','x':20,'y':216,'w':52,'h':108,'img':'red.png'},
        {'kind':32,'name':'aod_month','x':57,'y':424,'dw':22,'dh':32,'digits':2,'src':'1012','list':small},
        {'kind':30,'name':'aod_dot','x':101,'y':424,'w':12,'h':32,'img':'dot.png'},
        {'kind':32,'name':'aod_day','x':113,'y':424,'dw':22,'dh':32,'digits':2,'src':'1812','list':small},
    ]
    images={n:rgba(n) for n in set(big+small+['red.png','dot.png'])}
    for w in widgets:                                           # sizes must match the widget
        for n in (w['list'] if w['kind']==32 else [w['img']]):
            iw,ih,_=images[n]
            assert (iw,ih)==((w['dw'],w['dh']) if w['kind']==32 else (w['w'],w['h'])),(n,iw,ih)
    return widgets,images

NO_ROM=len(sys.argv)>1 and sys.argv[1]=='norom'
if __name__=='__main__':
    sys.path.insert(0,str(BASE.parent/'tools'))
    import facebin_mb11 as fb
    files=[('lua/'+f.name,f.read_bytes()) for f in sorted((BASE/'app/lua').iterdir()) if f.is_file() and not (NO_ROM and (f.name.startswith('gbank') or f.name.startswith('gbcore')))]
    files=sorted(files,key=lambda x:x[0])
    preview=encode_preview(BASE/'images/preview.png')
    plain=pack(files,preview)
    # the vendored packer must agree with ours byte for byte before it is trusted with the AOD
    names=[name for name,_ in files]
    assert names[-1]=='lua/main.lua','main.lua must sort last (the layout proven on the band)'
    main_index=names.index('lua/main.lua')
    same=fb.pack_face(files,preview,title=TITLE,face_id=ID,recs=(),has_aod=False,sentinel_idx=main_index)
    assert same==plain,'facebin_mb11 differs from the proven packer'
    widgets,images=aod_screen()
    recs=fb.aod_records(widgets,images)
    with_aod=fb.pack_face(files,preview,title=TITLE,face_id=ID,recs=recs,has_aod=True,sentinel_idx=main_index)
    count,sizes=unpack_check(plain,names)
    unpack_check(with_aod,names)
    OUT.mkdir(parents=True,exist_ok=True)
    tag='_noROM' if NO_ROM else ''
    for ext in ('face','bin'):
        (OUT/f'{NAME}{tag}.{ext}').write_bytes(with_aod)
        (OUT/f'{NAME}{tag}_noAOD.{ext}').write_bytes(plain)
    print(f'packed: with AOD {len(with_aod)} bytes, main only {len(plain)} bytes; {count} files; AOD widgets {len(widgets)}, records {len(recs)}')
    print('4.6.0: 64 ROM banks + engines (source + 3 bytecode) + Poketch clock images + main.lua (sorts last); watchface ID as before.')
