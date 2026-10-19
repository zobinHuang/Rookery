/**
 * Chrome's capture of what a media element plays, as a stream.
 */
interface HTMLMediaElement {
    captureStream(): MediaStream;
}

/**
 * Chrome's reader of a video track's frames, one `VideoFrame` at a time as the track produces them.
 */
declare class MediaStreamTrackProcessor {
    constructor(init: { track: MediaStreamTrack });
    readonly readable: ReadableStream<VideoFrame>;
}
