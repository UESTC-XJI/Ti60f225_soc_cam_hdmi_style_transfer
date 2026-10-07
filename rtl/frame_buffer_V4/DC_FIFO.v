`include "../defines.v"

`timescale 1ns/100ps

  //////////////////////////////////////////////////////////////////////////////////////
  // Change Date:    2020/04/30
  // Module Name:     
  // Tool versions:  EFINITY 2019.3.272.8.4
  // Description:    V3.0

  // Dependencies: EFINITY DaulClkFifo3.2 by Richard Zhu 朱仁昌
  //
  // Revision: 0.01 File Created 2019/08/11
  // Additional Comments: 
  //
  //2022-0105: V3.2
  //1、添加注释和例化模板;
  //2、优化了两个时钟域的复位同步逻辑
  //3、增加了RdEn 和 WrEn 的约束，避免误操作

  //2022-0108: V3.3
  //1、修改ReadFirst信号的在 EmptyFlag 变低，同时 EmptyReg 变高时导致 RdEmpty 错误指示 ；
  //2、添加了DataVal 作为有效数据指示；

  //2022-0120: V3.4
  //1、修改了 WrDNum 和 RdDNum 位宽和运算 （Bug)
  //2、添加了 WrDNum 和 RdDNum 仿真测试代码

  //2022-0123: V3.5
  //1、校准 WrDNum 和 RdDNum 的运算 （Bug)
  
  //2022-0124: V3.6
  //1、修改了 WrDNum 和 RdDNum的算法和描述方式，提高了Fmax ，并减少了资源利用
  //2、添加了 WrDNum 和 RdDNum 仿真测试代码
  //3、修改了非空即读的测试代码，同时测试读写一直为高的情况；
  //4、修改了 写满和读空过程中测试 WrDNum 和 RdDNum ；
  
  //2023-1013: V3.7 By Bruce Chen
  //1、修改了格雷码地址计数跨时钟域亚稳态同步器打2拍，增加同步器综合属性注释
  //2、增加了复位信号同步器属性注释
  //////////////////////////////////////////////////////////////////////////////////////

 /*例化模板和参数说明

  ///////////////////////////
  //System Signal
  //复位信号输入；高电平有效
  //内部做复位同步，保证两个时钟域都复位了才开始工作；
  wire                Reset   ; //System Reset
  //Write Signal    
  //写时钟输入；上升沿有效                         
  wire                WrClk   ; //(I)Wirte Clock
  //写允许信号；高电平有效
  wire                WrEn    ; //(I)Write Enable
  //写数据输入；
  wire  [DW_C -1:0]   WrData  ; //(I)Write Data
  //数据个数；表示从WrClk时钟域中FIFO中数据的个数
  //由于读写时钟不在一个时钟域，该值可能会不连续
  //可以使用数据个数（WrDNum）在 WrClk 时钟域实现
  // Almostfull 、 AlmostEmpty、 WrEmpty 信号
  wire  [AW_C-1:0]    WrDNum  ; //(O)Write Data Number In Fifo
  //满信号；有效时， WrEn 无效
  wire                WrFull  ; //(O)Write Full 
  //Read Signal    
  //读时钟输入；上升沿有效                        
  wire                RdClk   ; //(I)Read Clock
  //读允许信号；高电平有效                        
  wire                RdEn    ; //(I)Read Enable
  //读数据输出；                        
  wire  [DW_C-1 :0]   RdData  ; //(O)Read Data
  //数据个数；表示从 RdClk 时钟域中FIFO中数据的个数
  //由于读写时钟不在一个时钟域，该值可能会不连续
  //可以使用数据个数（RdDNum）在 RdClk 时钟域实现
  // Almostfull 、 AlmostEmpty、 Rdfull 信号
  wire  [AW_C-1:0]    RdDNum  ; //(O)Radd Data Number In Fifo
  //指示当前的数据有效
  wire                DataVal ; //(O)Data Valid 
  //空信号；有效时 RdEn 无效                        
  wire                RdEmpty ; //(O)Read FifoEmpty

  ///////////////////////////
  //FIFO数据输出模式： " Normal " & " ShowHead "
  //Normal    : RdEn 有效的下一个时钟周期出数据
  //ShowAhead ：RdEn 有效，数据有效
  //仅对数据输出有影响
  defparam     UX_XXXXXXXXXXXXX.FIFO_MODE     = "Normal"  , //"Normal"; //"ShowAhead"
  //数据宽度
  defparam     UX_XXXXXXXXXXXXX.DATA_WIDTH    = 8         ,
  //FIFO深度
  //FIFO深度会自动使用满足设置的2的n次方作为深度设置
  defparam     UX_XXXXXXXXXXXXX.FIFO_DEPTH    = 512        

  ///////////////////////////
  DC_FIFO   UX_XXXXXXXXXXXXX
  (   
    //System Signal
    .Reset    ( Reset   ) , //System Reset
    //Write Signal                             
    .WrClk    ( WrClk   ) , //(I)Wirte Clock
    .WrEn     ( WrEn    ) , //(I)Write Enable
    .WrDNum   ( WrDNum  ) , //(O)Write Data Number In Fifo
    .WrFull   ( WrFull  ) , //(O)Write Full 
    .WrData   ( WrData  ) , //(I)Write Data
    //Read Signal                            
    .RdClk    ( RdClk   ) , //(I)Read Clock
    .RdEn     ( RdEn    ) , //(I)Read Enable
    .RdDNum   ( RdDNum  ) , //(O)Radd Data Number In Fifo
    .RdEmpty  ( RdEmpty ) , //(O)Read FifoEmpty
    .DataVal  ( DataVal ) , //(O)Data Valid 
    .RdData   ( RdData  )   //(O)Read Data
  );
  ///////////////////////////

*/
module DC_FIFO
# (
    parameter     FIFO_MODE     = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_FIFO_MODE            , //"Normal"; //"ShowAhead"
    parameter     DATA_WIDTH    = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_DATA_WIDTH                 ,
    parameter     FIFO_DEPTH    = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_FIFO_DEPTH                 ,

    parameter     AW_C          = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_AW_C  ,
    parameter     DW_C          = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_DW_C          ,
    parameter     DD_C          = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_DD_C
  )
