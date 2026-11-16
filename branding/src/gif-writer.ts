import type { Animation } from "./animation.ts";
import { type ColorKey, PixelGrid } from "./pixel-grid.ts";

/**
 * Encodes a pixel animation as a looping GIF89a: every palette color in one global table, the empty pixels
 * transparent, each frame held for its share of the loop.
 */
export class GifWriter {
    /** The global table holds this many colors: the palette, the transparent slot, and padding. */
    static readonly TABLE_SIZE = 16;
    static readonly TABLE_BITS = 4;
    static readonly TRANSPARENT_INDEX = 0;
    static readonly MAX_CODE_SIZE = 12;
    static readonly CENTISECONDS_PER_SECOND = 100;
    static readonly SUB_BLOCK_MAX = 255;

    /**
     * The animation as a GIF.
     *
     * @param animation - the frames and their order
     * @param scale - how many GIF pixels a grid pixel becomes
     * @returns the file's bytes
     */
    static encode(animation: Animation, scale: number): Buffer {
        const list_keys = Object.keys(PixelGrid.PALETTE_COLORS) as ColorKey[];
        const map_indices = new Map<string, number>(list_keys.map((key, index) => [key, index + 1]));
        const width = animation.width * scale;
        const height = animation.height * scale;
        const list_parts: Buffer[] = [Buffer.from("GIF89a", "ascii")];
        const screen = Buffer.alloc(7);
        screen.writeUInt16LE(width, 0);
        screen.writeUInt16LE(height, 2);
        screen[4] = 0x80 | ((GifWriter.TABLE_BITS - 1) << 4) | (GifWriter.TABLE_BITS - 1);
        list_parts.push(screen);
        const table = Buffer.alloc(GifWriter.TABLE_SIZE * 3);
        list_keys.forEach((key, index) => {
            const hex = PixelGrid.PALETTE_COLORS[key];
            for (let channel = 0; channel < 3; channel += 1) {
                table[(index + 1) * 3 + channel] = parseInt(hex.slice(1 + channel * 2, 3 + channel * 2), 16);
            }
        });
        list_parts.push(table);
        list_parts.push(Buffer.from([0x21, 0xff, 0x0b, ...Buffer.from("NETSCAPE2.0", "ascii"), 0x03, 0x01, 0x00, 0x00, 0x00]));
        const delay = Math.round(GifWriter.CENTISECONDS_PER_SECOND / animation.frames_per_second);
        for (const run of GifWriter._runs(animation.list_sequence)) {
            const frame = animation.list_frames[run.frame_index];
            if (frame === undefined) {
                continue;
            }
            const control = Buffer.from([0x21, 0xf9, 0x04, 0x09, 0, 0, GifWriter.TRANSPARENT_INDEX, 0x00]);
            control.writeUInt16LE(delay * run.length, 4);
            list_parts.push(control);
            const descriptor = Buffer.alloc(10);
            descriptor[0] = 0x2c;
            descriptor.writeUInt16LE(width, 5);
            descriptor.writeUInt16LE(height, 7);
            list_parts.push(descriptor);
            const list_pixels: number[] = [];
            const enlarged = frame.enlarged(scale);
            for (const row of enlarged.list_rows) {
                for (const key of row) {
                    list_pixels.push(map_indices.get(key) ?? GifWriter.TRANSPARENT_INDEX);
                }
            }
            list_parts.push(Buffer.from([GifWriter.TABLE_BITS]));
            list_parts.push(GifWriter._sub_blocks(GifWriter._lzw(list_pixels, GifWriter.TABLE_BITS)));
        }
        list_parts.push(Buffer.from([0x3b]));
        return Buffer.concat(list_parts);
    }

    /** The sequence as runs of one frame, so a held frame is written once with a longer delay. */
    private static _runs(list_sequence: readonly number[]): { frame_index: number; length: number }[] {
        const list_runs: { frame_index: number; length: number }[] = [];
        for (const frame_index of list_sequence) {
            const last = list_runs[list_runs.length - 1];
            if (last !== undefined && last.frame_index === frame_index) {
                last.length += 1;
            } else {
                list_runs.push({ frame_index, length: 1 });
            }
        }
        return list_runs;
    }

    /** Variable-length LZW, as GIF wants it: codes packed least significant bit first. */
    private static _lzw(list_pixels: readonly number[], minimum_code_size: number): Buffer {
        const clear_code = 1 << minimum_code_size;
        const end_code = clear_code + 1;
        const list_bytes: number[] = [];
        let bit_buffer = 0;
        let bit_count = 0;
        let code_size = minimum_code_size + 1;
        const emit = (code: number): void => {
            bit_buffer |= code << bit_count;
            bit_count += code_size;
            while (bit_count >= 8) {
                list_bytes.push(bit_buffer & 0xff);
                bit_buffer >>>= 8;
                bit_count -= 8;
            }
        };
        let map_dictionary = new Map<string, number>();
        let next_code = end_code + 1;
        emit(clear_code);
        let prefix = "";
        for (const pixel of list_pixels) {
            const candidate = prefix === "" ? `${pixel}` : `${prefix},${pixel}`;
            if (prefix === "" || map_dictionary.has(candidate)) {
                prefix = candidate;
                continue;
            }
            emit(GifWriter._code_of(prefix, map_dictionary));
            map_dictionary.set(candidate, next_code);
            next_code += 1;
            if (next_code > (1 << code_size) && code_size < GifWriter.MAX_CODE_SIZE) {
                code_size += 1;
            }
            if (next_code >= (1 << GifWriter.MAX_CODE_SIZE)) {
                emit(clear_code);
                map_dictionary = new Map<string, number>();
                next_code = end_code + 1;
                code_size = minimum_code_size + 1;
            }
            prefix = `${pixel}`;
        }
        if (prefix !== "") {
            emit(GifWriter._code_of(prefix, map_dictionary));
        }
        emit(end_code);
        if (bit_count > 0) {
            list_bytes.push(bit_buffer & 0xff);
        }
        return Buffer.from(list_bytes);
    }

    private static _code_of(prefix: string, map_dictionary: ReadonlyMap<string, number>): number {
        return prefix.includes(",") ? (map_dictionary.get(prefix) ?? 0) : Number(prefix);
    }

    private static _sub_blocks(data: Buffer): Buffer {
        const list_parts: Buffer[] = [];
        for (let offset = 0; offset < data.length; offset += GifWriter.SUB_BLOCK_MAX) {
            const chunk = data.subarray(offset, offset + GifWriter.SUB_BLOCK_MAX);
            list_parts.push(Buffer.from([chunk.length]), chunk);
        }
        list_parts.push(Buffer.from([0]));
        return Buffer.concat(list_parts);
    }
}
