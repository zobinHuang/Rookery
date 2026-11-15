import { type PaletteKey, PixelGrid } from "./pixel-grid.ts";

/**
 * The name "ROOKERY" in a pixel font drawn here, five by seven pixels a letter, set in the crow's style:
 * black letters standing up off the page on a dark grey side, which the yellow outline then rings.
 */
export class Wordmark {
    static readonly TEXT = "ROOKERY";
    /** How many logo pixels across one pixel of the font is. */
    static readonly FONT_SCALE = 4;
    /** Font pixels between letters. */
    static readonly LETTER_GAP = 1;
    /** How far below its face a letter's side shows, in logo pixels. */
    static readonly DEPTH = 2;
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
     * @returns the grid, with room below for the letters' side
     * @throws Error when the text holds a letter the font lacks
     */
    static grid(): PixelGrid {
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
        const face = PixelGrid.parse(list_face_rows).enlarged(Wordmark.FONT_SCALE);
        const side = PixelGrid.from_keys(face.list_rows.map((row) => row.map((key): PaletteKey => (key === "." ? "." : "G"))));
        const width = font_width * Wordmark.FONT_SCALE;
        const height = glyph_height * Wordmark.FONT_SCALE + Wordmark.DEPTH;
        const list_placements = Array.from({ length: Wordmark.DEPTH }, (_, step) => ({ grid: side, left: 0, top: Wordmark.DEPTH - step }));
        return PixelGrid.compose(width, height, [...list_placements, { grid: face, left: 0, top: 0 }]);
    }
}
