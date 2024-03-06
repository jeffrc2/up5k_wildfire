import Spram::*;
import Vector::*;
import BRAMFIFO::*;
import QuantizedMath::*;
import FIFO::*;
import FIFOF::*;
import DSPArith::*;

interface Conv2DIfc;
	
	//receive data from SD Card
	//receive data from 
	
	//Send req to SD Card
	//Bit#(32) addr, Bit#(8) x, Bit#(8) burstLen SDReq(
	
	//Send req FRAM
	//Bit#(32) addr, Bit#(8) burstLen) FRAMReq
	method Action spramFill(Bit#(8) data);
	method Action bramFill(Bit#(8) feature_data);
	method ActionValue#(Tuple2#(Bit#(32), Bit#(11))) sdReq;
	method ActionValue#(Tuple2#(Bit#(32), Bit#(17))) framReq;
		
	method Action swap();
	
	method ActionValue#(Int#(8)) conv2Dout;
	
	method Bool conv2DFRAMFlag;
	
	
endinterface

module mkConv2D(Conv2DIfc);
	Vector#(4,Spram256KAIfc) spram <- replicateM(mkSpram256KA);
	Reg#(Bit#(16)) spram_addr <- mkReg(0); // top 2 bits correspond to spram vector;
	Reg#(Bit#(16)) spram_data <- mkReg(0);
	Reg#(Bit#(16)) spram_counter; //counts fillage of SPRAM; Max 1024 kbits
	
	Reg#(Bit#(32)) sd_addr <- mkReg(0);
	Reg#(Bit#(32)) fram_addr <- mkReg(0);
	FIFO#(Bit#(8)) spramFIFO <- mkFIFO;
	Reg#(Bool) spram_pair <- mkReg(False);
	Reg#(Bit#(8)) spram_temp <- mkReg(0);
	Reg#(Bit#(3)) stride <- mkReg(3);
	Reg#(Bit#(4)) window <- mkReg(12);
	Reg#(Bit#(10)) inChannels <- mkReg(3);
	Reg#(Bit#(10)) outChannels <- mkReg(96);
	
	Reg#(Bit#(16)) feature_addr <- mkReg(0);//access SD card addr
	
	Reg#(Bit#(8)) input_dim <- mkReg(250);
	
	Reg#(Bit#(10)) blockCounter <- mkReg(0);
	Reg#(Bool) sdCardReading <- mkReg(False);
	
	Reg#(Bit#(1)) layer <- mkReg(0);
	
	Reg#(Bit#(12)) featurelen <- mkReg(432);
	Reg#(Bit#(11)) burstLen <- mkReg(0);
	
	Reg#(Bit#(11)) burstCounter <- mkReg(0);
	Reg#(Bit#(8)) remainder <- mkReg(80); //leftover SD Card reads to burn;
	Reg#(Bit#(8)) remCounter <- mkReg(0);
	Reg#(Bit#(12)) featureCounter <- mkReg(0);
	Reg#(Bit#(16)) currIn <- mkReg(0);
	
	Reg#(Bit#(10)) outChanCounter <- mkReg(0);
	
	Reg#(Bool) outReady  <- mkReg(True);
	Reg#(Bool) reqSpram <- mkReg(False);
	Reg#(Bool) bramReload <- mkReg(False);
	FIFOF#(Bit#(8)) featureMapQ <-  mkSizedBRAMFIFOF(2400);
	
	QuantizedMathIfc qm <- mkQuantizedMath;
	
	Reg#(Int#(8)) aggregate<- mkReg(0);
	Reg#(Int#(8)) mult <- mkReg(0);
	
	Reg#(Int#(8)) out <- mkReg(0);
	
	Reg#(Bit#(16)) origin_addr <- mkReg(0);
	Reg#(Bit#(16)) windowCol <- mkReg(0);
	Reg#(Bit#(8)) origin_col <- mkReg(0);
	
	Reg#(Bit#(8)) init <- mkReg(0); 
	rule doInit0(init == 1||init == 2 && spram_addr < 16'b1111111111111111); //load SPRAM
		if (!spram_pair) begin
			spram_pair <= True;
			spramFIFO.deq;
			spram_temp <= spramFIFO.first;
		end else begin
			let ramidx = spram_addr[15:14];
			spramFIFO.deq;
			spram[ramidx].req(spram_addr[13:0], {spram_temp,spramFIFO.first}, True, 4'b1111);
			spram_addr <= spram_addr + 1;
			spram_pair <= False;
		end
	endrule
	
	rule doInit1(init == 1||init == 2 && spram_addr == 16'b1111111111111111);
		init <= init + 1;
		spram_addr <= 0;
	endrule
	
	rule reload(init == 3 && spram_addr == 16'b1111111111111111);
		init <= 2;
		spram_addr <= 0;
	endrule
	
	rule request(init == 3 && reqSpram);
		let ramidx = spram_addr[15:14];
		spram[ramidx].req(spram_addr[13:0], 0, False, 4'b1111);
		reqSpram <= False;
	endrule 
	
	rule windowUpdate(reqSpram);
		if (origin_addr + extend(window) == spram_addr) begin
			if (windowCol < extend(window)) begin
				origin_addr <= origin_addr + extend(stride);
				spram_addr <= origin_addr + extend(stride);
				windowCol <= windowCol + 1;
			end else begin
				origin_addr <= spram_addr - extend(window)*extend(input_dim);
				spram_addr <= spram_addr - extend(window)*extend(input_dim);
				windowCol <= 0;
			end
		end else if (spram_addr + extend(window) >= 16'b1111111111111111) begin
			origin_addr <= 0;
			spram_addr <= 0;
		end else begin
			let in_dim = extend(input_dim);
			let o_col = extend(origin_col);
			if (spram_addr % in_dim == 0) begin
				origin_col <= origin_col + 1;
				origin_addr <= in_dim*(o_col + 1);
				spram_addr <= in_dim*(o_col + 1);
			end
		end
	endrule
	
	rule resp;
		let ramidx = spram_addr[15:14];
		let resp = spram[ramidx].resp;
		Bit#(16) curr <- resp;
		currIn <= curr;
	endrule
	
	rule qMult(init == 3);
		let val = currIn[15:8];
		featureMapQ.deq;
		let feature = featureMapQ.first;
		Int#(8) qmul <- qm.quantizedMult(unpack(val),unpack(feature));
		mult <= qmul;
		featureCounter <= featureCounter + 1;
		if (featurelen == featureCounter + 1) begin
			currIn <= currIn << 8;
		end

	endrule
	
	rule qAdd(init == 3);
		if (featureCounter < featurelen) begin
			Int#(8) qadd = qm.quantizedAdd(mult,aggregate);
			aggregate <= qadd;
		end else begin
			Int#(8) qadd = qm.quantizedAdd(mult,0);
			out <= qadd;
			outReady <= True;
			aggregate <= 0;
			featureCounter <= 0;
			if (outChanCounter < outChannels) begin
				outChanCounter <= outChanCounter + 1;
			end else begin
				reqSpram <= True;
				spram_addr <= spram_addr + 1;
			end
		end	
	endrule
	
	method Action bramFill(Bit#(8) feature_data) if (sdCardReading);
		//Need to dump block offset while reading (block - featuredim^2*input_channel)
		if (burstCounter < burstLen) begin
			featureMapQ.enq(feature_data);
		end else begin //dump
			if (remCounter == remainder) begin //finished dumping reads
				remCounter <= 0;
				sdCardReading <= False;
			end else begin //dump reads
				remCounter <= remCounter + 1;
			end
		end 
		if (blockCounter < 512) begin
			blockCounter <= blockCounter + 1;
		end else begin
			blockCounter <= 0;
			feature_addr <= feature_addr + 1;
			burstCounter <= burstCounter + 1;
		end
	endmethod
	
	method ActionValue#(Tuple2#(Bit#(32), Bit#(11))) sdReq if (!sdCardReading); 
		sdCardReading <= True;
		return tuple2(sd_addr, burstLen);
	endmethod
	
	method ActionValue#(Tuple2#(Bit#(32), Bit#(17))) framReq if (layer ==1);
		fram_addr <= fram_addr + 128000;
		init <= 2;
		return tuple2(fram_addr,128000);
	endmethod
	
	method Action spramFill(Bit#(8) input_data);
		if (init < 1) begin
			init <= 1;
		end
		spramFIFO.enq(input_data);
	endmethod
	
	method ActionValue#(Int#(8)) conv2Dout if (outReady);
		outReady <= False;
		return out;
	endmethod
	
	method Bool conv2DFRAMFlag;
		return layer==1 && init < 2;
	endmethod
	method Action swap(); //alternate between 2 layer parameters
		if (layer == 0) begin //layer 2
			stride <= 1;
			window <= 5;
			input_dim <= 250;
			inChannels <= 96;
			outChannels <= 256;
			remainder <= 160; 
			featurelen <= 2400; //window^2*in_channel
			burstLen <= 4;
			feature_addr <= 96;
		end else begin //layer 1
			stride <= 4;
			window <= 12;
			inChannels <= 3;
			input_dim <= 29;
			outChannels <= 96;
			remainder <= 80;
			featurelen <= 432;//window^2*in_channel
			burstLen <= 0;
			feature_addr <= 0;
			fram_addr <= 0;
		end
		layer <= ~layer;
	endmethod
	
endmodule

