import type {
    BrowserEvent,
    BrowserTab,
    CaptureMessage,
    ChannelLevels,
    PageMessage,
    PageMode,
    TabLevels,
    TabMode,
} from "./messages";
import { MessageSchema } from "./messages";
import type { TrackSettings } from "./track-settings";
import { TrackSettingsSchema } from "./track-settings";

/**
 * The extension's hub: connects to the MuxShots app through its native messaging host, reports the tabs
 * and their levels to it, and carries its settings to each tab, either to the page's own processing or
 * to a capture of the whole tab when the user asked for one with the toolbar button.
 *
 * Whenever the app goes away every tab gets its sound back untouched, and the extension keeps trying to
 * reconnect. Each tab's settings are kept in the browser's session storage, so they come back when the
 * app does, and go with the tab when it closes or with the browser when it quits.
 */
class MixerBridge {
    static readonly BRIDGE_HOST_NAME = "io.github.zobinhuang.muxshots";
    static readonly BRIDGE_RECONNECT_ALARM = "muxshots-reconnect";
    static readonly BRIDGE_RECONNECT_MINUTES = 0.5;
    static readonly REPORT_DELAY_MS = 150;
    static readonly LEVELS_INTERVAL_MS = 100;
    static readonly OFFSCREEN_PATH = "offscreen.html";
    static readonly BADGE_TEXT_CAPTURED = "ON";
    static readonly BADGE_COLOR_CAPTURED = "#2f7cf6";
    /** How strongly each page mode speaks for a tab whose frames disagree. */
    static readonly LIST_MODE_PRECEDENCE: readonly PageMode[] = ["page", "blocked", "waiting", "idle"];
    static readonly ERROR_NO_RECEIVER = "Receiving end does not exist";
    static readonly STORAGE_KEY_TAB_SETTINGS = "tab_settings";
    /** The frame id of a tab's page itself, as opposed to the frames inside it. */
    static readonly FRAME_ID_TOP = 0;
    static readonly CONTENT_SCRIPT_PATH = "content.js";
    /** The pages a content script can run in. */
    static readonly LIST_SCRIPTABLE_SCHEMES: readonly string[] = ["http:", "https:", "file:"];

    private _port: chrome.runtime.Port | undefined;
    private readonly _map_settings = new Map<number, TrackSettings>();
    private readonly _map_frame_modes = new Map<number, Map<number, PageMode>>();
    private readonly _set_captured = new Set<number>();
    private readonly _map_levels = new Map<number, ChannelLevels>();
    /** How large a video each frame of each tab plays. */
    private readonly _map_frame_videos = new Map<number, Map<number, number>>();
    /** The frame showing each tab's video in the sidebar. */
    private readonly _map_picture_frames = new Map<number, number>();
    /** Whether the app shows the tabs' meters, so the pages and captures should measure their levels. */
    private _is_meter_wanted = false;
    private _report_timer: ReturnType<typeof setTimeout> | undefined;
    private _levels_timer: ReturnType<typeof setInterval> | undefined;

    /**
     * Listen to the tabs, the pages and the toolbar button, and connect to the app.
     */
    start(): void {
        chrome.runtime.onMessage.addListener(
            (message: unknown, sender, send_response) => this._receive(message, sender, send_response),
        );
        chrome.tabs.onUpdated.addListener(
            (tab_id, change) => this._on_tab_updated(tab_id, change),
        );
        chrome.tabs.onRemoved.addListener(
            (tab_id) => this._forget(tab_id),
        );
        chrome.action.onClicked.addListener(
            (tab) => void this._toggle_capture(tab),
        );
        chrome.runtime.onInstalled.addListener(
            () => void this._inject_open_tabs(),
        );
        chrome.alarms.onAlarm.addListener(
            (alarm) => alarm.name === MixerBridge.BRIDGE_RECONNECT_ALARM && this._connect(),
        );
        void chrome.alarms.create(MixerBridge.BRIDGE_RECONNECT_ALARM, {
            periodInMinutes: MixerBridge.BRIDGE_RECONNECT_MINUTES,
        });
        void this._start_connected();
    }

    /** Connect once the kept settings are read back, or without them if they cannot be. */
    private async _start_connected(): Promise<void> {
        try {
            await this._load_settings();
        } finally {
            this._connect();
        }
    }

