from PIL import Image, ImageDraw, ImageFont
from pathlib import Path

font = ImageFont.truetype(r"C:\Windows\Fonts\CascadiaMono.ttf", 14)
out = ["// Compact 128-character ASCII ROM; printable ASCII 0x20..0x7e is unchanged.",
       "module osd_font8x16(input logic clk, input logic [7:0] ch, input logic [3:0] row, output logic [7:0] bits);",
       "  logic [7:0] rom [0:2047]; integer i;",
       "  initial begin for(i=0;i<2048;i=i+1) rom[i]=8'h00;"]
for c in range(32, 127):
    im = Image.new("1", (8, 16), 0)
    ImageDraw.Draw(im).text((0, -1), chr(c), font=font, fill=1)
    for y in range(16):
        value = 0
        for x in range(8):
            value = (value << 1) | int(im.getpixel((x, y)))
        out.append(f"    rom[12'h{c:02x}{y:x}] = 8'h{value:02x};")
out += ["  end",
        "  wire printable = ch >= 8'h20 && ch <= 8'h7e;",
        "  logic [6:0] safe_ch;",
        "  always_comb begin",
        "    safe_ch = 7'h20;",
        "    if(printable) safe_ch = ch[6:0];",
        "  end",
        "  always_ff @(posedge clk) bits <= rom[{safe_ch,row}];", "endmodule", ""]
Path("rtl/soc_integration/osd_font8x16.sv").write_text("\n".join(out), encoding="utf-8")
print(f"generated {95*16} ROM rows")
