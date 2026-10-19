import type { ChannelLevels } from "./messages";
import type { ReverbRoom, TrackSettings } from "./track-settings";
import { TrackSettingsSchema } from "./track-settings";

/**
 * One track's sound on its way to the speakers, as the MuxShots mixer treats it: phase and channel swap,
 * stereo width, volume, a ten-band equalizer, reverb and pan, then meters, and muting last so a muted
 * track still shows on its meters.
 */
export class TrackGraph {
    /** Each band's width, one octave as in the app's equalizer. */
    static readonly EQUALIZER_BAND_Q = Math.SQRT2;
    static readonly METER_FFT_SIZE = 1024;
    /** How long each room's reverb rings, in seconds. */
    static readonly MAP_REVERB_SECONDS: ReadonlyMap<ReverbRoom, number> = new Map([
        ["smallRoom", 0.5],
        ["mediumRoom", 0.9],
        ["largeRoom", 1.4],
        ["mediumHall", 2.0],
        ["largeHall", 2.8],
        ["plate", 1.6],
        ["cathedral", 4.5],
    ]);
    /** How steeply a reverb fades, higher dying away sooner. */
    static readonly REVERB_DECAY_POWER = 3;
    static readonly REVERB_MIX_FULL = 100;
    /** How quickly a change of setting takes effect, smoothed so it does not click. */
    static readonly RAMP_TIME_CONSTANT_SECONDS = 0.015;

    private readonly _context: BaseAudioContext;
    private readonly _input: GainNode;
    private readonly _splitter: ChannelSplitterNode;
    private readonly _left_to_left: GainNode;
    private readonly _left_to_right: GainNode;
    private readonly _right_to_left: GainNode;
    private readonly _right_to_right: GainNode;
    private readonly _merger: ChannelMergerNode;
    private readonly _volume: GainNode;
    private readonly _list_bands: BiquadFilterNode[];
    private readonly _dry: GainNode;
    private readonly _wet: GainNode;
    private readonly _convolver: ConvolverNode;
    private readonly _panner: StereoPannerNode;
    private readonly _mute: GainNode;
    private readonly _meter_splitter: ChannelSplitterNode;
    private readonly _left_analyser: AnalyserNode;
    private readonly _right_analyser: AnalyserNode;
    private readonly _meter_samples: Float32Array<ArrayBuffer>;
    private _reverb_room: ReverbRoom | undefined;

    /**
     * Build the chain, playing into a destination.
     *
     * @param context - the audio context the chain lives in
     * @param destination - where the treated sound goes
     */
    constructor(context: BaseAudioContext, destination: AudioNode) {
        this._context = context;
        this._input = new GainNode(context, {
            channelCount: 2,
            channelCountMode: "explicit",
            channelInterpretation: "speakers",
        });
        this._splitter = new ChannelSplitterNode(context, { numberOfOutputs: 2 });
        this._left_to_left = new GainNode(context);
        this._left_to_right = new GainNode(context, { gain: 0 });
        this._right_to_left = new GainNode(context, { gain: 0 });
        this._right_to_right = new GainNode(context);
        this._merger = new ChannelMergerNode(context, { numberOfInputs: 2 });
        this._volume = new GainNode(context);
        this._list_bands = TrackSettingsSchema.LIST_EQUALIZER_FREQUENCIES.map(
            (frequency, index) => TrackGraph._make_band({ context, frequency, index }),
        );
        this._dry = new GainNode(context);
        this._wet = new GainNode(context, { gain: 0 });
        this._convolver = new ConvolverNode(context);
        this._panner = new StereoPannerNode(context);
        this._mute = new GainNode(context);
        this._meter_splitter = new ChannelSplitterNode(context, { numberOfOutputs: 2 });
        this._left_analyser = new AnalyserNode(context, { fftSize: TrackGraph.METER_FFT_SIZE });
        this._right_analyser = new AnalyserNode(context, { fftSize: TrackGraph.METER_FFT_SIZE });
        this._meter_samples = new Float32Array(TrackGraph.METER_FFT_SIZE);

        this._input.connect(this._splitter);
        this._splitter.connect(this._left_to_left, 0);
        this._splitter.connect(this._left_to_right, 0);
        this._splitter.connect(this._right_to_left, 1);
        this._splitter.connect(this._right_to_right, 1);
        this._left_to_left.connect(this._merger, 0, 0);
        this._right_to_left.connect(this._merger, 0, 0);
        this._left_to_right.connect(this._merger, 0, 1);
        this._right_to_right.connect(this._merger, 0, 1);
        this._merger.connect(this._volume);
        let tail: AudioNode = this._volume;
        for (const band of this._list_bands) {
            tail.connect(band);
            tail = band;
        }
        tail.connect(this._dry);
        tail.connect(this._convolver);
        this._convolver.connect(this._wet);
        this._dry.connect(this._panner);
        this._wet.connect(this._panner);
        this._panner.connect(this._mute);
        this._mute.connect(destination);
        this._panner.connect(this._meter_splitter);
        this._meter_splitter.connect(this._left_analyser, 0);
        this._meter_splitter.connect(this._right_analyser, 1);
    }

