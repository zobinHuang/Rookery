import type { PageMessage } from "./messages";

/**
 * A page's video shown in the MuxShots sidebar, streamed to the app over a WebRTC connection on this
 * machine: the video's own track, encoded by the browser and played by the app, so no frame passes
 * through the extension. The track comes from a capture of the video element, which keeps playing even
 * while its tab is in the background.
 */
export class PagePicture {
    static readonly MEDIA_SELECTOR_VIDEO = "video";
    /** The widest the streamed video needs to be, for the sidebar. */
    static readonly STREAM_MAX_WIDTH = 640;
    static readonly STREAM_MAX_BITRATE = 1_500_000;
    static readonly STREAM_MAX_FRAMERATE = 30;
    /** How long to wait for the connection's addresses before offering it with those found so far. */
    static readonly ICE_GATHERING_TIMEOUT_MS = 2000;
    static readonly LIST_FAILED_STATES: readonly RTCPeerConnectionState[] = ["failed", "closed"];
    /** The codec both ends encode and decode in hardware, offered first. */
    static readonly CODEC_PREFERRED_MIME_TYPE = "video/H264";
    /** H.264's packetization that both browsers and the system decoder take. */
    static readonly CODEC_PACKETIZATION_MODE = "packetization-mode=1";

    private readonly _video: HTMLVideoElement;
    private readonly _track: MediaStreamTrack;
    private readonly _connection = new RTCPeerConnection();
    private _is_stopped = false;
    private readonly _on_play_state = (): void => this._send_state();

    private constructor(video: HTMLVideoElement, track: MediaStreamTrack) {
        this._video = video;
        this._track = track;
    }

    /**
     * The frame's largest playing video, as how much of the page it covers, for choosing which frame of
     * a tab shows its video.
     *
     * @returns the video's area in pixels, 0 when nothing plays
     */
    static largest_video_area(): number {
        const video = PagePicture._largest_video();
        return video === undefined ? 0 : video.clientWidth * video.clientHeight;
    }

    /**
     * Start streaming the frame's largest video.
     *
     * @returns the picture, or undefined when no video can be streamed, as for protected or cross-site video
     */
    static start(): PagePicture | undefined {
        const video = PagePicture._largest_video() ?? PagePicture._any_video();
        if (video === undefined || video.mediaKeys !== null) {
            return undefined;
        }
        let stream: MediaStream;
        try {
            stream = video.captureStream();
        } catch (err: unknown) {
            if (err instanceof DOMException) {
                return undefined;
            }
            throw err;
        }
        const track = stream.getVideoTracks()[0];
        if (track === undefined) {
            return undefined;
        }
        return new PagePicture(video, track);
    }

    /**
     * Offer the stream to the app.
     *
     * @returns the offer's session description, with every address the app can reach it at
     */
    async offer(): Promise<string> {
        const transceiver = this._connection.addTransceiver(this._track, {
            direction: "sendonly",
            streams: [new MediaStream([this._track])],
        });
        transceiver.setCodecPreferences(PagePicture._codecs_hardware_first());
        this._connection.addEventListener(
            "connectionstatechange",
            () => this._on_connection_state(),
        );
        this._video.addEventListener("play", this._on_play_state);
        this._video.addEventListener("pause", this._on_play_state);
        await this._connection.setLocalDescription(await this._connection.createOffer());
        await this._gathered();
        return this._connection.localDescription?.sdp ?? "";
    }

    /**
     * Take the app's answer, which starts the stream.
     *
     * @param sdp - the answer's session description
     */
    async accept(sdp: string): Promise<void> {
        await this._connection.setRemoteDescription({ type: "answer", sdp });
        const sender = this._connection.getSenders()[0];
        if (sender === undefined) {
            return;
        }
        const parameters = sender.getParameters();
        const scale = Math.max(1, this._video.videoWidth / PagePicture.STREAM_MAX_WIDTH);
        parameters.encodings = parameters.encodings.map((encoding) => ({
            ...encoding,
            maxBitrate: PagePicture.STREAM_MAX_BITRATE,
            maxFramerate: PagePicture.STREAM_MAX_FRAMERATE,
            scaleResolutionDownBy: scale,
        }));
        await sender.setParameters(parameters);
        this._send_state();
    }

    /**
     * Stop streaming.
     */
    stop(): void {
        if (this._is_stopped) {
            return;
        }
        this._is_stopped = true;
        this._video.removeEventListener("play", this._on_play_state);
        this._video.removeEventListener("pause", this._on_play_state);
        this._connection.close();
        this._track.stop();
    }

    /**
     * Play or pause the video.
     *
     * @param is_playing - whether it should play
     */
    async control(is_playing: boolean): Promise<void> {
        if (is_playing) {
            await this._video.play();
        } else {
            this._video.pause();
        }
    }

    /** Wait until the connection knows its addresses, or a little while at most. */
    private async _gathered(): Promise<void> {
        if (this._connection.iceGatheringState === "complete") {
            return;
        }
        await new Promise<void>((resolve) => {
            const timer = setTimeout(resolve, PagePicture.ICE_GATHERING_TIMEOUT_MS);
            this._connection.addEventListener("icegatheringstatechange", () => {
                if (this._connection.iceGatheringState === "complete") {
                    clearTimeout(timer);
                    resolve();
                }
            });
        });
    }

    private _on_connection_state(): void {
        if (this._is_stopped || !PagePicture.LIST_FAILED_STATES.includes(this._connection.connectionState)) {
            return;
        }
        this.stop();
        const message: PageMessage = { type: "page_picture_ended" };
        void chrome.runtime.sendMessage(message);
    }

    /** Tell the app the video was paused or played. */
    private _send_state(): void {
        const message: PageMessage = { type: "page_picture_state", is_paused: this._video.paused };
        void chrome.runtime.sendMessage(message);
    }

    /** Every video codec the browser sends, H.264 first so neither end encodes or decodes in software. */
    private static _codecs_hardware_first(): RTCRtpCodec[] {
        const list_codecs = RTCRtpSender.getCapabilities("video")?.codecs ?? [];
        return [
            ...list_codecs.filter((codec) => PagePicture._is_hardware_codec(codec)),
            ...list_codecs.filter((codec) => !PagePicture._is_hardware_codec(codec)),
        ];
    }

    private static _is_hardware_codec(codec: RTCRtpCodec): boolean {
        return codec.mimeType === PagePicture.CODEC_PREFERRED_MIME_TYPE
            && (codec.sdpFmtpLine?.includes(PagePicture.CODEC_PACKETIZATION_MODE) ?? false);
    }

    private static _largest_video(): HTMLVideoElement | undefined {
        let best: HTMLVideoElement | undefined;
        let best_area = 0;
        for (const video of document.querySelectorAll<HTMLVideoElement>(PagePicture.MEDIA_SELECTOR_VIDEO)) {
            const area = video.clientWidth * video.clientHeight;
            if (!video.paused && video.videoWidth > 0 && area > best_area) {
                best = video;
                best_area = area;
            }
        }
        return best;
    }

    private static _any_video(): HTMLVideoElement | undefined {
        return [...document.querySelectorAll<HTMLVideoElement>(PagePicture.MEDIA_SELECTOR_VIDEO)].find(
            (video) => video.videoWidth > 0,
        );
    }
}
