`include "../defines.v"

///////////////////////////////////////////////////////////
/**********************************************************
  Function Description:

  Establishment : Richard Zhu
  Create date   : 2022-09-24
  Versions      : V0.1
  Revision of records:
  Ver0.1

**********************************************************/
module  Sc_Fifo_Slr8 #(


)
(
  Sys_Clk     , //System Clock
  Sync_Clr    , //Sync Reset
  I_Wr_En     , //(I) FIFO Write Enable
  I_Wr_Data   , //(I) FIFO Write Data
  I_Rd_En     , //(I) FIFO Read Enable
  O_Rd_Data   , //(I) FIFO Read Data
  O_Data_Num  , //(I) FIFO Data Number
  O_Wr_Full   , //(O) FIFO Write Full
  O_Rd_Empty  , //(O) FIFO Write Empty
  O_Fifo_Err    //Fifo Error
);

  //Define  Parameter
  /////////////////////////////////////////////////////////
  parameter   OUT_REG       = `CFG_DVI_TX_SC_FIFO_SLR8_V_PARAMETER_OUT_REG  ; //"Yes" Output Register Eanble ; "No"  Output Register Disble
  parameter   DATA_WIDTH    = `CFG_DVI_TX_SC_FIFO_SLR8_V_PARAMETER_DATA_WIDTH   ; //Data Width
  parameter   DATA_DEPTH    = `CFG_DVI_TX_SC_FIFO_SLR8_V_PARAMETER_DATA_DEPTH     ; //Address Width
  parameter   INITIAL_VALUE = `CFG_DVI_TX_SC_FIFO_SLR8_V_PARAMETER_INITIAL_VALUE  ;

  localparam  ADDR_WIDTH    = `CFG_DVI_TX_SC_FIFO_SLR8_V_LOCALPARAM_ADDR_WIDTH  ;
  localparam  SRL8_NUMBER   = `CFG_DVI_TX_SC_FIFO_SLR8_V_LOCALPARAM_SRL8_NUMBER ;


  localparam  DW  = `CFG_DVI_TX_SC_FIFO_SLR8_V_LOCALPARAM_DW    ;
  localparam  AW  = `CFG_DVI_TX_SC_FIFO_SLR8_V_LOCALPARAM_AW    ;
  localparam  SN  = `CFG_DVI_TX_SC_FIFO_SLR8_V_LOCALPARAM_SN   ;

  /////////////////////////////////////////////////////////

  // Signal Define
  /////////////////////////////////////////////////////////
  input             Sys_Clk     ; //System Clock
  input             Sync_Clr    ; //Sync Reset
  input             I_Wr_En     ; //(I) Write Enable
  input   [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_1]  I_Wr_Data   ; //(I) Write Data
  input             I_Rd_En     ; //(I) Read Enable
  output  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_2]  O_Rd_Data   ; //(O) Read Data
  output  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_3]  O_Data_Num  ; //(O) Ram Data Number
  output            O_Wr_Full   ; //(O) FIFO Write Full
  output            O_Rd_Empty  ; //(O) FIFO Write Empty
  output            O_Fifo_Err  ; //(O) FIFO Error

  /////////////////////////////////////////////////////////
//000000000000000000000000000000000000000000000000000000000
//整理输入信号
//********************************************************/
  /////////////////////////////////////////////////////////
  wire            Wr_En     = I_Wr_En     ; //Write Enable
  wire  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_4]  Wr_Data   = I_Wr_Data   ; //Write Data
  wire            Rd_En     = I_Rd_En     ; //Read Enable

  /////////////////////////////////////////////////////////
//000000000000000000000000000000000000000000000000000000000

