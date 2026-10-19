import type { PageMessage, PageMode } from "./messages";
import { MessageSchema } from "./messages";
import { PagePicture } from "./page-picture";
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
}

/**
 * What every MuxShots script that has run in a page shares: the page's audio once wired, and how to stop
 * the script running the page now, as a newer one takes over.
 */
export interface PageState {
    audio: PageAudio | undefined;
    retire: () => void;
}

declare global {
    var muxshots_page: PageState | undefined;
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
    /** The media events after which the frame may have a different video playing. */
    static readonly LIST_VIDEO_EVENTS: readonly string[] = ["playing", "pause", "emptied", "ended", "loadedmetadata"];

    private _settings: TrackSettings = TrackSettingsSchema.make_neutral();
    private readonly _set_blocked = new Set<HTMLMediaElement>();
    private _levels_timer: number | undefined;
    private _mode: PageMode | undefined;
    private _is_retired = false;
    /** Whether the app shows this page's meter, so its levels are worth measuring. */
    private _is_meter_wanted = false;
    private readonly _on_play_listener = (event: Event): void => this._on_play(event);
    private readonly _on_video_listener = (): void => this._report_video();
    private _picture: PagePicture | undefined;
    private _video_area = 0;

    /**
     * Start following the page's media and the settings the background sends, taking the page's audio
     * over from an earlier script if one wired it.
     */
    async start(): Promise<void> {
        const previous = globalThis.muxshots_page;
        previous?.retire();
        globalThis.muxshots_page = {
            audio: previous?.audio,
            retire: () => this._retire(),
        };
        if (previous?.audio !== undefined) {
            this._start_levels();
        }
        chrome.runtime.onMessage.addListener(
            (message: unknown, _sender, send_response) => this._receive(message, send_response),
        );
        document.addEventListener("play", this._on_play_listener, true);
        for (const event_name of PageMixer.LIST_VIDEO_EVENTS) {
            document.addEventListener(event_name, this._on_video_listener, true);
        }
        const hello: PageMessage = { type: "page_hello" };
        const reply: unknown = await chrome.runtime.sendMessage(hello);
        const settings = TrackSettingsSchema.parse(MessageSchema.field(reply, "settings"));
        this._is_meter_wanted = MessageSchema.field(reply, "is_meter_wanted") === true;
        await this._apply(settings ?? TrackSettingsSchema.make_neutral());
    }

    private _receive(message: unknown, send_response: (response: unknown) => void): boolean {
        if (this._is_retired) {
            return false;
        }
        switch (MessageSchema.type_of(message)) {
            case "page_apply": {
                const settings = TrackSettingsSchema.parse(MessageSchema.field(message, "settings"));
                if (settings !== undefined) {
                    void this._apply(settings);
                }
                break;
            }
            case "page_picture_start":
                void this._start_picture(send_response);
                return true;
            case "page_picture_answer": {
                const sdp = MessageSchema.field(message, "sdp");
                if (typeof sdp === "string") {
                    void this._picture?.accept(sdp);
                }
                break;
            }
            case "page_meter":
                this._is_meter_wanted = MessageSchema.field(message, "is_wanted") === true;
                break;
            case "page_picture_stop":
                this._picture?.stop();
                this._picture = undefined;
                break;
            case "page_picture_control": {
                const is_playing = MessageSchema.field(message, "is_playing");
                if (typeof is_playing === "boolean") {
                    void this._picture?.control(is_playing);
                }
                break;
            }
            default:
                return false;
        }
        send_response({});
        return false;
    }

    /** Start streaming the frame's video, answering with the stream's offer, or with none if it cannot be. */
    private async _start_picture(send_response: (response: unknown) => void): Promise<void> {
        this._picture?.stop();
        this._picture = PagePicture.start();
        send_response({ sdp: this._picture === undefined ? null : await this._picture.offer() });
    }

    /** Tell the background how large a video this frame plays, so it knows which frame to show. */
    private _report_video(): void {
        const area = PagePicture.largest_video_area();
        if (area === this._video_area || this._is_retired) {
            return;
        }
        this._video_area = area;
        const message: PageMessage = { type: "page_video", area };
        void chrome.runtime.sendMessage(message);
    }

    private async _apply(settings: TrackSettings): Promise<void> {
        this._settings = settings;
        globalThis.muxshots_page?.audio?.graph.apply(settings);
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
        const existing = globalThis.muxshots_page?.audio;
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
        };
        if (globalThis.muxshots_page !== undefined) {
            globalThis.muxshots_page.audio = audio;
        }
        return audio;
    }

    private _report(): void {
        const routed_count = globalThis.muxshots_page?.audio?.routed_count ?? 0;
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
        const audio = globalThis.muxshots_page?.audio;
        if (audio === undefined || !this._settings.is_taken_over || !this._is_meter_wanted) {
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
        for (const event_name of PageMixer.LIST_VIDEO_EVENTS) {
            document.removeEventListener(event_name, this._on_video_listener, true);
        }
        this._picture?.stop();
        this._picture = undefined;
    }

    /** Leave the page's sound untouched, as the extension that set it up was updated or removed. */
    private _orphan(): void {
        this._retire();
        this._settings = TrackSettingsSchema.make_neutral();
        globalThis.muxshots_page?.audio?.graph.apply(this._settings);
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