    /**
     * The node the track's sound goes into.
     *
     * @returns the chain's first node
     */
    get input(): AudioNode {
        return this._input;
    }

    /**
     * Treat the sound as settings say; settings that are not taken over leave it as it is.
     *
     * @param settings - the track's settings
     */
    apply(settings: TrackSettings): void {
        const effective = settings.is_taken_over ? settings : TrackSettingsSchema.make_neutral();
        const left_sign = effective.is_left_inverted ? -1 : 1;
        const right_sign = effective.is_right_inverted ? -1 : 1;
        const same_side = (1 + effective.width) / 2;
        const other_side = (1 - effective.width) / 2;
        const left_kept = effective.is_swapped ? other_side : same_side;
        const left_crossed = effective.is_swapped ? same_side : other_side;
        const right_kept = effective.is_swapped ? other_side : same_side;
        const right_crossed = effective.is_swapped ? same_side : other_side;
        this._ramp(this._left_to_left.gain, left_sign * left_kept);
        this._ramp(this._left_to_right.gain, left_sign * left_crossed);
        this._ramp(this._right_to_right.gain, right_sign * right_kept);
        this._ramp(this._right_to_left.gain, right_sign * right_crossed);
        this._ramp(this._volume.gain, effective.volume);
        this._list_bands.forEach((band, index) => {
            const gain = effective.list_equalizer_gains[index] ?? 0;
            this._ramp(band.gain, effective.is_equalizer_enabled ? gain : 0);
        });
        if (effective.reverb_mix > 0 && this._reverb_room !== effective.reverb_room) {
            this._convolver.buffer = this._make_impulse(effective.reverb_room);
            this._reverb_room = effective.reverb_room;
        }
        const wet_share = effective.reverb_mix / TrackGraph.REVERB_MIX_FULL;
        this._ramp(this._wet.gain, wet_share);
        this._ramp(this._dry.gain, 1 - wet_share);
        this._ramp(this._panner.pan, effective.pan);
        this._ramp(this._mute.gain, settings.is_muted ? 0 : 1);
    }

    /**
     * How loud each channel is right now.
     *
     * @returns the peak of the latest stretch of each channel
     */
    read_levels(): ChannelLevels {
        return {
            left: this._peak(this._left_analyser),
            right: this._peak(this._right_analyser),
        };
    }

    /**
     * Take the chain apart, so it no longer plays.
     */
    dispose(): void {
        this._input.disconnect();
        this._mute.disconnect();
    }

    private _ramp(parameter: AudioParam, value: number): void {
        parameter.setTargetAtTime(
            /* target */          value,
            /* startTime */       this._context.currentTime,
            /* timeConstant */    TrackGraph.RAMP_TIME_CONSTANT_SECONDS,
        );
    }

    private _peak(analyser: AnalyserNode): number {
        analyser.getFloatTimeDomainData(this._meter_samples);
        let peak = 0;
        for (const sample of this._meter_samples) {
            peak = Math.max(peak, Math.abs(sample));
        }
        return peak;
    }

    /** A room's echo: noise on each channel, fading away over the room's ringing time. */
    private _make_impulse(room: ReverbRoom): AudioBuffer {
        const seconds = TrackGraph.MAP_REVERB_SECONDS.get(room) ?? 1;
        const length = Math.round(this._context.sampleRate * seconds);
        const impulse = new AudioBuffer({
            numberOfChannels: 2,
            length,
            sampleRate: this._context.sampleRate,
        });
        for (let channel = 0; channel < 2; channel += 1) {
            const list_samples = impulse.getChannelData(channel);
            for (let index = 0; index < length; index += 1) {
                const fade = (1 - index / length) ** TrackGraph.REVERB_DECAY_POWER;
                list_samples[index] = (Math.random() * 2 - 1) * fade;
            }
        }
        return impulse;
    }

    private static _make_band(options: {
        context: BaseAudioContext;
        frequency: number;
        index: number;
    }): BiquadFilterNode {
        const last_index = TrackSettingsSchema.LIST_EQUALIZER_FREQUENCIES.length - 1;
        const type: BiquadFilterType = options.index === 0
            ? "lowshelf"
            : options.index === last_index ? "highshelf" : "peaking";
        return new BiquadFilterNode(options.context, {
            type,
            frequency: options.frequency,
            Q: TrackGraph.EQUALIZER_BAND_Q,
            gain: 0,
        });
    }
}
