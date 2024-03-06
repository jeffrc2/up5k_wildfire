import SPI::*;

interface MicroSDPins;
	method Bit#(1) sclk;
	method Bit#(1) mosi;
	method Action miso(Bit#(1) x); 
	method Bit#(1) ncs;
endinterface

interface MicroSDIfc;
	
	method Action readReq(Bit#(32) addr, Bit#(26) burstLen); //request block read
	
	method ActionValue#(Bit#(8)) readFetch(); //retrieve value
	
	interface MicroSDPins pins;
endinterface

module mkMicroSDMaster(MicroSDIfc);
	let clock <- exposeCurrentClock();
	
	SPIMaster spi <- mkSPIMaster;
	
	Reg#(Bool) idle <- mkReg(True);
	
	Reg#(Bit#(8)) init <- mkReg(0); 
	Reg#(Bit#(48)) buffer <- mkReg(0);
	Reg#(Bit#(5)) bufferCounter <- mkReg(0); 
	Reg#(Bit#(9)) blockCounter <- mkReg(500); //internal counter for 512 bytes
	Reg#(Bit#(26)) burstCounter <- mkReg(0);//counter for # of blocks to read
	Reg#(Bool) burstFlag <- mkReg(False);
	Reg#(Bit#(8)) readResult <- mkReg(0);
	Reg#(Bool) readReady <- mkReg(False);
	Reg#(Bool) readWait <- mkReg(False);
	
	rule doInit(init == 0); //initialization step.
		spi.setNcs(1);
		spi.setCpol(0);
		spi.setCpha(0);
		spi.setSclkDiv(2);
		init <= 1;
		idle <= False;
	endrule
	
	rule doInit1(init == 1 && blockCounter > 0); //Give SD card time start up
		blockCounter <= blockCounter - 1;
	endrule
	
	rule doInit2(init == 1 && blockCounter == 0);
		init <= 2;
		spi.setNcs(0);
		buffer[38:0] <= {20'b00000000000000000000,4'b0110,7'b0000000,8'b00000100}; //CMD8 - init
		bufferCounter <= 5;
		idle <= False;
	endrule
	
	rule doInit3(init == 2 && bufferCounter == 0);
		init <= 3;
		spi.setNcs(0);
		buffer[7:0] <= 8'b00110111; //CMD 55 - announce app-specific (for CMD41)
		bufferCounter <= 5;
		idle <= False;
	endrule
	
	rule doInit5(init == 4 && bufferCounter == 0);
		init <= 5;
		spi.setNcs(0);
		buffer[7:0] <= 8'b00111010; //CMD58 - read OCR
		bufferCounter <= 5;
		idle <= False;
	endrule
	
	rule doInit6(init == 5 && bufferCounter == 0);
		buffer[7:0] <= 8'b00111010; //CMD59 - crc disable
		init <= 6;
		spi.setNcs(0);
		bufferCounter <= 5;
		idle <= False;
	endrule
	
	rule doInit4(init == 3 && bufferCounter == 0);
		init <= 4;
		spi.setNcs(0);
		buffer[7:0] <= 8'b101001; //CMD 41 - set SDHC
		bufferCounter <= 5;
		idle <= False;
	endrule
	
	rule load(init > 1 && !idle && bufferCounter != 0);
		spi.put(buffer[7:0]);
		buffer <= buffer >> 8;
		if (bufferCounter > 1) begin 
			bufferCounter <= bufferCounter - 1;
		end else begin //no more buffer
			//burstCounter <= 0;
			bufferCounter <= 0;
			readWait <= True;
			//if (!writeEn) begin //wait for value
			if (burstFlag) begin //stop transmission
				
			end else begin
				spi.setNcs(1); //turn off since no more values
				idle <= True;
			end

		end
	endrule
	
	rule fetch(init > 2 && !idle && readWait); //); 
		let result <- spi.get();
		readResult <= result;
		readReady <= True;
		if (burstCounter > 0 || blockCounter > 0) begin 
			if (blockCounter == 0) begin
				burstCounter <= burstCounter - 1;
				blockCounter <= 511;
			end else begin
				blockCounter <= blockCounter - 1;
			end
		end else begin //done
			if (burstFlag) begin //termination command
				buffer[7:0] <= 8'b00001100;//CMD12 - stop transmission
				bufferCounter <= 5;
			end else begin
				spi.setNcs(1);
				burstCounter <= 0;
				idle <= True;
				readWait <= False;
			end
		end
	endrule
	
	method Action readReq(Bit#(32) addr, Bit#(26) burstLen); //request block read
		buffer <= {0, addr[7:0],addr[15:8], addr[23:16],addr[31:24],8'b00000011}; //OPCODE_READ
		burstCounter <= burstLen;
		bufferCounter <= 5;
		idle <= False;
		spi.setNcs(0);
	endmethod
	
	method ActionValue#(Bit#(8)) readFetch() if (readReady); // || (burstReady));
		readReady <= False;
		return readResult;
	endmethod
	
	
	interface MicroSDPins pins;
        method Bit#(1) sclk;
            return spi.pins.sclk;
        endmethod
        method Bit#(1) mosi;
            return spi.pins.mosi;
        endmethod
        method Action miso(Bit#(1) x);
            spi.pins.miso(x);
        endmethod
        method Bit#(1) ncs;
            return spi.pins.ncs;
        endmethod
    endinterface	
	
	
endmodule


