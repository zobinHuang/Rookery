import type { TrackSettings } from "./track-settings";

/**
 * How the extension is treating a tab's sound, as the MuxShots app reads it.
 */
export type TabMode = "idle" | "page" | "waiting" | "blocked" | "captured";

/**
 * How a page is treating its own sound: every mode but capturing, which the page does not see.
 */
export type PageMode = Exclude<TabMode, "captured">;

/**
 * How loud a track's two channels are, 0 silent to 1 full scale.
 */
export interface ChannelLevels {
    left: number;
    right: number;
}

/**
 * A tab's levels, as reported to the app.
 */
export interface TabLevels extends ChannelLevels {
    tab_id: number;
}

/**
 * A tab, as reported to the app.
 */
export interface BrowserTab {
    tab_id: number;
    window_id: number;
    title: string;
    url: string;
    fav_icon_url: string | null;
    is_audible: boolean;
    is_muted: boolean;
    mode: TabMode;
}

/**
 * A message from the extension to the MuxShots app.
 */
export type BrowserEvent =
    | { type: "tabs"; list_tabs: BrowserTab[] }
    | { type: "levels"; list_levels: TabLevels[] };

/**
 * A message from the MuxShots app to the extension.
 */
export type BrowserCommand = { type: "apply"; tab_id: number; settings: TrackSettings };

/**
 * A message between the background and a page's content script.
 */
export type PageMessage =
    | { type: "page_hello" }
    | { type: "page_apply"; settings: TrackSettings }
    | { type: "page_state"; mode: PageMode }
    | { type: "page_levels"; levels: ChannelLevels };

/**
 * A message between the background and the offscreen document that plays captured tabs.
 */
export type CaptureMessage =
    | { type: "capture_start"; tab_id: number; stream_id: string; settings: TrackSettings }
    | { type: "capture_apply"; tab_id: number; settings: TrackSettings }
    | { type: "capture_stop"; tab_id: number }
    | { type: "capture_levels"; list_levels: TabLevels[] }
    | { type: "capture_ended"; tab_id: number };

/**
 * Reading the messages the extension's parts and the app send each other.
 */
export class MessageSchema {
    /**
     * The message's type, if it is an object carrying one.
     *
     * @param value - the untrusted message
     * @returns the type, or undefined
     */
    static type_of(value: unknown): string | undefined {
        if (typeof value !== "object" || value === null || !("type" in value)) {
            return undefined;
        }
        return typeof value.type === "string" ? value.type : undefined;
    }

    /**
     * A field of a message object.
     *
     * @param value - the untrusted message
     * @param key - the field's name
     * @returns the field's value, or undefined if absent
     */
    static field(value: unknown, key: string): unknown {
        if (typeof value !== "object" || value === null) {
            return undefined;
        }
        const record: Record<string, unknown> = { ...value };
        return record[key];
    }
}
