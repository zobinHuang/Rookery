import type { PageMessage, PageMode } from "./messages";
import { MessageSchema } from "./messages";
import { TrackGraph } from "./track-graph";
import type { TrackSettings } from "./track-settings";
import { TrackSettingsSchema } from "./track-settings";

/**
 * The page's audio as the extension has wired it: the context, the track every routed element plays
 * through, and which elements are routed. An element can be routed only once in its life, so this outlives
 * the script that built it: a script injected after the extension is updated takes it over.
 */
export interface PageAudio {
    context: AudioContext;
    graph: TrackGraph;
    set_routed: WeakSet<HTMLMediaElement>;
    routed_count: number;
    /** Stop the script that is running the page's audio now, as a newer one takes over. */
    retire: () => void;
}

declare global {
    /** The page's audio, shared by every MuxShots script that has run in this page. */
    var muxshots_page_audio: PageAudio | undefined;
}

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
    static readonly ERROR_ALREADY_ROUTED = "InvalidStateError";

    private _settings: TrackSettings = TrackSettingsSchema.make_neutral();
    private readonly _set_blocked = new Set<HTMLMediaElement>();
    private _levels_timer: number | undefined;
    private _mode: PageMode | undefined;
    private _is_retired = false;
    private readonly _on_play_listener = (event: Event): void => this._on_play(event);

    /**
     * Start following the page's media and the settings the background sends, taking the page's audio
     * over from an earlier script if one wired it.
     */
    async start(): Promise<void> {
        const audio = globalThis.muxshots_page_audio;
        if (audio !== undefined) {
            audio.retire();
            audio.retire = () => this._retire();
            this._start_levels();
        }
        chrome.runtime.onMessage.addListener(
            (message: unknown, _sender, send_response) => this._receive(message, send_response),
        );
        document.addEventListener("play", this._on_play_listener, true);
        const hello: PageMessage = { type: "page_hello" };
        const reply: unknown = await chrome.runtime.sendMessage(hello);
        const settings = TrackSettingsSchema.parse(MessageSchema.field(reply, "settings"));
        await this._apply(settings ?? TrackSettingsSchema.make_neutral());
    }

    private _receive(message: unknown, send_response: (response: unknown) => void): boolean {
        if (this._is_retired || MessageSchema.type_of(message) !== "page_apply") {
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
        globalThis.muxshots_page_audio?.graph.apply(settings);
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
        const existing = globalThis.muxshots_page_audio;
        if (existing?.set_routed.has(element) ?? false) {
            return;
        }
        if (!PageMixer._is_processable(element)) {
            this._set_blocked.add(element);
            return;
        }
        const audio = existing ?? this._make_audio();
        if (audio.context.state !== "running") {
            await audio.context.resume();
        }
        if (audio.context.state !== "running" || audio.set_routed.has(element)) {
            return;
        }
        try {
            audio.context.createMediaElementSource(element).connect(audio.graph.input);
        } catch (err: unknown) {
            if (err instanceof DOMException && err.name === PageMixer.ERROR_ALREADY_ROUTED) {
                this._set_blocked.add(element);
                return;
            }
            throw err;
        }
        audio.set_routed.add(element);
        audio.routed_count += 1;
        this._set_blocked.delete(element);
        this._start_levels();
    }

    private _make_audio(): PageAudio {
        const context = new AudioContext();
        const graph = new TrackGraph(context, context.destination);
        graph.apply(this._settings);
        const audio: PageAudio = {
            context,
            graph,
            set_routed: new WeakSet(),
            routed_count: 0,
            retire: () => this._retire(),
        };
        globalThis.muxshots_page_audio = audio;
        return audio;
    }

    private _report(): void {
        const routed_count = globalThis.muxshots_page_audio?.routed_count ?? 0;
        const mode: PageMode = !this._settings.is_taken_over
            ? "idle"
            : routed_count > 0 ? "page" : this._set_blocked.size > 0 ? "blocked" : "waiting";
        if (mode === this._mode || this._is_retired) {
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
        const audio = globalThis.muxshots_page_audio;
        if (audio === undefined || !this._settings.is_taken_over) {
            return;
        }
        const message: PageMessage = { type: "page_levels", levels: audio.graph.read_levels() };
        void chrome.runtime.sendMessage(message);
    }

    /** Stop for good, as a newer script runs the page's audio now. */
    private _retire(): void {
        this._is_retired = true;
        window.clearInterval(this._levels_timer);
        this._levels_timer = undefined;
        document.removeEventListener("play", this._on_play_listener, true);
    }

    /** Leave the page's sound untouched, as the extension that set it up was updated or removed. */
    private _orphan(): void {
        this._retire();
        this._settings = TrackSettingsSchema.make_neutral();
        globalThis.muxshots_page_audio?.graph.apply(this._settings);
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
