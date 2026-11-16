import { type PaletteKey, PixelGrid } from "./pixel-grid.ts";

/**
 * One of Rookery's interface icons that are the crow's pixel art: its head, the agent badge, and the crow
 * glyph. The app draws its other icons itself, at full resolution.
 *
 * A badge is drawn in the logo's own way: a dark silhouette lit from the top left and shadowed to the
 * bottom right, with yellow details, outlined in yellow, so it reads on a light background as on a dark
 * one; it keeps its colors. A glyph is a one-color silhouette at the same pixel size, which the app tints
 * like text, for the small marks that follow the text's color and state.
 */
export interface Icon {
    name: string;
    kind: "badge" | "glyph";
    /**
     * The art, one string a row. In a badge: `#` the silhouette, shaded on its own; `k` a dark detail cut
     * into it; `Y`, `L` and `W` yellow, light yellow and white details; `.` nothing. In a glyph: `#` the
     * mark.
     */
    list_rows: readonly string[];
}

/**
 * Rookery's interface icons, and how each is turned into a grid.
 */
export class Icons {
    /** A badge's art is this wide, inside the outline that brings it to 16. */
    static readonly BADGE_ART_SIZE = 14;
    static readonly GLYPH_SIZE = 12;

    static readonly LIST_BADGES: readonly Icon[] = [
        Icons.badge("agent", [
            "..............",
            "....#####.....",
            "..#########...",
            ".###########..",
            ".#######WW##..",
            ".#######Wk###.",
            "############YY",
            "###########YYL",
            "###########LL.",
            ".##########...",
            "..#########...",
            "...#######....",
            "....#####.....",
            "..............",
        ]),
    ];

    static readonly LIST_GLYPHS: readonly Icon[] = [
        Icons.glyph("crow", [
            "............",
            "......###...",
            ".....#####..",
            ".....##.####",
            ".....####...",
            "...######...",
            "..#######...",
            ".########...",
            "#########...",
            "...#####....",
            "....#..#....",
            "...##.##....",
        ]),
    ];

    /**
     * A badge's 16-pixel grid: its art centred, its silhouette shaded, and the yellow outline around it.
     *
     * @param icon - a badge
     * @returns the grid
     */
    static badge_grid(icon: Icon): PixelGrid {
        const size = Icons.BADGE_ART_SIZE + 2;
        const list_padded = ["".padEnd(size, "."), ...icon.list_rows.map((row) => `.${row}.`), "".padEnd(size, ".")];
        const is_body = (x: number, y: number): boolean => {
            const key = list_padded[y]?.[x];
            return key === "#" || key === "k";
        };
        const list_keys = list_padded.map((row, y) => [...row].map((key, x): PaletteKey => {
            switch (key) {
                case "#":
                    if (!is_body(x, y - 1) || !is_body(x - 1, y)) {
                        return "H";
                    }
                    if (!is_body(x, y + 1) || !is_body(x + 1, y)) {
                        return "K";
                    }
                    return "M";
                case "k":
                    return "K";
                case "Y":
                case "L":
                case "W":
                    return key;
                default:
                    return ".";
            }
        }));
        return PixelGrid.from_keys(list_keys).backed("outline", "W");
    }

    /**
     * A glyph's grid: its mark in black, which the app tints.
     *
     * @param icon - a glyph
     * @returns the grid
     */
    static glyph_grid(icon: Icon): PixelGrid {
        return PixelGrid.from_keys(icon.list_rows.map((row) => [...row].map((key): PaletteKey => (key === "#" ? "K" : "."))));
    }

    private static badge(name: string, list_rows: readonly string[]): Icon {
        Icons._check(name, list_rows, Icons.BADGE_ART_SIZE);
        return { name, kind: "badge", list_rows };
    }

    private static glyph(name: string, list_rows: readonly string[]): Icon {
        Icons._check(name, list_rows, Icons.GLYPH_SIZE);
        return { name, kind: "glyph", list_rows };
    }

    private static _check(name: string, list_rows: readonly string[], size: number): void {
        if (list_rows.length !== size || list_rows.some((row) => row.length !== size)) {
            throw new Error(`icon ${name} is not ${size} × ${size}`);
        }
    }
}