    /** Read back the settings kept for the tabs, as after the extension's worker was restarted. */
    private async _load_settings(): Promise<void> {
        const stored = await chrome.storage.session.get(MixerBridge.STORAGE_KEY_TAB_SETTINGS);
        const map_stored = MessageSchema.field(stored, MixerBridge.STORAGE_KEY_TAB_SETTINGS);
        if (typeof map_stored !== "object" || map_stored === null) {
            return;
        }
        for (const [key, value] of Object.entries(map_stored)) {
            const settings = TrackSettingsSchema.parse(value);
            const tab_id = Number(key);
            if (settings !== undefined && Number.isInteger(tab_id) && !this._map_settings.has(tab_id)) {
                this._map_settings.set(tab_id, settings);
            }
        }
    }

    private async _store_settings(): Promise<void> {
        await chrome.storage.session.set({
            [MixerBridge.STORAGE_KEY_TAB_SETTINGS]: Object.fromEntries(this._map_settings),
        });
    }

    /** Apply the kept settings again once the app is back, forgetting tabs that have closed meanwhile. */
    private async _restore_tabs(): Promise<void> {
        for (const [tab_id, settings] of [...this._map_settings]) {
            try {
                await chrome.tabs.get(tab_id);
            } catch (err: unknown) {
                if (!(err instanceof Error)) {
                    throw err;
                }
                this._map_settings.delete(tab_id);
                continue;
            }
            await this._apply_mute(tab_id, settings.is_muted);
            await this._send_to_page(tab_id);
        }
        await this._store_settings();
        this._schedule_report();
    }

    // The app

    private _connect(): void {
        if (this._port !== undefined) {
            return;
        }
        const port = chrome.runtime.connectNative(MixerBridge.BRIDGE_HOST_NAME);
        port.onMessage.addListener(
            (message: unknown) => this._receive_command(message),
        );
        port.onDisconnect.addListener(
            () => this._on_disconnect(),
        );
        this._port = port;
        this._levels_timer = setInterval(
            () => this._send_levels(),
            MixerBridge.LEVELS_INTERVAL_MS,
        );
        this._schedule_report();
    }

    /** Give every tab its sound back while the app is gone, keeping its settings for when it is back. */
    private _on_disconnect(): void {
        void chrome.runtime.lastError;
        this._port = undefined;
        void this._want_meter(false);
        clearInterval(this._levels_timer);
        this._levels_timer = undefined;
        const list_tab_ids = [...new Set([...this._map_settings.keys(), ...this._set_captured])];
        this._map_levels.clear();
        for (const [tab_id, frame_id] of [...this._map_picture_frames]) {
            const stop: PageMessage = { type: "page_picture_stop" };
            void this._send_to_frame({ tab_id, frame_id, message: stop });
        }
        this._map_picture_frames.clear();
        for (const tab_id of list_tab_ids) {
            if (this._set_captured.has(tab_id)) {
                void this._stop_capture(tab_id);
            } else {
                void this._send_to_page(tab_id);
            }
        }
        void this._unmute_own_tabs();
    }

    /** Unmute the tabs the mixer muted, leaving those the user muted from Chrome's tab strip. */
    private async _unmute_own_tabs(): Promise<void> {
        const list_muted_tabs = await chrome.tabs.query({ muted: true });
        for (const tab of list_muted_tabs) {
            if (tab.id !== undefined && tab.mutedInfo?.extensionId === chrome.runtime.id) {
                await chrome.tabs.update(tab.id, { muted: false });
            }
        }
    }

