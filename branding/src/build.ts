import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { type Animation, Animator } from "./animation.ts";
import { type CrowState, CrowStates, type SpriteStamp } from "./crow-states.ts";
import { GifWriter } from "./gif-writer.ts";
import { Icons } from "./icons.ts";
import { type PaletteKey, PixelGrid } from "./pixel-grid.ts";
import { PngWriter } from "./png-writer.ts";
import { Sprites } from "./sprites.ts";
import { type Lockup, RookeryMark } from "./rookery-mark.ts";

/**
 * Builds the logo's preview page from the pixel data: Rookery's mark in each layout, and the crow in each
 * state of a code agent session, all animated, on a dark and a light background.
 */
class LogoBuild {
    static readonly OUTPUT_DIRECTORY = join(dirname(fileURLToPath(import.meta.url)), "..", "dist");
    /** The app's resources, where the sidebar's logo goes. */
    static readonly APP_RESOURCES_DIRECTORY = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "Resources");
    static readonly SIDEBAR_LOGO_NAME = "SidebarLogo";
    /** The crows the app's Agents list shows, one strip per state, and the timeline of all of them. */
    static readonly CROW_STRIP_PREFIX = "Crow_";
    static readonly CROW_TIMELINE_NAME = "Crows";
    static readonly RAVEN_STRIP_PREFIX = "Raven_";
    static readonly RAVEN_TIMELINE_NAME = "Raven";
    /** The raven's sheen in place of the crow's mid grey and highlight. */
    static readonly RAVEN_SHEEN: Partial<Record<PaletteKey, PaletteKey>> = { M: "U", H: "V" };
    /** The letter Raven holds, its corner at the beak's tip. */
    static readonly RAVEN_LETTER: SpriteStamp = { sprite: Sprites.LETTER, anchor: "beak", dx: -2, dy: -2 };
    /** The logo's files for use outside the app. */
    static readonly EXPORT_DIRECTORY = join(dirname(fileURLToPath(import.meta.url)), "..", "exports");
    /** How many file pixels a grid pixel becomes in the exported PNGs and GIFs. */
    static readonly EXPORT_SCALE = 4;
    /** The interface icons' folder in the app's resources. */
    static readonly ICON_DIRECTORY_NAME = "Icons";
    /** The still logo the repository's README shows, each pixel a block of this many. */
    static readonly README_LOGO_PATH = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "docs", "images", "rookery-logo.png");
    static readonly README_LOGO_SCALE = 2;
    /** The screen scales the sidebar's logo is written for, each pixel a block of that many. */
    /** The backing the logo uses: a yellow outline around the black. */
    static readonly BACKING = "outline";
    static readonly LIST_HARNESSES: readonly string[] = ["Claude Code", "Codex", "dsh"];
    static readonly LIST_LOCKUPS: readonly { lockup: Lockup; title: string; list_scales: readonly number[] }[] = [
        { lockup: "icon", title: "Mark", list_scales: [4, 2, 1] },
        { lockup: "horizontal", title: "Horizontal", list_scales: [3, 1] },
        { lockup: "vertical", title: "Vertical", list_scales: [3, 1] },
    ];
    /** The scales a state's crow is shown at. */
    static readonly LIST_STATE_SCALES: readonly number[] = [3, 1];

    /** Render everything and write the preview page. */
    static main(): void {
        mkdirSync(LogoBuild.OUTPUT_DIRECTORY, { recursive: true });
        const map_animations = new Map<string, Animation>();
        for (const { lockup } of LogoBuild.LIST_LOCKUPS) {
            map_animations.set(`mark-${lockup}`, RookeryMark.animate(lockup, LogoBuild.BACKING));
        }
        for (const state of CrowStates.LIST_STATES) {
            map_animations.set(`crow-${state.name}`, Animator.animate(state, LogoBuild.BACKING));
        }
        const path = join(LogoBuild.OUTPUT_DIRECTORY, "preview.html");
        writeFileSync(path, LogoBuild._page(map_animations));
        console.log(path);
        LogoBuild._write_sidebar_logo();
        LogoBuild._write_crows();
        LogoBuild._write_raven();
        LogoBuild._write_icons();
        LogoBuild._write_exports();
        LogoBuild._write_readme_logo();
    }

    /**
     * The logo for use outside the app, in `exports/`: each lockup of the mark, and the crow in each state,
     * as an SVG of its first frame at a unit a pixel, a PNG of that frame and a looping GIF, both at
     * `EXPORT_SCALE` pixels a grid pixel, on a transparent background.
     */
    private static _write_exports(): void {
        rmSync(LogoBuild.EXPORT_DIRECTORY, { recursive: true, force: true });
        mkdirSync(LogoBuild.EXPORT_DIRECTORY, { recursive: true });
        const list_exports: { name: string; animation: Animation }[] = [
            ...LogoBuild.LIST_LOCKUPS.map(({ lockup }) => ({
                name: `rookery-${lockup}`,
                animation: RookeryMark.animate(lockup, LogoBuild.BACKING, RookeryMark.FULL_SIZE, true),
            })),
            ...CrowStates.LIST_STATES.map((state) => ({
                name: `crow-${state.name}`,
                animation: Animator.animate(state, LogoBuild.BACKING),
            })),
        ];
        for (const { name, animation } of list_exports) {
            const first = animation.list_frames[animation.list_sequence[0] ?? 0];
            if (first === undefined) {
                throw new Error(`${name} has no frames`);
            }
            const base = join(LogoBuild.EXPORT_DIRECTORY, name);
            writeFileSync(`${base}.svg`, first.to_svg(1));
            writeFileSync(`${base}.png`, PngWriter.encode(first.enlarged(LogoBuild.EXPORT_SCALE)));
            writeFileSync(`${base}.gif`, GifWriter.encode(animation, LogoBuild.EXPORT_SCALE));
        }
        console.log(LogoBuild.EXPORT_DIRECTORY, `${list_exports.length} marks as SVG, PNG and GIF`);
    }

    /**
     * The interface icons, for the app: one PNG each at a pixel a grid pixel, badges in their colors and
     * glyphs in black for the app to tint, named `<name>.png` in a folder of their own.
     */
    private static _write_icons(): void {
        const directory = join(LogoBuild.APP_RESOURCES_DIRECTORY, LogoBuild.ICON_DIRECTORY_NAME);
        rmSync(directory, { recursive: true, force: true });
        mkdirSync(directory, { recursive: true });
        for (const icon of Icons.LIST_BADGES) {
            writeFileSync(join(directory, `${icon.name}.png`), PngWriter.encode(Icons.badge_grid(icon)));
        }
        for (const icon of Icons.LIST_GLYPHS) {
            writeFileSync(join(directory, `${icon.name}.png`), PngWriter.encode(Icons.glyph_grid(icon)));
        }
        console.log(directory, `${Icons.LIST_BADGES.length} badges, ${Icons.LIST_GLYPHS.length} glyphs`);
    }

    /**
     * The crow in each state, for the app: one PNG strip of a state's distinct frames at one pixel a grid
     * pixel, named by the state as roost reports it, and one timeline for all of them. The app scales them
     * with nearest-neighbour filtering, so a 64-pixel crow fills 32 points on a Retina screen exactly.
     */
    private static _write_crows(): void {
        LogoBuild._write_sheet(
            LogoBuild.CROW_TIMELINE_NAME,
            LogoBuild.CROW_STRIP_PREFIX,
            CrowStates.LIST_STATES.map((state) => ({
                name: state.name.replaceAll("-", "_"),
                animation: Animator.animate(state, LogoBuild.BACKING),
            })),
        );
    }

    /**
     * Raven, Rookery's agent over the fleet, told from the agents' crows at a glance: a raven's violet sheen
     * on its feathers, a sealed letter in its beak, facing left toward the conversation, outlined in white;
     * at rest and at work, in strips and a timeline as the crows'.
     */
    private static _write_raven(): void {
        const list_loops = [
            { name: "idle", state: CrowStates.IDLE },
            { name: "working", state: CrowStates.THINKING },
        ];
        LogoBuild._write_sheet(
            LogoBuild.RAVEN_TIMELINE_NAME,
            LogoBuild.RAVEN_STRIP_PREFIX,
            list_loops.map(({ name, state }) => {
                const raven: CrowState = {
                    ...state,
                    tint: "W",
                    list_frames: state.list_frames.map((frame) => ({
                        ...frame,
                        list_stamps: [...frame.list_stamps, LogoBuild.RAVEN_LETTER],
                    })),
                };
                const animation = Animator.animate(raven, LogoBuild.BACKING);
                return {
                    name,
                    animation: {
                        ...animation,
                        list_frames: animation.list_frames.map((frame) => frame.recolored(LogoBuild.RAVEN_SHEEN).mirrored()),
                    },
                };
            }),
        );
    }

    /** Named loops of one size, each a PNG strip of its distinct frames, and one timeline for all of them. */
    private static _write_sheet(
        timeline_name: string,
        strip_prefix: string,
        list_loops: readonly { name: string; animation: Animation }[],
    ): void {
        const map_loops: Record<string, { frame_count: number; sequence: readonly number[] }> = {};
        let width = 0;
        let height = 0;
        let frames_per_second = 0;
        for (const { name, animation } of list_loops) {
            const strip = PixelGrid.compose(
                animation.width * animation.list_frames.length,
                animation.height,
                animation.list_frames.map((frame, frame_index) => ({ grid: frame, left: frame_index * animation.width, top: 0 })),
            );
            writeFileSync(join(LogoBuild.APP_RESOURCES_DIRECTORY, `${strip_prefix}${name}.png`), PngWriter.encode(strip));
            map_loops[name] = { frame_count: animation.list_frames.length, sequence: animation.list_sequence };
            width = animation.width;
            height = animation.height;
            frames_per_second = animation.frames_per_second;
        }
        const path = join(LogoBuild.APP_RESOURCES_DIRECTORY, `${timeline_name}.json`);
        writeFileSync(path, `${JSON.stringify({ frame_width: width, frame_height: height, frames_per_second, states: map_loops }, undefined, 4)}\n`);
        console.log(path, `${list_loops.length} loops, ${width} × ${height}`);
    }

    /** The full-size horizontal mark's first frame, for the README. */
    private static _write_readme_logo(): void {
        const animation = RookeryMark.animate("horizontal", LogoBuild.BACKING, RookeryMark.FULL_SIZE, true);
        const first = animation.list_frames[animation.list_sequence[0] ?? 0];
        if (first === undefined) {
            throw new Error("the mark has no frames");
        }
        mkdirSync(dirname(LogoBuild.README_LOGO_PATH), { recursive: true });
        writeFileSync(LogoBuild.README_LOGO_PATH, PngWriter.encode(first.enlarged(LogoBuild.README_LOGO_SCALE)));
        console.log(LogoBuild.README_LOGO_PATH, `${first.width * LogoBuild.README_LOGO_SCALE} × ${first.height * LogoBuild.README_LOGO_SCALE}`);
    }

    /**
     * The animated horizontal mark the app's sidebar shows: its distinct frames side by side in one PNG per
     * screen scale, and how to play them, for the app to hand to Core Animation. The Retina strip is drawn
     * on a grid twice as fine rather than enlarged, so the mark keeps its pixels' look at twice the detail.
     */
    private static _write_sidebar_logo(): void {
        const animation = RookeryMark.animate("horizontal", LogoBuild.BACKING, RookeryMark.SIDEBAR_SIZE, true);
        const retina = RookeryMark.animate("horizontal", LogoBuild.BACKING, RookeryMark.SIDEBAR_RETINA_SIZE, true);
        if (JSON.stringify(retina.list_sequence) !== JSON.stringify(animation.list_sequence)) {
            throw new Error("the sidebar mark's Retina frames do not follow the same sequence");
        }
        for (const [suffix, drawn] of [["", animation], ["@2x", retina]] as const) {
            const strip = PixelGrid.compose(
                drawn.width * drawn.list_frames.length,
                drawn.height,
                drawn.list_frames.map((frame, frame_index) => ({ grid: frame, left: frame_index * drawn.width, top: 0 })),
            );
            const path = join(LogoBuild.APP_RESOURCES_DIRECTORY, `${LogoBuild.SIDEBAR_LOGO_NAME}${suffix}.png`);
            writeFileSync(path, PngWriter.encode(strip));
            console.log(path, `${drawn.width} × ${drawn.height}`);
        }
        const path = join(LogoBuild.APP_RESOURCES_DIRECTORY, `${LogoBuild.SIDEBAR_LOGO_NAME}.json`);
        writeFileSync(path, `${JSON.stringify({
            frame_width: animation.width,
            frame_height: animation.height,
            retina_frame_width: retina.width,
            retina_frame_height: retina.height,
            frames_per_second: animation.frames_per_second,
            sequence: animation.list_sequence,
        }, undefined, 4)}\n`);
        console.log(path, `${animation.list_frames.length} frames`);
    }

    /** An animation's frames, each run-length encoded row after row, for the page's player. */
    private static _encode(animation: Animation): object {
        return {
            width: animation.width,
            height: animation.height,
            fps: animation.frames_per_second,
            sequence: animation.list_sequence,
            frames: animation.list_frames.map((frame) => {
                const flat = frame.list_rows.map((row) => row.join("")).join("");
                return flat.replace(/(.)\1*/g, (run, key: string) => (run.length > 1 ? `${key}${run.length}` : key));
            }),
        };
    }

    private static _canvas(id: string, animation: Animation | undefined, scale: number): string {
        const width = (animation?.width ?? 0) * scale;
        const height = (animation?.height ?? 0) * scale;
        return `<figure><canvas data-animation="${id}" style="width:${width}px;height:${height}px"></canvas>`
            + `<figcaption>${scale}×</figcaption></figure>`;
    }

    private static _mark_section(map_animations: ReadonlyMap<string, Animation>): string {
        const rows = LogoBuild.LIST_LOCKUPS.map(({ lockup, title, list_scales }) => {
            const id = `mark-${lockup}`;
            const animation = map_animations.get(id);
            const canvases = list_scales.map((scale) => LogoBuild._canvas(id, animation, scale)).join("");
            return `<div class="lockup"><h3>${title}<span>${animation?.width ?? 0} × ${animation?.height ?? 0}</span></h3>`
                + `<div class="surfaces"><div class="surface dark">${canvases}</div><div class="surface light">${canvases}</div></div></div>`;
        }).join("");
        return `<section><h2>Rookery</h2><p class="note">A murder of crows in its nest: the mark for Rookery itself. `
            + `The crows breathe, blink and look about out of step, and the tall one caws; the name stays still.</p>${rows}</section>`;
    }

    private static _state_card(state: CrowState, map_animations: ReadonlyMap<string, Animation>): string {
        const id = `crow-${state.name}`;
        const animation = map_animations.get(id);
        const canvases = LogoBuild.LIST_STATE_SCALES.map((scale) => LogoBuild._canvas(id, animation, scale)).join("");
        const signals = LogoBuild.LIST_HARNESSES.map((harness) => {
            const signal = state.list_signals.find((candidate) => candidate.harness === harness)?.signal ?? "To confirm";
            return `<tr><th>${harness}</th><td>${signal}</td></tr>`;
        }).join("");
        return `<article class="card"><div class="stage"><div class="surface dark">${canvases}</div>`
            + `<div class="surface light">${LogoBuild._canvas(id, animation, 1)}</div></div>`
            + `<h3>${state.title}</h3><p>${state.meaning}</p><table>${signals}</table></article>`;
    }

    private static _page(map_animations: ReadonlyMap<string, Animation>): string {
        const data = Object.fromEntries([...map_animations].map(([id, animation]) => [id, LogoBuild._encode(animation)]));
        const cards = CrowStates.LIST_STATES.map((state) => LogoBuild._state_card(state, map_animations)).join("");
        return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rookery logo</title>
<style>
:root { color-scheme: dark; --page: #101012; --dark: #18181b; --light: #f4f1ea; --text: #e8e6e1; --muted: #8d8a85; --line: #2a2a2e; }
* { box-sizing: border-box; }
body { margin: 0; padding: 40px 24px 80px; background: var(--page); color: var(--text); font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
main { max-width: 1240px; margin: 0 auto; }
h1 { font-size: 28px; margin: 0 0 6px; letter-spacing: -0.01em; }
h2 { font-size: 22px; margin: 0 0 4px; }
.lead, .note { color: var(--muted); margin: 0 0 24px; max-width: 760px; }
section { margin-bottom: 64px; }
.lockup { margin-bottom: 22px; }
.lockup h3, .card h3 { font-size: 14px; margin: 0 0 8px; }
.lockup h3 span { color: var(--muted); font-weight: 400; margin-left: 8px; font-variant-numeric: tabular-nums; }
.surfaces { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }
@media (max-width: 900px) { .surfaces { grid-template-columns: 1fr; } }
.surface { border-radius: 14px; padding: 18px; display: flex; align-items: flex-end; gap: 20px; flex-wrap: wrap; overflow: hidden; }
.surface.dark { background: var(--dark); }
.surface.light { background: var(--light); color: #4b4945; }
figure { margin: 0; display: flex; flex-direction: column; align-items: center; gap: 6px; }
figcaption { font-size: 11px; opacity: 0.55; }
canvas { display: block; image-rendering: pixelated; }
.cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(330px, 1fr)); gap: 16px; }
.card { background: #141417; border: 1px solid var(--line); border-radius: 16px; padding: 14px; }
.card .stage { display: grid; grid-template-columns: 1fr auto; gap: 8px; margin-bottom: 12px; }
.card .surface { padding: 12px; justify-content: center; align-items: center; }
.card p { color: var(--muted); margin: 0 0 10px; }
table { width: 100%; border-collapse: collapse; font-size: 12px; }
th, td { border-top: 1px solid var(--line); padding: 4px 10px 4px 0; vertical-align: top; text-align: left; }
th { font-weight: 600; white-space: nowrap; }
td { color: var(--muted); }
</style>
</head>
<body>
<main>
<h1>Rookery logo</h1>
<p class="lead">2.5D pixel art rendered from one crow model, with the yellow outline backing. Every frame is a grid of palette keys generated by <code>npm run build:logo</code>; nothing is blended, so the edges stay sharp at any whole scale.</p>
${LogoBuild._mark_section(map_animations)}
<section><h2>Crow</h2><p class="note">One crow is one agent session. Each state of a session has its own loop at ${CrowStates.FRAMES_PER_SECOND} frames a second; the table says which event of each harness puts a session in it.</p>
<div class="cards">${cards}</div></section>
</main>
<script>
const PALETTE = ${JSON.stringify(PixelGrid.PALETTE_COLORS)};
const ANIMATIONS = ${JSON.stringify(data)};
const RGBA = Object.fromEntries(Object.entries(PALETTE).map(([key, hex]) => [key, [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16))]));
function decode(animation, encoded) {
    const image = new ImageData(animation.width, animation.height);
    let pixel = 0;
    for (const [, key, count] of encoded.matchAll(/(\\D)(\\d*)/g)) {
        const length = count === "" ? 1 : Number(count);
        const color = RGBA[key];
        for (let i = 0; i < length; i += 1, pixel += 1) {
            if (color !== undefined) {
                image.data.set([...color, 255], pixel * 4);
            }
        }
    }
    return image;
}
const players = [...document.querySelectorAll("canvas[data-animation]")].map((canvas) => {
    const animation = ANIMATIONS[canvas.dataset.animation];
    canvas.width = animation.width;
    canvas.height = animation.height;
    return { context: canvas.getContext("2d"), animation, images: animation.frames.map((frame) => decode(animation, frame)), shown: -1 };
});
function tick(time) {
    for (const player of players) {
        const step = Math.floor(time * player.animation.fps / 1000) % player.animation.sequence.length;
        const frame = player.animation.sequence[step];
        if (frame !== player.shown) {
            player.context.putImageData(player.images[frame], 0, 0);
            player.shown = frame;
        }
    }
    requestAnimationFrame(tick);
}
requestAnimationFrame(tick);
</script>
</body>
</html>
`;
    }
}

LogoBuild.main();
