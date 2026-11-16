import { type ColorKey, type PaletteKey, PixelGrid } from "./pixel-grid.ts";

/**
 * A small picture stamped over a frame, one string of palette keys per row, `.` where it lets the frame
 * show through.
 */
export type Sprite = readonly string[];

/**
 * The marks that float around a crow to say what it is doing, and how they are stamped onto a frame: in
 * yellow, edged in black so they read on a light background as well as a dark one.
 */
export class Sprites {
    /** A thought's dot. */
    static readonly DOT: Sprite = [
        "YY",
        "YL",
    ];
    static readonly QUESTION: Sprite = [
        ".YYY.",
        "YL..Y",
        "...LY",
        "..YY.",
        "..Y..",
        ".....",
        "..Y..",
    ];
    static readonly EXCLAMATION: Sprite = [
        "YY",
        "LY",
        "YY",
        "YY",
        "YY",
        "..",
        "YY",
    ];
    static readonly SMALL_Z: Sprite = [
        "YYY",
        "..Y",
        ".Y.",
        "YYY",
    ];
    static readonly LARGE_Z: Sprite = [
        "YYYYY",
        "...Y.",
        "..Y..",
        ".Y...",
        "YYYYY",
    ];
    /** An hourglass with its sand still up top. */
    static readonly HOURGLASS_FULL: Sprite = [
        "KKKKKKK",
        ".YLLLY.",
        "..YLY..",
        "...Y...",
        "..Y.Y..",
        ".Y...Y.",
        "KKKKKKK",
    ];
    /** Half the sand run through. */
    static readonly HOURGLASS_HALF: Sprite = [
        "KKKKKKK",
        ".Y...Y.",
        "..YLY..",
        "...L...",
        "..YLY..",
        ".Y.L.Y.",
        "KKKKKKK",
    ];
    /** All the sand run through. */
    static readonly HOURGLASS_EMPTY: Sprite = [
        "KKKKKKK",
        ".Y...Y.",
        "..Y.Y..",
        "...Y...",
        "..YLY..",
        ".YLLLY.",
        "KKKKKKK",
    ];
    static readonly CHECK: Sprite = [
        "......YY",
        ".....YY.",
        "YY..YY..",
        ".YYYY...",
        "..YY....",
    ];
    static readonly BOLT: Sprite = [
        "...YY",
        "..YY.",
        ".YYLY",
        "YLYY.",
        "..YY.",
        ".YY..",
        ".Y...",
    ];
    /** Code angle brackets around a slash: the agent is at work on code. */
    static readonly CODE: Sprite = [
        "..Y.....Y..",
        ".Y....Y..Y.",
        "Y....Y....Y",
        ".Y..Y....Y.",
        "..Y.Y...Y..",
    ];
    /** A spark thrown off where the beak strikes. */
    static readonly SPARK: Sprite = [
        ".L.",
        "LWL",
        ".L.",
    ];
    /** One arc of a caw's sound, opening to the right. */
    static readonly WAVE: Sprite = [
        "Y.",
        ".Y",
        ".Y",
        ".Y",
        "Y.",
    ];
    /** A speck being drawn in as the context is compacted. */
    static readonly SPECK: Sprite = [
        "L",
    ];

    /**
     * A sprite's key in a state's color: its yellow becomes the tint, and its light yellow white, so a mark
     * reads in the state's color.
     *
     * @param key - the sprite's key
     * @param tint - the state's color
     * @returns the key to draw
     */
    static tinted(key: PaletteKey, tint: ColorKey): PaletteKey {
        if (tint === "Y") {
            return key;
        }
        if (key === "Y") {
            return tint;
        }
        return key === "L" ? "W" : key;
    }

    /**
     * Stamp a sprite onto a frame, edging its yellow in black where it meets empty pixels.
     *
     * @param list_rows - the frame, changed in place
     * @param sprite - the sprite
     * @param left - the column of the sprite's left edge, rounded to a pixel
     * @param top - the row of the sprite's top edge, rounded to a pixel
     * @param tint - the state's color, which the sprite's yellow takes
     */
    static stamp(list_rows: PaletteKey[][], sprite: Sprite, left: number, top: number, tint: ColorKey = "Y"): void {
        const x0 = Math.round(left);
        const y0 = Math.round(top);
        const is_inside = (x: number, y: number): boolean => (sprite[y - y0]?.[x - x0] ?? ".") !== ".";
        for (let y = y0 - 1; y <= y0 + sprite.length; y += 1) {
            const row = list_rows[y];
            if (row === undefined) {
                continue;
            }
            for (let x = x0 - 1; x <= x0 + (sprite[0]?.length ?? 0); x += 1) {
                if (x < 0 || x >= row.length) {
                    continue;
                }
                const key = sprite[y - y0]?.[x - x0] ?? ".";
                if (key !== ".") {
                    row[x] = Sprites.tinted(PixelGrid.palette_key(key), tint);
                } else if (row[x] === "." && (is_inside(x - 1, y) || is_inside(x + 1, y) || is_inside(x, y - 1) || is_inside(x, y + 1))) {
                    row[x] = "K";
                }
            }
        }
    }
}