    private _receive_command(message: unknown): void {
        const tab_id = MessageSchema.field(message, "tab_id");
        switch (MessageSchema.type_of(message)) {
            case "hello":
                void this._restore_tabs();
                return;
            case "picture_start":
                if (typeof tab_id === "number") {
                    void this._start_picture(tab_id);
                }
                return;
            case "picture_stop":
                if (typeof tab_id === "number") {
                    void this._stop_picture(tab_id);
                }
                return;
            case "picture_answer": {
                const sdp = MessageSchema.field(message, "sdp");
                const frame_id = typeof tab_id === "number" ? this._map_picture_frames.get(tab_id) : undefined;
                if (typeof tab_id === "number" && frame_id !== undefined && typeof sdp === "string") {
                    const answer: PageMessage = { type: "page_picture_answer", sdp };
                    void this._send_to_frame({ tab_id, frame_id, message: answer });
                }
                return;
            }
            case "picture_control": {
                const is_playing = MessageSchema.field(message, "is_playing");
                const frame_id = typeof tab_id === "number" ? this._map_picture_frames.get(tab_id) : undefined;
                if (typeof tab_id === "number" && frame_id !== undefined && typeof is_playing === "boolean") {
                    const control: PageMessage = { type: "page_picture_control", is_playing };
                    void this._send_to_frame({ tab_id, frame_id, message: control });
                }
                return;
            }
            case "focus_tab":
                if (typeof tab_id === "number") {
                    void this._focus_tab(tab_id);
                }
                return;
            case "meter": {
                const is_wanted = MessageSchema.field(message, "is_wanted");
                if (typeof is_wanted === "boolean") {
                    void this._want_meter(is_wanted);
                }
                return;
            }
        }
        const settings = TrackSettingsSchema.parse(MessageSchema.field(message, "settings"));
        if (
            MessageSchema.type_of(message) !== "apply"
            || typeof tab_id !== "number"
            || settings === undefined
        ) {
            return;
        }
        void this._apply_settings(tab_id, settings);
    }

    /** Keep and apply a tab's new settings, unless the tab no longer exists. */
    private async _apply_settings(tab_id: number, settings: TrackSettings): Promise<void> {
        try {
            await chrome.tabs.get(tab_id);
        } catch (err: unknown) {
            if (err instanceof Error) {
                return;
            }
            throw err;
        }
        this._map_settings.set(tab_id, settings);
        void this._store_settings();
        void this._apply_mute(tab_id, settings.is_muted);
        if (!this._set_captured.has(tab_id)) {
            void this._send_to_page(tab_id);
        } else if (settings.is_taken_over) {
            const capture: CaptureMessage = { type: "capture_apply", tab_id, settings };
            void this._send_to_offscreen(capture);
        } else {
            void this._stop_capture(tab_id);
        }
        this._schedule_report();
    }

    private _schedule_report(): void {
        if (this._report_timer !== undefined || this._port === undefined) {
            return;
        }
        this._report_timer = setTimeout(
            () => void this._report(),
            MixerBridge.REPORT_DELAY_MS,
        );
    }

    /** Tell the app about every tab that plays, is taken over or was adjusted. */
    private async _report(): Promise<void> {
        this._report_timer = undefined;
        const list_all_tabs = await chrome.tabs.query({});
        const list_tabs: BrowserTab[] = [];
        for (const tab of list_all_tabs) {
            if (tab.id === undefined) {
                continue;
            }
            const mode = this._mode_of(tab.id);
            if (
                !tab.audible
                && !(tab.mutedInfo?.muted ?? false)
                && mode === "idle"
                && !this._map_settings.has(tab.id)
                && !this._map_picture_frames.has(tab.id)
                && this._largest_video_frame(tab.id) === undefined
            ) {
                continue;
            }
            list_tabs.push({
                tab_id: tab.id,
                window_id: tab.windowId,
                title: tab.title ?? "",
                url: tab.url ?? "",
                fav_icon_url: tab.favIconUrl ?? null,
                is_audible: tab.audible ?? false,
                is_muted: tab.mutedInfo?.muted ?? false,
                mode,
                settings: this._map_settings.get(tab.id) ?? null,
                has_video: this._map_picture_frames.has(tab.id) || this._largest_video_frame(tab.id) !== undefined,
            });
        }
        const event: BrowserEvent = { type: "tabs", list_tabs };
        this._port?.postMessage(event);
    }

    /** Have the pages and captures measure their levels only while the app shows them. */
    private async _want_meter(is_wanted: boolean): Promise<void> {
        this._is_meter_wanted = is_wanted;
        this._map_levels.clear();
        const page: PageMessage = { type: "page_meter", is_wanted };
        for (const tab_id of this._map_settings.keys()) {
            try {
                await chrome.tabs.sendMessage(tab_id, page);
            } catch (err: unknown) {
                if (!(err instanceof Error)) {
                    throw err;
                }
            }
        }
        const capture: CaptureMessage = { type: "capture_meter", is_wanted };
        await this._send_to_offscreen(capture);
    }

