"""Emit fixed graph microprogram and firmware banked coefficient image."""
import argparse,json
from pathlib import Path

def main():
    p=argparse.ArgumentParser();p.add_argument('--model',type=Path,required=True);p.add_argument('--out',type=Path,required=True)
    a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True);g=json.loads((a.model/'graph.json').read_text())
    f0,f1,f2,big=0x06000000,0x060A0000,0x06120000,0x06200000
    pairs=[(0,f0,0),(f0,f2,0),(f2,f1,0)];current=f1
    for b in range(4):
        other=f2 if current==f1 else f1
        pairs.extend([(current,f0,0),(f0,other,0),(other,f0,0),(f0,other,current)]);current=other
    pairs.extend([(current,big,0),(big,f0,0),(f0,f1,0),(f1,0,0)])
    inlevels=[0,1,2]+[2]*16+[2,1,1,0];outlevels=[1,2,2]+[2]*16+[1,1,0,0]
    words=[];ledger=[]
    for l,(src,dst,skip),il,ol in zip(g['layers'],pairs,inlevels,outlevels):
        flags=int(l['kernel']==3)|(int(l['dw'])<<1)|(int(l['stride']==2)<<2)|(int(l['upsample']==2)<<3)|(int(l['residual']>=0)<<4)|(int(l['relu'])<<5)
        fields=[(l['ci'],5),(l['co'],5),(flags,6),(il,2),(ol,2),(l['weight_base'],8),(l['norm_base'],8),(src,32),(dst,32),(skip,32)]
        word=offset=0
        for value,bits in fields:word|=value<<offset;offset+=bits
        words.append(f'{word:040x}\n')
        ledger.append(dict(layer=l['name'],src=hex(src),dst=hex(dst),skip=hex(skip),inlevel=il,outlevel=ol))
    (a.out/'program.hex').write_text(''.join(words));(a.out/'program.json').write_text(json.dumps(ledger,indent=2))
    verilog='// Generated graph descriptor ROM; literal cases preserve synthesis initialization.\nfunction [159:0] descriptor_word;\n  input [4:0] index;\n  begin case(index)\n'
    verilog+=''.join(f"    5'd{i}:descriptor_word=160'h{word.strip()};\n" for i,word in enumerate(words))
    verilog+="    default:descriptor_word=0;\n  endcase end\nendfunction\n"
    (a.out/'program.vh').write_text(verilog)
    for name in ('coeff.hex','coeff.bin','model.bin','graph.json'):(a.out/name).write_bytes((a.model/name).read_bytes())
    blob=(a.model/'coeff.bin').read_bytes();ints=[int.from_bytes(blob[i:i+4],'little') for i in range(0,len(blob),4)]
    header='/* Generated from the trained INT8 model; 24 words per coefficient row. */\n#include <stdint.h>\nstatic const uint32_t style_coefficients[6144] = {\n'
    header+=''.join('  '+','.join(f'0x{v:08x}u' for v in ints[i:i+8])+',\n' for i in range(0,len(ints),8))+'};\n'
    (a.out/'style_weights.h').write_text(header)
if __name__=='__main__':main()
