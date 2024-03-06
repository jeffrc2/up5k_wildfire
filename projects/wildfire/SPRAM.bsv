import FIFO::*;
import RegFile::*;

interface Spram256KAImportIfc;
	method Action address(Bit#(14) address);
	method Action datain(Bit#(16) data);
	method Action maskwrin(Bit#(4) mask);
	method Action wren(Bit#(1) wren);
	method Action chipselect(Bit#(1) sel);
	method Bit#(16) dataout;

	method Action standby(Bit#(1) standby);
	method Action sleep(Bit#(1) sleep);
	method Action poweroff(Bit#(1) poweroff);
endinterface

import "BVI" SB_SPRAM256KA =
module mkSpram256KAImport#(Clock clk)(Spram256KAImportIfc);
	default_clock no_clock;
	default_reset no_reset;

	input_clock (CLOCK) = clk;

	method DATAOUT dataout;
	method address(ADDRESS) enable((*inhigh*) addr_EN) reset_by(no_reset) clocked_by(clk);
	method datain(DATAIN) enable((*inhigh*) datain_EN) reset_by(no_reset) clocked_by(clk);
	method maskwrin(MASKWREN) enable((*inhigh*) maskwrin_EN) reset_by(no_reset) clocked_by(clk);
	method wren(WREN) enable((*inhigh*) wren_EN) reset_by(no_reset) clocked_by(clk);
	method chipselect(CHIPSELECT) enable((*inhigh*) chipselect_EN) reset_by(no_reset) clocked_by(clk);
	
	method standby(STANDBY) enable((*inhigh*) standby_EN) reset_by(no_reset) clocked_by(clk);
	method sleep(SLEEP) enable((*inhigh*) sleep_EN) reset_by(no_reset) clocked_by(clk);
	method poweroff(POWEROFF) enable((*inhigh*) poweroff_EN) reset_by(no_reset) clocked_by(clk);
	schedule (
		dataout, address, datain, maskwrin, wren, chipselect, standby, sleep, poweroff
	) CF (
		dataout, address, datain, maskwrin, wren, chipselect, standby, sleep, poweroff
	);
endmodule

interface Spram256KAIfc;
	method Action req(Bit#(14) addr, Bit#(16) data, Bool write, Bit#(4) mask);
	method ActionValue#(Bit#(16)) resp;
endinterface

module mkSpram256KA(Spram256KAIfc);
	Clock curclk <- exposeCurrentClock;
	FIFO#(Bit#(16)) outQ <- mkSizedFIFO(4);
	Reg#(Bit#(3)) inCnt <- mkReg(0);
	Reg#(Bit#(3)) readCnt <- mkReg(0);
	Reg#(Bit#(3)) outCnt <- mkReg(0);

	Spram256KAImportIfc ram <- mkSpram256KAImport(curclk);
	rule assertDefault;
		ram.chipselect(1);
		ram.standby(0);
		ram.sleep(0);
		ram.poweroff(1); //active low
	endrule

	rule getRead (inCnt-readCnt > 0 );
		let d = ram.dataout;
		outQ.enq(d);
		readCnt <= readCnt + 1;
	endrule

	method Action req(Bit#(14) addr, Bit#(16) data, Bool write, Bit#(4) mask) if ( inCnt-outCnt < 2 );
		ram.address(addr>>1);
		ram.datain(data);
		ram.maskwrin(mask);
		ram.wren(pack(write));
		if ( !write ) begin
			inCnt <= inCnt + 1;
		end
	endmethod

	method ActionValue#(Bit#(16)) resp;
		outQ.deq;
		outCnt <= outCnt + 1;
		return outQ.first;
	endmethod
`endif
endmodule