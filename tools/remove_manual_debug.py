from pathlib import Path
import re
p=Path('rtl/ti60f225_oob_top.v')
s=p.read_bytes().decode('utf-8','replace')
a=s.index('debug_edb_top debug_edb_top_inst (')
b=s.index('endmodule',a)
replacement='''// USER1 is owned by the Sapphire hard-JTAG channel.  The former manual\n// VIO/LA instance was removed to avoid a second USER1 TAP; Efinity auto-debug\n// probes use USER2 and the control values below are deterministic defaults.\nassign r_gain=16'd255; assign g_gain=16'd255; assign b_gain=16'd255;\nassign osd_hist_enable=1'b0; assign osd_hist_mode=2'b0; assign osd_text_enable=osd_apb_enable;\nassign ae_enable=1'b0; assign ae_target=8'd128; assign ae_high_protect=1'b0;\nassign ae_high_threshold=8'd232; assign ae_high_limit=8'd0;\nassign lift_auto_enable=1'b0; assign lift_auto_max=8'd0;\nassign lift_enable=1'b0; assign lift_strength=8'd0; assign tone_enable=1'b0;\nassign high_green_strength=8'd0; assign dark_red_strength=8'd0;\n\n'''
s=s[:a]+replacement+s[b:]
p.write_bytes(s.encode('utf-8'))
