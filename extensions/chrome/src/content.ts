import type { PageMessage, PageMode } from "./messages";
import { MessageSchema } from "./messages";
import { TrackGraph } from "./track-graph";
import type { TrackSettings } from "./track-settings";
import { TrackSettingsSchema } from "./track-settings";

/**
 * A page's own sound, processed through the mixer by routing its audio and video elements into a track
 * of its own. An element is routed only once the page is taken over and only when its sound can be
 * processed: protected media and media from other sites without permission would fall silent instead,
 * so they are left alone and the page reports itself blocked.
 */
class PageMixer {
    static readonly MIXER_LEVELS_INTERVAL_MS = 100;
    static readonly MEDIA_SELECTOR = "audio, video";
    static readonly LIST_PROCESSABLE_SCHEMES: readonly string[] = ["blob:", "data:"];

    private _settings: TrackSettings = TrackSettingsSchema.make_neutral();
    private _context: AudioContext | undefined;
    private _graph: TrackGraph | undefined;
    private readonly _set_routed = new WeakSet<HTMLMediaElement>();
    private _routed_count = 0;
    private readonly _set_blocked = new Set<HTMLMediaElement>();
    private _levels_timer: number | undefined;
    private _mode: PageMode = "idle";

    /**
     * Start following the page's media and the settings the background sends.
     */
    async start(): Promise<void> {
        chrome.runtime.onMessage.addListener(
            (message: unknown, _sender, send_response) => this._receive(message, send_response),
        );
        document.addEventListener(
            "play",
            (event) => this._on_play(event),
            true,
        );
        const hello: PageMessage = { type: "page_hello" };
        const reply: unknown = await chrome.runtime.sendMessage(hello);
        const settings = TrackSettingsSchema.parse(MessageSchema.field(reply, "settings"));
        if (settings !== undefined) {
            await this._apply(settings);
        }
    }

    private _receive(message: unknown, send_response: (response: unknown) => void): boolean {
        if (MessageSchema.type_of(message) !== "page_apply") {
            return false;
        }
        const settings = TrackSettingsSchema.parse(MessageSchema.field(message, "settings"));
        if (settings !== undefined) {
            void this._apply(settings);
        }
        send_response({});
        return false;
    }

    private async _apply(settings: TrackSettings): Promise<void> {
        this._settings = settings;
        this._graph?.apply(settings);
        if (settings.is_taken_over) {
            for (const element of document.querySelectorAll<HTMLMediaElement>(PageMixer.MEDIA_SELECTOR)) {
                if (!element.paused) {
                    await this._route(element);
                }
            }
        }
        this._report();
    }

    private _on_play(event: Event): void {
        if (event.target instanceof HTMLMediaElement && this._settings.is_taken_over) {
            void this._route(event.target).then(() => this._report());
        }
    }

    /** Send an element's sound through the track, if it can be processed. */
    private async _route(element: HTMLMediaElement): Promise<void> {
        if (this._set_routed.has(element)) {
            return;
        }
        if (!PageMixer._is_processable(element)) {
            this._set_blocked.add(element);
            return;
        }
        const context = this._context ?? new AudioContext();
        this._context = context;
        if (context.state !== "running") {
            await context.resume();
        }
        if (context.state !== "running" || this._set_routed.has(element)) {
            return;
        }
        const graph = this._graph ?? new TrackGraph(context, context.destination);
        if (this._graph === undefined) {
            graph.apply(this._settings);
            this._graph = graph;
        }
        context.createMediaElementSource(element).connect(graph.input);
        this._set_routed.add(element);
        this._routed_count += 1;
        this._set_blocked.delete(element);
        this._start_levels();
    }

    private _report(): void {
        const mode: PageMode = !this._settings.is_taken_over
            ? "idle"
            : this._routed_count > 0 ? "page" : this._set_blocked.size > 0 ? "blocked" : "waiting";
        if (mode === this._mode) {
            return;
        }
        this._mode = mode;
        const message: PageMessage = { type: "page_state", mode };
        void chrome.runtime.sendMessage(message);
    }

    private _start_levels(): void {
        if (this._levels_timer !== undefined) {
            return;
        }
        this._levels_timer = window.setInterval(
            () => this._send_levels(),
            PageMixer.MIXER_LEVELS_INTERVAL_MS,
        );
    }

    private _send_levels(): void {
        if (chrome.runtime?.id === undefined) {
            this._orphan();
            return;
        }
        if (this._graph === undefined || !this._settings.is_taken_over) {
            return;
        }
        const message: PageMessage = { type: "page_levels", levels: this._graph.read_levels() };
        void chrome.runtime.sendMessage(message);
    }

    /** Leave the page's sound untouched for good, as the extension that set it up was updated or removed. */
    private _orphan(): void {
        window.clearInterval(this._levels_timer);
        this._levels_timer = undefined;
        this._settings = TrackSettingsSchema.make_neutral();
        this._graph?.apply(this._settings);
    }

    /** Whether the element's sound reaches Web Audio, rather than arriving as silence. */
    private static _is_processable(element: HTMLMediaElement): boolean {
        const source = element.currentSrc;
        if (element.mediaKeys !== null || source === "") {
            return false;
        }
        if (PageMixer.LIST_PROCESSABLE_SCHEMES.some((scheme) => source.startsWith(scheme))) {
            return true;
        }
        return element.crossOrigin !== null || new URL(source, location.href).origin === location.origin;
    }
}

void new PageMixer().start();
