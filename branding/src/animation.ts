import { type CrowState, CrowStates, type FrameSpec } from "./crow-states.ts";
import { type Backing, type ColorKey, PixelGrid } from "./pixel-grid.ts";
import { SceneRenderer } from "./scene-renderer.ts";
import { Sprites } from "./sprites.ts";

/**
 * A looping pixel animation: its distinct frames, and the order they play in. Frames that repeat are kept
 * once.
 */
export interface Animation {
    width: number;
    height: number;
    frames_per_second: number;
    list_frames: readonly PixelGrid[];
    list_sequence: readonly number[];
}

/**
 * Turns the crow's states into animations, rendering each distinct frame once.
 */
export class Animator {
    /**
     * A state's loop, with a backing.
     *
     * @param state - the state
     * @param backing - how the crow is set off from the background
     * @returns the animation
     */
    static animate(state: CrowState, backing: Backing): Animation {
        const map_frame_indices = new Map<string, number>();
        const list_frames: PixelGrid[] = [];
        const list_sequence = state.list_frames.map((frame) => {
            const key = JSON.stringify(frame);
            const known = map_frame_indices.get(key);
            if (known !== undefined) {
                return known;
            }
            list_frames.push(Animator.render_frame(frame, backing, state.tint));
            map_frame_indices.set(key, list_frames.length - 1);
            return list_frames.length - 1;
        });
        return {
            width: CrowStates.GRID_SIZE,
            height: CrowStates.GRID_SIZE,
            frames_per_second: CrowStates.FRAMES_PER_SECOND,
            list_frames,
            list_sequence,
        };
    }

    /**
     * One frame of the single crow with its backing, and its sprites stamped on after it, so that the
     * outline is the crow's alone.
     *
     * @param frame - the pose and the sprites
     * @param backing - how the crow is set off from the background
     * @returns the frame
     */
    static render_frame(frame: FrameSpec, backing: Backing, tint: ColorKey = "Y"): PixelGrid {
        const scene = SceneRenderer.render({
            size: CrowStates.GRID_SIZE,
            list_crows: [{ position: { x: 0, y: 0, z: 0 }, yaw: 0, scale: 1, pose: frame.pose }],
            zoom: CrowStates.CAMERA_ZOOM,
            centre_x: CrowStates.CAMERA_CENTRE_X,
            centre_y: CrowStates.CAMERA_CENTRE_Y,
            has_shadows: true,
        });
        const list_rows = PixelGrid.from_keys(scene.list_rows).backed(backing, tint).list_rows.map((row) => [...row]);
        const anchors = scene.list_anchors[0];
        if (anchors !== undefined) {
            for (const stamp of frame.list_stamps) {
                const x = stamp.anchor === "head" ? anchors.head_top_x : anchors.beak_x;
                const y = stamp.anchor === "head" ? anchors.head_top_y : anchors.beak_y;
                Sprites.stamp(list_rows, stamp.sprite, x + stamp.dx, y + stamp.dy, tint);
            }
        }
        return PixelGrid.from_keys(list_rows);
    }
}
