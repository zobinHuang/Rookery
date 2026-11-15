import { deflateSync } from "node:zlib";
import { PixelGrid } from "./pixel-grid.ts";

/**
 * Writes a pixel grid as a PNG: eight-bit RGBA, transparent where the grid is empty, one image pixel per
 * grid pixel, so it stays sharp when it is shown at whole multiples of its size.
 */
export class PngWriter {
    static readonly SIGNATURE = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    static readonly BIT_DEPTH = 8;
    static readonly COLOR_TYPE_RGBA = 6;
    static readonly CRC_POLYNOMIAL = 0xedb88320;
    private static readonly _LIST_CRC_TABLE: readonly number[] = Array.from({ length: 256 }, (_, index) => {
        let value = index;
        for (let bit = 0; bit < 8; bit += 1) {
            value = value & 1 ? PngWriter.CRC_POLYNOMIAL ^ (value >>> 1) : value >>> 1;
        }
        return value >>> 0;
    });

    /**
     * Encode a grid.
     *
     * @param grid - the grid
     * @returns the PNG file's bytes
     * @throws Error when the grid holds a key with no fixed color
     */
    static encode(grid: PixelGrid): Buffer {
        const stride = grid.width * 4 + 1;
        const pixels = Buffer.alloc(stride * grid.height);
        grid.list_rows.forEach((row, y) => row.forEach((key, x) => {
            if (key === ".") {
                return;
            }
            if (key === "S") {
                throw new Error("a shadow pixel has no color of its own; give the grid a backing first");
            }
            const hex = PixelGrid.PALETTE_COLORS[key];
            const offset = y * stride + 1 + x * 4;
            for (let channel = 0; channel < 3; channel += 1) {
                pixels[offset + channel] = parseInt(hex.slice(1 + channel * 2, 3 + channel * 2), 16);
            }
            pixels[offset + 3] = 255;
        }));
        const header = Buffer.alloc(13);
        header.writeUInt32BE(grid.width, 0);
        header.writeUInt32BE(grid.height, 4);
        header[8] = PngWriter.BIT_DEPTH;
        header[9] = PngWriter.COLOR_TYPE_RGBA;
        return Buffer.concat([
            PngWriter.SIGNATURE,
            PngWriter._chunk("IHDR", header),
            PngWriter._chunk("IDAT", deflateSync(pixels)),
            PngWriter._chunk("IEND", Buffer.alloc(0)),
        ]);
    }

    private static _chunk(type: string, data: Buffer): Buffer {
        const length = Buffer.alloc(4);
        length.writeUInt32BE(data.length, 0);
        const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
        const crc = Buffer.alloc(4);
        crc.writeUInt32BE(PngWriter._crc(body), 0);
        return Buffer.concat([length, body, crc]);
    }

    private static _crc(bytes: Buffer): number {
        let value = 0xffffffff;
        for (const byte of bytes) {
            value = (PngWriter._LIST_CRC_TABLE[(value ^ byte) & 0xff] ?? 0) ^ (value >>> 8);
        }
        return (value ^ 0xffffffff) >>> 0;
    }
}
