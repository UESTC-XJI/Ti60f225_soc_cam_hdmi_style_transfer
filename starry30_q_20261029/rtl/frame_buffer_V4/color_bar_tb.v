`include "../defines.v"
`timescale  1ns /1ps
module color_bar_tb;

parameter	MAX_HRES		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_PARAMETER_MAX_HRES;
parameter	MAX_VRES		= `CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_PARAMETER_MAX_VRES;
parameter	HSP				= `CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_PARAMETER_HSP;
parameter	HBP				= `CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_PARAMETER_HBP;
parameter	HFP				= `CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_PARAMETER_HFP;
parameter	VSP				= `CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_PARAMETER_VSP;
parameter	VBP				= `CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_PARAMETER_VBP;
parameter	VFP				= `CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_PARAMETER_VFP;

reg clk = 1'b0;
reg rst_n = 1'b0;
always #10 clk = ~clk;

initial
begin
        #0
            rst_n = 0;
        # 100

            rst_n = 1;
end 


color_bar_rgb #(
			.HS_POLORY 		(`CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_INST_U_COLOR_BAR_RGB_HS_POLORY	),
			.VS_POLORY 		(`CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_INST_U_COLOR_BAR_RGB_VS_POLORY	),
			.H_FRONT_PORCH 	(`CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_INST_U_COLOR_BAR_RGB_H_FRONT_PORCH	),
			.H_SYNC 		(`CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_INST_U_COLOR_BAR_RGB_H_SYNC	),
			.H_VALID 		(`CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_INST_U_COLOR_BAR_RGB_H_VALID	),
			.H_BACK_PORCH 	(`CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_INST_U_COLOR_BAR_RGB_H_BACK_PORCH	),
			.V_FRONT_PORCH 	(`CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_INST_U_COLOR_BAR_RGB_V_FRONT_PORCH		),
			.V_SYNC 		(`CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_INST_U_COLOR_BAR_RGB_V_SYNC		),
			.V_VALID 		(`CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_INST_U_COLOR_BAR_RGB_V_VALID	),
			.V_BACK_PORCH 	(`CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_INST_U_COLOR_BAR_RGB_V_BACK_PORCH		),
			.TEST_MODE 		(`CFG_FRAME_BUFFER_V4_COLOR_BAR_TB_V_INST_U_COLOR_BAR_RGB_TEST_MODE		)
	)u_color_bar_rgb(
	/*i*/.clk	(clk),
	/*i*/.rst_n	(rst_n ),
	/*o*/.hs	(hs),
	/*o*/.vs	(vs),
	/*o*/.de	(de),
	/*O*/.h_cnt (h_cnt),
	/*O*/.v_cnt (v_cnt),
	/*o*/.rgb_r	(r_data),    //像素数据、红色分量
	/*o*/.rgb_g	(g_data),    //像素数据、绿色分量
	/*o*/.rgb_b (b_data)    //像素数据、蓝色分量
	
	);


endmodule