    private _send_levels(): void {
        if (this._map_levels.size === 0 || !this._is_meter_wanted) {
            return;
        }
        const list_levels: TabLevels[] = [...this._map_levels].map(
            ([tab_id, levels]) => ({ tab_id, ...levels }),
        );
        this._map_levels.clear();
        const event: BrowserEvent = { type: "levels", list_levels };
        this._port?.postMessage(event);
    }

    // Tabs and pages

    private _receive(
        message: unknown,
        sender: chrome.runtime.MessageSender,
        send_response: (response: unknown) => void,
    ): boolean {
        const tab_id = sender.tab?.id;
        switch (MessageSchema.type_of(message)) {
            case "page_hello":
                send_response({ settings: this._page_settings(tab_id), is_meter_wanted: this._is_meter_wanted });
                return false;
            case "page_state": {
                const mode = MessageSchema.field(message, "mode");
                if (tab_id !== undefined && sender.frameId !== undefined && MixerBridge._is_page_mode(mode)) {
                    const map_modes = this._map_frame_modes.get(tab_id) ?? new Map<number, PageMode>();
                    map_modes.set(sender.frameId, mode);
                    this._map_frame_modes.set(tab_id, map_modes);
                    this._schedule_report();
                }
                break;
            }
            case "page_levels":
                if (tab_id !== undefined) {
                    this._merge_levels(tab_id, MessageSchema.field(message, "levels"));
                }
                break;
            case "capture_levels": {
                const list_levels = MessageSchema.field(message, "list_levels");
                for (const levels of Array.isArray(list_levels) ? list_levels : []) {
                    const captured_tab_id = MessageSchema.field(levels, "tab_id");
                    if (typeof captured_tab_id === "number") {
                        this._merge_levels(captured_tab_id, levels);
                    }
                }
                break;
            }
            case "page_video": {
                const area = MessageSchema.field(message, "area");
                if (tab_id !== undefined && sender.frameId !== undefined && typeof area === "number") {
                    const map_areas = this._map_frame_videos.get(tab_id) ?? new Map<number, number>();
                    map_areas.set(sender.frameId, area);
                    this._map_frame_videos.set(tab_id, map_areas);
                    this._schedule_report();
                }
                break;
            }
            case "page_picture_state": {
                const is_paused = MessageSchema.field(message, "is_paused");
                if (tab_id !== undefined && this._map_picture_frames.has(tab_id) && typeof is_paused === "boolean") {
                    const event: BrowserEvent = { type: "picture_state", tab_id, is_paused };
                    this._port?.postMessage(event);
                }
                break;
            }
            case "page_picture_ended":
                if (tab_id !== undefined && this._map_picture_frames.get(tab_id) === sender.frameId) {
                    this._end_picture(tab_id);
                }
                break;
            case "capture_ended": {
                const ended_tab_id = MessageSchema.field(message, "tab_id");
                if (typeof ended_tab_id === "number" && this._set_captured.has(ended_tab_id)) {
                    void this._stop_capture(ended_tab_id);
                }
                break;
            }
            default:
                return false;
        }
        send_response({});
        return false;
    }

    private _on_tab_updated(tab_id: number, change: chrome.tabs.OnUpdatedInfo): void {
        if (change.status === "loading" && change.url !== undefined) {
            this._map_frame_modes.delete(tab_id);
            this._map_frame_videos.delete(tab_id);
            if (this._map_picture_frames.has(tab_id)) {
                this._end_picture(tab_id);
            }
        }
        this._schedule_report();
    }

    private _forget(tab_id: number): void {
        this._map_settings.delete(tab_id);
        void this._store_settings();
        this._map_frame_modes.delete(tab_id);
        this._map_levels.delete(tab_id);
        this._map_frame_videos.delete(tab_id);
        if (this._map_picture_frames.has(tab_id)) {
            this._end_picture(tab_id);
        }
        if (this._set_captured.delete(tab_id)) {
            const capture: CaptureMessage = { type: "capture_stop", tab_id };
            void this._send_to_offscreen(capture);
        }
        this._schedule_report();
    }

