"""Convert the approved boot artwork into a compact initialized FPGA ROM."""
from pathlib import Path
from PIL import Image
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'assets/boot'
def main():
    src=Image.open(OUT/'source.png').convert('RGB')
    screen=src.resize((1280,720),Image.Resampling.LANCZOS)
    screen.save(OUT/'screen_1280x720.png')
    small=screen.resize((256,144),Image.Resampling.LANCZOS)
    indexed=small.quantize(colors=256,method=Image.Quantize.MEDIANCUT,dither=Image.Dither.NONE)
    (OUT/'pixels.hex').write_text(''.join(f'{v:02x}\n' for v in indexed.tobytes()),encoding='ascii')
    pal=indexed.getpalette()
    (OUT/'palette.hex').write_text(''.join(f'{pal[i]:02x}{pal[i+1]:02x}{pal[i+2]:02x}\n' for i in range(0,768,3)),encoding='ascii')
    faded=[]
    for level in range(16):
        for i in range(0,768,3):
            faded.append(''.join(f'{(pal[i+c]*level+7)//15:02x}' for c in range(3))+'\n')
    (OUT/'fade_palette.hex').write_text(''.join(faded),encoding='ascii')
    indexed.convert('RGB').resize((1280,720),Image.Resampling.NEAREST).save(OUT/'rom_preview.png')
    print('PASS boot asset: 1280x720 layout, 256x144 indexed ROM + 16-level RGB palette ROM; no runtime multipliers')
if __name__=='__main__':main()
