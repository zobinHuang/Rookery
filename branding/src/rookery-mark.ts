import type { Animation } from "./animation.ts";
import { CrowModel, type CrowPose } from "./crow-model.ts";
import { CrowStates } from "./crow-states.ts";
import { type Backing, PixelGrid } from "./pixel-grid.ts";
import { type CrowPlacement, SceneRenderer } from "./scene-renderer.ts";
import { Wordmark } from "./wordmark.ts";

/**
 * How the mark is laid out: the crows alone, the name to their right, or the name below them.
 */
export type Lockup = "icon" | "horizontal" | "vertical";

/**
 * How big the mark is drawn: the crows' grid, and the scale of the name's font.
 */
export interface MarkSize {
    grid_size: number;
    font_scale: number;
}

/**
 * Rookery's own mark: a murder of three crows in a woven nest, the one at the back the tallest. They
 * breathe, blink and look about out of step with one another, and the tall one caws, while the name beside
 * them stays still.
 */
export class RookeryMark {
    static readonly GRID_SIZE = 96;
    /** The size the mark is shown at unless a place calls for another. */
    static readonly FULL_SIZE: MarkSize = { grid_size: RookeryMark.GRID_SIZE, font_scale: 4 };
    /** Small enough for the top of the app's sidebar, one logo pixel a point. */
    static readonly SIDEBAR_SIZE: MarkSize = { grid_size: 56, font_scale: 2 };
    /** Pixels between the crows and the name. */
    static readonly LOCKUP_GAP = 6;
    /** Room around the name for its outline. */
    static readonly WORDMARK_MARGIN = 1;
    private static readonly _ZOOM = 1.62;
    private static readonly _CENTRE_X = 0.04;
    private static readonly _CENTRE_Y = 0.12;
    private static readonly _NEST = { position: { x: 0, y: -0.62, z: 0 }, radius: 0.95, thickness: 0.36 };
    /** Where each crow sits, before its pose: the tall one at the back, one each side in front. */
    private static readonly _LIST_SEATS: readonly Omit<CrowPlacement, "pose">[] = [
        { position: { x: -0.05, y: 0.08, z: -0.4 }, yaw: -8, scale: 0.95 },
        { position: { x: -0.72, y: -0.36, z: 0.25 }, yaw: 196, scale: 0.74 },
        { position: { x: 0.6, y: -0.3, z: 0.32 }, yaw: 14, scale: 0.72 },
    ];
    /** The crows already rendered, by their poses, so each layout reuses them. */
    private static readonly _MAP_RENDERED = new Map<string, PixelGrid>();

    /**
     * The three crows' poses in one frame of the loop.
     *
     * @param index - the frame, from 0
     * @returns a pose for each crow, back one first
     */
    static poses(index: number): readonly CrowPose[] {
        const step = (2 * RookeryMark._ZOOM) / RookeryMark.GRID_SIZE;
        const is_caw = index === 20 || index === 21;
        return [
            CrowModel.pose({
                bob: Math.floor(index / 5) % 2 === 1 ? step : 0,
                eye: index === 7 || index === 8 ? "closed" : "open",
                beak_open: is_caw ? 0.1 : 0,
                head_tilt: index >= 19 && index <= 23 ? 10 : 0,
            }),
            CrowModel.pose({
                head_tilt: index >= 12 && index < 19 ? -10 : -4,
                eye: index === 26 || index === 27 ? "closed" : "open",
                look_y: index >= 12 && index < 19 ? -0.4 : 0,
            }),
            CrowModel.pose({
                bob: Math.floor((index + 3) / 5) % 2 === 1 ? step : 0,
                head_tilt: index >= 19 && index < 26 ? 22 : 14,
                look_y: 0.6,
                eye: index === 3 || index === 4 ? "closed" : "open",
            }),
        ];
    }

