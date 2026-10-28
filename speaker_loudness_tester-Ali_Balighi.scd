/*
    SPEAKER LOUDNESS TESTER: 4 CHANNELS
    ===================================

    HOW TO RUN
      Click anywhere inside the big ( ... ) block below and press
      Cmd+Return (macOS) or Ctrl+Return (Windows / Linux).
      The server boots with 4 outputs and the tester window opens.

    HOW TO USE
      1. Pick a test signal. For level matching, use
         "Pink noise 500 Hz-2 kHz (calibration)". It is the usual
         speaker-calibration signal.
      2. Keep the output gain low at first (-30 dB) and raise it slowly.
         For the noise signals the output gain equals the RMS level in
         dBFS, so -20 dB gives the standard -20 dBFS calibration level.
         Sine signals peak at the output gain.
      3. Click CH 1 / CH 2 / CH 3 / CH 4 to play each speaker on its own.
         With "Solo" ticked, only one channel plays at a time.
         Untick it to play several channels together.
      4. Hold an SPL meter (or a phone SPL app) at the listening position
         and adjust each channel's Trim until all speakers read the same.
      5. Optional: plug a measurement mic into your audio interface, switch
         on "Mic meter", then press "Auto-cycle". The window measures each
         speaker through the mic, and "Match trims" sets the trims for you.
         Keep the mic in the same spot for all four speakers.

    The vertical meters show the level SuperCollider sends to each output
    (dBFS). The acoustic loudness in the room comes from the SPL meter or mic.

    If your 4-channel audio interface is not the system default, add this
    line before running (and run ServerOptions.devices.postln; to list names):
      s.options.device = "Your Interface Name";

    If the server is already running with fewer than 4 outputs, this script
    reboots it automatically.
*/

