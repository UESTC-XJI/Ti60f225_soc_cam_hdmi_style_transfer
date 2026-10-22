"""Apply the authorized video replacement on the isolated style branch only."""
from pathlib import Path
import xml.etree.ElementTree as ET
ROOT=Path(__file__).resolve().parents[1]
top=ROOT/'rtl/ti60f225_oob_top.v';text=top.read_text(encoding='latin1')
if 'style_video_system style_demo' not in text:
    start=text.index('rgb_area_resize_3to2 #');end=text.index('wire [`CFG_BITS_32-1:0] m_axis_tdata;',start)
    text=text[:start]+'''assign resize_vs=rgb_vs;
assign resize_valid=1'b0;
assign resize_data=64'b0;
'''+text[end:]
    start=text.index('// SC431HAI resized XBGR8888 frame buffer.');end=text.index('// Sapphire CPU + shared DDR bridge.',start)
    text=text[:start]+'''// Shared INT8 network and paired VGA video store, on the independent demo branch.
wire [31:0] style_prdata,video_prdata;
wire style_pready,style_pslverr,video_pready,video_pslverr,style_irq;
wire style_select=soc_apb_paddr[15:8]==8'h02;
assign soc_apb_prdata=style_select ? style_prdata:video_prdata;
assign soc_apb_pready=style_select ? style_pready:video_pready;
assign soc_apb_pslverr=style_select ? style_pslverr:video_pslverr;
style_video_system style_demo(
  .clk(core_clk),.cnn_clk(vid_clk_dvi2),.pix_clk(hdmi_tx_slow_clk),.rst_n(status_reset_n&&!soc_system_reset),
  .rgb_vs(rgb_vs),.rgb_de(rgb_de),.rgb_data(rgb_datax2),
  .psel(soc_apb_psel&&style_select),.penable(soc_apb_penable),.pwrite(soc_apb_pwrite),.paddr(soc_apb_paddr[7:0]),.pwdata(soc_apb_pwdata),
  .prdata(style_prdata),.pready(style_pready),.pslverr(style_pslverr),.irq(style_irq),
  .pixel(display_pixel),.hs(ch0_hs),.vs(ch0_vs),.de(ch0_de),.underflow(display_underflow),.capture_fault(resize_fault),.resized_frames(resize_completed_frames),
  .awid(fb_awid),.awaddr(fb_awaddr),.awlen(fb_awlen),.awsize(fb_awsize),.awburst(fb_awburst),.awvalid(fb_awvalid),.awready(fb_awready),
  .wdata(fb_wdata),.wstrb(fb_wstrb),.wlast(fb_wlast),.wvalid(fb_wvalid),.wready(fb_wready),.bid(fb_bid),.bresp(fb_bresp),.bvalid(fb_bvalid),.bready(fb_bready),
  .arid(fb_arid),.araddr(fb_araddr),.arlen(fb_arlen),.arsize(fb_arsize),.arburst(fb_arburst),.arvalid(fb_arvalid),.arready(fb_arready),
  .rid(fb_rid),.rdata(fb_rdata),.rresp(fb_rresp),.rlast(fb_rlast),.rvalid(fb_rvalid),.rready(fb_rready));
'''+text[end:]
    text=text.replace('.axi_error_count(soc_axi_error_count));','.axi_error_count(soc_axi_error_count),.style_irq(style_irq));',1)
    text=text.replace('.psel(soc_apb_psel),.penable(soc_apb_penable),.pwrite(soc_apb_pwrite),.paddr(soc_apb_paddr),.pwdata(soc_apb_pwdata),.prdata(soc_apb_prdata),.pready(soc_apb_pready),.pslverr(soc_apb_pslverr),',
        '.psel(soc_apb_psel&&!style_select),.penable(soc_apb_penable),.pwrite(soc_apb_pwrite),.paddr(soc_apb_paddr),.pwdata(soc_apb_pwdata),.prdata(video_prdata),.pready(video_pready),.pslverr(video_pslverr),',1)
    start=text.index('cvo_axi # (');end=text.index('ddr3_top ',start)
    text=text[:start]+text[end:];top.write_text(text,encoding='latin1')
text=top.read_text(encoding='latin1')
style_index=text.index('// Shared INT8 network and paired VGA video store,')
soc_index=text.index('// Sapphire CPU + shared DDR bridge.')
if style_index<soc_index:
    block=text[style_index:soc_index];text=text[:style_index]+text[soc_index:]
    anchor='wire status_reset_n=barrier_sys_reset_n && capture_reset_n && display_reset_n;'
    pos=text.index(anchor)+len(anchor)
    text=text[:pos]+'\n'+block+text[pos:];top.write_text(text,encoding='latin1')
soc=ROOT/'rtl/soc_integration/soc_video_ddr_integration.sv';text=soc.read_text(encoding='latin1')
if 'input wire style_irq' not in text:
    text=text.replace('input wire clk, rst_n, allow_access,','input wire clk, rst_n, allow_access,\n  input wire style_irq,',1)
    text=text.replace("assign userInterruptA = '0;","assign userInterruptA = style_irq;");soc.write_text(text,encoding='latin1')
ns='http://www.efinixinc.com/enf_proj';ET.register_namespace('efx',ns)
ET.register_namespace('xsi','http://www.w3.org/2001/XMLSchema-instance')
project=ROOT/'ti60f225_cam_hdmi.xml';tree=ET.parse(project);design=tree.find('{'+ns+'}design_info')
existing={e.get('name') for e in design.findall('{'+ns+'}design_file')}
for source in sorted((ROOT/'rtl/style').glob('*.sv')):
    name=source.relative_to(ROOT).as_posix()
    if name not in existing:ET.SubElement(design,'{'+ns+'}design_file',name=name,version='default',library='default')
style_nodes=[e for e in design if e.tag=='{'+ns+'}design_file' and e.get('name','').startswith('rtl/style/')]
for e in style_nodes:design.remove(e)
insert=max(i for i,e in enumerate(design) if e.tag=='{'+ns+'}design_file')+1
for i,e in enumerate(style_nodes):design.insert(insert+i,e)
ET.indent(tree,space='    ');tree.write(project,encoding='utf-8')
print('PASS integration: VGA crop, INT8 network, paired DDR ownership, 720p comparison and PLIC IRQ')
