import FRAM::*;
//import LoRa::*;
import MicroSD::*;

import Conv2D::*;
import BatchPool::*;

import Dense::*;


interface MainIfc;
	method Action uartIn(Bit#(8) data);
	method ActionValue#(Bit#(8)) uartOut;
	method Bit#(3) rgbOut;
	
	method Bit#(3) spi0_out;
	method Bit#(3) spi1_out;
	method Action spi0_in(Bit#(1) miso0);
	method Action spi1_in(Bit#(1) miso1);
	
endinterface

module mkMain(MainIfc);
	FRAMIfc fram1 <- mkFRAMMaster;
	MicroSDIfc sd0 <- mkMicroSDMaster;
	Conv2DIfc conv2d <- mkConv2D;
	
	BatchPoolIfc batch <- mkBatchNorm;
	BatchPoolIfc pool <- mkMaxPool;

	DenseIfc dense <- mkDense;
	Clock curclk <- exposeCurrentClock;
	Reg#(Bool) framReadWrite <- mkReg(False);
	Reg#(Bit#(8)) layerStage <- mkReg(0);

	rule framRelay;//flag transfer
		batch.flagRelay(conv2d.conv2DFRAMFlag);
	endrule 
	
	rule framRelay2;//flag transfer
		let val = conv2d.conv2DFRAMFlag && batch.framFlag;
		pool.flagRelay(val);//conv2d.conv2DFRAMFlag(batch.framFlag && );
	endrule 

	rule relayConv2DBatch;
		let out <- conv2d.conv2Dout;
		batch.in(out);
	endrule
	
	rule sdConv2DRelay;//command transfer
		let req <- conv2d.sdReq();
		sd0.readReq(tpl_1(req), extend(tpl_2(req)));
	endrule
	
	rule densereadReqRelay(dense.requestReady);
		let req1 <- dense.sdReq();
		let req2 <- dense.framReq();
		sd0.readReq(tpl_1(req1), tpl_2(req1));
		fram1.readReq(tpl_1(req2), tpl_2(req2));
		framReadWrite <= False;
	endrule
	
	rule denseBurstFRAMRelay;
		let val <- fram1.readFetch();
		dense.framResp(val);
	endrule

	rule denseBurstSDRelay;
		let val <- sd0.readFetch();
		dense.sdResp(val);
	endrule
	
	rule framConv2DRelay(conv2d.conv2DFRAMFlag);//command transfer
		let req <- conv2d.framReq();
		fram1.readReq(tpl_1(req), tpl_2(req));
		framReadWrite <= False;
	endrule
	
	rule framConv2DBurstRelay;
		let val <- fram1.readFetch();
		conv2d.bramFill(val);
	endrule
	
	rule framBatchRelay(!conv2d.conv2DFRAMFlag);//command transfer
		let req <- batch.framReq();
		let readWrite = tpl_4(req);
		if (readWrite == 0) begin
			fram1.readReq(tpl_1(req), tpl_2(req));
			framReadWrite <= False;
		end else begin
			fram1.writeReq(tpl_1(req), tpl_3(req), tpl_2(req));
			framReadWrite <= True;
		end
	endrule
	
	rule framPoolRelay(!batch.framFlag && !conv2d.conv2DFRAMFlag);//command transfer
		let req <- pool.framReq();
		let readWrite = tpl_4(req);
		if (readWrite == 0) begin
			fram1.readReq(tpl_1(req), tpl_2(req));
			framReadWrite <= False;
		end else begin
			fram1.writeReq(tpl_1(req), tpl_3(req), tpl_2(req));
			framReadWrite <= True;
		end
	endrule
	
	rule framBatchBurstRelay(batch.framFlag && !conv2d.conv2DFRAMFlag);
		if (framReadWrite == True) begin
			let val <- fram1.readFetch();
			batch.framGet(val);
		end else begin
			let val <- batch.burstWrite();
			fram1.writeBurst(val);
		end
	endrule
	
	rule framPoolBurstRelay(pool.framFlag && !batch.framFlag && !conv2d.conv2DFRAMFlag);
		if (framReadWrite == True) begin
			let val <- fram1.readFetch();
			batch.framGet(val);
		end else begin
			let val <- batch.burstWrite();
			fram1.writeBurst(val);
		end
	endrule
	
	
	
	rule convBatchPoolSwap(batch.completeFlag && pool.completeFlag);
		conv2d.swap();
		batch.swap();
		pool.swap();
		dense.start();
	endrule
	
	

	
	
	method Bit#(3) spi0_out;//SD Card output pins
		return {sd0.pins.ncs, sd0.pins.mosi, sd0.pins.sclk};
	endmethod
	
	method Bit#(3) spi1_out; //fram output pins
		return {fram1.pins.ncs, fram1.pins.mosi, fram1.pins.sclk};
	endmethod
	
	method Action spi0_in(Bit#(1) miso0); //SD input pin
		sd0.pins.miso(miso0);
	endmethod
	
	method Action spi1_in(Bit#(1) miso1); //fram input pin
		fram1.pins.miso(miso1);
	endmethod

	method Action uartIn(Bit#(8) data);
		conv2d.spramFill(data);
	endmethod
	
	method ActionValue#(Bit#(8)) uartOut if (dense.outputReady);
		return 0;
	endmethod
	
	method Bit#(3) rgbOut;
		return 0;
	endmethod
	
endmodule