(
// ===================== settings =====================
var numCh     = 4;      // number of speakers to test (outputs 1-4)
var numInputs = 2;      // hardware inputs to open (for the optional mic)
var startDb   = -30;    // starting output gain in dB: start low!
var sweepTime = 6;      // seconds per sine sweep

// ===================== state =====================
var synths    = Array.newClear(numCh);   // one test synth per channel (nil = off)
var trims     = Array.fill(numCh, 0);    // per-channel trim in dB
var measPow   = Array.newClear(numCh);   // mic reading (mean power) per channel
var chOnTime  = Array.fill(numCh, 0);    // when each channel was switched on
var masterDb  = startDb;
var sigType   = 1;
var toneFreq  = 1000;
var cycleTime = 3;
var cycleRout, micSynth, micIn = 0;
var settleUntil = 0;    // mic readings pause until levels settle after a change
var outOSC, micOSC, cmdPeriodFunc, needReboot;

// ===================== GUI =====================
var win, chButtons, meters, levelTexts, trimBoxes, micTexts;
var sigMenu, freqBox, masterSpec, masterSlider, masterBox, soloBox;
var cycleButton, cycleBox, micButton, micInBox, micMeter, micText, statusText;

// ===================== functions =====================
var setup, buildGui, ampFor, startCh, stopCh, soloCh, stopAll, startCycle, stopCycle;
var updateAmps, resetReadings, refreshReadings, matchTrims, startMic, stopMic, settle;

var sigNames = [
    "Pink noise (full range)",
    "Pink noise 500 Hz-2 kHz (calibration)",
    "White noise",
    "Sine tone",
    "Sine sweep 20 Hz-20 kHz"
];


// ---------------------------------------------------------------
// Sound control
// ---------------------------------------------------------------
ampFor = { |i| (masterDb + trims[i]).min(0).dbamp };   // never above 0 dBFS

startCh = { |i|
    if(synths[i].isNil) {
        synths[i] = Synth(\spkTest, [
            \out, i, \id, i, \amp, ampFor.(i),
            \type, sigType, \freq, toneFreq, \sweepDur, sweepTime
        ]);
        chOnTime[i] = Main.elapsedTime;
    };
    chButtons[i].value = 1;
};

stopCh = { |i|
    if(synths[i].notNil) {
        synths[i].release;
        synths[i] = nil;
        // clear the meter once the fade-out is over
        AppClock.sched(0.4, {
            if(win.isClosed.not and: { synths[i].isNil }) {
                meters[i].value = 0;
                meters[i].peakLevel = 0;
                levelTexts[i].string = "-";
            };
            nil
        });
    };
    chButtons[i].value = 0;
};

soloCh = { |i|
    numCh.do { |k| if(k != i) { stopCh.(k) } };
    startCh.(i);
};

stopAll = {
    stopCycle.();
    numCh.do { |i| stopCh.(i) };
};

updateAmps = {
    numCh.do { |i| synths[i] !? { |syn| syn.set(\amp, ampFor.(i)) } };
    settle.();
};

// after any level or signal change, ignore the mic for a moment
settle = { settleUntil = Main.elapsedTime + 0.7 };


// ---------------------------------------------------------------
// Auto-cycle: plays 1 -> 2 -> 3 -> 4 -> 1 ... one at a time
// ---------------------------------------------------------------
startCycle = {
    stopCycle.();
    cycleRout = Routine {
        inf.do { |k|
            var i = k % numCh;
            soloCh.(i);
            statusText.string = "Auto-cycle: CH % playing (% s each)".format(i + 1, cycleTime);
            cycleTime.wait;
        };
    }.play(AppClock);
    cycleButton.value = 1;
};

stopCycle = {
    if(cycleRout.notNil) { cycleRout.stop; cycleRout = nil };
    cycleButton.value = 0;
};


// ---------------------------------------------------------------
// Optional measurement mic
// ---------------------------------------------------------------
startMic = {
    if(micSynth.isNil) { micSynth = Synth(\spkTestMic, [\inCh, micIn]) };
    micButton.value = 1;
};

stopMic = {
    if(micSynth.notNil) { micSynth.free; micSynth = nil };
    micButton.value = 0;
    micMeter.value = 0;
    micMeter.peakLevel = 0;
    micText.string = "Mic: off";
};

refreshReadings = {
    var dbs = measPow.collect { |p| if(p.isNil) { nil } { p.sqrt.ampdb } };
    var valid = dbs.reject(_.isNil);
    var ref = if(valid.isEmpty) { nil } { valid.minItem };
    numCh.do { |i|
        micTexts[i].string = case
            { dbs[i].isNil } { "Mic: -" }
            { dbs[i] == ref } { "Mic: % dB\nquietest".format(dbs[i].round(0.1)) }
            { "Mic: % dB\n+% dB vs quietest".format(dbs[i].round(0.1), (dbs[i] - ref).round(0.1)) };
    };
};

resetReadings = {
    measPow = Array.newClear(numCh);
    refreshReadings.();
};

matchTrims = {
    var dbs = measPow.collect { |p| if(p.isNil) { nil } { p.sqrt.ampdb } };
    var ref;
    if(dbs.any(_.isNil)) {
        statusText.string = "Measure every channel with the mic first (turn on Mic meter, then Auto-cycle).";
    } {
        ref = dbs.minItem;
        numCh.do { |i|
            trims[i] = (trims[i] + ref - dbs[i]).clip(-30, 10).round(0.1);
            trimBoxes[i].value = trims[i];
        };
        updateAmps.();
        resetReadings.();
        statusText.string = "Trims set: every speaker now matches the quietest one. Auto-cycle again to check.";
    };
};


// ---------------------------------------------------------------
// Synths (built once the server is up)
// ---------------------------------------------------------------
setup = {
    SynthDef(\spkTest, { |out = 0, amp = 0.03, type = 1, freq = 1000, gate = 1, id = 0, sweepDur = 6|
        var env, pink, sweepFreq, sig;
        env  = EnvGen.kr(Env.asr(0.05, 1, 0.1), gate, doneAction: 2);
        pink = PinkNoise.ar;
        sweepFreq = Sweep.kr(Impulse.kr(sweepDur.reciprocal), sweepDur.reciprocal).linexp(0, 1, 20, 20000);
        // noise signals are scaled so their RMS level equals the output gain;
        // sine signals peak at the output gain
        sig = Select.ar(type, [
            pink * 15.7.dbamp,                                                        // 0 pink noise, full range
            HPF.ar(HPF.ar(LPF.ar(LPF.ar(pink, 2000), 2000), 500), 500) * 28.3.dbamp,  // 1 pink noise 500 Hz-2 kHz
            WhiteNoise.ar * 3.sqrt,                                                   // 2 white noise
            SinOsc.ar(freq.lag(0.05)),                                                // 3 sine tone
            SinOsc.ar(sweepFreq)                                                      // 4 log sine sweep
        ]);
        sig = sig * amp.lag(0.1) * env;
        sig = Limiter.ar(sig, -1.dbamp, 0.01);              // safety: never above -1 dBFS
        SendPeakRMS.kr(sig, 20, 3, '/spkTestLevel', id);   // feeds the on-screen meters
        Out.ar(out, sig);
    }).add;

    SynthDef(\spkTestMic, { |inCh = 0|
        SendPeakRMS.kr(SoundIn.ar(inCh), 20, 3, '/spkTestMic');
    }).add;

    s.sync;
    { buildGui.() }.defer;
};


// ---------------------------------------------------------------
// Interface
// ---------------------------------------------------------------
buildGui = {
    var columns, allButton, stopButton, resetButton, matchButton, footerLine, credit, link;
    var bigFont  = Font(Font.defaultSansFace, 15, true);
    var monoFont = Font(Font.defaultMonoFace, 11);

    win = Window("Speaker Loudness Tester (% channels)".format(numCh), Rect(120, 120, 780, 740));

    // --- test signal + output gain ---
    sigMenu = PopUpMenu().items_(sigNames).value_(sigType)
    .action_({ |menu|
        sigType = menu.value;
        synths.do { |syn| syn !? { syn.set(\type, sigType) } };
        settle.();
        resetReadings.();
    });

    freqBox = NumberBox().clipLo_(20).clipHi_(20000).decimals_(0)
    .step_(10).scroll_step_(10).value_(toneFreq).fixedWidth_(70)
    .action_({ |nb|
        toneFreq = nb.value;
        synths.do { |syn| syn !? { syn.set(\freq, toneFreq) } };
        settle.();
        resetReadings.();
    });

    masterSpec = ControlSpec(-80, 0, \lin, 0.5, startDb);

    masterSlider = Slider().orientation_(\horizontal).value_(masterSpec.unmap(masterDb))
    .action_({ |sl|
        masterDb = masterSpec.map(sl.value);
        masterBox.value = masterDb;
        updateAmps.();
        resetReadings.();
    });

    masterBox = NumberBox().clipLo_(-80).clipHi_(0).decimals_(1).step_(0.5)
    .scroll_step_(0.5).value_(masterDb).fixedWidth_(60)
    .action_({ |nb|
        masterDb = nb.value;
        masterSlider.value = masterSpec.unmap(masterDb);
        updateAmps.();
        resetReadings.();
    });

    // --- one column per channel ---
    chButtons = numCh.collect { |i|
        Button().font_(bigFont).minHeight_(56)
        .states_([
            ["CH %\nOFF".format(i + 1), Color.white, Color.grey(0.35)],
            ["CH %\nPLAYING".format(i + 1), Color.black, Color(0.35, 0.9, 0.45)]
        ])
        .action_({ |b|
            stopCycle.();
            if(b.value == 1) {
                if(soloBox.value) { soloCh.(i) } { startCh.(i) };
                statusText.string = "CH % playing.".format(i + 1);
            } {
                stopCh.(i);
            };
        });
    };

    meters = numCh.collect {
        LevelIndicator().drawsPeak_(true).warning_(0.8).critical_(0.95)
        .numTicks_(13).numMajorTicks_(7).fixedWidth_(34).minHeight_(220)
    };

    levelTexts = numCh.collect {
        StaticText().string_("-").align_(\center).font_(monoFont).minHeight_(34)
    };

    trimBoxes = numCh.collect { |i|
        NumberBox().clipLo_(-30).clipHi_(10).decimals_(1).step_(0.5).scroll_step_(0.5)
        .value_(0).fixedWidth_(56).align_(\center)
        .action_({ |nb|
            trims[i] = nb.value;
            synths[i] !? { |syn| syn.set(\amp, ampFor.(i)) };
            settle.();
            measPow[i] = nil;
            refreshReadings.();
        });
    };

    micTexts = numCh.collect {
        StaticText().string_("Mic: -").align_(\center).font_(monoFont).minHeight_(34)
    };

    columns = numCh.collect { |i|
        VLayout(
            chButtons[i],
            HLayout(nil, meters[i], nil),
            levelTexts[i],
            HLayout(nil, StaticText().string_("Trim"), trimBoxes[i], StaticText().string_("dB"), nil),
            micTexts[i]
        )
    };

    // --- transport ---
    soloBox = CheckBox().string_("Solo (one channel at a time)").value_(true);

    allButton = Button().states_([["All channels ON"]])
    .action_({
        stopCycle.();
        numCh.do { |i| startCh.(i) };
        statusText.string = "All channels playing.";
    });

    stopButton = Button().font_(bigFont)
    .states_([["STOP ALL", Color.white, Color(0.8, 0.15, 0.15)]])
    .action_({ stopAll.(); statusText.string = "Stopped." });

    cycleButton = Button()
    .states_([
        ["Auto-cycle 1 -> %".format(numCh)],
        ["Stop auto-cycle", Color.black, Color(1, 0.8, 0.3)]
    ])
    .action_({ |b|
        if(b.value == 1) { startCycle.() } { stopAll.(); statusText.string = "Auto-cycle stopped." };
    });

    cycleBox = NumberBox().clipLo_(0.5).clipHi_(60).decimals_(1).step_(0.5)
    .value_(cycleTime).fixedWidth_(50)
    .action_({ |nb| cycleTime = nb.value });

    // --- mic ---
    micButton = Button()
    .states_([["Mic meter: OFF"], ["Mic meter: ON", Color.black, Color(0.45, 0.8, 1)]])
    .action_({ |b| if(b.value == 1) { startMic.() } { stopMic.() } });

    micInBox = NumberBox().clipLo_(1).clipHi_(numInputs).decimals_(0).step_(1)
    .value_(micIn + 1).fixedWidth_(40)
    .action_({ |nb|
        micIn = nb.value.asInteger - 1;
        if(micSynth.notNil) { stopMic.(); startMic.() };
        resetReadings.();
    });

    micMeter = LevelIndicator().drawsPeak_(true).warning_(0.8).critical_(0.95)
    .minWidth_(160).fixedHeight_(20);

    micText = StaticText().string_("Mic: off").font_(monoFont).fixedWidth_(150);

    resetButton = Button().states_([["Reset mic readings"]]).action_({ resetReadings.() });
    matchButton = Button().states_([["Match trims to quietest speaker"]]).action_({ matchTrims.() });

    statusText = StaticText().string_("Ready. Keep the output gain low at first and raise it slowly.");

    // --- footer ---
    footerLine = View().fixedHeight_(1).background_(Color.grey(0.65));

    credit = StaticText().string_("Ali Balighi © 2026").align_(\center)
    .font_(Font(Font.defaultSansFace, 12, true)).stringColor_(Color.grey(0.25));

    link = StaticText().string_("alibalighi.com").align_(\center)
    .font_(Font(Font.defaultSansFace, 12)).stringColor_(Color(0.1, 0.35, 0.8))
    .toolTip_("Open alibalighi.com in your browser")
    .mouseDownAction_({ "https://alibalighi.com".openOS; true });

    // --- layout ---
    win.layout = VLayout(
        HLayout(StaticText().string_("Test signal:"), [sigMenu, stretch: 1], StaticText().string_("Sine freq (Hz):"), freqBox),
        HLayout(StaticText().string_("Output gain:"), masterSlider, masterBox, StaticText().string_("dB")),
        HLayout(*columns),
        StaticText().string_("Meters: level sent to each output, -60 to 0 dBFS (bar = RMS, line = peak)").align_(\center),
        HLayout(allButton, stopButton, soloBox),
        HLayout(cycleButton, StaticText().string_("seconds per channel:"), cycleBox, nil),
        HLayout(micButton, StaticText().string_("input #"), micInBox, [micMeter, stretch: 1], micText),
        HLayout(resetButton, matchButton, nil),
        statusText,
        footerLine,
        VLayout(credit, HLayout(nil, link, nil)).spacing_(2)
    );

    // --- meter updates from the server ---
    outOSC = OSCFunc({ |msg|
        var i = msg[2].asInteger, peak = msg[3], rms = msg[4];
        {
            if(win.isClosed.not and: { synths[i].notNil }) {
                meters[i].value = rms.ampdb.linlin(-60, 0, 0, 1);
                meters[i].peakLevel = peak.ampdb.linlin(-60, 0, 0, 1);
                levelTexts[i].string = "RMS  % dB\npeak % dB".format(rms.ampdb.round(0.1), peak.ampdb.round(0.1));
            };
        }.defer;
    }, '/spkTestLevel', s.addr);
    outOSC.permanent = true;

    micOSC = OSCFunc({ |msg|
        var peak = msg[3], rms = msg[4];
        {
            var active, j, p;
            if(win.isClosed.not and: { micSynth.notNil }) {
                micMeter.value = rms.ampdb.linlin(-80, 0, 0, 1);
                micMeter.peakLevel = peak.ampdb.linlin(-80, 0, 0, 1);
                micText.string = "Mic: % dBFS".format(rms.ampdb.round(0.1));
                // record a reading only while exactly one speaker is playing
                active = (0 .. numCh - 1).select { |k| synths[k].notNil };
                if(active.size == 1 and: { rms > 0 }) {
                    j = active[0];
                    if(((Main.elapsedTime - chOnTime[j]) > 0.7) and: { Main.elapsedTime > settleUntil }) {
                        p = rms.squared;
                        measPow[j] = if(measPow[j].isNil) { p } { (measPow[j] * 0.95) + (p * 0.05) };
                        refreshReadings.();
                    };
                };
            };
        }.defer;
    }, '/spkTestMic', s.addr);
    micOSC.permanent = true;

    // --- Cmd/Ctrl + Period stops all sound; reset the interface to match ---
    cmdPeriodFunc = {
        if(cycleRout.notNil) { cycleRout.stop; cycleRout = nil };
        synths = Array.newClear(numCh);
        micSynth = nil;
        {
            if(win.isClosed.not) {
                numCh.do { |i|
                    chButtons[i].value = 0;
                    meters[i].value = 0;
                    meters[i].peakLevel = 0;
                    levelTexts[i].string = "-";
                };
                cycleButton.value = 0;
                micButton.value = 0;
                micMeter.value = 0;
                micMeter.peakLevel = 0;
                micText.string = "Mic: off";
                statusText.string = "Stopped (Cmd/Ctrl + Period).";
            };
        }.defer;
    };
    CmdPeriod.add(cmdPeriodFunc);

    // --- closing the window stops everything ---
    win.onClose = {
        if(cycleRout.notNil) { cycleRout.stop };
        synths.do { |syn| syn !? { syn.release } };
        micSynth !? { micSynth.free };
        outOSC.free;
        micOSC.free;
        CmdPeriod.remove(cmdPeriodFunc);
        if(~spkTestWin === win) { ~spkTestWin = nil };
    };

    ~spkTestWin = win;
    win.front;
};


// ---------------------------------------------------------------
// Boot the server with enough channels, then open the window
// ---------------------------------------------------------------
~spkTestWin !? { |w| if(w.isClosed.not) { w.close } };   // close a window left from an earlier run

needReboot = s.serverRunning and: {
    (s.options.numOutputBusChannels < numCh) or: { s.options.numInputBusChannels < numInputs }
};
s.options.numOutputBusChannels = max(s.options.numOutputBusChannels, numCh);
s.options.numInputBusChannels  = max(s.options.numInputBusChannels, numInputs);

if(needReboot) {
    "Rebooting the server with % outputs...".format(numCh).postln;
    s.reboot({ s.doWhenBooted(setup) });
} {
    s.waitForBoot(setup);
};
)
