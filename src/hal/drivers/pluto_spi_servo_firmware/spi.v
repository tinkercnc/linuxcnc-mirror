/*   This is a component of pluto_servo_rpspi for RaspberryPi , a PWM servo driver and quadrature
 *    counter over SPI for linuxcnc.
 *    Copyright 2013 Matsche <tinker@play-pla.net>.
 *
 *
 *    This program is free software; you can redistribute it and/or modify
 *    it under the terms of the GNU General Public License as published by
 *    the Free Software Foundation; either version 3 of the License, or
 *    (at your option) any later version.
 *
 *    This program is distributed in the hope that it will be useful,
 *    but WITHOUT ANY WARRANTY; without even the implied warranty of
 *    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *    GNU General Public License for more details.
 *
 *    You should have received a copy of the GNU General Public License
 *    along with this program; if not, write to the Free Software
 *    Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301 USA
 */
 
module SPI_slave(clk, SCK, MOSI, MISO, SSEL, datain, dataout, dataready, strtmsg, endmsg);
input clk;

input SCK, SSEL, MOSI;
output MISO;
output dataready;
output strtmsg = SSEL_startmessage;
output endmsg;
input [31:0] datain;
output [31:0] dataout;
reg  [31:0] dataoutreg;

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

// we handle SPI in 32-bits format, so we need a 5 bits counter to count the bits as they come in
reg [4:0] bitcnt;
//reg [1:0] bytecnt;

reg word_received;  // high when 32 bit has been received
assign dataready = word_received;
reg mesg_received;  // high when a message has been received
assign endmsg = ~SSEL_active;
//assign strtmsg = SSEL_startmessage;

reg [31:0] data_recvd;
always @(posedge clk)
begin
  if(~SSEL_active)
    bitcnt <= 5'b00000;
  else
  if(SCK_risingedge) begin
    bitcnt <= bitcnt + 5'b00001;
    // implement a shift-left register (since we receive the data MSB first)
    //byte_data_received <= {byte_data_received[6:0], MOSI_data};
    data_recvd <= {data_recvd[30:0], MOSI_data};
  end
end

/*
always @(posedge clk)
begin 
	byte_received <= SSEL_active && SCK_fallingedge && (bitcnt==3'b111);
end

always @(posedge clk) begin
	if(byte_received) begin
		bytecnt <= bytecnt + 2'b01;
	end
end
*/

reg [31:0] data_sent;
//wire [31:0] w_dataout;
always @(posedge clk) begin
	if(SSEL_active) begin
		if(SSEL_startmessage) begin
			if(bitcnt==5'b11111) begin
				dataoutreg <= data_recvd;
				word_received <= 1'b1;
			end
		end
		else if(SCK_fallingedge) begin
			if((bitcnt==5'b00000) && word_received) begin
				data_sent <= datain;
				word_received <= 1'b0;
				//data_sent <= dataout;	// nur fuer feedback-test
			end
			else
				data_sent <= {data_sent[30:0], 1'b0};
		end
	end
end
assign MISO = data_sent[31];  // send MSB first
// we assume that there is only one slave on the SPI bus
// so we don't bother with a tri-state buffer for MISO
// otherwise we would need to tri-state MISO when SSEL is inactive
assign dataout = dataoutreg;
endmodule