    /**
     * The mark's loop in a layout, with a backing.
     *
     * @param lockup - the crows alone, or with the name beside or below them
     * @param backing - how the black is set off from the background
     * @param size - how big the crows and the name are
     * @param is_trimmed - whether the empty space around the crows and around the whole is cut away, the
     *   same from every frame, so the name sits close and the frames keep one size
     * @returns the animation
     */
    static animate(
        lockup: Lockup,
        backing: Backing,
        size: MarkSize = RookeryMark.FULL_SIZE,
        is_trimmed = false,
    ): Animation {
        const map_frame_indices = new Map<string, number>();
        const list_crow_frames: PixelGrid[] = [];
        const list_sequence = Array.from({ length: CrowStates.FRAME_COUNT }, (_, index) => {
            const list_poses = RookeryMark.poses(index);
            const key = JSON.stringify(list_poses);
            const known = map_frame_indices.get(key);
            if (known !== undefined) {
                return known;
            }
            list_crow_frames.push(RookeryMark.render_crows(list_poses, size.grid_size).backed(backing));
            map_frame_indices.set(key, list_crow_frames.length - 1);
            return list_crow_frames.length - 1;
        });
        const wordmark = RookeryMark._backed_wordmark(backing, size.font_scale);
        const list_frames = RookeryMark._trimmed(is_trimmed, list_crow_frames)
            .map((crows) => RookeryMark._lay_out(lockup, crows, wordmark));
        const list_trimmed_frames = RookeryMark._trimmed(is_trimmed, list_frames);
        const first = list_trimmed_frames[0];
        return {
            width: first?.width ?? 0,
            height: first?.height ?? 0,
            frames_per_second: CrowStates.FRAMES_PER_SECOND,
            list_frames: list_trimmed_frames,
            list_sequence,
        };
    }

    /** Frames cut to the space they jointly fill, when asked to be. */
    private static _trimmed(is_trimmed: boolean, list_frames: readonly PixelGrid[]): readonly PixelGrid[] {
        const bounds = is_trimmed ? PixelGrid.joint_bounds(list_frames) : undefined;
        return bounds === undefined ? list_frames : list_frames.map((frame) => frame.cropped(bounds));
    }

    /**
     * The nest and its crows in some poses, before any backing.
     *
     * @param list_poses - a pose for each crow, back one first
     * @param grid_size - the grid's side in pixels
     * @returns the grid
     */
    static render_crows(list_poses: readonly CrowPose[], grid_size: number = RookeryMark.GRID_SIZE): PixelGrid {
        const key = `${grid_size} ${JSON.stringify(list_poses)}`;
        const rendered = RookeryMark._MAP_RENDERED.get(key);
        if (rendered !== undefined) {
            return rendered;
        }
        const scene = SceneRenderer.render({
            size: grid_size,
            zoom: RookeryMark._ZOOM,
            centre_x: RookeryMark._CENTRE_X,
            centre_y: RookeryMark._CENTRE_Y,
            has_shadows: false,
            nest: RookeryMark._NEST,
            list_crows: RookeryMark._LIST_SEATS.map((seat, crow_index) => ({
                ...seat,
                pose: list_poses[crow_index] ?? CrowModel.REST_POSE,
            })),
        });
        const grid = PixelGrid.from_keys(scene.list_rows);
        RookeryMark._MAP_RENDERED.set(key, grid);
        return grid;
    }

    /** The name with room around it for its backing. */
    private static _backed_wordmark(backing: Backing, font_scale: number): PixelGrid {
        const bare = Wordmark.grid(font_scale);
        const margin = RookeryMark.WORDMARK_MARGIN;
        return PixelGrid.compose(bare.width + margin * 2, bare.height + margin * 2, [{ grid: bare, left: margin, top: margin }])
            .backed(backing === "tile" ? "outline" : backing);
    }

    /** The crows and the name placed in a layout. */
    private static _lay_out(lockup: Lockup, crows: PixelGrid, wordmark: PixelGrid): PixelGrid {
        const gap = RookeryMark.LOCKUP_GAP;
        switch (lockup) {
            case "icon":
                return crows;
            case "horizontal":
                return PixelGrid.compose(crows.width + gap + wordmark.width, crows.height, [
                    { grid: crows, left: 0, top: 0 },
                    { grid: wordmark, left: crows.width + gap, top: Math.round((crows.height - wordmark.height) / 2) },
                ]);
            case "vertical": {
                const width = Math.max(crows.width, wordmark.width);
                return PixelGrid.compose(width, crows.height + gap + wordmark.height, [
                    { grid: crows, left: Math.round((width - crows.width) / 2), top: 0 },
                    { grid: wordmark, left: Math.round((width - wordmark.width) / 2), top: crows.height + gap },
                ]);
            }
        }
    }
}