(   
  //System Signal
  input                 Reset   , //System Reset
  //Write Signal                             
  input                 WrClk   , //(I)Wirte Clock
  input                 WrEn    , //(I)Write Enable
  output  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_1]    WrDNum  , //(O)Write Data Number In Fifo
  output                WrFull  , //(O)Write Full 
  input   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_2]   WrData  , //(I)Write Data
  //Read Signal                            
  input                 RdClk   , //(I)Read Clock
  input                 RdEn    , //(I)Read Enable
  output  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_3]    RdDNum  , //(O)Radd Data Number In Fifo
  output                RdEmpty , //(O)Read FifoEmpty
  output                DataVal , //(O)Data Valid 
  output  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_4]   RdData    //(O)Read Data
);

//Define  Parameter
  /////////////////////////////////////////////////////////
  localparam    TCo_C       = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_LOCALPARAM_TCO_C  ;

  /////////////////////////////////////////////////////////

//111111111111111111111111111111111111111111111111111111111
//将输入的异步复位信号，同步到内部时钟源；
//保证两个时钟域都接收到了复位信号，才释放同步复位信号	
//********************************************************/ 
  /////////////////////////////////////////////////////////
 (* async_reg = "true" *) reg   [`CFG_BITS_2-1:0]         WrClkRstGen   = 2'h3;
 (* async_reg = "true" *) reg   [`CFG_BITS_2-1:0]         RdClkRstGen   = 2'h3;
  
  always @( posedge   WrClk or posedge Reset)
  begin
    if (Reset)                WrClkRstGen  <= # TCo_C 2'h3 ;
    else if (&WrClkRstGen)    WrClkRstGen  <= # TCo_C 2'h2 ;
    else if (~&RdClkRstGen)   WrClkRstGen  <= # TCo_C WrClkRstGen - {1'h0,(|WrClkRstGen)} ;
  end  
  always @( posedge   RdClk or posedge Reset)
  begin
    if (Reset)              RdClkRstGen  <= # TCo_C 2'h3  ;
    else if (&RdClkRstGen)  RdClkRstGen  <= # TCo_C 2'h2  ;
    else if (~&WrClkRstGen) RdClkRstGen  <= # TCo_C RdClkRstGen - {1'h0,(|RdClkRstGen)} ;
  end  

  /////////////////////////////////////////////////////////
  reg     WrClkRst =  1'h1 ;
  reg     RdClkRst =  1'h1 ;
  
  always @( posedge   WrClk or posedge Reset)
  begin
    if (Reset)        WrClkRst  <= # TCo_C 1'h1 ;
    else              WrClkRst  <= # TCo_C |WrClkRstGen ;
  end 
  always @( posedge   RdClk or posedge Reset)
  begin
    if (Reset)        RdClkRst  <= # TCo_C 1'h1 ;
    else              RdClkRst  <= # TCo_C |RdClkRstGen ;
  end       
    
  ///////////////////////////////////////////////////////// 
