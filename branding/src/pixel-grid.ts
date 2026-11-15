/**
 * A key of the palette: `.` is transparent, the rest name the logo's five colors.
 */
export type PaletteKey = "." | "K" | "G" | "Y" | "L" | "W";

/**
 * One crow, drawn on the 32 by 32 grid and redrawn by hand on the 16 by 16 one for the smallest icons.
 */
export interface CrowDesign {
    name: string;
    title: string;
    note: string;
    list_rows_large: readonly string[];
    list_rows_small: readonly string[];
}

/**
 * How the crow stands out from a dark background: on a yellow tile, or with a yellow outline of its own.
 */
export type Backing = "tile" | "outline" | "none";

/**
 * A square grid of palette keys, one per pixel, and what the logo derives from one: the backings and the
 * SVG drawing. Every pixel is a whole square on an integer position, so nothing is ever blended.
 */
export class PixelGrid {
    /** The logo's colors, five in all. */
    static readonly PALETTE_COLORS: Readonly<Record<Exclude<PaletteKey, ".">, string>> = {
        K: "#0E0E10",
        G: "#2A2A2E",
        Y: "#FFC83D",
        L: "#FFE58A",
        W: "#FFFFFF",
    };
    /** The tile's corner radius against the grid's size. */
    static readonly TILE_CORNER_FRACTION = 5 / 32;
    /** Slack on the corner test, so the rounding steps evenly. */
    static readonly TILE_CORNER_SLACK = 0.3;

    readonly list_rows: readonly (readonly PaletteKey[])[];

    private constructor(list_rows: readonly (readonly PaletteKey[])[]) {
        this.list_rows = list_rows;
    }

    /**
     * Read a grid from its rows, one string of palette keys per row.
     *
     * @param list_rows - the rows, all as long as there are rows
     * @returns the grid
     * @throws Error when the grid is not square or holds a key outside the palette
     */
    static parse(list_rows: readonly string[]): PixelGrid {
        const list_parsed = list_rows.map((row) => {
            if (row.length !== list_rows.length) {
                throw new Error(`row "${row}" is not ${list_rows.length} pixels long`);
            }
            return [...row].map((key) => PixelGrid._palette_key(key));
        });
        return new PixelGrid(list_parsed);
    }

    /** How many pixels the grid is across and down. */
    get size(): number {
        return this.list_rows.length;
    }

    /**
     * The grid with a backing that keeps the black crow visible on a dark background.
     *
     * @param backing - a yellow rounded tile behind it, a yellow outline around it, or none
     * @returns the backed grid
     */
    backed(backing: Backing): PixelGrid {
        switch (backing) {
            case "tile":
                return this._on_tile();
            case "outline":
                return this._outlined();
            case "none":
                return this;
        }
    }

    /**
     * The grid as an SVG of whole-pixel rectangles, one per run of a color along a row.
     *
     * @param pixel_size - the side of one pixel in the SVG's own units
     * @returns the SVG markup
     */
    to_svg(pixel_size: number): string {
        const side = this.size * pixel_size;
        const list_rects: string[] = [];
        this.list_rows.forEach((row, y) => {
            let run_start = 0;
            for (let x = 1; x <= row.length; x += 1) {
                if (x < row.length && row[x] === row[run_start]) {
                    continue;
                }
                const key = row[run_start];
                if (key !== undefined && key !== ".") {
                    list_rects.push(
                        `<rect x="${run_start * pixel_size}" y="${y * pixel_size}" width="${(x - run_start) * pixel_size}" `
                        + `height="${pixel_size}" fill="${PixelGrid.PALETTE_COLORS[key]}"/>`,
                    );
                }
                run_start = x;
            }
        });
        return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${side} ${side}" width="${side}" height="${side}" `
            + `shape-rendering="crispEdges">${list_rects.join("")}</svg>`;
    }

    private static _palette_key(key: string): PaletteKey {
        if (key === "." || key in PixelGrid.PALETTE_COLORS) {
            return key as PaletteKey;
        }
        throw new Error(`"${key}" is not a palette key`);
    }

    private _key_at(x: number, y: number): PaletteKey {
        return this.list_rows[y]?.[x] ?? ".";
    }

    /** Whether any of a pixel's neighbors holds one of some keys. */
    private _touches(x: number, y: number, keys: string, is_diagonal: boolean): boolean {
        for (let dy = -1; dy <= 1; dy += 1) {
            for (let dx = -1; dx <= 1; dx += 1) {
                const is_neighbor = (dx !== 0 || dy !== 0) && (is_diagonal || dx === 0 || dy === 0);
                if (is_neighbor && keys.includes(this._key_at(x + dx, y + dy))) {
                    return true;
                }
            }
        }
        return false;
    }

    /** On a yellow rounded tile, the yellow beak and feet edged in black so they do not melt into it. */
    private _on_tile(): PixelGrid {
        const radius = this.size * PixelGrid.TILE_CORNER_FRACTION;
        const list_rows = this.list_rows.map((row, y) => row.map((key, x): PaletteKey => {
            const corner_x = Math.min(Math.max(x + 0.5, radius), this.size - radius);
            const corner_y = Math.min(Math.max(y + 0.5, radius), this.size - radius);
            const distance_squared = (x + 0.5 - corner_x) ** 2 + (y + 0.5 - corner_y) ** 2;
            if (distance_squared > radius * radius + PixelGrid.TILE_CORNER_SLACK) {
                return ".";
            }
            if (key !== ".") {
                return key;
            }
            return this._touches(x, y, "YL", false) ? "K" : "Y";
        }));
        return new PixelGrid(list_rows);
    }

    /** A one-pixel yellow outline around the black body; the yellow beak and feet need none. */
    private _outlined(): PixelGrid {
        const list_rows = this.list_rows.map((row, y) => row.map((key, x): PaletteKey => {
            if (key !== ".") {
                return key;
            }
            return this._touches(x, y, "KG", true) ? "Y" : ".";
        }));
        return new PixelGrid(list_rows);
    }
}
