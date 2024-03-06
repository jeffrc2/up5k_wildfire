

import Vector::*;
import QuantizedMath::*;
import FIFO::*;
import FIFOF::*;
import BRAMFIFO::*;

interface BatchPoolIfc;
	method Action flagRelay(Bool flag);
	method ActionValue#(Tuple4#(Bit#(32), Bit#(17), Bit#(8), Bit#(1))) framReq;
	method Action in(Int#(8) data);
	method Action framGet(Bit#(8) data);
	method ActionValue#(Bit#(8)) burstWrite;
	method Action swap();
	
	method Bool framFlag();
	method Bool completeFlag();
endinterface

module mkBatchNorm(BatchPoolIfc);
	Reg#(Bool) fram_access <- mkReg(False);
	Reg#(Bit#(10)) channels <- mkReg(96);
	Reg#(Bit#(10)) channelCount <- mkReg(0);
	Reg#(Bit#(12)) featurelen <- mkReg(60);
	Reg#(Bit#(12)) featureCount <- mkReg(0);
	Reg#(Bit#(32)) infram_addr <- mkReg(0);
	Reg#(Bit#(32)) outfram_addr <- mkReg(0);
	Reg#(Int#(8)) in_val <- mkReg(0);
	Reg#(Int#(8)) coeff <- mkReg(0);
	Reg#(Int#(8)) constant <- mkReg(0);
	Reg#(Int#(8)) mult <- mkReg(0);
	Reg#(Bool) batchComplete <- mkReg(False);
	Reg#(Bool) writeFull <- mkReg(False);
	Reg#(Bit#(2)) batchLoad <- mkReg(0);
	Reg#(Bool) nextFeature <- mkReg(False);
	Reg#(Bit#(17)) outQCount <- mkReg(0);
	FIFOF#(Bit#(8)) outQ <-  mkSizedBRAMFIFOF(512); //number changes with leftover BRAM availability
	
	Reg#(Bit#(1)) layer <- mkReg(0);
	Reg#(Bit#(17)) burstCount <- mkReg(0);
	Reg#(Bit#(17)) burstLen <- mkReg(0);
	
	Reg#(Bool) fullComplete <- mkReg(False);
	
	QuantizedMathIfc qm <- mkQuantizedMath;
	
	rule retrieveFRAMval(nextFeature == True && fram_access == True && featureCount < featurelen); //retrieve 2 values
		if (batchLoad == 1) begin
			coeff <= in_val;
		end else begin
			constant <= in_val;
			nextFeature <= False;
		end
		batchLoad <= batchLoad + 1;
	endrule
	
	rule qMult(nextFeature == False && !writeFull); //qmult
		Int#(8) qmul <- qm.quantizedMult(in_val, coeff);
		mult <= qmul;
	endrule
	
	rule writeInit(outQCount == 512 || batchComplete); //initiate write-availability
		writeFull <= True;
	endrule
	
	rule qAdd(nextFeature == False && !writeFull); //qadd
		Int#(8) qadd = qm.quantizedAdd(mult,constant);
		outQ.enq(pack(qadd));
		outQCount <= outQCount + 1;
		if (featureCount == featurelen) begin //next features to process
			featureCount <= 0;
			if (channelCount + 1 == channels) begin
				batchComplete <= True; //begin transfer of values
			end else begin
				nextFeature <= True;
				batchLoad <= 0;
				channelCount <= channels + 1;
			end
		end else begin //
			featureCount <= featureCount + 1;
		end
	endrule
	
	method Action framGet(Bit#(8) data) if (batchLoad < 2);
		in_val <= unpack(data);
	endmethod
	
	method Action in(Int#(8) data) if (batchLoad == 2);
		in_val <= data;
	endmethod

	method Action flagRelay(Bool flag);
		if (flag) begin
			fram_access <= False;
		end else begin
			fram_access <= True;
		end
	endmethod
	
	method ActionValue#(Tuple4#(Bit#(32), Bit#(17), Bit#(8), Bit#(1))) framReq if ((nextFeature || writeFull)&& fram_access);
		if (featureCount == featurelen) begin //read 
			infram_addr <= infram_addr + 2;
			//init <= 2;
			featureCount <= 0;
			Bit#(8) empty = 0;
			Bit#(17) pairlen = 2;
			Bit#(1) read = 0;
			return tuple4(infram_addr,pairlen,empty,read);
		end
		else begin //write
			outfram_addr <= outfram_addr + extend(outQCount);
			outQ.deq;
			outQCount <= outQCount - 1;
			burstLen <= outQCount;
			burstCount <= 0;
			Bit#(1) write = 1;
			return tuple4(outfram_addr,outQCount,outQ.first,write);
		end
	endmethod
	
	method ActionValue#(Bit#(8)) burstWrite if (burstCount < burstLen);
		burstCount <= burstCount + 1;
		outQCount <= outQCount - 1;
		if (outQCount == 0) begin
			if (batchComplete) fullComplete <= True;
			writeFull <= False;
		end
		outQ.deq;
		return outQ.first;
	endmethod
	
	method Action swap if(fullComplete); //alternate between batch normalization layers
		let fram_max_addr = 512000;
		if (layer == 0) begin
			channels <= 256;
			featurelen <= 625;
			infram_addr <= fram_max_addr - 192;//96
			layer <= 1;
		end else begin
			channels <= 96;
			featurelen <= 3600;
			infram_addr <= fram_max_addr - 704;//96,256
			layer <= 0;
		end
		outfram_addr <= 0;
		batchComplete <= False;
		fullComplete <= False;
	endmethod
	
	method Bool framFlag;
		return writeFull || nextFeature;
	endmethod

	method Bool completeFlag;
		return fullComplete;
	endmethod
endmodule

module mkMaxPool(BatchPoolIfc);
	QuantizedMathIfc qm <- mkQuantizedMath;
	Reg#(Bool) fram_access <- mkReg(False);
	Reg#(Bool) writeFull <- mkReg(False);
	Reg#(Bit#(2)) layer <- mkReg(0);//3 layers to swap between for pooling, with intermediate one not using relu
	Reg#(Bit#(17)) burstCount <- mkReg(0);
	Reg#(Bit#(17)) burstLen <- mkReg(0);
	Vector#(16,Reg#(Int#(8))) winVector <- replicateM(mkReg(0));
	Vector#(8,Reg#(Int#(8))) halfVectorA <- replicateM(mkReg(0));
	Vector#(9, Reg#(Int#(8))) halfVectorB <- replicateM(mkReg(0)); //last one reserved for halfVectorA result;
	Reg#(Bit#(32)) outfram_addr <- mkReg(0);
	Reg#(Bit#(32)) infram_addr <- mkReg(0);
	Reg#(Bit#(32)) indim <- mkReg(29);
	Reg#(Bit#(32)) infram_level <- mkReg(1);
	Reg#(Bool) fullComplete <- mkReg(False);
	
	Reg#(Bit#(5)) poolLoad <- mkReg(0);
	Reg#(Bit#(3)) halfLoadA <- mkReg(0);
	Reg#(Bit#(3)) halfLoadB <- mkReg(0);
	Reg#(Bit#(1)) half <- mkReg(0);
	Reg#(Bool) reqSet <- mkReg(False);
	Reg#(Bool) reluOn <- mkReg(True);
	Reg#(Bool) poolComplete <- mkReg(False);
	Reg#(Bit#(3)) windowCount <- mkReg(0);
	Reg#(Bit#(3)) window <- mkReg(4); //window is always 4
	Reg#(Bit#(2)) stride <- mkReg(2); //stride always 2
	Reg#(Bit#(2)) stage <- mkReg(0); 
	FIFOF#(Int#(8)) outQ_b <-  mkSizedBRAMFIFOF(256);
	FIFOF#(Int#(8)) outQ_a <-  mkSizedBRAMFIFOF(256); //number changes with leftover BRAM availability
	Reg#(Bit#(17)) outQCount <- mkReg(0);
	
	rule writeInit(outQCount == 512 || poolComplete); //initiate write-availability
		writeFull <= True;
	endrule
	
	
	
	
	rule process(poolLoad == 16);
		Int#(8) mainVal2 = fold(max, readVReg(winVector));
		Int#(8) halfVal = fold(max, readVReg(halfVectorA));
		Int#(8) mainVal1 = fold(max, readVReg(halfVectorB));
		poolLoad <= 0;
		if (reluOn) begin
			if (mainVal2 < 0) outQ_b.enq(0);
			else outQ_b.enq(mainVal2);
			if (mainVal1 < 0) outQ_a.enq(0);
			else outQ_a.enq(mainVal1);
		end else begin
			outQ_b.enq(mainVal2);
			outQ_a.enq(mainVal1);
		end
		outQCount <= outQCount + 2;
		reqSet <= False;
	endrule
	
	method ActionValue#(Bit#(8)) burstWrite if (burstCount < burstLen);
		burstCount <= burstCount + 1;
		outQCount <= outQCount - 1;
		if (outQCount == 0 && writeFull) begin
			if (poolComplete) begin
				fullComplete <= True;
			end
			writeFull <= False;
		end
		if (half==0) begin
			outQ_b.deq;
			half <= 1;
			return pack(outQ_b.first);
		end else begin
			outQ_a.deq;
			half <= 0;
			return pack(outQ_a.first);
		end 
	endmethod
	
	method ActionValue#(Tuple4#(Bit#(32), Bit#(17), Bit#(8), Bit#(1))) framReq if ((poolLoad == 0 && reqSet) || writeFull && fram_access);
		if (poolLoad == 0) begin //read
			Bit#(32) infram_addrinc = infram_addr + extend(windowCount)*indim;
			if (windowCount < window - 1) begin //rows 1-3
				windowCount <= windowCount + 1;
			end else if (windowCount == window - 1) begin //row 4 - increment addr by 4
				if (infram_addr + 4 < indim*infram_level) begin
					infram_addr <= infram_addr + 4;
				end else begin
					if (infram_level < indim*indim) begin
						infram_level <= infram_level + 2;
						infram_addr <= infram_level*indim;
					end else begin //over limit
						stage <= 3;
						poolComplete <= True;
					end
				end
				windowCount <= 0;
			end 
			Bit#(17) len = 4;
			Bit#(8) empty = 0;
			Bit#(1) read = 0;
			reqSet <= True;
			return tuple4(infram_addrinc,len,empty,read);
		end else //write
		begin
			outfram_addr <= outfram_addr + extend(outQCount);
			half <= 0;
			outQ_a.deq;
			outQCount <= outQCount - 1;
			Bit#(1) write = 1;
			return tuple4(outfram_addr,outQCount,pack(outQ_a.first),write);
		end

	endmethod
	
	method Action framGet(Bit#(8) data) if (poolLoad < 16);
		Int#(8) val = unpack(data);
		winVector[poolLoad] <= val;
		poolLoad <= poolLoad + 1;
		if (half == 0) begin //first two columns
			halfVectorA[halfLoadA] <= val;
			if (halfLoadA[0] == 1) begin 
				half <= 1;
			end 
			halfLoadA <= halfLoadA + 1;
		end 
		else begin //last two columns
			halfVectorB[halfLoadB] <= val;
			if (halfLoadB[0] == 1) begin 
				half <= 0;
			end 
			halfLoadB <= halfLoadB + 1;
		end
	endmethod
	
	method Action flagRelay(Bool flag);
		if (flag) begin
			fram_access <= False;
		end else begin
			fram_access <= True;
		end
	endmethod
	
	method Bool framFlag;
		return writeFull || reqSet;
	endmethod
	
	method Bool completeFlag;
		return fullComplete;
	endmethod
	
	method Action swap() if (fullComplete); //alternate between batch normalization layers
		let fram_max_addr = 512000;
		if (layer == 0) begin //layer 0
			indim <= 29;
			reluOn <= True;
		end else if (layer == 1) begin //layer 1
			indim <= 11;
			reluOn <= False;
		end else begin //layer 2
			indim <= 4;
			reluOn <= False;
		end
		outfram_addr <= 0;
		infram_addr <= 0;
		fullComplete <= False;
		poolComplete <= False;
	endmethod
	
endmodule

//BatchNormFRAMFlag //indicates access priority to MaxPool