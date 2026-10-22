#!/usr/bin/env python3
"""Remove atlas padding while retaining logical canvas placement in render-layout.json.
Run after either asset importer. Never executes or launches the desktop pet.
"""
import hashlib
import json
import shutil
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
FOLDER = ROOT / 'Apps/macOS/Resources/CommunityActions'

def main():
    layout_path = FOLDER/'render-layout.json'
    old = json.loads(layout_path.read_text()) if layout_path.exists() else {}
    manifests = [FOLDER/'sprite-manifest.json']
    backups = ROOT/'work/atlas-before-compaction'
    backups.mkdir(parents=True, exist_ok=True)
    (backups/'metadata').mkdir(exist_ok=True)
    for source in manifests + [FOLDER/'provenance.json']:
        backup = backups/'metadata'/source.name
        if not backup.exists(): shutil.copyfile(source, backup)
    layouts = {}
    saved = 0
    old_pixels = new_pixels = 0
    for manifest_path in manifests:
        manifest = json.loads(manifest_path.read_text())
        for atlas in manifest['atlases']:
            path = ROOT/'Apps/macOS/Resources'/atlas['resource']
            sha = hashlib.sha256(path.read_bytes()).hexdigest()
            if atlas['id'] in old and old[atlas['id']].get('compactSHA256') == sha:
                layouts[atlas['id']] = old[atlas['id']]
                continue
            clips = [c for c in manifest['clips'] if c['atlasID'] == atlas['id']]
            original_frames = clips[0]['frames']
            width, height = int(original_frames[0]['rect']['width']), int(original_frames[0]['rect']['height'])
            image = Image.open(path).convert('RGBA')
            unique = {}
            for c in clips:
                for f in c['frames']:
                    r=f['rect'];key=(int(r['x']),int(r['y']))
                    if key not in unique:
                        frame=image.crop((key[0],key[1],key[0]+width,key[1]+height))
                        unique[key]=frame
            # Imported WebM padding contains alpha=1/255 across the entire canvas.
            # Ignore only that residue; retain all pixels with alpha >= 2.
            boxes=[f.getchannel('A').point(lambda a: 255 if a >= 2 else 0).getbbox() for f in unique.values()]
            boxes=[b for b in boxes if b]
            crop=(min(b[0] for b in boxes),min(b[1] for b in boxes),max(b[2] for b in boxes),max(b[3] for b in boxes))
            cw,ch=crop[2]-crop[0],crop[3]-crop[1]
            columns=min(8,len(unique));rows=(len(unique)+columns-1)//columns
            target=Image.new('RGBA',(cw*columns,ch*rows));positions={}
            for i,(key,frame) in enumerate(unique.items()):
                x,y=i%columns*cw,i//columns*ch
                target.paste(frame.crop(crop),(x,y));positions[key]=(x,y)
            backup=backups/path.name
            if not backup.exists(): shutil.copyfile(path,backup)
            for clip in clips:
                for f in clip['frames']:
                    r=f['rect'];x,y=positions[(int(r['x']),int(r['y']))]
                    f['rect']=dict(x=x,y=y,width=cw,height=ch)
                    for field in ['visualBounds','hitbox']:
                        b=f[field];x0=max(0,b['x']*width-crop[0]);y0=max(0,b['y']*height-crop[1])
                        x1=min(cw,(b['x']+b['width'])*width-crop[0]);y1=min(ch,(b['y']+b['height'])*height-crop[1])
                        f[field]=dict(x=x0/cw,y=y0/ch,width=max(1,x1-x0)/cw,height=max(1,y1-y0)/ch)
                    f['anchor']=dict(x=min(1,max(0,(f['anchor']['x']*width-crop[0])/cw)),y=min(1,max(0,(f['anchor']['y']*height-crop[1])/ch)))
            # Lossless encoding preserves cropped decoded pixels; only <=1/255 padding is omitted.
            temporary = path.with_suffix('.compact.tmp')
            target.save(temporary,'WEBP',lossless=True,method=3,exact=True)
            temporary.replace(path)
            layouts[atlas['id']]=dict(canvasWidth=width,canvasHeight=height,x=crop[0],y=crop[1],width=cw,height=ch,
                 originalAtlasSHA256=sha,compactSHA256=hashlib.sha256(path.read_bytes()).hexdigest())
            old_pixels+=atlas['pixelWidth']*atlas['pixelHeight'];new_pixels+=target.width*target.height
            atlas['pixelWidth']=target.width;atlas['pixelHeight']=target.height
            saved+=1
        manifest_path.write_text(json.dumps(manifest,separators=(',',':'))+'\n')
    layout_path.write_text(json.dumps(layouts,separators=(',',':'))+'\n')
    for filename in ['provenance.json']:
        p=FOLDER/filename;data=json.loads(p.read_text())
        def update(value):
            if isinstance(value,dict):
                if 'atlasSha256' in value and 'id' in value:
                    item=layouts.get('community.'+value['id'])
                    if item:
                        value.setdefault('originalAtlasSha256',value['atlasSha256']);value['atlasSha256']=item['compactSHA256']
                        value['atlasBytes']=(FOLDER/(value['id']+'.webp')).stat().st_size
                for v in value.values():update(v)
            elif isinstance(value,list):
                for v in value:update(v)
        update(data)
        data['atlasCompaction'] = dict(layoutFile='render-layout.json', alphaThreshold=2,
            encoding='lossless WebP of cropped source pixels; omits only peripheral alpha <= 1/255',
            canvasPlacement='preserved in render-layout.json')
        p.write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(dict(compacted=saved,originalDecodedRGBABytes=old_pixels*4,compactDecodedRGBABytes=new_pixels*4,
                         reductionPercent=round((1-new_pixels/old_pixels)*100,1) if old_pixels else 0)))

if __name__=='__main__': main()
