import SPI::*;

interface FRAMPins;
	method Bit#(1) sclk;
	method Bit#(1) mosi;
	method Action miso(Bit#(1) x); 
	method Bit#(1) ncs;
endinterface

interface FRAMIfc;
	//configuration
	//method Action setSPISclkDiv(Bit#(16) d);
	
	method Action readReq(Bit#(32)addr, Bit#(17) burstLen); //retrieve value from addr.
	
	method Action writeReq(Bit#(32) addr, Bit#(8) x, Bit#(17) burstLen); //put 8-bit value in addr.
	method Action writeBurst(Bit#(8) x);
	method ActionValue#(Bit#(8)) readFetch();
	
	interface FRAMPins pins;
	
endinterface

module mkFRAMMaster(FRAMIfc);
	let clock <- exposeCurrentClock();
	
	SPIMaster spi <- mkSPIMaster;
	
	Reg#(Bit#(3)) init <- mkReg(0); 
	Reg#(Bool) writeEn <- mkReg(False);
	Reg#(Bool) idle <- mkReg(True);
	Reg#(Bit#(48)) buffer <- mkReg(0);
	Reg#(Bit#(8)) bufferCounter <- mkReg(0);
	
	Reg#(Bit#(17)) burstCounter <- mkReg(0);
	
	Reg#(Bool) readWait <- mkReg(False);
	Reg#(Bool) readReady <- mkReg(False);
	Reg#(Bool) burstReady <- mkReg(False);
	Reg#(Bit#(8)) readResult <- mkReg(0);
	
	Reg#(Bit#(3)) accessState <- mkReg(0); //0 = misc. 1 = read, 2 = write
	
	rule doInit(init == 1); //initialization step.
		spi.setNcs(1);
		spi.setCpol(0);
		spi.setCpha(0);
		spi.setSclkDiv(2);
		init <= 2;
		idle <= False;
	endrule
	
	rule doInit2(init == 2);
		writeEn <= True;
		buffer[7:0] <= 8'b00000110; //OPCODE_WREN
		bufferCounter <= 1;
		idle <= False;
		spi.setNcs(0);
		init <= 3;
	endrule
	
	rule doInit3(init == 3 && idle == True);
		init <= 4;
		spi.setNcs(1);
	endrule
	
	rule load(init > 2 && !idle && bufferCounter != 0 && !burstReady);
		spi.put(buffer[7:0]);
		buffer <= buffer >> 8;
		if (bufferCounter > 1) begin 
			bufferCounter <= bufferCounter - 1;
		end else begin //no more buffer
			if (accessState == 2 && burstCounter > 0) begin
				burstCounter <= burstCounter - 1;
				burstReady <= True;
					//keep not-idle to receive next write value;
			end else if (accessState == 1) begin
				readWait <= True;
			end else begin
				burstCounter <= 0;
				bufferCounter <= 0;
				spi.setNcs(1); //turn off since no more values
				idle <= True;
			
			end
		end
	endrule
	
	rule fetch(init > 2 && accessState == 1 && !idle && readWait);
		let result <- spi.get();
		readResult <= result;
		readReady <= True;
		if (burstCounter > 0) begin 
			burstCounter <= burstCounter - 1;
		end else begin
			spi.setNcs(1);
			burstCounter <= 0;
			idle <= True;
			readWait <= False;
		end
	endrule
	
	method Action writeReq(Bit#(32) addr, Bit#(8) x, Bit#(17) burstLen) if (init == 4 && writeEn && idle);
		buffer <= {x, addr[7:0],addr[15:8], addr[23:16],addr[31:24], 8'b00000010}; //OPCODE_WRITE
		//buffer[7:0] <= 8'b00000010; //OPCODE_WRITE
		// buffer[15:8] <= ;
		// buffer[23:16] <= ;
		// buffer[31:24] <= ;
		// buffer[39:32] <= ;
		// buffer[47:40] <= x;
		bufferCounter <= 6;
		idle <= False;
		spi.setNcs(0);
		accessState <= 2;
		burstCounter <= burstLen;
	endmethod
	
	method Action writeBurst(Bit#(8) x) if (burstCounter > 0 && accessState == 2 && burstReady);
		buffer [7:0] <= x;
		bufferCounter <= 1;
		burstReady <= False;
	endmethod
	
	method Action readReq(Bit#(32) addr, Bit#(17) burstLen) if (init == 4 && idle);
		buffer <= {0, addr[7:0],addr[15:8], addr[23:16],addr[31:24],8'b00000010}; //OPCODE_WRITE
		// buffer[7:0] <= 8'b00000011; //OPCODE_READ
		// buffer[15:8] <= addr[31:24];
		// buffer[23:16] <= addr[23:16];
		// buffer[31:24] <= addr[15:8];
		// buffer[39:32] <= addr[7:0];
		bufferCounter <= 5;
		idle <= False;
		spi.setNcs(0);
		readReady <= False;
		accessState <= 1;
		burstCounter <= burstLen;
	endmethod
	
	method ActionValue#(Bit#(8)) readFetch() if (readReady || (burstReady && accessState == 1));
		readReady <= False;
		burstReady <= False;
		return readResult;
	endmethod
	
	interface FRAMPins pins;
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

