import BRAMFIFO::*;
import QuantizedMath::*;
import FIFO::*;
import FIFOF::*;
import DSPArith::*;


interface DenseIfc;
	method Action start;
	method Bool requestReady;
	method ActionValue#(Tuple2#(Bit#(32), Bit#(26))) sdReq;
	method ActionValue#(Tuple2#(Bit#(32), Bit#(17))) framReq;
	method Bool outputReady;
	method ActionValue#(Bit#(8)) getOutput;
	method Action sdResp(Bit#(8) data);
	method Action framResp(Bit#(8) data);
endinterface

module mkDense(DenseIfc);
	QuantizedMathIfc qm <- mkQuantizedMath;
	Reg#(Bool) active <- mkReg(False);
	Reg#(Bool) reqReady <- mkReg(False);
	Reg#(Bit#(2)) layer <- mkReg(0);
	Reg#(Bit#(32)) read_addr <- mkReg(352);
	Reg#(Bit#(32)) read <- mkReg(0);
	Reg#(Bit#(26)) xCount <- mkReg(0);
	Reg#(Bit#(26)) yCount <- mkReg(0);
	Reg#(Bit#(26)) dim_x <- mkReg(4096);
	Reg#(Bit#(26)) dim_y <- mkReg(4096);
	FIFO#(Int#(8)) sdQ <- mkFIFO;
	FIFOF#(Int#(8)) outQ <-  mkSizedBRAMFIFOF(4096);
	FIFOF#(Int#(8)) framQ <-  mkSizedBRAMFIFOF(4096);

	Reg#(Int#(8)) mult <- mkReg(0);
	Reg#(Int#(8)) aggregate <- mkReg(0);
	Reg#(Bool) reluOn <- mkReg(True);
	Reg#(Bool) outputFlag <- mkReg(False);
	Reg#(Bool) swapReady <- mkReg(False);
	Reg#(Bool) transfer <- mkReg(False);

	rule swap(swapReady);
		if (layer == 0) begin //switch to layer 2
			layer<= 1;
			reluOn <= True;
			reqReady <= True;
		end else if (layer == 1) begin //switch to layer 3
			dim_x <= 4096;
			dim_y <= 1;
			layer<= 2;
			reluOn <= False;
		end
		else begin //switch back to layer 1
			dim_x <= 4096;
			dim_y <= 4096;
			active <= False;
			layer<= 0;
			reluOn <= False;
		end 
		xCount <= 0;
		yCount <= 0;
		swapReady <= False;
	endrule 
	
	rule transferFIFO(transfer);
		if (xCount == 0) framQ.clear();
		outQ.deq;
		framQ.enq(outQ.first);
		if (xCount < dim_x - 1 ) xCount <= xCount + 1;
		else begin
			xCount <= 0;
			swapReady <= True;
			transfer <= False;
		end
		
	endrule
	
	rule qMult(active && !transfer && !swapReady);
		framQ.deq;
		sdQ.deq;
		Int#(8) qmul <- qm.quantizedMult(framQ.first, sdQ.first);
		mult <= qmul;
	endrule
	
	rule qAdd(active && !transfer);
		Int#(8) qadd = qm.quantizedAdd(mult,aggregate);
		Int#(8) qval = (qadd > 0) ? qadd : 0;
		Int#(8) qresult = (reluOn) ? qval : qadd;
		if (xCount < dim_x - 1) begin
			aggregate <= qresult;
			xCount <= xCount + 1;
		end else begin //output
			outQ.enq(qresult); //put result in outQ
			aggregate <= 0;
			xCount <= 0;
			if (yCount < dim_y - 1) begin 
				
				yCount <= yCount + 1;	
			end else begin //last value
				if (layer < 2) begin
					swapReady <= True;
				end else begin
					outputFlag <= True;
					swapReady <= True;
					active <= False;
				end 
			end
		end 
	endrule
	
	method ActionValue#(Tuple2#(Bit#(32), Bit#(26))) sdReq if (reqReady);
		Bit#(32) addr = 352;
		Bit#(26) burst = 69632; //read them all
		reqReady <= False;
		return tuple2(addr,burst);
	endmethod
	method ActionValue#(Tuple2#(Bit#(32), Bit#(17))) framReq if (reqReady);
		Bit#(32) addr = 0;
		Bit#(17) offset = 4096;
		return tuple2(addr, offset);
	endmethod
	method Action sdResp(Bit#(8) data) if (active);
		sdQ.enq(unpack(data));
	endmethod
	method Action framResp(Bit#(8) data) if (active && layer == 0);
		framQ.enq(unpack(data));
	endmethod
	
	method Bool outputReady;
		return outputFlag;
	endmethod
	method Bool requestReady;
		return reqReady;
	endmethod
	
	method ActionValue#(Bit#(8)) getOutput;
		outQ.deq;
		outputFlag <= False;
		return pack(outQ.first);
	endmethod

	method Action start;
		active <= True;
		reqReady <= True;
	endmethod
endmodule