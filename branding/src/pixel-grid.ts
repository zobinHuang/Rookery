/**
 * A key of the palette: `.` is transparent, `S` the ground shadow, whose color depends on what is behind it,
 * and the rest name the logo's colors.
 */
export type PaletteKey = "." | "S" | "K" | "G" | "M" | "H" | "Y" | "L" | "W";

/** A key that stands for one fixed color. */
type ColorKey = Exclude<PaletteKey, "." | "S">;

/**
 * One crow, drawn on the 64 by 64 grid for large sizes, and on the 32 and 16 pixel grids for the small ones.
 */
export interface CrowDesign {
    name: string;
    title: string;
    note: string;
    list_rows_large: readonly string[];
    list_rows_medium: readonly string[];
    list_rows_small: readonly string[];
}

/**
 * How the crow stands out from a dark background: on a yellow tile, or with a yellow outline of its own.
 */
export type Backing = "tile" | "outline" | "none";

/**
 * One grid placed on another, its top left corner at a pixel.
 */
export interface GridPlacement {
    grid: PixelGrid;
    left: number;
    top: number;
}

/**
 * A rectangular grid of palette keys, one per pixel, and what the logo derives from one: the backings, the
 * layouts and the SVG drawing. Every pixel is a whole square on an integer position, so nothing is ever
 * blended.
 */
export class PixelGrid {
    /** The logo's colors: the five of the brief, and two sheen greys that light the black feathers. */
    static readonly PALETTE_COLORS: Readonly<Record<ColorKey, string>> = {
        K: "#0E0E10",
        G: "#2A2A2E",
        M: "#44444F",
        H: "#6E6E7E",
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
     * @param list_rows - the rows, all as long as the first
     * @returns the grid
     * @throws Error when the rows differ in length or hold a key outside the palette
     */
    static parse(list_rows: readonly string[]): PixelGrid {
        const width = list_rows[0]?.length ?? 0;
        const list_parsed = list_rows.map((row) => {
            if (row.length !== width) {
                throw new Error(`row "${row}" is not ${width} pixels long`);
            }
            return [...row].map((key) => PixelGrid.palette_key(key));
        });
        return new PixelGrid(list_parsed);
    }

    /**
     * Grids laid out on one empty canvas; where they overlap, the later one's pixels win, but its empty
     * pixels let the earlier ones show.
     *
     * @param width - the canvas's width in pixels
     * @param height - the canvas's height in pixels
     * @param list_placements - the grids and where they go
     * @returns the canvas
     */
    static compose(width: number, height: number, list_placements: readonly GridPlacement[]): PixelGrid {
        const list_rows: PaletteKey[][] = Array.from({ length: height }, () => Array.from({ length: width }, (): PaletteKey => "."));
        for (const { grid, left, top } of list_placements) {
            grid.list_rows.forEach((row, y) => row.forEach((key, x) => {
                const target = list_rows[top + y];
                if (key !== "." && target !== undefined && left + x >= 0 && left + x < width) {
                    target[left + x] = key;
                }
            }));
        }
        return new PixelGrid(list_rows);
    }

    /**
     * A grid from rows of keys already read.
     *
     * @param list_rows - the rows, as many as each is long
     * @returns the grid
     */
    static from_keys(list_rows: readonly (readonly PaletteKey[])[]): PixelGrid {
        return new PixelGrid(list_rows.map((row) => [...row]));
    }

    /** How many pixels the grid is across. */
    get width(): number {
        return this.list_rows[0]?.length ?? 0;
    }

    /** How many pixels the grid is down. */
    get height(): number {
        return this.list_rows.length;
    }

    /**
     * The grid with every pixel made a square block of pixels.
     *
     * @param factor - how many pixels across each pixel becomes
     * @returns the enlarged grid
     */
    enlarged(factor: number): PixelGrid {
        return new PixelGrid(this.list_rows.flatMap((row) => {
            const wide = row.flatMap((key) => Array.from({ length: factor }, () => key));
            return Array.from({ length: factor }, () => [...wide]);
        }));
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
                return new PixelGrid(this.list_rows.map((row) => row.map((key) => (key === "S" ? "G" : key))));
        }
    }

    /**
     * The grid as an SVG of whole-pixel rectangles, one per run of a color along a row.
     *
     * @param pixel_size - the side of one pixel in the SVG's own units
     * @returns the SVG markup
     */
    to_svg(pixel_size: number): string {
        const width = this.width * pixel_size;
        const height = this.height * pixel_size;
        const list_rects: string[] = [];
        this.list_rows.forEach((row, y) => {
            let run_start = 0;
            for (let x = 1; x <= row.length; x += 1) {
                if (x < row.length && row[x] === row[run_start]) {
                    continue;
                }
                const key = row[run_start];
                if (key !== undefined && key !== "." && key !== "S") {
                    list_rects.push(
                        `<rect x="${run_start * pixel_size}" y="${y * pixel_size}" width="${(x - run_start) * pixel_size}" `
                        + `height="${pixel_size}" fill="${PixelGrid.PALETTE_COLORS[key]}"/>`,
                    );
                }
                run_start = x;
            }
        });
        return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}" `
            + `shape-rendering="crispEdges">${list_rects.join("")}</svg>`;
    }

    /**
     * A character read as a palette key.
     *
     * @param key - the character
     * @returns the key
     * @throws Error when the character is not a palette key
     */
    static palette_key(key: string): PaletteKey {
        if (key === "." || key === "S" || key in PixelGrid.PALETTE_COLORS) {
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
        const radius = Math.min(this.width, this.height) * PixelGrid.TILE_CORNER_FRACTION;
        const list_rows = this.list_rows.map((row, y) => row.map((key, x): PaletteKey => {
            const corner_x = Math.min(Math.max(x + 0.5, radius), this.width - radius);
            const corner_y = Math.min(Math.max(y + 0.5, radius), this.height - radius);
            const distance_squared = (x + 0.5 - corner_x) ** 2 + (y + 0.5 - corner_y) ** 2;
            if (distance_squared > radius * radius + PixelGrid.TILE_CORNER_SLACK) {
                return ".";
            }
            if (key === "S") {
                return "K";
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
            if (key === "S") {
                return "G";
            }
            if (key !== ".") {
                return key;
            }
            return this._touches(x, y, "KGMH", true) ? "Y" : ".";
        }));
        return new PixelGrid(list_rows);
    }
}
