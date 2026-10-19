import type { CaptureMessage, TabLevels } from "./messages";
import { MessageSchema } from "./messages";
import { TrackGraph } from "./track-graph";
import type { TrackSettings } from "./track-settings";
import { TrackSettingsSchema } from "./track-settings";

/**
 * Chrome's constraints for capturing a tab's sound by the stream id the background obtained.
 */
export interface TabCaptureConstraints extends MediaTrackConstraints {
    mandatory: {
        chromeMediaSource: "tab";
        chromeMediaSourceId: string;
    };
}

/**
 * A captured tab: the stream of its sound and the track it plays through.
 */
export interface CapturedTab {
    stream: MediaStream;
    graph: TrackGraph;
}

/**
 * The sound of whole tabs, captured at the user's request and played through a track each. Capturing a
 * tab silences it everywhere else, so its sound is heard only as treated here.
 */
class CaptureMixer {
    static readonly CAPTURE_LEVELS_INTERVAL_MS = 100;

    private readonly _context = new AudioContext();
    private readonly _map_tabs = new Map<number, CapturedTab>();
    private _levels_timer: number | undefined;

    /**
     * Start taking the background's requests.
     */
    start(): void {
        chrome.runtime.onMessage.addListener(
            (message: unknown, _sender, send_response) => this._receive(message, send_response),
        );
    }

    private _receive(message: unknown, send_response: (response: unknown) => void): boolean {
        const tab_id = MessageSchema.field(message, "tab_id");
        if (typeof tab_id !== "number") {
            return false;
        }
        const settings = TrackSettingsSchema.parse(MessageSchema.field(message, "settings"));
        switch (MessageSchema.type_of(message)) {
            case "capture_start": {
                const stream_id = MessageSchema.field(message, "stream_id");
                if (typeof stream_id === "string" && settings !== undefined) {
                    void this._capture({ tab_id, stream_id, settings });
                }
                break;
            }
            case "capture_apply":
                if (settings !== undefined) {
                    this._map_tabs.get(tab_id)?.graph.apply(settings);
                }
                break;
            case "capture_stop":
                this._stop(tab_id);
                break;
            default:
                return false;
        }
        send_response({});
        return false;
    }

    private async _capture(options: {
        tab_id: number;
        stream_id: string;
        settings: TrackSettings;
    }): Promise<void> {
        this._stop(options.tab_id);
        const constraints: TabCaptureConstraints = {
            mandatory: {
                chromeMediaSource: "tab",
                chromeMediaSourceId: options.stream_id,
            },
        };
        let stream: MediaStream;
        try {
            stream = await navigator.mediaDevices.getUserMedia({ audio: constraints, video: false });
        } catch (err: unknown) {
            if (err instanceof DOMException) {
                this._on_ended(options.tab_id);
                return;
            }
            throw err;
        }
        if (this._context.state !== "running") {
            await this._context.resume();
        }
        const graph = new TrackGraph(this._context, this._context.destination);
        graph.apply(options.settings);
        this._context.createMediaStreamSource(stream).connect(graph.input);
        for (const track of stream.getAudioTracks()) {
            track.addEventListener(
                "ended",
                () => this._on_ended(options.tab_id),
            );
        }
        this._map_tabs.set(options.tab_id, { stream, graph });
        this._update_levels_timer();
    }

    private _on_ended(tab_id: number): void {
        this._stop(tab_id);
        const message: CaptureMessage = { type: "capture_ended", tab_id };
        void chrome.runtime.sendMessage(message);
    }

    private _stop(tab_id: number): void {
        const captured = this._map_tabs.get(tab_id);
        if (captured === undefined) {
            return;
        }
        captured.graph.dispose();
        for (const track of captured.stream.getTracks()) {
            track.stop();
        }
        this._map_tabs.delete(tab_id);
        this._update_levels_timer();
    }

    private _update_levels_timer(): void {
        if (this._map_tabs.size > 0 && this._levels_timer === undefined) {
            this._levels_timer = window.setInterval(
                () => this._send_levels(),
                CaptureMixer.CAPTURE_LEVELS_INTERVAL_MS,
            );
        } else if (this._map_tabs.size === 0 && this._levels_timer !== undefined) {
            window.clearInterval(this._levels_timer);
            this._levels_timer = undefined;
        }
    }

    private _send_levels(): void {
        const list_levels: TabLevels[] = [...this._map_tabs].map(
            ([tab_id, captured]) => ({ tab_id, ...captured.graph.read_levels() }),
        );
        const message: CaptureMessage = { type: "capture_levels", list_levels };
        void chrome.runtime.sendMessage(message);
    }
}

new CaptureMixer().start();