    /** The settings a tab's page should apply itself: none while the app is gone or the whole tab is
     * captured instead. */
    private _page_settings(tab_id: number | undefined): TrackSettings {
        if (tab_id === undefined || this._port === undefined || this._set_captured.has(tab_id)) {
            return TrackSettingsSchema.make_neutral();
        }
        return this._map_settings.get(tab_id) ?? TrackSettingsSchema.make_neutral();
    }

    private _mode_of(tab_id: number): TabMode {
        if (this._set_captured.has(tab_id)) {
            return "captured";
        }
        const list_modes = [...(this._map_frame_modes.get(tab_id)?.values() ?? [])];
        return MixerBridge.LIST_MODE_PRECEDENCE.find(
            (mode) => list_modes.includes(mode),
        ) ?? "idle";
    }

    private _merge_levels(tab_id: number, levels: unknown): void {
        const left = MessageSchema.field(levels, "left");
        const right = MessageSchema.field(levels, "right");
        if (typeof left !== "number" || typeof right !== "number") {
            return;
        }
        const previous = this._map_levels.get(tab_id);
        this._map_levels.set(tab_id, {
            left: Math.max(left, previous?.left ?? 0),
            right: Math.max(right, previous?.right ?? 0),
        });
    }

    /** Mute or unmute a tab as Chrome itself does, which silences it however its sound is played. */
    private async _apply_mute(tab_id: number, is_muted: boolean): Promise<void> {
        const tab = await chrome.tabs.get(tab_id);
        if ((tab.mutedInfo?.muted ?? false) !== is_muted) {
            await chrome.tabs.update(tab_id, { muted: is_muted });
        }
    }

    private async _send_to_page(tab_id: number): Promise<void> {
        const message: PageMessage = { type: "page_apply", settings: this._page_settings(tab_id) };
        try {
            await chrome.tabs.sendMessage(tab_id, message);
        } catch (err: unknown) {
            if (err instanceof Error && err.message.includes(MixerBridge.ERROR_NO_RECEIVER)) {
                return;
            }
            throw err;
        }
    }

    /** Give the tabs open before the extension was installed or updated their content script. */
    private async _inject_open_tabs(): Promise<void> {
        const list_tabs = await chrome.tabs.query({});
        for (const tab of list_tabs) {
            if (
                tab.id === undefined
                || !MixerBridge.LIST_SCRIPTABLE_SCHEMES.some((scheme) => tab.url?.startsWith(scheme) ?? false)
            ) {
                continue;
            }
            try {
                await chrome.scripting.executeScript({
                    target: { tabId: tab.id, allFrames: true },
                    files: [MixerBridge.CONTENT_SCRIPT_PATH],
                });
            } catch (err: unknown) {
                if (!(err instanceof Error)) {
                    throw err;
                }
                console.warn(`MuxShots cannot reach tab ${tab.id}: ${err.message}`);
            }
        }
    }

    // Showing videos in the sidebar

    /** The frame of a tab playing its largest video, if any frame plays one. */
    private _largest_video_frame(tab_id: number): number | undefined {
        let best_frame_id: number | undefined;
        let best_area = 0;
        for (const [frame_id, area] of this._map_frame_videos.get(tab_id) ?? []) {
            if (area > best_area) {
                best_frame_id = frame_id;
                best_area = area;
            }
        }
        return best_frame_id;
    }

    /** Show a tab's video in the sidebar, from the frame playing its largest video. */
    private async _start_picture(tab_id: number): Promise<void> {
        await this._stop_picture(tab_id);
        const frame_id = this._largest_video_frame(tab_id) ?? MixerBridge.FRAME_ID_TOP;
        this._map_picture_frames.set(tab_id, frame_id);
        const start: PageMessage = { type: "page_picture_start" };
        const reply = await this._send_to_frame({ tab_id, frame_id, message: start });
        const sdp = MessageSchema.field(reply, "sdp");
        if (typeof sdp !== "string") {
            this._end_picture(tab_id);
        } else if (this._map_picture_frames.get(tab_id) === frame_id) {
            const offer: BrowserEvent = { type: "picture_offer", tab_id, sdp };
            this._port?.postMessage(offer);
        }
        this._schedule_report();
    }