//111111111111111111111111111111111111111111111111111111111
//
//********************************************************/
  /////////////////////////////////////////////////////////
  reg   Wr_Full     = 1'h0  ;
  reg   Rd_Empty    = 1'h1  ;

  wire  Fifo_Wr_En  = Wr_En & ( ~Wr_Full  ) ;
  wire  Fifo_Rd_En  = Rd_En & ( ~Rd_Empty ) ;

  /////////////////////////////////////////////////////////
  reg   [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_5]  Data_Num  = {AW+1{1'h0}}  ;

  always @(posedge Sys_Clk)
  begin
    if (Sync_Clr)           Data_Num  <= {AW+1{1'h0}} ;
    else if (Fifo_Wr_En ^ Fifo_Rd_En)
    begin
      if (Fifo_Wr_En)       Data_Num  <= Data_Num + {{AW{1'h0}},1'h1} ;
      else if (Fifo_Rd_En)  Data_Num  <= Data_Num - {{AW{1'h0}},1'h1} ;
    end
  end

  /////////////////////////////////////////////////////////
  wire    [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_6]  Out_Sel  ;

  assign  Out_Sel = (|Data_Num)   ? ( DATA_DEPTH  - Data_Num) : {AW+1{1'h0}} ;

  /////////////////////////////////////////////////////////
  wire    [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_7]    O_Data_Num  = Data_Num  ; //(O)Data Number In Fifo

  /////////////////////////////////////////////////////////
  /////////////////////////////////////////////////////////

//111111111111111111111111111111111111111111111111111111111

//222222222222222222222222222222222222222222222222222222222
//
//********************************************************/
  /////////////////////////////////////////////////////////
  wire  [   `CFG_BITS_3-1:0]  Shift_Out_Sel   = Out_Sel[2:0]  ;
  wire            Shift_Clk_En    = Fifo_Wr_En    ;

  wire  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_8]  Shift_Data_In   [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_9]  ;
  wire  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_10]  Shift_Data_Out  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_11]  ;
  wire  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_12]  Shift_Q7_Out    [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_13]  ; //(O)Shift Output

  wire  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_14]  SftReg_Data_In   [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_15]  ;
  wire  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_16]  SftReg_Data_Out  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_17]  ;
  wire  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_18]  SftReg_Q7_Out    [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_19]  ; //(O)Shift Output

  genvar  i , j ;
  generate
    for (i=0; i<SRL8_NUMBER ; i=i+1)
    begin : U_SRL8_D
      if (i==SRL8_NUMBER-1) assign  Shift_Data_In[i]  = ~Wr_Data          ;
      else                  assign  Shift_Data_In[i]  = Shift_Q7_Out[i+1] ;

      if (i==SRL8_NUMBER-1) assign  SftReg_Data_In[i]  = ~Wr_Data           ;
      else                  assign  SftReg_Data_In[i]  = SftReg_Q7_Out[i+1] ;

      for (j=0; j<DATA_WIDTH; j=j+1)
      begin : U_SRL8_W

        EFX_SRL8
        #(
            .CLK_POLARITY ( `CFG_DVI_TX_SC_FIFO_SLR8_V_INST_SRL8_INST_CLK_POLARITY            ) , // clk polarity
            .CE_POLARITY  ( `CFG_DVI_TX_SC_FIFO_SLR8_V_INST_SRL8_INST_CE_POLARITY            ) , // clk polarity
            .INIT         ( `CFG_DVI_TX_SC_FIFO_SLR8_V_INST_SRL8_INST_INIT   )   // 8-bit initial value
        )
        srl8_inst
        (
            .A      ( Shift_Out_Sel         ) ,   // 3-bit address select for Q
            .D      ( Shift_Data_In [i][j]  ) ,   // 1-bit data-in
            .CLK    ( Sys_Clk               ) ,   // clock
            .CE     ( Shift_Clk_En          ) ,   // clock enable
            .Q      ( Shift_Data_Out[i][j]  ) ,   // 1-bit data output
            .Q7     ( Shift_Q7_Out  [i][j]  )     // 1-bit last shift register output
        );
        
      end
    end
  endgenerate

  wire   Sft_Data_Right   =   Shift_Data_Out[0] ==  SftReg_Data_Out[0]  ; 
  wire   Sft_Q7_Rigth     =   Shift_Q7_Out  [0] ==  SftReg_Q7_Out  [0]  ; 


//222222222222222222222222222222222222222222222222222222222

//333333333333333333333333333333333333333333333333333333333
//
//********************************************************/
  /////////////////////////////////////////////////////////
  reg   [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_20]  Data_Out  = {DW{1'h0}}  ;
  reg   [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_21]  Shift_Out = {DW{1'h0}}  ;

  always @(posedge  Sys_Clk )
  begin
    if (Sync_Clr)               Data_Out  <=  {DW{1'h0}}  ;
    else if (SRL8_NUMBER == 1)  Data_Out  <=  Shift_Data_Out[0][DW-1:0]  ;
    else
    begin
      if (Out_Sel != 0 )        Data_Out  <=  Shift_Data_Out[Out_Sel[AW-1:3]][DW-1:0]  ;
      else if (Shift_Clk_En)    Data_Out  <=  Wr_Data     ;
      else                      Data_Out  <=  Shift_Data_Out[Out_Sel[AW-1:3]][DW-1:0]  ;
    end
  end

  /////////////////////////////////////////////////////////
  reg  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_22]  Rd_Data   ;

  always @ ( * )
  begin
    if (OUT_REG == "Yes")           Rd_Data = Data_Out  ;
    else if ( (SRL8_NUMBER <= 1) )  Rd_Data = Shift_Data_Out[              0][DW-1:0] ;
    else                            Rd_Data = Shift_Data_Out[Out_Sel[AW:3]][DW-1:0] ;
  end

  /////////////////////////////////////////////////////////
  wire  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_23]  O_Rd_Data   = Rd_Data ; //(O) Read Data

  /////////////////////////////////////////////////////////
//333333333333333333333333333333333333333333333333333333333

//444444444444444444444444444444444444444444444444444444444
//
//********************************************************/
  /////////////////////////////////////////////////////////
  localparam  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_24]  FULL_ENTER      = `CFG_DVI_TX_SC_FIFO_SLR8_V_LOCALPARAM_FULL_ENTER ;
  localparam  [`CFG_DVI_TX_SC_FIFO_SLR8_V_RANGE_25]  EMPTY_ENTER     = `CFG_DVI_TX_SC_FIFO_SLR8_V_LOCALPARAM_EMPTY_ENTER  ;

  /////////////////////////////////////////////////////////
  always @(posedge Sys_Clk)
  begin
    if (Sync_Clr)           Wr_Full   <=  1'h0 ;
    else if (Fifo_Rd_En)    Wr_Full   <=  1'h0 ;
    else if (Fifo_Wr_En)    Wr_Full   <=  (Data_Num == FULL_ENTER)  ;
  end

  /////////////////////////////////////////////////////////
  always @(posedge Sys_Clk)
  begin
    if (Sync_Clr)           Rd_Empty  <=  1'h1 ;
    else if (Fifo_Wr_En)    Rd_Empty  <=  1'h0 ;
    else if (Fifo_Rd_En)    Rd_Empty  <=  (Data_Num == EMPTY_ENTER) ;
  end

  /////////////////////////////////////////////////////////
  reg   Fifo_Err  = 1'h0 ;

  always @(posedge Sys_Clk)   Fifo_Err  <=  (Rd_En & Rd_Empty) | (Wr_En & Wr_Full) ;

  /////////////////////////////////////////////////////////
  assign    O_Wr_Full   = Wr_Full   ; //(O) FIFO Write Full
  assign    O_Rd_Empty  = Rd_Empty  ; //(O) FIFO Write Empty
  assign    O_Fifo_Err  = Fifo_Err  ; //(O) Fifo Error

  /////////////////////////////////////////////////////////
//444444444444444444444444444444444444444444444444444444444

endmodule

///////////////////////////////////////////////////////////

