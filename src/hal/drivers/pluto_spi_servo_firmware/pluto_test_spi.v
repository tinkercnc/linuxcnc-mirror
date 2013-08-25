

//**********************************************************************
// Open-Collector/Drain buffer
module OC_Buff(in, out);
input in;
output out;
assign out = in ? 1'bz : 1'b0;
endmodule

//**********************************************************************
module pluto_test_spi(clk, SCK, MOSI, MISO, SSEL, LED, nConfig, nPE, quadA, quadB, quadZ, up, down, dout, din);
parameter QW=14;
input clk;

input SCK, SSEL, MOSI;
output MISO, nConfig, nPE;
output LED;
output [3:0] down = 4'bZZZZ;
output [3:0] up = 4'bZZZZ;

input [7:0] din;
input [3:0] quadA;
input [3:0] quadB;
input [3:0] quadZ;

assign nConfig = ~do_reset; //1'b1;
assign nPE = 1'b1;

reg[9:0] real_dout; 
//output [9:0] dout = real_dout[9:0] ? 10'bZZZZZZZZZZ : 10'b0000000000 ;
output [9:0] dout = 10'bZZZZZZZZZZ;
//assign dout = real_dout;
OC_Buff ocout[9:0](real_dout, dout);

wire[3:0] real_down;
OC_Buff ocdown[3:0](real_down, down);
wire[3:0] real_up;
OC_Buff ocup[3:0](real_up, up);

reg Zpolarity;
wire do_reset;
wdt w(clk, SSEL, pwm_at_top, do_reset);		// if no SSEL-toggle then unconfigure the fpga
//**********************************************************************
// PWM stuff
// PWM clock is about 20kHz for clk @ 40MHz, 11-bit cnt
wire pwm_at_top;
reg [10:0] pwmcnt;
wire [10:0] top = 11'd2046;
assign pwm_at_top = (pwmcnt == top);
reg [15:0] pwm0, pwm1, pwm2, pwm3;
always @(posedge clk) begin
    if(pwm_at_top) pwmcnt <= 0;
    else pwmcnt <= pwmcnt + 11'd1;
end

wire [10:0] pwmrev = { 
    pwmcnt[4], pwmcnt[5], pwmcnt[6], pwmcnt[7], pwmcnt[8], pwmcnt[9],
    pwmcnt[10], pwmcnt[3:0]};
