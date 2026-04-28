// Evaluate line to list available devices
("Available output devices:"); ServerOptions.outDevices.collect({|msg| msg.postln}); "";

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//                                                     START MAIN CODE                                                        //
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
(
////////////////////////////////
//1. server config
////////////////////////////////

s = Server.local;
// Select output device
s.options.numInputBusChannels = 0;
s.options.outDevice_(
	"Windows WASAPI : Microphone Array (Realtek High Definition Audio)"
	// "MacBook Pro Speakers"
	// "ASIO : Focusrite USB ASIO"
	// "ASIO : ReaRoute ASIO (x64)";
	// "ASIO : MOTU M Series";
	// "ASIO : AudioBox ASIO Driver"
	// "ASIO : ASIO MADIface USB"
);
s.options.sampleRate_(48000);

// number of output channels (may allow for other processes to run on other audio channels)
~fMnumChannels = 2;

// Choose mono/stereo output
// ~mode = "mono";
~mode = "stereo";

// mono ro stereo audio output (default is mono)
~fMnumOut = (~mode == "stereo").if(2, 1);
s.options.numOutputBusChannels_(~fMnumChannels);

// Main Volume in dBFS (may be adjusted in volume GUI)
~masterVol = 0;

// T-Stick name
~fMtStick = "TStick_516";

// receiving port
~fMrecvPort = 8100;

// audio output bus
~out = 0;

s.newBusAllocators; // resets the bus allocation counter
ServerTree.removeAll;
ServerQuit.removeAll;

// clean up
Buffer.freeAll;
OSCdef.freeAll;
Window.closeAll;


////////////////////////////////
//2. initialize global variables
////////////////////////////////


// List of DMI control parameters [OSC address, size, mapped to a control bus or not]
~tStickParam = [
	["/raw/capsense"                 ,      30, "mapped"],
	["/raw/fsr"                      ,       1, "mapped"],
	["/raw/accl"                     ,       3, "mapped"],
	["/raw/gyro"                     ,       3, "mapped"],
	["/raw/magn"                     ,       3,         ],
	["/instrument/shakexyz"          ,       3, "mapped"],
	["/instrument/squeeze"           ,       1,         ],
	["/instrument/touch/all"         ,       1,         ],
	["/instrument/touch/top"         ,       1,         ],
	["/instrument/touch/middle"      ,       1,         ],
	["/instrument/touch/bottom"      ,       1,         ],
	["/instrument/touch/discrete"    ,      30,         ],
	["/instrument/jabxyz"            ,       3, "mapped"],
	["/instrument/brush"             ,       1,         ],
	["/instrument/multibrush"        ,       4,         ],
	["/instrument/rub"               ,       1,         ],
	["/instrument/multirub"          ,       4,         ],
	["/instrument/button/count"      ,       1,         ],
	["/instrument/button/tap"        ,       1,         ],
	["/instrument/button/ttap"       ,       1,         ],
	["/battery/percentage"           ,       1,         ],
	["/battery/current"              ,       1,         ],
	["/battery/timetoempty"          ,       1,         ],
	["/battery/voltage"              ,       1,         ],
	["/orientation"                  ,       4,         ],
	["/ypr"                          ,       3,         ]
];

// List of sound synthesis control parameters [, [intial values], mapped or not]
~fmParam = [
	["revMix"        ,                [ 0.33 ], "mapped"],
	["revRoom"       ,                 [ 0.5 ], "mapped"],
	["revDamp"       ,                 [ 0.2 ], "mapped"],
	["gainLow"       ,                   [ 1 ], "mapped"],
	["gainMid"       ,                   [ 1 ], "mapped"],
	["gainHigh"      ,                   [ 1 ], "mapped"]
];

// Global Variables
~fMbatteryOSC = "/battery/percentage";

// Emulate Gen4 T-Stick with only 16 capsense....
~fMcapsense = Array.fill(16, 0);

// default amp value for FM synth
~fmAmp = (-18).dbamp;

// Turn on/off calibration
~toggle = 0;

// Dictionnary containing calibration results
~calibrationVals = Dictionary.with(*[
	\fsr -> [0, 4095],
	\shakeThresh -> [0, 2],
	\shakeMax -> [0, 6]
]);

// Maximum detune coefficient
~fMdevMax = 3.0;

~fMsynthArray = Array.fill(128, nil);
~fMsynthIndex = 0; // incremental index of audio synth
~fMnumGrp = 3; // number of groups to store audio Synth
~fMsynthGrpSize = 32; // number of audio Synth per group
~fMprevGrp = 1; // because first Synth are sent to group 0, (0 - 2).wrap(0, 2) = 1

~fMcmArray = [1/9, 1/8, 1/7, 1/6, 1/5, 2/9, 2/8, 2/7, 2/6, 3/8, 2/5, 3/7]; // À REVISITER TAILLE BODY (11 ou 12...)

~fMoct = [1/2, 1, 2];

// ~fMroot = 110 * [1, 6/5, 4/3, 3/2, 3/4, 2/3]; //Hz
// ~fMroot = 110 * [1, 1/2, 2, 6/5, 3/5, 12/5, 4/3, 2/3, 8/3, 3/2, 3/4, 3]; //Hz
~fMroot = 110 * [1, 2, 6/5, 12/5, 4/3, 8/3, 3/2, 6/2, 5/3, 10/3]; //Hz // REVISITER SEULEMENT root[0] UTILISÉ?

// Triads
~fMchords = [[110, 110, 110], [110, 220, 330], [110, 165, 220], 110*[4/3, 5/3, 10/3], 110*[6/5, 3/2, 2], 110*[4/3, 2, 12/5], 110*[4/3, 6/2, 10/3]];
~fMchordsWeight = [1, 5, 8, 3, 5, 3, 5].normalizeSum;


// ~fMnotes = [1, 1, 1] * ~fMroot[0];
~fMnotes = Array.fill(11, ~fMroot[0]); // 11 capsense are used for triggering Synth REWORK SMARTER SIZE body dans \touch

~fMsynthTrig = Array.fill(~fMcmArray.size, 0); // PAS NÉCESSAIRE DE MAPPER SUR UN BUS DE CONTRÔLE
~fMfFreq = 15000;
~fMfcMin = 150;
~fMfcMax = 20000;


// Brush detection threshold
~fmBrushThr = 0.25;

// Dictionary of SynthDef arguments
~synthDef = ~fmParam.collect{
	arg item, i;
	var dic;
	if(item[2] == "mapped") {
		// create a Dictionary for each argument that is mapped
		dic = Dictionary();
		// argument name
		dic.add(\arg -> item[0]);
		// argument initial value(s)
		dic.add(\init -> item[1]);
	}
};
~synthDef = ~synthDef.reject({|item| item.isNil});

////////////////////////////////
//3. define piece-specific functions
////////////////////////////////

// function to express a sideband frequency as a string representing a fraction of carrier frequency C
~fMcFraction = {
	arg f;
	f.asFraction[0].asString ++ ":" ++ f.asFraction[1];
};


// function returning the Normal Form of a C:M ratio
~fMfmNFcm = {
	arg cm=1/1;
	var c=1, m=1;
	c = cm.asFraction[0];
	m = cm.asFraction[1];
	// C:M ratio is in its Normal Form if M >= 2*C or C:M = 1:1
	while { and( m < (2*c), c/m != 1 ) } { c = abs(c-m)};
	~fMcFraction.value(c/m)
};

// function returning the carrier frequency corresponding to requested fundamental and C:M ratio
~fMfmCarrier = {
	arg ffund=100, cm=1/1;
	var nfcm=1/1, fcarr=100;
	nfcm = ~fMfmNFcm.value(cm);
	nfcm = nfcm.split($:);
	nfcm = nfcm[0].asInteger / nfcm[1].asInteger;
	ffund * cm / nfcm;
};

// function returning an array of notes (Hz)
//
~fmNotesConstruct = {
	arg chord;
	var array;
	array = chord.stutter(4);
	array.removeAt(array.size - 1);
	array.sort.reverse;
};

// GUI for battery check
~fMwinBatt = Window("/" ++ ~fMtStick ++ "/battery", Rect(10, 710, 300, 32)).front;
~fMslider = MultiSliderView(~fMwinBatt, Rect(0, 0, 300, 32));
~fMslider.indexIsHorizontal_(false);
~fMslider.indexThumbSize_(30);
~fMslider.elasticMode_(1);
~fMslider.size_(1);
~fMslider.isFilled_(1);

// create buffer for LPF
~fMmakeBuffers = {
	~fsrBuf = Buffer.alloc(s, 1024);
	"--------------------------------".postln;"        Buffers created".postln;"--------------------------------".postln;
};


// Calibration Function
~calibrationFunc = {
	arg onOff=0, bus=0, dict=nil, key=nil;
	var arr=[], val, minVal=4095, maxVal=0;

	if(onOff == 1) {
		~calibRoutine = Routine{

			loop{
				// get current value of all the channels of a bus
				val = bus.getnSynchronous;
				val = val.mean;

				if( arr.size < 10,
					{
						arr = arr.add(val);
					},{
						arr = arr.add(val);
						arr = arr.shift(-1);
						arr = arr.keep(10);
					}
				);
				minVal = minVal.min(arr.mean);
				maxVal = maxVal.max(arr.mean);
				(key ++ " min value: " ++ minVal.round(0.001) ++ " - " ++ key ++ " max value: " ++ maxVal.round(0.001)).postln;

				dict[key] = [minVal, maxVal];
				0.01.wait;
			}
		};
		~calibRoutine.play;
	}{
		~calibRoutine.stop;
	};
};


// create control busses when server has booted
// dictionary of busses, keys are Synth arguments names
~fMmakeBusses = {
	var bus = 0;
	// Dictionary of busses, keys are DMI source names
	~busDmi = Dictionary.new;

	~tStickParam.do({
		arg item;
		if(item[2] == "mapped") {
			~busDmi.add((~fMtStick ++ item[0]) -> Bus.control(s, item[1].asInteger));
			bus = bus + item[1].asInteger;
		};
	});

	("      " ++ bus.asString ++" DMI control busses").postln;

	~fMbus = Dictionary.new;
	// REPLACE WITH FUNCTION

	~fMbusCapsense = Bus.control(s, 30); // USELESS REMOVE
	~fMbusCm = Bus.control(s, ~fMcmArray.size);
	~fMbusAtkRel = Bus.control(s, 4); // atk time, curve, rel time, curve
	~fMbusOctave = Bus.control(s, 1); // USELESS REMOVE???
	~fMbusTrig = Bus.control(s, 16); // USELESS REMOVE???
	~fMbusIndex = Bus.control(s, 1);
	~fMbusIndex.numChannels.do({|i| ~fMbusIndex.subBus(i).set(1);}); // USELESS REMOVE???
	~fMbusAccZ = Bus.control(s, 1);
	~fMbusOnset = Bus.control(s, 1); // USELESS REMOVE???
	~fMbusFsr = Bus.control(s, 1); // USELESS REMOVE???
	~fMbusLpf = Bus.control(s, 1); // USELESS REMOVE???
	~fMbusRoot = Bus.control(s, 1); // USELESS REMOVE???
	~fMbusRoot.set(~fMroot[0]); // USELESS REMOVE???
	~fMbusModIndex = Bus.control(s, ~fMcmArray.size); // the index of each synth is modulated differently for each c/m ratio it follows
	~fMbusShake = Bus.control(s, 1); // USELESS REMOVE???
	~fMbusRoll = Bus.control(s, 1); // USELESS REMOVE???
	~fMbusDev = Bus.control(s, 1); // USELESS REMOVE???
	~fMbrushBus = Bus.control(s, 1); // USELESS REMOVE???
	~fMgateBus = Bus.control(s, 1); // TBC IN DETAIL???
	~fMbusAmp = Bus.control(s, 1); // INCREASE SIZE ??? map each synth on his amp bus

	// Initialize c/m ratio busses
	~fMbusCm.numChannels.do({|i| ~fMbusCm.subBus(i).set(~fMcmArray[i])});

	// Audio busses for FX
	~fMbusFX = Bus.audio(s,~fMnumChannels);

	"Control and audio busses created".postln;"--------------------------------".postln;
};

// TBC Eli Fieldsteel
~fMcleanup = {
	s.newBusAllocators;
	ServerBoot.removeAll;
	ServerTree.removeAll;
	ServerQuit.removeAll;
};

// Create various fx and modulation Synth when server has booted
~fMmakeNodes = {
	s.bind({

		~fMmainGrp = Group.new;
		// groups inside of main one for audio synth management
		~fMsynthGrp = Array.fill(~fMnumGrp, {Group.new(~fMmainGrp)});
		~fMfxGrp = Group.after(~fMmainGrp); // FX synth group
		~fMlimGrp = Group.after(~fMfxGrp); // limiter group (could be removed when using SafetyNet quark)
		~fMmapGrp = Group.new; // group for modulation synth

		~fMmodulatorCM = ~fMbusCm.numChannels.collect{
			arg i;
			Synth(\modulatorCm, [\out, ~fMbusCm.subBus(i), \cm, ~fMcmArray[i]], ~fMmapGrp);
		};

		// Create synth modulating
		~fMmodulatorIndex = ~fMbusModIndex.numChannels.collect{
			arg i;
			Synth(\modulatorIndex, [\out, ~fMbusModIndex.subBus(i), \dev, 1], ~fMmapGrp);
		};

		//
		// low-pass Synth
		~fMlpfSynth = Synth(\lpf, [\in, ~fMbusFX, \fFreq, ~fMfFreq, \rq, 0.5, \out, 0], ~fMfxGrp);

		//
		// Schmidt trigger VÉRIFIER!!!!
		~schmidt = Synth(\schmidtEnv, [\in, ~fMgateBus, \out, ~fMbusAmp, \lowT, 0.01, \highT, ~fmBrushThr, \atk, 0.1, \relTune, 1, \release, 1], ~fMlpfSynth, \addBefore);

		// stereo chorus Synth
		~fMchorusSynth = Synth(\stereoChorus, [\in, ~fMbusFX, \mix, 0], ~fMlpfSynth, \addAfter);

		// reverb Synth (tail of the fx group)
		~fMrevSynth = Synth.tail(~fMfxGrp, \reverb, [\in, ~fMbusFX,
			\mix, 0.33,
			\room, 0.5,
			\damp, 0.2,
			// 	\out, ~fMbus[\lim],
		], ~fMfxGrp);


		// limiter Synth   !!!careful correct value if needed!!!
		~fMlimitSynth = Synth(\comp, [\in, ~fMbusFX, \thresh, -2.dbamp, \out, ~out], ~fMlimGrp);
	});


	"         Nodes created".postln;"--------------------------------".postln;
};

// mapping of control busses on synth control parameters (placeholder not used in this case)
~fMmakeMaps = {
	// Wait to make sure Synth are created
	"       Creating mappings".postln;
	32.do{0.1.wait; "-".post;};
	"".postln;
	s.bind({

		// mappings of ...

		// mappings of \triBand

		// mappings of \reverb
	});
};

////////////////////////////////
// OSC message reception
////////////////////////////////

~fMmakeOSCdef = {

	// Battery Check
	OSCdef(\batteryCheck, {
		arg msg;
		// (~fMtStick ++ " Battery: " ++ (msg[1]/100).round(0.01)).postln;
		defer{~fMslider.value_([msg[1]/100])};
	}, ~fMtStick ++ ~fMbatteryOSC, recvPort: ~fMrecvPort);

	////////////////////////////////
	// Note triggering by touching Middle and Bottom of surface

	OSCdef(\touch, {
		arg msg;
		var caps, trig, body, oct, capsRedux = Array.fill(15, nil);
		var targetGrpIndex, id;

		// capsense #16 is absent of TStick_311, and is located under the bottom endcap on TStick_191
		// only capsense  #1 to #15 are used
		// capsRedux est l'Array de 15 touches....

		caps = msg[1..30].normalize.roundUp;  /// OK avec CAPS!!!!!!!!!!
		caps.pairsDo{
			arg a, b, i;
			capsRedux[(i/2).trunc(1)] = (a+b);
		};
		caps = capsRedux.normalize.roundUp;

		// to account for disparities between firmware versions (values [0,1] or [0, ~400])
		// values in the array are normalized and rounded up -> value is 1 when a strip is touched

		// trigs when 0 to 1 -> caps - ~fMcapsense = 1
		~fMbusCapsense.setn(caps); //USELESS REMOVE!
		// Map to busses controlling synth gates

		// Determine if a Synth is already playing
		// trig = caps[4..13] - ~fMsynthTrig;
		// body = caps[2..11];
		body = caps[4..14];
		trig = body - ~fMsynthTrig;

		// Octave Choice
		// oct = [1, 0, 2][caps[0] + caps[14]];

		if ( (caps[0] == 0) && (caps[1] == 0) && (caps[2] == 0) && (caps[3] == 0) ) {
			oct = ~fMoct[0]
		} {
			if ( ((caps[0] == 1) || (caps[1] == 1)) && ((caps[2] == 0) && (caps[3] == 0)) ) {
				oct = ~fMoct[1]
			} {
				if ( ((caps[2] == 1) || (caps[3] == 1)) && ((caps[0] == 0) && (caps[1] == 0)) ) {
					oct = ~fMoct[2]
				} {
					oct = ~fMoct[3.rand];
				}
			}
		};
		// oct.postln;
		// oct = case
		// { caps[0] == 1 } {~fMoct[2]}
		// { caps[1] == 1 } {~fMoct[2]}
		// { caps[14] == 1 } {~fMoct[0]}
		// { (caps[0] == 0) && (caps[14] == 0) } {~fMoct[1]};
		// oct.postln;
		// trig.postln;
		trig.do{
			arg item, i;
			var root;
			if((item > 0), {
				// wrap synth ID allowed range
				id = ~fMsynthIndex % (~fMnumGrp * ~fMsynthGrpSize);

				// calculate target group index in the array
				targetGrpIndex = (id / ~fMsynthGrpSize).floor;

				// detect group change (start new block of synth)
				if(targetGrpIndex !=  ~fMprevGrp) {
					// if synth is played in the next group, free all synth in group n-2
					~fMsynthGrp[(targetGrpIndex - 2) % ~fMnumGrp].freeAll;
				};

				// root = ~fMbusRoot.getSynchronous();
				// root = ~fMnotes[rand(~fMnotes.size)];
				root = ~fMnotes[i]; // essayer de fixer
				("note: " + (root * oct).round(0.1) + " Hz").postln;
				// ~fMcmArray[i].asFraction.postln;
				~fMsynthArray[i] = Synth(\fmChowningLag_N, [
					// \c, ~fMfmCarrier.value(~fMroot[0] * ~fMoct[oct] * 0.25.rrand(-0.25).midiratio, ~fMcmArray[i]), // +/- 1/8 tone deviation
					\c, ~fMfmCarrier.value(root * oct * (0.25.rrand(-0.25)).midiratio, ~fMcmArray[i]), // +/- 1/8 tone deviation
					// \cm, ~fMcmArray[i],
					\cm, ~fMcmArray[i],
					\index, ~fMbusIndex.getSynchronous(), // samples the index value when Synth is triggered
					\inIndex, ~fMbusModIndex.subBus(~fMbusModIndex.numChannels.rand),
					// \amp, 0.2 * ~fMbusRoll.getSynchronous(),
					// \amp, ~fMbusAmp.getSynchronous(), // mapping sur le brush...
					\amp, ~fmAmp,
					\atk, ~fMbusAtkRel.subBus(0).getSynchronous() * (0.9.rrand(1.1)),
					\atkCrv, ~fMbusAtkRel.subBus(1).getSynchronous() * (0.9.rrand(1.1)),
					// \rel, ~fMbusAtkRel.subBus(2).getSynchronous() * (0.8.rrand(1.2)), // release value is picked when Synth is freed
					// \relCrv, ~fMbusAtkRel.subBus(3).getSynchronous() * (0.9.rrand(1.1)),
					\out, ~fMbusFX,
				],
				// Synth in Main Group / SubGroups
				~fMsynthGrp[targetGrpIndex]);
				// ~fMsynthArray[i].map(\index, ~fMbusIndex);
				~fMsynthArray[i].map(\cm, ~fMbusCm.subBus(i));
				~fMsynthArray[i].map(\amp, ~fMbusAmp);
				// ~fMbusAtkRel.get();
				// increment synth ID and group
				~fMsynthIndex = ~fMsynthIndex + 1;
				~fMprevGrp = targetGrpIndex;
			});
			if((item < 0), {
				// ~fMcmArray[i].asFraction.postln;
				~fMsynthArray[i].set(\rel, ~fMbusAtkRel.subBus(2).getSynchronous() * (0.8.rrand(1.2)));
				~fMsynthArray[i].set(\relCrv, ~fMbusAtkRel.subBus(3).getSynchronous() * (0.9.rrand(1.1)));
				~fMsynthArray[i].set(\gate, 0);
			});
		};
		// b.changed.postln;
		~fMcapsense = caps;
		~fMsynthTrig = body;
	}, ~fMtStick ++ "/raw/capsense", recvPort: ~fMrecvPort);

	////////////////////////////////
	// maps X acceleration to elevation and FM index control
	// REPLACE BY
	// 1 Synth: CALCULATE AND WRITE Index ON CONTROL BUSSES (x1)
	// 1 Synth: CALCULATE AND WRITE atk, rel values and curves ON CONTROL BUSSES (x4)
	OSCdef(\accl, {
		arg msg;
		var accX = msg[1] * (-1); // 5 gen to investigate
		var index, atk, atkCrv, rel, relCrv;
		var sMin = -10, sMax = 10, iMin = 0, iMax = 8, iCurve = 3.5;
		var atkMin = 0.5, atkMax = 0.001, atkCurve = -3;
		var atkCrvMin = -5, atkCrvMax = 5, atkCrvCurve = 0;
		var relMin = 5, relMax = 0.1, relCurve = 0;
		var relCrvMin = 1, relCrvMax = -5, relCrvCurve = 0;
		// accX.postln;
		index = accX.lincurve(sMin, sMax, iMin, iMax, iCurve, nil);

		// ASR envelope
		atk = accX.lincurve(sMin, sMax, atkMin, atkMax, atkCurve, nil);
		atkCrv = accX.lincurve(sMin, sMax, atkCrvMin, atkCrvMax, atkCrvCurve, nil);
		rel = accX.lincurve(sMin, sMax, relMin, relMax, relCurve, -5);
		relCrv = accX.lincurve(sMin, sMax, relCrvMin, relCrvMax, relCrvCurve, nil);
		// index.postln;
		~fMbusIndex.set(index);
		~fMbusAtkRel.setn([atk, atkCrv, rel, relCrv]);
	}, ~fMtStick ++ "/raw/accl", recvPort: ~fMrecvPort);

	~fMtenVals = Array.fill(10, 0.0);

	////////////////////////////////
	// maps FSR pressure RLPF
	OSCdef(\fsr, {
		arg msg;
		var fsr = msg[1];
		var mean, norm, dev, fFilt, release, fTemp, fsrThr = ~calibrationVals[\fsr][1]*0.9;
		// fsr.postln;
		~fMtenVals = ~fMtenVals.shift(1).putFirst(fsr);
		// ~fMtenVals.postln;
		mean = (~fMtenVals.sum / ~fMtenVals.size);
		// REMOVED fMaxFsr -> golbal variable (no overlap with dynamic envelope))
		~calibrationVals[\fsr][0] = ~calibrationVals[\fsr][0].min(mean);

		norm = fsr.linlin(~calibrationVals[\fsr][0], ~calibrationVals[\fsr][1], 0, 1); // normalized fsr value
		~fMbusFsr.set(norm); // NOT USED ????

		// deviation factor
		// if (norm > 0.5, {dev = norm.linlin(0.5, 1.0, 1.0, 1.1)}, {dev = 1});
		// ~fMbusCm.numChannels.do{
		// 	arg  i;
		// 	// ~fMbusCm.subBus(i).set(~fMcmArray[i] * dev);
		// 	~fMmodulator[i].set(\dev, dev);
		// };
		// filter
		// if (norm > 0.2, {fFilt = norm.linexp(0.2, 1.0, 18000, 500)}, {fFilt = 500});
		// if (norm > 0.2, {fFilt = norm.lincurve(0.2, 1.0, ~fMfcMax, ~fMfcMin, -3)}, {fFilt = ~fMfcMax}); // until version 14
		if (norm > 0.2, {
			~fsrBuf.get(norm*1023, {|val| ~fTemp = val; /*~fTemp.round(1).postln;*/ })
		}, {
			fFilt = ~fMfcMax
		});
		fFilt = ~fTemp;
		// ~fsrBuf.get(norm*1023, {|val| val.postln; ~fTemp = val;});
		// ("fTEmp " ++ ~fTemp).postln;
		// norm.postln;
		// Addition of activation on the gate on ~fmGateBus
		release = ~fMtenVals.maxItem.linlin(fsrThr, ~calibrationVals[\fsr][1], 2, 5);
		if(fsr > fsrThr,
			{
				~fMgateBus.set(0.4);
				("BOOST " ++ fsr).postln;
				~schmidt.set(\release, release);
				~schmidt.set(\level, fsr.linlin(~calibrationVals[\fsr][1]*0.9, ~calibrationVals[\fsr][1], 0.2, 0.9));
			},{
				~fMgateBus.set(0.0)
		});

		// ("fc " ++ fFilt).postln;
		~fMlpfSynth.set(\fFreq, fFilt);
	}, ~fMtStick ++ "/raw/fsr", recvPort: ~fMrecvPort);

	////////////////////////////////
	// maps gyro to reverb
	~fMmvtVals = Array.fill(100, 0.0);


	OSCdef(\gyro, {
		arg msg;
		var mvt = msg[1..3].abs.mean;
		var mix, room, damp;
		var chorus, mvtMean;

		~fMmvtVals = ~fMmvtVals.shift(1).putFirst(mvt); // last 100 values

		// ~fMmvtVals.mean.postln;
		mix = ~fMmvtVals.mean.lincurve(0, 2, 0.2, 0.8, -3.5);
		damp = ~fMmvtVals.mean;
		room = ~fMmvtVals.mean.lincurve(0, 2, 0.2, 0.8, -2);
		// (mix.round(0.1) + "|" + room.round(0.1) ++ "|" + damp.round(0.1)).postln;
		~fMrevSynth.set(\mix, mix);
		~fMrevSynth.set(\romm, room);
		~fMrevSynth.set(\damp, damp);
		// (2*mvt+1).lag(10).postln;
		~fMmodulatorIndex.do{
			arg mod, i;
			mod.set(\dev, (2*~fMmvtVals.mean+1));
		};
		chorus = ~fMmvtVals.mean.lincurve(0, 2, -1, 1, -4);
		// chorus.postln;
		~fMchorusSynth.set(\mix, chorus);

	}, ~fMtStick ++ "/raw/gyro", recvPort: ~fMrecvPort);


	////////////////////////////////
	// maps shake to detune
	~fMnumShakes = Array.fill(10, 0.0);
	OSCdef(\shake, {
		arg msg;
		var shake = msg[1..3], dev=1, shakeSmooth=0;
		// shake.postln;
		shake = shake[0..2].mean;
		// ("sh" + shake.round(0.01)).postln;

		~fMnumShakes = ~fMnumShakes.shift(1).putFirst(shake);
		shakeSmooth = ~fMnumShakes.mean;
		// ("smooth" + shakeSmooth.round(0.01)).postln;
		// deviation factor
		if (shake > ~calibrationVals[\shakeThresh][1], {
			dev = shake.lincurve(~calibrationVals[\shakeThresh][1], ~calibrationVals[\shakeMax][1], 1.0, ~fMdevMax, -1)
		}, {
			dev = 1}
		); // ajouter porteuse...
		// ("dev " ++ dev.round(0.01)).postln;
		~fMbusCm.numChannels.do{
			arg  i;
			// ~fMbusCm.subBus(i).set(~fMcmArray[i] * dev);
			~fMmodulatorCM[i].set(\dev, dev);
		};
		~fMbusShake.set(shake); // USELESS REMOVE???
		~fMbusDev.set(dev); // USELESS REMOVE???
	}, ~fMtStick ++ "/instrument/shakexyz", recvPort: ~fMrecvPort);

	////////////////////////////////
	// maps jabX to change the note
	~fMnumJabs = Array.fill(3, 0.0);

	OSCdef(\jab, {
		arg msg;
		var jabNote = msg[1], note=1;
		("jab" + jabNote).postln;

		~fMnumJabs = ~fMnumJabs.shift(1).putFirst(jabNote);
		~fMnumJabs.postln;

		~fMnotes = ~fmNotesConstruct.value(~fMchords.wchoose(~fMchordsWeight));
	}, ~fMtStick ++ "/instrument/jabxyz", recvPort: ~fMrecvPort);

	////////////////////////////////
	// test triple tap
	~fMnumTap = 0;

	OSCdef(\ttap, {
		arg msg;
		var tap = msg[1], note=0;
		("ttap" + tap).postln;
		~fMnumTap = ~fMnumTap + tap;
		note = ~fMnumTap%2;
		note.postln;

		~fMnotes = Array.fill(~fMnotes.size, ~fMroot[0])
	}, ~fMtStick ++ "/instrument/button/ttap", recvPort: ~fMrecvPort);


	// Assign OSC data to control busses
	~busDmi.keys.do({
		arg item, i;
		// ~busDmi[item].postln;
		OSCdef(item, {
			arg msg;
			// Remove the addres from the OSC message
			msg.removeAt(0);
			//
			msg = msg.reshape(~busDmi[item].numChannels);
			~busDmi[item].setn(msg);
		}, item, recvPort: ~recvPort);
	});



	OSCdef(\calibration, {
		arg msg;
		var tog;

		~toggle = (~toggle + 1)%8;

		case
		{ ~toggle == 1 } {
			// ~mappingGrp.free; // frees mapping nodes -> cuts off sound (not applicable here)
			// Mute sound
			defer{v.volume = -90};
			~calibrationFunc.(1, ~busDmi[~fMtStick ++ "/raw/fsr"], ~calibrationVals, \fsr);
			"FSR Calibration Started".postln;

		}
		{ ~toggle == 3 } {
			~calibrationFunc.(0);
			~calibrationFunc.(1, ~busDmi[~fMtStick ++ "/instrument/shakexyz"], ~calibrationVals, \shakeThresh);
			"FSR Calibration Completed".postln;
			"Shake Threshold Calibration Started".postln;

		}
		{ ~toggle == 5 } {
			~calibrationFunc.(0);
			~calibrationFunc.(1, ~busDmi[~fMtStick ++ "/instrument/shakexyz"], ~calibrationVals, \shakeMax);
			"Shake Threshold Calibration Completed".postln;
			"Maximum Shake Calibration Started".postln;

		}
		{ ~toggle == 7 } {
			~calibrationFunc.(0);
			"Maximum Shake Calibration Completed".postln;
			// ~makeBusMappings.();
			// Restore sound
			defer{v.volume = ~masterVol};
		}
	}, ~fMtStick ++ "/instrument/button/tap", recvPort: ~recvPort);

	"        OSCdef created".postln;"--------------------------------".postln;
	// Last step of process: OSCdef creation
	"           DMI READY".postln;"--------------------------------".postln;
};

////////////////////////////////
//4. register functions with ServerBoot/Quit/Tree
////////////////////////////////
ServerBoot.add(~fMmakeBuffers);
ServerBoot.add(~fMmakeBusses);
// ServerBoot.add(~fMmakeOSCdef); // moved to \remaining functions
ServerQuit.add(~fMcleanup);


////////////////////////////////
//5. boot server
////////////////////////////////

"".postln;"--------------------------------".postln;"        BOOTING SERVER".postln;"--------------------------------".postln;

// wait for boot function
s.waitForBoot({

	s.sync;
	"--------------------------------".postln;"         SERVER BOOTED".postln;"--------------------------------".postln;

	////////////////
	//6a. SynthDefs
	////////////////

	// Synth starts when caps = 1, caps = 0 -> gate=0
	SynthDef(\fmChowningLag_N, {
		arg out=0, c=220, cm=1, index=0, amp=0.4, atk=0.01, rel=1, atkCrv=0, relCrv=0, gate=1, lag=0.1, inIndex=0;
		var freq, sig, env, envI, carr, modI, pan;
		c = Lag.kr(c, lag);
		envI = EnvGen.kr(Env.perc(atk, rel, 4), gate)*0; // CHECK ENVINDEX
		modI = In.kr(inIndex, 1);
		// index = Lag.kr(index, lag);
		index = Lag.kr(index, lag) * modI; // added modulation of index
		freq = (index + envI) * c / cm * SinOsc.ar(c / cm) + c;
		env = EnvGen.kr(Env.asr(atk, 1, rel, [atkCrv, relCrv]), gate, doneAction: 2) * amp;
		sig = SinOsc.ar(freq) * env;

		sig = LeakDC.ar(sig);
		// panning
		// PanAz in mono -> pan = 0
		// PanAz in stereo -> -0.4 < pan < 0.4 (speakers are located at +/- 0.5)
		pan = LFNoise2.ar(LFNoise1.kr(1).range(0.1, 1.0)).range(-0.4, 0.4) * (~fMnumOut - 1);
		// Out.ar(out, Pan2.ar(sig, pan)); // Replace with PanAz
		Out.ar(out, PanAz.ar(~fMnumOut, sig, pan)); // Replace with PanAz
	}).add;

	// Control SynthDef
	SynthDef(\modulatorCm, {
		arg in = 0, out = 0, dev = 1, cm = 1;
		var sig;
		sig = LFNoise2.kr(LFNoise1.kr(5).range(0.5, 2)).range(dev.reciprocal, dev) * cm;
		Out.kr(out, sig);
	}).add;

	// Control SynthDef
	SynthDef(\modulatorIndex, {
		arg in = 0, out = 0, dev = 1;
		var sig;
		sig = LFNoise2.kr(LFNoise1.kr(5).range(0.05, 0.5)).range(dev, dev.reciprocal);
		Out.kr(out, sig);
	}).add;

	// Effects
	// low-pass filter
	SynthDef(\lpf, {
		arg in=0, out=0, fFreq=5000, rq=1.0;
		var sig;
		fFreq = fFreq.lag(0.1);
		// fFreq.poll;
		sig = In.ar(in, ~fMnumOut);
		// sig = LPF.ar(sig, fFreq);
		sig = RLPF.ar(sig, fFreq, rq);
		ReplaceOut.ar(in, sig);
		// Out.ar(out, sig);
	}).add;

	// 3 band filter
	SynthDef(\triBand, {
		arg in=0, out=0, freq1=500, freq2=8000, gainLow=1.0, gainMid=1.0, gainHigh=1.0;
		var sig, sigLow, sigMid, sigHigh;
		sig = In.ar(in, ~fMnumOut);
		sig = BLowShelf.ar(sig, freq1, 1, gainLow-gainMid);
		sig = BHiShelf.ar(sig, freq2, 1, gainHigh-gainMid);
		sig = gainMid.dbamp * sig;
		ReplaceOut.ar(in, sig);
		// Out.ar(out, sig);
	}).add;

	// reverb
	SynthDef(\reverb, {
		arg in=0, out=0, mix=0, room=0.5, damp=0.5;
		var sig;
		mix = mix.lag(0.1);
		room = room.lag(0.1);
		damp = damp.lag(0.1);
		sig = In.ar(in, ~fMnumOut);
		sig = FreeVerb.ar(   // formerly FreeVerb2.... -> multichannel
			sig,
			// sig[1],
			mix,
			room,
			damp,
		);
		ReplaceOut.ar(in, sig);
		// Out.ar(out, sig);
	}).add;

	// Stereo Chorus
	// https://scsynth.org/t/chorus-effect-design/5512
	// 3 tap chorus
	SynthDef(\stereoChorus, {
		arg in=0, out=0, mix=0;
		var dry, wet, sig, nTap;
		nTap = 3;
		// define if audio coming in is mono or stereo
		dry = In.ar(in, ~fMnumOut);
		// wet calculation
		wet = ~fMnumOut.collect{ |i|
			DelayC.ar(
				dry,
				0.03,
				SinOsc.ar(0.1, ((0..nTap - 1) + (i * 0.5)) / nTap * 2pi)
				.linlin(-1, 1, [10e-3, 5e-3][~fMnumOut - 1], 20e-3)
			).sum / sqrt(nTap);
		};
		// 2 channel equal power crossfade (mix/pan in [-1,+1])
		sig = XFade2.ar(dry, wet, mix);
		ReplaceOut.ar(in, sig);
	}).add;

	// security compressor
	SynthDef(\comp, {
		arg in=0, out=0, thresh=0.5;
		in = In.ar(in, ~fMnumOut);
		in = Compander.ar(in , in, thresh, 1.0, 0.1, 0.005) * 0.9;
		Out.ar(out, in);
	}).add;

	// envelope generator using a Schmidt trigger
	SynthDef(\schmidtEnv, {
		arg in=0, out=0, lowT=0.15, highT=0.3, level=1.0, levTune=1.0, atk=0.01, release=1.0, relTune=1.0;
		var input, env, gate;
		input = In.kr(in, 1).abs;
		gate = Schmidt.kr(input, lowT, highT);
		env = EnvGen.kr(Env.asr(atk, levTune, relTune * release, 0), gate) * level + ~fmAmp;
		Out.kr(out, env);
	}).add;

	s.sync;

	////////////////
	//6b. Register remaining functions
	////////////////

	ServerMeter(s, 2, ~fMnumChannels);
	FreqScope.new; // doesn't work if ServerBoot.removeAll is called

	s.plotTree;

	// Create audio Synth then wait for command to be completed
	ServerTree.add(~fMmakeNodes);
	s.sync;

	// FSR envelope
	~fsrBuf.sendCollection(
		Env.new(
			[~fMfcMax, ~fMfcMin, ~fMfcMax],
			[~calibrationVals[\fsr][1]*0.9 - ~calibrationVals[\fsr][0], ~calibrationVals[\fsr][1] - (~calibrationVals[\fsr][1]*0.9)],
			[0, -4]
		).discretize;
	);

	s.sync;

	// Maps Synth parameters to control busses
	ServerTree.add(~fMmakeMaps); // placeholder
	s.sync;

	// Create OSCdef (make sure all busses and mapping synth are already created)
	ServerTree.add(~fMmakeOSCdef);
	s.sync;

	s.freeAll; // necessary?

	// Main Volume
	v = s.volume;
	v.gui;
	v.volume = ~masterVol;

	s.sync;

});
// end of wait for boot function


)
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
//                                                      END MAIN CODE                                                         //
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