//111111111111111111111111111111111111111111111111111111111

//222222222222222222222222222222222222222222222222222222222
//写数据到 FifoBuff	
//地址采用格雷码
//********************************************************/ 
  ///////////////////////////////////////////////////////// 
  wire                FifoWrEn    = WrEn & (~WrFull) ;
  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_5]     WrNextAddr  ;
  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_6]     FifoWrAddr  ;
  wire                FifoWrFull  ;   

  FifoAddrCnt     # ( .CounterWidth_C (`CFG_FRAME_BUFFER_V4_DC_FIFO_V_INST_U1_WRADDRCNT_COUNTERWIDTH_C))
  U1_WrAddrCnt
  (   
    //System Signal
    .Reset          ( WrClkRst    ) , //System Reset
    .SysClk         ( WrClk       ) , //System Clock
    //Counter Signal            
    .ClkEn          ( FifoWrEn    ) , //(I)Clock Enable 
    .FifoFlag       ( FifoWrFull  ) , //(I)Fifo Flag
    .AddrCnt        ( WrNextAddr  ) , //(O)Next Address
    .Addess         ( FifoWrAddr  )   //(O)Address Output
  );

  ///////////////////////////////////////////////////////// 
  reg [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_7]      FifoBuff [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_8];

  always @( posedge   WrClk)  
  begin
    if (WrEn & (~WrFull))   
    begin
      FifoBuff[FifoWrAddr[AW_C-1:0]]  <= # TCo_C WrData;
    end
  end
 
  ///////////////////////////////////////////////////////// 

//222222222222222222222222222222222222222222222222222222222

//333333333333333333333333333333333333333333333333333333333
// 从 FifoBuff 中读出数据
// 地址采用格雷码
//********************************************************/ 
  ///////////////////////////////////////////////////////// 
  wire                FifoEmpty   ;  
  wire                FifoRdEn    ;
                                  
  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_9]     RdNextAddr  ;
  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_10]     FifoRdAddr  ;

  FifoAddrCnt     # ( .CounterWidth_C (`CFG_FRAME_BUFFER_V4_DC_FIFO_V_INST_U2_RDADDRCNT_COUNTERWIDTH_C))
  U2_RdAddrCnt
  (   
    //System Signal
    .Reset          ( RdClkRst    ) , //System Reset
    .SysClk         ( RdClk       ) , //System Clock
    //Counter Signal              
    .ClkEn          ( FifoRdEn    ) , //(I)Clock Enable 
    .FifoFlag       ( FifoEmpty   ) , //(I)Fifo Flag
    .AddrCnt        ( RdNextAddr  ) , //(O)Next Address
    .Addess         ( FifoRdAddr  )   //(O)Address Output
  );

  /////////////////////////////////////////////////////////   
  reg   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_11]   FifoRdData  ;

  always @( posedge   RdClk) 
  begin
    if (FifoRdEn)     FifoRdData  <= # TCo_C FifoBuff[FifoRdAddr[AW_C-1:0]];
  end

  /////////////////////////////////////////////////////////  
  assign RdData   =   FifoRdData  ; //(O)Read Data
  
  /////////////////////////////////////////////////////////  
//333333333333333333333333333333333333333333333333333333333

//444444444444444444444444444444444444444444444444444444444
//在写时钟域计算读写地址差
//********************************************************/ 
  /////////////////////////////////////////////////////////   
  //把读地址搬到写时钟域（ WrClk ）
