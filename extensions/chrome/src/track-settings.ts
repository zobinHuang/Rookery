/**
 * The rooms the reverb can simulate, spelled as the Rookery app spells them.
 */
export type ReverbRoom =
    | "smallRoom"
    | "mediumRoom"
    | "largeRoom"
    | "mediumHall"
    | "largeHall"
    | "plate"
    | "cathedral";

/**
 * How the mixer treats one tab's sound, as the Rookery app sends it.
 */
export interface TrackSettings {
    /** Whether the extension processes the tab's sound at all. */
    is_taken_over: boolean;
    /** Whether the tab is silenced, whether or not it is taken over. */
    is_muted: boolean;
    /** The gain, 1 unchanged. */
    volume: number;
    /** The stereo position, -1 hard left to 1 hard right. */
    pan: number;
    is_left_inverted: boolean;
    is_right_inverted: boolean;
    is_swapped: boolean;
    /** The stereo width, 0 mono, 1 unchanged, 2 twice as wide. */
    width: number;
    is_equalizer_enabled: boolean;
    /** Each equalizer band's gain in decibels, matching `TrackSettingsSchema.LIST_EQUALIZER_FREQUENCIES`. */
    list_equalizer_gains: number[];
    reverb_room: ReverbRoom;
    /** The share of reverberated sound, 0 dry to 100 wet. */
    reverb_mix: number;
}

/**
 * The shape of track settings: their neutral values, and reading them from untrusted messages.
 */
export class TrackSettingsSchema {
    static readonly LIST_EQUALIZER_FREQUENCIES: readonly number[] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
    static readonly LIST_REVERB_ROOMS: readonly ReverbRoom[] = [
        "smallRoom",
        "mediumRoom",
        "largeRoom",
        "mediumHall",
        "largeHall",
        "plate",
        "cathedral",
    ];

    /**
     * Settings that leave the sound as it is.
     *
     * @returns fresh neutral settings
     */
    static make_neutral(): TrackSettings {
        return {
            is_taken_over: false,
            is_muted: false,
            volume: 1,
            pan: 0,
            is_left_inverted: false,
            is_right_inverted: false,
            is_swapped: false,
            width: 1,
            is_equalizer_enabled: true,
            list_equalizer_gains: TrackSettingsSchema.LIST_EQUALIZER_FREQUENCIES.map(
                () => 0,
            ),
            reverb_room: "mediumHall",
            reverb_mix: 0,
        };
    }

    /**
     * Read settings from a message, if it holds well-formed ones.
     *
     * @param value - the untrusted value
     * @returns the settings, or undefined if the value is not settings
     */
    static parse(value: unknown): TrackSettings | undefined {
        if (typeof value !== "object" || value === null) {
            return undefined;
        }
        const record: Record<string, unknown> = { ...value };
        const list_gains = record["list_equalizer_gains"];
        const reverb_room = record["reverb_room"];
        if (
            typeof record["is_taken_over"] !== "boolean"
            || typeof record["is_muted"] !== "boolean"
            || typeof record["volume"] !== "number"
            || typeof record["pan"] !== "number"
            || typeof record["is_left_inverted"] !== "boolean"
            || typeof record["is_right_inverted"] !== "boolean"
            || typeof record["is_swapped"] !== "boolean"
            || typeof record["width"] !== "number"
            || typeof record["is_equalizer_enabled"] !== "boolean"
            || !Array.isArray(list_gains)
            || !list_gains.every((gain: unknown) => typeof gain === "number")
            || !TrackSettingsSchema.is_reverb_room(reverb_room)
            || typeof record["reverb_mix"] !== "number"
        ) {
            return undefined;
        }
        return {
            is_taken_over: record["is_taken_over"],
            is_muted: record["is_muted"],
            volume: record["volume"],
            pan: record["pan"],
            is_left_inverted: record["is_left_inverted"],
            is_right_inverted: record["is_right_inverted"],
            is_swapped: record["is_swapped"],
            width: record["width"],
            is_equalizer_enabled: record["is_equalizer_enabled"],
            list_equalizer_gains: list_gains.filter((gain: unknown) => typeof gain === "number"),
            reverb_room,
            reverb_mix: record["reverb_mix"],
        };
    }

    private static is_reverb_room(value: unknown): value is ReverbRoom {
        return TrackSettingsSchema.LIST_REVERB_ROOMS.some(
            (room) => room === value,
        );
    }
}