wire [10:0] pwmcmp0 = pwm0[14] ? pwmrev : pwmcnt;   // pwm0[14] = pdm/pwm bit
// wire [10:0] pwmcmp1 = pwm1[14] ? pwmrev : pwmcnt;
// wire [10:0] pwmcmp2 = pwm2[14] ? pwmrev : pwmcnt;
// wire [10:0] pwmcmp3 = pwm3[14] ? pwmrev : pwmcnt;
wire pwmact0 = pwm0[10:0] > pwmcmp0;
wire pwmact1 = pwm1[10:0] > pwmcmp0;
wire pwmact2 = pwm2[10:0] > pwmcmp0;
wire pwmact3 = pwm3[10:0] > pwmcmp0;
assign real_up[0] = pwm0[12] ^ (pwm0[15] ? 1'd0 : pwmact0);
assign real_up[1] = pwm1[12] ^ (pwm1[15] ? 1'd0 : pwmact1);
assign real_up[2] = pwm2[12] ^ (pwm2[15] ? 1'd0 : pwmact2);
assign real_up[3] = pwm3[12] ^ (pwm3[15] ? 1'd0 : pwmact3);
assign real_down[0] = pwm0[13] ^ (~pwm0[15] ? 1'd0 : pwmact0);
assign real_down[1] = pwm1[13] ^ (~pwm1[15] ? 1'd0 : pwmact1);
assign real_down[2] = pwm2[13] ^ (~pwm2[15] ? 1'd0 : pwmact2);
assign real_down[3] = pwm3[13] ^ (~pwm3[15] ? 1'd0 : pwmact3);

//**********************************************************************
// Quadrature stuff
// Quadrature is digitized at 40MHz into 14-bit counters
// Read up to 2^13 pulses / polling period = 8MHz for 1kHz servo period
reg qtest;
wire [2*QW:0] quad0, quad1, quad2, quad3;
wire qr0, qr1, qr2, qr3;
//quad q0(clk, qtest ? real_dout[0] : quadA[0], qtest ? real_dout[1] : quadB[0], qtest ? real_dout[2] : quadZ[0]^Zpolarity, qr0, quad0);
quad q0(clk, quadA[0], quadB[0], quadZ[0]^Zpolarity, qr0, quad0);
quad q1(clk, quadA[1], quadB[1], quadZ[1]^Zpolarity, qr1, quad1);
quad q2(clk, quadA[2], quadB[2], quadZ[2]^Zpolarity, qr2, quad2);
quad q3(clk, quadA[3], quadB[3], quadZ[3]^Zpolarity, qr3, quad3);

//**********************************************************************
// SPI zeugs
// sync SCK to the FPGA clock using a 3-bits shift register
reg [2:0] SCKr;
always @(posedge clk) SCKr <= {SCKr[1:0], SCK};
wire SCK_risingedge = (SCKr[2:1]==2'b01);  // now we can detect SCK rising edges
wire SCK_fallingedge = (SCKr[2:1]==2'b10);  // and falling edges

// same thing for SSEL
reg [2:0] SSELr;
always @(posedge clk) SSELr <= {SSELr[1:0], SSEL};
wire SSEL_active = ~SSELr[1];  // SSEL is active low
wire SSEL_startmessage = (SSELr[2:1]==2'b10);  // message starts at falling edge
wire SSEL_endmessage = (SSELr[2:1]==2'b01);  // message stops at rising edge

// and for MOSI
reg [1:0] MOSIr;
always @(posedge clk) MOSIr <= {MOSIr[0], MOSI};
wire MOSI_data = MOSIr[1];

// we handle SPI in 8-bits format, so we need a 3 bits counter to count the bits as they come in
reg [2:0] bitcnt;
reg byte_received;  // high when 8 bit has been received

reg [7:0] data_recvd;
always @(posedge clk) begin
  if(~SSEL_active)
    bitcnt <= 3'b000;
  else
  if(SCK_risingedge) begin
    // implement a shift-left register (since we receive the data MSB first)
    //byte_data_received <= {byte_data_received[6:0], MOSI_data};
    data_recvd <= {data_recvd[6:0], MOSI_data};
    bitcnt <= bitcnt + 3'b001;
  end
  /*
  else if(SCK_fallingedge)
  	bitcnt <= bitcnt + 3'b001;
  	*/
end



//reg [7:0] datainreg;
reg [7:0] data_sent;
reg [7:0] data_buf;
always @(posedge clk) byte_received <= SSEL_active && SCK_risingedge && (bitcnt==3'b111);
always @(posedge clk) begin
	if(SSEL_active) begin
		/*
		if(SCK_risingedge) begin
			if(bitcnt==3'b111) begin
				byte_received <= 1'b1;
				datainreg <= data_recvd;
			end
			//else if(bitcnt==3'b000)
			//	byte_received <= {byte_received[0], 1'b0};
		end
		
		if(byte_received) begin
			data_sent <= data_buf;
			//byte_received <= 1'b0;
			//data_sent <= data_recvd;	// nur fuer feedback-test
			//if(bitcnt==3'b000) byte_received <= 1'b0;
		end
		
		else  */
		if(SSEL_startmessage)
			data_sent <= data_buf;
		else if(SCK_risingedge) begin
			if(bitcnt==3'b000)
				data_sent <= data_buf;
		end
		else if(SCK_fallingedge) begin
			/*
			if(bitcnt==3'b000)
				data_sent <= data_buf;
			else
			*/
			data_sent <= {data_sent[6:0], 1'b0};
		end
	end
end
assign MISO = data_sent[7];  // send MSB first
// we assume that there is only one slave on the SPI bus
// so we don't bother with a tri-state buffer for MISO
// otherwise we would need to tri-state MISO when SSEL is inactive

reg [5:0] spibytecnt;
always @(posedge clk) begin
	if(SSEL_startmessage) spibytecnt <= 6'b0000;
	else if(SCK_fallingedge) begin
		if(bitcnt==3'b000) begin
			spibytecnt <= spibytecnt + 6'b0001;
		end
	end
end

always @(posedge clk) begin
	if(SSEL_active) begin
		//------------------------------------------------- word 0
		if(spibytecnt == 6'b0000) begin	// 0
			data_buf <= quad0[7:0];
			//data_buf <= 8'h01;
			if(byte_received)
				pwm0[7:0] <= data_recvd;
		end
		else if(spibytecnt == 6'b0001) begin	// 1
			data_buf <= quad0[15:8];
			//data_buf <= 8'h23;
			if(byte_received)
				pwm0[15:8] <= data_recvd;
		end
		else if(spibytecnt == 6'b0010) begin	// 2
			data_buf <= quad0[23:16];
			//data_buf <= 8'h45;
			if(byte_received)
				pwm1[7:0] <= data_recvd;
		end
		else if(spibytecnt == 6'b0011) begin	// 3
			data_buf <= {4'b0, quad0[27:24]};
			//data_buf <= 8'h67;
			if(byte_received)
				pwm1[15:8] <= data_recvd;
		end
		//------------------------------------------------- word 1
		else if(spibytecnt == 6'b0100) begin	// 4
			data_buf <= quad1[7:0];
			if(byte_received)
				pwm2[7:0] <= data_recvd;
		end
		else if(spibytecnt == 6'b0101) begin	// 5
			data_buf <= quad1[15:8];
			if(byte_received)
				pwm2[15:8] <= data_recvd;
		end
		else if(spibytecnt == 6'b0110) begin	// 6
			data_buf <= quad1[23:16];
			if(byte_received)
				pwm3[7:0] <= data_recvd;
		end
		else if(spibytecnt == 6'b0111) begin	// 7
			data_buf <= {4'b0, quad1[27:24]};
			if(byte_received)
				pwm3[15:8] <= data_recvd;
		end
		//------------------------------------------------- word 2
		else if(spibytecnt == 6'b1000)  begin	// 8
			data_buf <= quad2[7:0];
			if(byte_received)
				real_dout[7:0] <= data_recvd;
		end
		else if(spibytecnt == 6'b1001) begin	// 9
			data_buf <= quad2[15:8];
			if(byte_received) begin
				real_dout[9:8] <= data_recvd[1:0];
				Zpolarity <= data_recvd[7];
				qtest <= data_recvd[5];
			end
		end
		else if(spibytecnt == 6'b1010) data_buf <= quad2[23:16];
		else if(spibytecnt == 6'b1011) data_buf <= {4'b0, quad2[27:24]};
		//------------------------------------------------- word 3
		else if(spibytecnt == 6'b1100) data_buf <= quad3[7:0];
		else if(spibytecnt == 6'b1101) data_buf <= quad3[15:8];
		else if(spibytecnt == 6'b1110) data_buf <= quad3[23:16];
		else if(spibytecnt == 6'b1111) data_buf <= {4'b0, quad3[27:24]};
		//------------------------------------------------- word 4
		else if(spibytecnt == 6'b10000) data_buf <= 8'b0;
		else if(spibytecnt == 6'b10001) data_buf <= 8'b0;
		else if(spibytecnt == 6'b10010) data_buf <= {4'b0, quadA};
		else if(spibytecnt == 6'b10011) data_buf <= {quadB, quadZ};
		//------------------------------------------------- word 5
		else if(spibytecnt == 6'b10100) data_buf <= din;
		//else if(spibytecnt == 16'b10101) data_buf <= 8'b0;
		//else if(spibytecnt == 16'b10110) data_buf <= spibytecnt[15:8];
		//else if(spibytecnt == 16'b10111) data_buf <= spibytecnt[7:0];
		else data_buf <= spibytecnt;
	end
end

assign LED = (real_up[0] ^ real_down[0]);
endmodule

/*
always @(posedge clk) begin
	if(SSEL_active) begin
		if(byte_received) begin
			if(spibytecnt == 6'b0000) begin	// 0
				data_buf <= quad0[7:0];
				pwm0[7:0] <= data_recvd;
			end
			else if(spibytecnt == 6'b0001) begin	// 1
				data_buf <= quad0[15:8];
				pwm0[15:8] <= data_recvd;
			end
			else if(spibytecnt == 6'b0010) begin	// 2
				data_buf <= quad0[23:16];
				pwm1[7:0] <= data_recvd;
			end
			else if(spibytecnt == 6'b0011) begin	// 3
				data_buf <= {4'b0, quad0[27:24]};
				pwm1[15:8] <= data_recvd;
			end
			else if(spibytecnt == 6'b0100) begin	// 4
				data_buf <= quad1[7:0];
				pwm2[7:0] <= data_recvd;
			end
			else if(spibytecnt == 6'b0101) begin	// 5
				data_buf <= quad1[15:8];
				pwm2[15:8] <= data_recvd;
			end
			else if(spibytecnt == 6'b0110) begin	// 6
				data_buf <= quad1[23:16];
				pwm3[7:0] <= data_recvd;
			end
			else if(spibytecnt == 6'b0111) begin	// 7
				data_buf <= {4'b0, quad1[27:24]};
				pwm3[15:8] <= data_recvd;
			end
			else if(spibytecnt == 6'b1000)  begin	// 8
				data_buf <= quad2[7:0];
				real_dout[7:0] <= data_recvd;
			end
			else if(spibytecnt == 6'b1001) begin	// 9
				data_buf <= quad2[15:8];
				real_dout[9:8] <= data_recvd[1:0];
				Zpolarity <= data_recvd[7];
				qtest <= data_recvd[5];
			end
			else if(spibytecnt == 6'b1010) data_buf <= quad2[23:16];
			else if(spibytecnt == 6'b1011) data_buf <= {4'b0, quad2[27:24]};
			else if(spibytecnt == 6'b1100) data_buf <= quad3[7:0];
			else if(spibytecnt == 6'b1101) data_buf <= quad3[15:8];
			else if(spibytecnt == 6'b1110) data_buf <= quad3[23:16];
			else if(spibytecnt == 6'b1111) data_buf <= {4'b0, quad3[27:24]};
			
			else if(spibytecnt == 6'b10000) data_buf <= 8'b0;
			else if(spibytecnt == 6'b10001) data_buf <= 8'b0;
			else if(spibytecnt == 6'b10010) data_buf <= {4'b0, quadA};
			else if(spibytecnt == 6'b10011) data_buf <= {quadB, quadZ};
			else if(spibytecnt == 6'b10100) data_buf <= din;
			//else if(spibytecnt == 16'b10101) data_buf <= 8'b0;
			//else if(spibytecnt == 16'b10110) data_buf <= spibytecnt[15:8];
			//else if(spibytecnt == 16'b10111) data_buf <= spibytecnt[7:0];
			else data_buf <= spibytecnt;
		end
	end
end
*/
/*
// data write
always @(posedge clk) begin
    if(EPP_strobe_edge1 & EPP_write & EPP_data_strobe) begin
        if(addr_reg[3:0] == 4'd1)      pwm0 <= { EPP_datain, lowbyte };	// if addr == x0001b
        else if(addr_reg[3:0] == 4'd3) pwm1 <= { EPP_datain, lowbyte };	// if addr == x0011b
        else if(addr_reg[3:0] == 4'd5) pwm2 <= { EPP_datain, lowbyte };	// if addr == x0101b
        else if(addr_reg[3:0] == 4'd7) pwm3 <= { EPP_datain, lowbyte };	// if addr == x0111b
        else if(addr_reg[3:0] == 4'd9) begin														// if addr == x1001b
            real_dout <= { EPP_datain[1:0], lowbyte };
            Zpolarity <= EPP_datain[7];
            qtest <= EPP_datain[5];
        end
        // das is komisch....  x1010b || x1011b || x1100b || x1101b || x1110b || x1111b  die sollt ma eigentlich aussieben
        else lowbyte <= EPP_datain;																			// if addr == x0000b || x0010b || x0100b || x0110b || x1000b  alle geraden adressen
    end
end
*/

