import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { CrowDrafts } from "./crow-drafts.ts";
import { type Backing, type CrowDesign, PixelGrid } from "./pixel-grid.ts";

/**
 * Builds the logo's preview page from the pixel data: every crow draft with each backing, on a dark and a
 * light page, at the sizes the icon is used at.
 */
class LogoBuild {
    static readonly OUTPUT_DIRECTORY = join(dirname(fileURLToPath(import.meta.url)), "..", "dist");
    /** The sizes drawn from the 32-pixel design, in screen pixels. */
    static readonly LIST_LARGE_SIZES: readonly number[] = [256, 128, 64, 32];
    /** The 16-pixel design, drawn at its own size and enlarged to check it pixel by pixel. */
    static readonly SMALL_SIZE = 16;
    static readonly SMALL_ENLARGED_SIZE = 64;
    static readonly LIST_BACKINGS: readonly { backing: Backing; title: string; note: string }[] = [
        { backing: "tile", title: "A · Yellow tile", note: "App-icon style; the beak and feet are edged in black" },
        { backing: "outline", title: "B · Yellow outline", note: "Transparent, with a 1px yellow outline around the body" },
        { backing: "none", title: "Bare", note: "For light backgrounds only" },
    ];
    static readonly LIST_SURFACES: readonly { name: string; title: string }[] = [
        { name: "dark", title: "On dark" },
        { name: "light", title: "On light" },
    ];

    /** Write the preview page. */
    static main(): void {
        mkdirSync(LogoBuild.OUTPUT_DIRECTORY, { recursive: true });
        const path = join(LogoBuild.OUTPUT_DIRECTORY, "preview.html");
        writeFileSync(path, LogoBuild._preview_page(CrowDrafts.LIST_DRAFTS));
        console.log(path);
    }

    private static _preview_page(list_drafts: readonly CrowDesign[]): string {
        const sections = list_drafts.map((draft, draft_index) => LogoBuild._draft_section(draft, draft_index)).join("");
        return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rookery logo drafts</title>
<style>
:root { color-scheme: dark; --page: #101012; --dark: #18181b; --light: #f4f1ea; --text: #e8e6e1; --muted: #8d8a85; --yellow: #ffc83d; }
* { box-sizing: border-box; }
body { margin: 0; padding: 40px 24px 80px; background: var(--page); color: var(--text); font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
main { max-width: 1180px; margin: 0 auto; }
h1 { font-size: 28px; margin: 0 0 6px; letter-spacing: -0.01em; }
.lead { color: var(--muted); margin: 0 0 40px; }
section { margin-bottom: 56px; }
h2 { font-size: 20px; margin: 0 0 4px; display: flex; gap: 10px; align-items: baseline; }
h2 .tag { color: var(--page); background: var(--yellow); border-radius: 6px; padding: 1px 8px; font-size: 13px; }
.note { color: var(--muted); margin: 0 0 16px; }
.backing { margin: 0 0 18px; }
.backing h3 { font-size: 13px; font-weight: 600; margin: 0 0 8px; color: var(--text); }
.backing h3 span { color: var(--muted); font-weight: 400; margin-left: 8px; }
.surfaces { display: grid; grid-template-columns: repeat(auto-fit, minmax(520px, 1fr)); gap: 12px; }
.surface { border-radius: 14px; padding: 18px; display: flex; align-items: flex-end; gap: 22px; flex-wrap: wrap; }
.surface.dark { background: var(--dark); }
.surface.light { background: var(--light); color: #4b4945; }
.surface .label { width: 100%; font-size: 12px; opacity: 0.7; margin-bottom: -8px; }
figure { margin: 0; display: flex; flex-direction: column; align-items: center; gap: 6px; }
figcaption { font-size: 11px; opacity: 0.6; font-variant-numeric: tabular-nums; }
svg { display: block; image-rendering: pixelated; }
</style>
</head>
<body>
<main>
<h1>Rookery crow drafts</h1>
<p class="lead">Three original crows on a 32 × 32 grid, each redrawn by hand at 16 × 16. Pick one, and a backing, and it gets the animation, the wordmark and the exports.</p>
${sections}
</main>
</body>
</html>
`;
    }

    private static _draft_section(draft: CrowDesign, draft_index: number): string {
        const large = PixelGrid.parse(draft.list_rows_large);
        const small = PixelGrid.parse(draft.list_rows_small);
        const backings = LogoBuild.LIST_BACKINGS.map(({ backing, title, note }) => {
            const surfaces = LogoBuild.LIST_SURFACES
                .filter((surface) => backing !== "none" || surface.name === "light")
                .map((surface) => {
                    const figures = LogoBuild.LIST_LARGE_SIZES
                        .map((size) => LogoBuild._figure(large.backed(backing).to_svg(size / large.size), `${size}`))
                        .join("");
                    const small_figures = LogoBuild._figure(small.backed(backing).to_svg(1), `${LogoBuild.SMALL_SIZE}`)
                        + LogoBuild._figure(
                            small.backed(backing).to_svg(LogoBuild.SMALL_ENLARGED_SIZE / small.size),
                            `${LogoBuild.SMALL_SIZE} × 4`,
                        );
                    return `<div class="surface ${surface.name}"><div class="label">${surface.title}</div>${figures}${small_figures}</div>`;
                })
                .join("");
            return `<div class="backing"><h3>${title}<span>${note}</span></h3><div class="surfaces">${surfaces}</div></div>`;
        }).join("");
        return `<section><h2><span class="tag">${draft_index + 1}</span>${draft.title}</h2>`
            + `<p class="note">${draft.note}</p>${backings}</section>`;
    }

    private static _figure(svg: string, caption: string): string {
        return `<figure>${svg}<figcaption>${caption}</figcaption></figure>`;
    }
}

LogoBuild.main();