    private async _stop_picture(tab_id: number): Promise<void> {
        const frame_id = this._map_picture_frames.get(tab_id);
        if (frame_id === undefined) {
            return;
        }
        this._map_picture_frames.delete(tab_id);
        const stop: PageMessage = { type: "page_picture_stop" };
        await this._send_to_frame({ tab_id, frame_id, message: stop });
        this._schedule_report();
    }

    /** Tell the app a tab's video is no longer shown, as it ended, could not be shown or its tab went away. */
    private _end_picture(tab_id: number): void {
        this._map_picture_frames.delete(tab_id);
        const event: BrowserEvent = { type: "picture_ended", tab_id };
        this._port?.postMessage(event);
        this._schedule_report();
    }

    private async _focus_tab(tab_id: number): Promise<void> {
        const tab = await chrome.tabs.update(tab_id, { active: true });
        if (tab?.windowId !== undefined) {
            await chrome.windows.update(tab.windowId, { focused: true });
        }
    }

    private async _send_to_frame(options: {
        tab_id: number;
        frame_id: number;
        message: PageMessage;
    }): Promise<unknown> {
        try {
            const reply: unknown = await chrome.tabs.sendMessage(
                options.tab_id,
                options.message,
                { frameId: options.frame_id },
            );
            return reply;
        } catch (err: unknown) {
            if (err instanceof Error && err.message.includes(MixerBridge.ERROR_NO_RECEIVER)) {
                return undefined;
            }
            throw err;
        }
    }

    // Capturing whole tabs

    /** Capture the tab whose toolbar button was clicked, or stop capturing it. */
    private async _toggle_capture(tab: chrome.tabs.Tab): Promise<void> {
        const tab_id = tab.id;
        if (tab_id === undefined) {
            return;
        }
        if (this._set_captured.has(tab_id)) {
            await this._stop_capture(tab_id);
            return;
        }
        let stream_id: string;
        try {
            stream_id = await chrome.tabCapture.getMediaStreamId({ targetTabId: tab_id });
        } catch (err: unknown) {
            if (err instanceof Error) {
                console.warn(`MuxShots cannot capture this tab: ${err.message}`);
                return;
            }
            throw err;
        }
        await this._ensure_offscreen();
        const settings = { ...this._map_settings.get(tab_id) ?? TrackSettingsSchema.make_neutral(), is_taken_over: true };
        this._map_settings.set(tab_id, settings);
        void this._store_settings();
        this._set_captured.add(tab_id);
        await this._send_to_page(tab_id);
        const capture: CaptureMessage = { type: "capture_start", tab_id, stream_id, settings };
        await this._send_to_offscreen(capture);
        const meter: CaptureMessage = { type: "capture_meter", is_wanted: this._is_meter_wanted };
        await this._send_to_offscreen(meter);
        await chrome.action.setBadgeBackgroundColor({ tabId: tab_id, color: MixerBridge.BADGE_COLOR_CAPTURED });
        await chrome.action.setBadgeText({ tabId: tab_id, text: MixerBridge.BADGE_TEXT_CAPTURED });
        this._schedule_report();
    }

    private async _stop_capture(tab_id: number): Promise<void> {
        this._set_captured.delete(tab_id);
        const capture: CaptureMessage = { type: "capture_stop", tab_id };
        await this._send_to_offscreen(capture);
        await chrome.action.setBadgeText({ tabId: tab_id, text: "" });
        await this._send_to_page(tab_id);
        this._schedule_report();
    }

    private async _ensure_offscreen(): Promise<void> {
        if (await chrome.offscreen.hasDocument()) {
            return;
        }
        await chrome.offscreen.createDocument({
            url: MixerBridge.OFFSCREEN_PATH,
            reasons: [chrome.offscreen.Reason.USER_MEDIA],
            justification: "Play captured tabs through the MuxShots mixer",
        });
    }

    private async _send_to_offscreen(message: CaptureMessage): Promise<void> {
        if (!(await chrome.offscreen.hasDocument())) {
            return;
        }
        await chrome.runtime.sendMessage(message);
    }

    private static _is_page_mode(value: unknown): value is PageMode {
        return MixerBridge.LIST_MODE_PRECEDENCE.some(
            (mode) => mode === value,
        );
    }
}

new MixerBridge().start();
