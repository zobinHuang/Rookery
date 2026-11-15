import { type PaletteKey, PixelGrid } from "./pixel-grid.ts";

/**
 * The name "ROOKERY" in a pixel font drawn here, five by seven pixels a letter, set in the crow's style:
 * black letters standing up off the page on a dark grey side, which the yellow outline then rings.
 */
export class Wordmark {
    static readonly TEXT = "ROOKERY";
    /** How many logo pixels across one pixel of the font is, unless asked otherwise. */
    static readonly FONT_SCALE = 4;
    /** Font pixels between letters. */
    static readonly LETTER_GAP = 1;
    static readonly MAP_GLYPHS: ReadonlyMap<string, readonly string[]> = new Map([
        ["R", [
            "####.",
            "#...#",
            "#...#",
            "####.",
            "#.#..",
            "#..#.",
            "#...#",
        ]],
        ["O", [
            ".###.",
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            "#...#",
            ".###.",
        ]],
        ["K", [
            "#...#",
            "#..#.",
            "#.#..",
            "##...",
            "#.#..",
            "#..#.",
            "#...#",
        ]],
        ["E", [
            "#####",
            "#....",
            "#....",
            "####.",
            "#....",
            "#....",
            "#####",
        ]],
        ["Y", [
            "#...#",
            "#...#",
            ".#.#.",
            "..#..",
            "..#..",
            "..#..",
            "..#..",
        ]],
    ]);

    /**
     * The wordmark, before any backing.
     *
     * @param font_scale - how many logo pixels across one pixel of the font is
     * @returns the grid, with room below for the letters' side, half a font pixel deep
     * @throws Error when the text holds a letter the font lacks
     */
    static grid(font_scale: number = Wordmark.FONT_SCALE): PixelGrid {
        const depth = Math.max(1, Math.floor(font_scale / 2));
        const list_glyphs = [...Wordmark.TEXT].map((letter) => {
            const glyph = Wordmark.MAP_GLYPHS.get(letter);
            if (glyph === undefined) {
                throw new Error(`the wordmark font has no "${letter}"`);
            }
            return glyph;
        });
        const glyph_width = list_glyphs[0]?.[0]?.length ?? 0;
        const glyph_height = list_glyphs[0]?.length ?? 0;
        const font_width = list_glyphs.length * (glyph_width + Wordmark.LETTER_GAP) - Wordmark.LETTER_GAP;
        const list_face_rows = Array.from({ length: glyph_height }, (_, y) => list_glyphs
            .map((glyph) => (glyph[y] ?? "").replaceAll("#", "K"))
            .join(".".repeat(Wordmark.LETTER_GAP)));
        const face = PixelGrid.parse(list_face_rows).enlarged(font_scale);
        const side = PixelGrid.from_keys(face.list_rows.map((row) => row.map((key): PaletteKey => (key === "." ? "." : "G"))));
        const width = font_width * font_scale;
        const height = glyph_height * font_scale + depth;
        const list_placements = Array.from({ length: depth }, (_, step) => ({ grid: side, left: 0, top: depth - step }));
        return PixelGrid.compose(width, height, [...list_placements, { grid: face, left: 0, top: 0 }]);
    }
}
