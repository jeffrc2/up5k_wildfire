module top (output wire led_blue,
				output wire led_green,
				output wire led_red,
			   
				//lora
				output wire spi0_sclk,
				output wire spi0_mosi,
			   
				output wire spi0_cs,
				//fram
				output wire spi1_sclk,
				output wire spi1_mosi,
				output wire spi1_cs,
				
				input wire  spi1_miso,
				input wire spi0_miso,
				
				output serial_txd,
				input serial_rxd,

				output spi_cs
				//, input clk // 12? MHz clock
			   );
	
	assign spi_cs = 1; // it is necessary to turn off the SPI flash chip

	wire clk; // 48 mhz clock
	SB_HFOSC# (
		.CLKHF_DIV("0b01") // divide clock by
	) inthosc(.CLKHFPU(1'b1), .CLKHFEN(1'b1), .CLKHF(clk));
	wire rst; 
	reg [3:0] cntr;
	assign rst = (cntr == 15);
	initial
	begin
		cntr <= 0;
	end
	always @ (posedge clk)
	begin
		if ( cntr != 15 ) begin
			cntr <= cntr + 1;
		end
	end

	mkBsvTop hwtop(.CLK(clk), .RST_N(rst), .blue(led_blue), .green(led_green), .red(led_red),  //RGB
		.sd_sclk(spi0_sclk), .sd_mosi(spi0_mosi), .sd_miso(spi0_miso), .sd_cs(spi0_cs), //SD Card
		.fram_sclk(spi1_sclk), .fram_mosi(spi1_mosi), .fram_miso(spi1_miso), .fram_cs(spi1_cs), //FRAM
		.serial_txd(serial_txd), .serial_rxd(serial_rxd)); //Uart
endmodule