/*   reg   [AW_C:0]      RdAddrOut   = {AW_C+1{1'h0}}; 
  reg   [AW_C:0]      WrRdAddr    = {AW_C+1{1'h0}}; 

  always @( posedge   WrClk)   
  begin
    if (WrClkRst)     WrRdAddr <= # TCo_C {AW_C+1{1'h0}}     ;
    else              WrRdAddr <= # TCo_C RdAddrOut [AW_C:0] ;
  end */
  
  
  (* async_reg = "true" *) reg   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_12]      RdAddrOut   = {AW_C+1{1'h0}};
  (* async_reg = "true" *) reg   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_13]      WrRdAddr_meta    = {AW_C+1{1'h0}};
  (* async_reg = "true" *) reg   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_14]      WrRdAddr    = {AW_C+1{1'h0}};
  
  always @( posedge   WrClk)   
  begin
    if (WrClkRst) begin
        WrRdAddr_meta <= # TCo_C {AW_C+1{1'h0}} ;
        WrRdAddr <= # TCo_C {AW_C+1{1'h0}}     ;
    end
    else  begin
        WrRdAddr_meta <= # TCo_C RdAddrOut [AW_C:0] ;
        WrRdAddr <= # TCo_C WrRdAddr_meta ;
    end
  end

  ///////////////////////////////////////////////////////// 
  //把读写地址的格雷码转化为16进制  
  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_15]    WrRdAHex  ;
  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_16]    WrWrAHex  ;

  GrayDecode #(`CFG_FRAME_BUFFER_V4_DC_FIFO_V_INST_WRAGRAY2HEX_ARG_0)  WRAGray2Hex (WrRdAddr   [AW_C-1:0] , WrRdAHex[AW_C-1:0])  ;
  GrayDecode #(`CFG_FRAME_BUFFER_V4_DC_FIFO_V_INST_WWAGRAY2HEX_ARG_0)  WWAGray2Hex (FifoWrAddr [AW_C-1:0] , WrWrAHex[AW_C-1:0])  ;

  /////////////////////////////////////////////////////////   
  //写时钟域中计算读写地址差
  reg   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_17]    WrAddrDiff  = {AW_C+1{1'h0}}  ;

  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_18]    Calc_WrAddrDiff =  ( {FifoWrAddr[AW_C]  , WrWrAHex  }
                                    +  { {AW_C{1'h0}}       , FifoWrEn  } ) ; 
  always @( posedge   WrClk)  
  begin
    if (WrClkRst)       WrAddrDiff  <= # TCo_C  {AW_C+1{1'h0}}      ;
    else                WrAddrDiff  <= # TCo_C  Calc_WrAddrDiff    
                                    - {WrRdAddr  [AW_C] , WrRdAHex} ;
  end

  /////////////////////////////////////////////////////////   
  assign  WrDNum  =   WrAddrDiff;  //(O)Data Number In Fifo

  /////////////////////////////////////////////////////////     
//444444444444444444444444444444444444444444444444444444444

//555555555555555555555555555555555555555555555555555555555
// 计算 WrFull 信号
//********************************************************/ 
  ///////////////////////////////////////////////////////// 
  //产生 WrFull 的清除信号 （ WrFullClr ）
  //当 FifoRdAddr 发生变化，产生 WrFullClr 
  reg   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_19]      WrRdAddrReg = {AW_C+1{1'h0}};
  reg                 WrFullClr   = 1'h0;   
                                  
  always @( posedge   WrClk)      
  begin                           
    if (  WrClkRst)   WrRdAddrReg <= # TCo_C {AW_C+1{1'h0}}     ;    
    else              WrRdAddrReg <= # TCo_C WrRdAddr[AW_C : 0] ;   
  end                             
  always @( posedge   WrClk)      
  begin                           
    if (  WrClkRst)   WrFullClr   <= # TCo_C 1'h0         ;   
    else              WrFullClr   <= # TCo_C (WrRdAddr[AW_C-1:0] != WrRdAddrReg[AW_C-1:0]);
  end
  
  /////////////////////////////////////////////////////////   
  //计算满信号 
  reg   RdAHighNext   = 1'h0;
                      
  wire  RdAHighRise   = (~WrRdAddrReg[AW_C-1]) &  WrRdAddr[AW_C-1];  
                      
  always @( posedge   WrClk)  
  begin
    if (WrClkRst  )         RdAHighNext <= # TCo_C 1'h0 ;
    else if (RdAHighRise)   RdAHighNext <= # TCo_C (~WrRdAddr[AW_C])  ;
  end
   
  wire  FullCalc = (WrNextAddr[AW_C-1:0] ==  WrRdAddr[AW_C-1:0]) 
                && (WrNextAddr[AW_C    ] != (WrRdAddr[AW_C-1] ? WrRdAddrReg[AW_C] : RdAHighNext) );
                
/////////////////////////////////////////////////// 
  reg   FullFlag        = 1'h0;
                        
  always @( posedge     WrClk)
  begin
    if (WrClkRst)       FullFlag  <= # TCo_C 1'h0;
    else if (FullFlag)  FullFlag  <= # TCo_C (~WrFullClr);
    else if (FifoWrEn)  FullFlag  <= # TCo_C FullCalc;
  end
    
  assign FifoWrFull     = FullFlag;
   
/////////////////////////////////////////////////// 
  assign  WrFull        = FifoWrFull  ; //(I)Write Full 
  
/////////////////////////////////////////////////// 
  

//555555555555555555555555555555555555555555555555555555555

//666666666666666666666666666666666666666666666666666666666
//	在读时钟域计算读写地址差
//********************************************************/ 
  ///////////////////////////////////////////////////////// 
  //把写地址 （ FifoWrAddr ）搬到读时钟域
/*   reg   [AW_C :0]     RdWrAddr  = {AW_C+1{1'h0}}; 
  
  always @( posedge   RdClk)    
  begin
    if (RdClkRst )    RdWrAddr  <= # TCo_C {AW_C+1{1'h0}}       ;   
    else              RdWrAddr  <= # TCo_C FifoWrAddr [AW_C:0]  ;   
  end   */
  
  (* async_reg = "true" *)  reg   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_20]     RdWrAddr  = {AW_C+1{1'h0}};
  (* async_reg = "true" *)  reg   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_21]     RdWrAddr_meta  = {AW_C+1{1'h0}};
  
  always @( posedge   RdClk)    
  begin
    if (RdClkRst )  begin
        RdWrAddr_meta <= # TCo_C {AW_C+1{1'h0}}   ;
        RdWrAddr  <= # TCo_C {AW_C+1{1'h0}}   ;
    end
    else begin
            RdWrAddr_meta  <= # TCo_C FifoWrAddr [AW_C:0]  ; 
            RdWrAddr  <= # TCo_C RdWrAddr_meta  ; 
    end
  end  
  
  ///////////////////////////////////////////////////////// 
  //根据 FIFO_MODE的设置，产生运算 WrDNum 和 RdDNum 用的 RdAddr
  wire  ReadEn  = (RdEn & (~RdEmpty)) ;

  generate
    if (FIFO_MODE == "ShowAhead")
    begin
      always @( posedge   RdClk)   
      begin
        if (RdClkRst )    RdAddrOut <= # TCo_C {AW_C+1{1'h0}}       ;   
        else if (ReadEn)  RdAddrOut <= # TCo_C FifoRdAddr [AW_C:0]  ;   
      end  
    end
    else  
    begin
      always @( * )   RdAddrOut = # TCo_C FifoRdAddr [AW_C:0]  ; 
    end
  endgenerate

  /////////////////////////////////////////////////////////   
  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_22]    RdWrAHex;
  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_23]    RdRdAHex;

  GrayDecode # (`CFG_FRAME_BUFFER_V4_DC_FIFO_V_INST_RWAGRAY2HEX_ARG_0) RWAGray2Hex (RdWrAddr   [AW_C-1:0] , RdWrAHex[AW_C-1:0] );
  GrayDecode # (`CFG_FRAME_BUFFER_V4_DC_FIFO_V_INST_RRAGRAY2HEX_ARG_0) RRAGray2Hex (RdAddrOut  [AW_C-1:0] , RdRdAHex[AW_C-1:0] );

  ///////////////////////////////////////////////////////// 
  //在读时钟域计算地址差  
  reg   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_24]      RdAddrDiff  = {AW_C+1{1'h0}} ;

  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_25]      Calc_RdAddrDiff = ( {RdAddrOut[AW_C] , RdRdAHex }
                                      + { {AW_C{1'h0}}     , ReadEn   } ) ;
  always @( posedge   RdClk)  
  begin
    if (RdClkRst)     RdAddrDiff <= # TCo_C {AW_C+1{1'h0}}    ;
    else              RdAddrDiff <= # TCo_C {RdWrAddr[AW_C]   , RdWrAHex } 
                                          - Calc_RdAddrDiff   ;
  end

  /////////////////////////////////////////////////////////   
  assign  RdDNum    = RdAddrDiff;   //(O)Data Number In Fifo

  /////////////////////////////////////////////////////////   
  

//666666666666666666666666666666666666666666666666666666666

//777777777777777777777777777777777777777777777777777777777
//计算 RdEmpty 信号
//********************************************************/
  ///////////////////////////////////////////////////////// 
  //产生 RdEmpty 的清除信号  
  reg   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_26]      RdWrAddrReg = {AW_C+1{1'h0}};
  reg                 EmptyClr    = 1'h0;
                      
  always @( posedge   RdClk)    
  begin               
    if (RdClkRst)     RdWrAddrReg <= # TCo_C {AW_C+1{1'h0}}     ;
    else              RdWrAddrReg <= # TCo_C RdWrAddr [AW_C:0]  ;
  end                 
  always @( posedge   RdClk)       
  begin               
    if (RdClkRst)     EmptyClr    <= # TCo_C 1'h0;
    else              EmptyClr    <= # TCo_C (RdWrAddr[AW_C-1:0] != RdWrAddrReg[AW_C-1:0])  ;
  end
  
  reg   EmptyClrReg   = 1'h0;

  always @( posedge     RdClk )   EmptyClrReg   <= EmptyClr ;

  ///////////////////////////////////////////////////////// 
  //计算空信号 （EmptyCalc）  
  reg   WrAHighNext   = 1'h0;  
  
  wire  WrAHighRise   = (~RdWrAddrReg[AW_C-1]) &  RdWrAddr[AW_C-1];  
  
  always @( posedge   RdClk)  
  begin
    if (RdClkRst)           WrAHighNext   <= # TCo_C  1'h0 ;
    else if (WrAHighRise)   WrAHighNext   <= # TCo_C (~RdWrAddr[AW_C]);
  end              

  wire  EmptyCalc   = (RdNextAddr[AW_C-1:0] == RdWrAddr[AW_C-1:0]) 
                   && (RdNextAddr[AW_C    ] == (RdWrAddr[AW_C-1] ? RdWrAddrReg[AW_C] : WrAHighNext));
                                       
  ///////////////////////////////////////////////////////// 
  reg     EmptyFlag     = 1'h1;

  always @( posedge     RdClk)
  begin
    if (RdClkRst)       EmptyFlag   <= # TCo_C  1'h1  ;
    else if (EmptyFlag) EmptyFlag   <= # TCo_C ~EmptyClr;
    else if (FifoRdEn)  EmptyFlag   <= # TCo_C  EmptyCalc;
  end

  assign FifoEmpty    = EmptyFlag;
    
  ///////////////////////////////////////////////////////// 
  reg   EmptyReg      = 1'h0;

  always @( posedge     RdClk )
  begin
    if (RdClkRst)       EmptyReg  <= # TCo_C 1'h1;
    else if (FifoRdEn)      EmptyReg  <= # TCo_C FifoEmpty;
  end

  ///////////////////////////////////////////////////////// 
  assign RdEmpty = (FIFO_MODE == "ShowAhead") ? EmptyReg : FifoEmpty; //(O)Read FifoEmpty
    
  ///////////////////////////////////////////////////////// 
//777777777777777777777777777777777777777777777777777777777

//888888888888888888888888888888888888888888888888888888888
//
//********************************************************/
  ///////////////////////////////////////////////////////// 
  reg   RdFirst     = 1'h0;
    
  always @( posedge   RdClk)
  begin
    if (FIFO_MODE == "ShowAhead")
    begin
      if (RdClkRst)       RdFirst <= # TCo_C 1'h0     ;  
    	else if (RdFirst)	  RdFirst <= # TCo_C 1'h0     ;
    	else if (EmptyClr)	RdFirst <= # TCo_C RdEmpty  ;
    	else if (EmptyReg ^ EmptyFlag)	RdFirst <= # TCo_C RdEmpty  ;
    end
    else                  RdFirst <= # TCo_C 1'h0     ;
  end
    
  ///////////////////////////////////////////////////////// 
  reg   ReadEn_Reg  = 1'h0 ;
  
  always @( posedge   RdClk)    ReadEn_Reg  <= ReadEn ;

  wire  Data_Valid  = (FIFO_MODE == "ShowAhead") ? ReadEn : ReadEn_Reg ;

  ///////////////////////////////////////////////////////// 
  assign  FifoRdEn  =   ReadEn ||  RdFirst ;
  assign  DataVal   =   Data_Valid  ; //(O)Data Valid 

  /////////////////////////////////////////////////////////
//888888888888888888888888888888888888888888888888888888888

endmodule

//////////////// DaulClkFifo //////////////////////////////




  
  
///////////////// FifoAddrCnt /////////////////////////////
/**********************************************************
// Create Date:    2020/03/25
// Module Name:     
// Tool versions:  EFINITY 2019.3.272.8.4
// Description:    V2.4

// Dependencies: EFINITY DaulClkFifo2.4 by Richard Zhu :锟绞诧拷
//
// Revision: 0.01 File Created 2019/11/08
// Additional Comments: 
//
**********************************************************/

module FifoAddrCnt
# (
    parameter CounterWidth_C  = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_COUNTERWIDTH_C   ,
    parameter CW_C            = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_CW_C
  )
(   
  //System Signal
  input             Reset     , //System Reset
  input             SysClk    , //System Clock
  //Counter Signal            
  input             ClkEn     , //(I)Clock Enable 
  input             FifoFlag  , //(I)Fifo Flag
  output  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_27]  AddrCnt   , //(O)Address Counter
  output  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_28]  Addess      //(O)Address Output
);

//Define  Parameter
  /////////////////////////////////////////////////////////
localparam    TCo_C       = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_LOCALPARAM_TCO_C_2;

//111111111111111111111111111111111111111111111111111111111
//	
//	Input:
//	output:
//********************************************************/ 

  /////////////////////////////////////////////////////////
  wire [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_29]   GrayAddrCnt;
  wire              CarryOut;

  GrayCnt #(.CounterWidth_C (`CFG_FRAME_BUFFER_V4_DC_FIFO_V_INST_U1_ADDRCNT_COUNTERWIDTH_C))
  U1_AddrCnt
  (   
    //System Signal
    .Reset    ( Reset       ),  //System Reset
    .SysClk   ( SysClk      ),  //System Clock
    //Counter Signal            
    .SyncClr  ( 1'h0        ),  //(I)Sync Clear
    .ClkEn    ( ClkEn       ),  //(I)Clock Enable 
    .CarryIn  ( ~FifoFlag   ),  //(I)Carry input
    .CarryOut ( CarryOut    ),  //(O)Carry output
    .Count    ( GrayAddrCnt )   //(O)Counter Value Output
  );
        
  /////////////////////////////////////////////////////////
  reg   CntHighBit;

  always @( posedge SysClk )
  begin
    if (Reset)      CntHighBit <= # TCo_C 1'h0;
    else if (ClkEn) CntHighBit <= # TCo_C CntHighBit + CarryOut;
  end

  /////////////////////////////////////////////////////////
  (* async_reg = "true" *)reg  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_30]  AddrOut;    //(O)Address Output

  always @(posedge SysClk)
  begin
    if (Reset)        AddrOut <= # TCo_C {CW_C{1'h0}};
    else if (ClkEn)   AddrOut <= # TCo_C FifoFlag ? AddrOut : AddrCnt;
  end    

  /////////////////////////////////////////////////////////
  assign  AddrCnt  = {CntHighBit , GrayAddrCnt} ; //(O)Next Address           
  assign  Addess   =  AddrOut                   ; //(O)Address Output    

//111111111111111111111111111111111111111111111111111111111

endmodule

/////////////////// FifoAddrCnt //////////////////////////






////////////////////// GrayCnt ////////////////////////////
/**********************************************************
// Create Date:    2019/08/11
// Module Name:     
// Tool versions:  EFINITY 2019.3.272.8.4
// Description:    V2.4

// Dependencies: EFINITY DaulClkFifo2.4 by Richard Zhu :锟绞诧拷
//
// Revision: 0.01 File Created 2019/08/11
// Additional Comments: 
//
**********************************************************/
  /////////////////////////////////////////////////////////

module GrayCnt
# (
    parameter   CounterWidth_C    = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_COUNTERWIDTH_C_2   ,
    parameter   CW_C              = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_CW_C_2
  )
( 
  //System Signal
  input                 Reset     , //System Reset
  input                 SysClk    , //System Clock
  //Counter Signal
  input                 SyncClr   , //(I)Sync Clear
  input                 ClkEn     , //(I)Clock Enable 
  input                 CarryIn   , //(I)Carry input
  output                CarryOut  , //(O)Carry output
  output  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_31]    Count       //(O)Counter Value Output
);

//Define  Parameter
  /////////////////////////////////////////////////////////
localparam    TCo_C       = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_LOCALPARAM_TCO_C_3;

//111111111111111111111111111111111111111111111111111111111
//	
//	Input:
//	output:
//********************************************************/ 

  /////////////////////////////////////////////////////////
  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_32  ]  CryIn  ;
  wire  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_33]  CryOut ;

  reg   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_34]  GrayCnt;

  assign CryIn[0] = CarryIn;

  genvar i;
  generate
    for(i=0;i<CW_C;i=i+1)
    begin : GrayCnt_CrayCntUnit
      //////////////   
      always @( posedge SysClk )
      begin
        if (Reset)        GrayCnt[i]  <= # TCo_C (i>1) ? 1'h0: 1'h1  ;
        else if (SyncClr) GrayCnt[i]  <= # TCo_C (i>1) ? 1'h0: 1'h1  ;
        else if (ClkEn)   GrayCnt[i]  <= # TCo_C GrayCnt[i] + CryIn[i];
      end
      
      //////////////   
      if (i==0)    
      begin
        assign CryOut[0]  =  GrayCnt[0] && CarryIn;
        assign CryIn [1]  = ~GrayCnt[0] && CarryIn;
      end
      else    
      begin
        assign CryOut[i  ]  =  CryOut[  0] && (~|GrayCnt[i:1]);
        assign CryIn [i+1]  =  CryOut[i-1] &&    GrayCnt[i  ] ;  
      end
    end
    
  endgenerate

  wire GrayCarry = CryOut[CW_C-2];
  
  /////////////////////////////////////////////////////////
  reg  CntHigh = 1'h0;

  always @( posedge SysClk)
  begin
    if (Reset)      CntHigh   <= # TCo_C 1'h0;
    else if (ClkEn) CntHigh   <= # TCo_C (CntHigh + GrayCarry);
  end

  /////////////////////////////////////////////////////////
  assign Count    = {CntHigh  , GrayCnt[CW_C-1:1]}  ; //(O)Counter Value Output
  assign CarryOut =  CntHigh  & GrayCarry           ; //(O)Carry output
  
  /////////////////////////////////////////////////////////

//111111111111111111111111111111111111111111111111111111111

endmodule

////////////////////// GrayCnt ////////////////////////////






  /////////////////////////////////////////////////////////
/**********************************************************
// Create Date:    2020/01/19
// Module Name:     
// Tool versions:  EFINITY 2019.3.272.8.4
// Description:    V2.4

// Dependencies: EFINITY DaulClkFifo2.4 by Richard Zhu :锟绞诧拷
//
// Revision: 0.01 File Created 2020/01/19
// Additional Comments: 
//
**********************************************************/

module GrayDecode
# (
    parameter DataWidht_C = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_DATAWIDHT_C
  )
(   
  input   [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_35]  GrayIn,
  output  [`CFG_FRAME_BUFFER_V4_DC_FIFO_V_RANGE_36]  HexOut
);

 	//Define  Parameter
  /////////////////////////////////////////////////////////
    parameter		TCo_C   		= `CFG_FRAME_BUFFER_V4_DC_FIFO_V_PARAMETER_TCO_C;
		
	localparam DW_C = `CFG_FRAME_BUFFER_V4_DC_FIFO_V_LOCALPARAM_DW_C;
	
  /////////////////////////////////////////////////////////
  // Continuous equations also evaluate a pointer held at zero after reset.
  assign HexOut[DW_C-1] = GrayIn[DW_C-1];
  genvar bit_index;
  generate for(bit_index=0;bit_index<DW_C-1;bit_index=bit_index+1) begin: decode_bits
    assign HexOut[bit_index] = HexOut[bit_index+1] ^ GrayIn[bit_index];
  end endgenerate

  /////////////////////////////////////////////////////////

endmodule
