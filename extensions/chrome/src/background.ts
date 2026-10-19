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
 * reconnect.
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
    static readonly CONTENT_SCRIPT_PATH = "content.js";
    /** The pages a content script can run in. */
    static readonly LIST_SCRIPTABLE_SCHEMES: readonly string[] = ["http:", "https:", "file:"];

    private _port: chrome.runtime.Port | undefined;
    private readonly _map_settings = new Map<number, TrackSettings>();
    private readonly _map_frame_modes = new Map<number, Map<number, PageMode>>();
    private readonly _set_captured = new Set<number>();
    private readonly _map_levels = new Map<number, ChannelLevels>();
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
        this._connect();
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

    /** Give every tab its sound back, as the app is gone. */
    private _on_disconnect(): void {
        void chrome.runtime.lastError;
        this._port = undefined;
        clearInterval(this._levels_timer);
        this._levels_timer = undefined;
        const list_tab_ids = [...new Set([...this._map_settings.keys(), ...this._set_captured])];
        this._map_settings.clear();
        this._map_levels.clear();
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
        const settings = TrackSettingsSchema.parse(MessageSchema.field(message, "settings"));
        if (
            MessageSchema.type_of(message) !== "apply"
            || typeof tab_id !== "number"
            || settings === undefined
        ) {
            return;
        }
        this._map_settings.set(tab_id, settings);
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
            });
        }
        const event: BrowserEvent = { type: "tabs", list_tabs };
        this._port?.postMessage(event);
    }

    private _send_levels(): void {
        if (this._map_levels.size === 0) {
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
                send_response({ settings: this._page_settings(tab_id) });
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
        }
        this._schedule_report();
    }

    private _forget(tab_id: number): void {
        this._map_settings.delete(tab_id);
        this._map_frame_modes.delete(tab_id);
        this._map_levels.delete(tab_id);
        if (this._set_captured.delete(tab_id)) {
            const capture: CaptureMessage = { type: "capture_stop", tab_id };
            void this._send_to_offscreen(capture);
        }
        this._schedule_report();
    }

    /** The settings a tab's page should apply itself: none while the whole tab is captured instead. */
    private _page_settings(tab_id: number | undefined): TrackSettings {
        if (tab_id === undefined || this._set_captured.has(tab_id)) {
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
        this._set_captured.add(tab_id);
        await this._send_to_page(tab_id);
        const capture: CaptureMessage = { type: "capture_start", tab_id, stream_id, settings };
        await this._send_to_offscreen(capture);
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
