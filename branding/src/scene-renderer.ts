import { CrowModel, type CrowPose, type SurfaceSample } from "./crow-model.ts";
import { Geometry, type Mat3, type Vec3 } from "./geometry.ts";
import type { PaletteKey } from "./pixel-grid.ts";

/**
 * One crow in a scene: where it stands, which way it faces and how big it is, and its pose.
 */
export interface CrowPlacement {
    position: Vec3;
    /** Degrees the crow is turned from facing right, about the vertical. */
    yaw: number;
    scale: number;
    pose: CrowPose;
}

/**
 * A woven nest the crows sit in: a squat ring.
 */
export interface NestPlacement {
    position: Vec3;
    radius: number;
    /** How thick the rim is. */
    thickness: number;
}

/**
 * What to render and how.
 */
export interface SceneOptions {
    /** The grid's side in pixels. */
    size: number;
    list_crows: readonly CrowPlacement[];
    nest?: NestPlacement;
    /** Half the side of the square of the world the grid shows. */
    zoom: number;
    /** The world point at the grid's centre, across and up. */
    centre_x: number;
    centre_y: number;
    /** Whether shadows fall on the ground under the crows. */
    has_shadows: boolean;
}

/**
 * Where the parts of a crow landed on the grid, for placing what floats around it.
 */
export interface CrowAnchors {
    /** Above the top of the head. */
    head_top_x: number;
    head_top_y: number;
    /** The tip of the beak. */
    beak_x: number;
    beak_y: number;
}

/**
 * A rendered scene: the pixels, and the anchors of each crow in it.
 */
export interface RenderedScene {
    list_rows: PaletteKey[][];
    list_anchors: CrowAnchors[];
}

/**
 * Renders crows as 2.5D pixel art: each pixel casts a ray through the scene, seen from a little above and to
 * the side, and the surface it meets is lit from the top left and quantized to the palette. Half tones are
 * dithered, edges where one part passes in front of another get a dark line, and the eye is drawn on top,
 * in the screen's pixels, so it stays crisp at every size.
 */
export class SceneRenderer {
    /** The camera looks down this much. */
    static readonly CAMERA_PITCH = 18;
    /** And is turned this much, so the crow is seen three-quarters on. */
    static readonly CAMERA_YAW = -28;
    static readonly LIGHT_DIRECTION: Vec3 = Geometry.normalize({ x: -0.55, y: 0.65, z: 0.55 });
    static readonly MAX_STEPS = 140;
    static readonly HIT_DISTANCE = 0.002;
    static readonly FAR_DISTANCE = 7;
    static readonly START_DISTANCE = 3;
    /** How far apart two surfaces must be in depth for a line to separate them. */
    static readonly CONTOUR_DEPTH = 0.12;
    static readonly NORMAL_STEP = 1e-3;
    /** The eye's radius against the grid's side. */
    static readonly EYE_RADIUS_FRACTION = 0.045;
    /** The shadow's half width and half height against the crow's size on the grid. */
    static readonly SHADOW_WIDTH = 0.27;
    static readonly SHADOW_HEIGHT = 0.05;
    /** How many twigs run around the nest each way. */
    static readonly NEST_TWIG_COUNT = 9;

    private static readonly _VIEW = Geometry.multiply(
        Geometry.rotation("x", SceneRenderer.CAMERA_PITCH),
        Geometry.rotation("y", SceneRenderer.CAMERA_YAW),
    );
    private static readonly _VIEW_INVERSE = Geometry.transpose(SceneRenderer._VIEW);

    /**
     * Render a scene to palette keys.
     *
     * @param options - the scene and the camera
     * @returns the grid of keys, `.` where the ray met nothing, and each crow's anchors
     */
    static render(options: SceneOptions): RenderedScene {
        const size = options.size;
        const list_rows: PaletteKey[][] = [];
        const list_depths: number[][] = [];
        const list_owners: number[][] = [];
        const list_materials: string[][] = [];
        const direction = Geometry.transform(SceneRenderer._VIEW_INVERSE, { x: 0, y: 0, z: -1 });
        for (let y = 0; y < size; y += 1) {
            const row: PaletteKey[] = [];
            const depths: number[] = [];
            const owners: number[] = [];
            const materials: string[] = [];
            for (let x = 0; x < size; x += 1) {
                const view_origin = SceneRenderer._view_point(options, x + 0.5, y + 0.5, SceneRenderer.START_DISTANCE);
                const origin = Geometry.transform(SceneRenderer._VIEW_INVERSE, view_origin);
                const hit = SceneRenderer._march(options, origin, direction);
                if (hit === undefined) {
                    row.push(".");
                    depths.push(Infinity);
                    owners.push(-1);
                    materials.push("");
                    continue;
                }
                const lighting = SceneRenderer._lighting(options, hit.point);
                const is_twig = hit.sample.material === "nest" && options.nest !== undefined
                    && SceneRenderer._is_twig(options.nest, hit.point);
                row.push(is_twig ? "K" : SceneRenderer._shade(hit.sample.material, lighting, (x + y) % 2 === 0));
                depths.push(hit.depth);
                owners.push(hit.owner);
                materials.push(hit.sample.material);
            }
            list_rows.push(row);
            list_depths.push(depths);
            list_owners.push(owners);
            list_materials.push(materials);
        }
        SceneRenderer._draw_contours(list_rows, list_depths, list_materials);
        const list_anchors = options.list_crows.map((crow, crow_index) => {
            SceneRenderer._draw_eye({ options, crow, crow_index, list_rows, list_depths, list_owners });
            return SceneRenderer._anchors(options, crow);
        });
        if (options.has_shadows) {
            for (const crow of options.list_crows) {
                SceneRenderer._draw_shadow(options, crow, list_rows);
            }
        }
        return { list_rows, list_anchors };
    }

    /** A point of the view's space for a position on the grid, at some distance toward the viewer. */
    private static _view_point(options: SceneOptions, grid_x: number, grid_y: number, z: number): Vec3 {
        return {
            x: options.centre_x + (grid_x / options.size * 2 - 1) * options.zoom,
            y: options.centre_y - (grid_y / options.size * 2 - 1) * options.zoom,
            z,
        };
    }

    /** Where a world point lands on the grid, and how far along the ray it lies. */
    private static _project(options: SceneOptions, point: Vec3): Vec3 {
        const view = Geometry.transform(SceneRenderer._VIEW, point);
        return {
            x: ((view.x - options.centre_x) / options.zoom + 1) / 2 * options.size,
            y: ((options.centre_y - view.y) / options.zoom + 1) / 2 * options.size,
            z: SceneRenderer.START_DISTANCE - view.z,
        };
    }

    /** A crow's turn about the vertical. */
    private static _crow_rotation(crow: CrowPlacement): Mat3 {
        return Geometry.rotation("y", crow.yaw);
    }

    /** A world point in a crow's own space. */
    private static _to_crow(crow: CrowPlacement, point: Vec3): Vec3 {
        const local = Geometry.transform(Geometry.transpose(SceneRenderer._crow_rotation(crow)), Geometry.sub(point, crow.position));
        return Geometry.scale(local, 1 / crow.scale);
    }

    /** A point of a crow's space in the world. */
    private static _from_crow(crow: CrowPlacement, local: Vec3): Vec3 {
        return Geometry.add(crow.position, Geometry.transform(SceneRenderer._crow_rotation(crow), Geometry.scale(local, crow.scale)));
    }

    /** The nearest surface of the whole scene, and which crow it belongs to (-1 for the nest). */
    private static _sample(options: SceneOptions, point: Vec3): { sample: SurfaceSample; owner: number } {
        let nearest: { sample: SurfaceSample; owner: number } = { sample: { distance: Infinity, material: "body" }, owner: -1 };
        options.list_crows.forEach((crow, crow_index) => {
            const sample = CrowModel.sample(SceneRenderer._to_crow(crow, point), crow.pose);
            const distance = sample.distance * crow.scale;
            if (distance < nearest.sample.distance) {
                nearest = { sample: { distance, material: sample.material }, owner: crow_index };
            }
        });
        if (options.nest !== undefined) {
            const distance = SceneRenderer._nest_distance(options.nest, point);
            if (distance < nearest.sample.distance) {
                nearest = { sample: { distance, material: "nest" }, owner: -1 };
            }
        }
        return nearest;
    }

    /** The distance to a nest: a thick ring of woven twigs, a little flattened, that the crows sit inside. */
    private static _nest_distance(nest: NestPlacement, point: Vec3): number {
        const local = Geometry.sub(point, nest.position);
        const across = Math.hypot(local.x, local.z) - nest.radius;
        return Math.hypot(across, local.y * 1.3) - nest.thickness;
    }

    /** Whether a point of the nest lies on one of the darker twigs woven through it, crossing both ways. */
    private static _is_twig(nest: NestPlacement, point: Vec3): boolean {
        const local = Geometry.sub(point, nest.position);
        const angle = Math.atan2(local.z, local.x);
        const height = local.y / nest.thickness;
        const strand = (phase: number): boolean => Math.abs(Math.sin(angle * SceneRenderer.NEST_TWIG_COUNT + height * 2.2 + phase)) < 0.16;
        return strand(0) || strand(Math.PI / 2 + height * -4.4);
    }

    /** Follow a ray until it meets a surface or gives up. */
    private static _march(
        options: SceneOptions,
        origin: Vec3,
        direction: Vec3,
    ): { point: Vec3; depth: number; sample: SurfaceSample; owner: number } | undefined {
        let depth = 0;
        for (let step = 0; step < SceneRenderer.MAX_STEPS && depth < SceneRenderer.FAR_DISTANCE; step += 1) {
            const point = Geometry.add(origin, Geometry.scale(direction, depth));
            const nearest = SceneRenderer._sample(options, point);
            if (nearest.sample.distance < SceneRenderer.HIT_DISTANCE) {
                return { point, depth, sample: nearest.sample, owner: nearest.owner };
            }
            depth += Math.max(nearest.sample.distance * 0.8, SceneRenderer.HIT_DISTANCE);
        }
        return undefined;
    }

    /** How much light falls on the surface at a point, from 0 to 1. */
    private static _lighting(options: SceneOptions, point: Vec3): number {
        const step = SceneRenderer.NORMAL_STEP;
        const at = (dx: number, dy: number, dz: number): number => SceneRenderer._sample(
            options,
            Geometry.add(point, { x: dx, y: dy, z: dz }),
        ).sample.distance;
        const normal = Geometry.normalize({
            x: at(step, 0, 0) - at(-step, 0, 0),
            y: at(0, step, 0) - at(0, -step, 0),
            z: at(0, 0, step) - at(0, 0, -step),
        });
        const view_normal = Geometry.transform(SceneRenderer._VIEW, normal);
        return Math.min(Math.max(Geometry.dot(view_normal, SceneRenderer.LIGHT_DIRECTION), 0), 1);
    }

    /** The palette key for a material under some light, dithering the steps between tones. */
    private static _shade(material: string, lighting: number, is_dither_pixel: boolean): PaletteKey {
        switch (material) {
            case "body":
            case "wing":
                if (lighting > 0.93) {
                    return "H";
                }
                if (lighting < 0.42) {
                    return "K";
                }
                if (lighting < 0.62) {
                    return "G";
                }
                return lighting > 0.8 || is_dither_pixel ? "M" : "G";
            case "beak":
                return lighting > 0.7 ? "L" : lighting > 0.12 ? "Y" : "K";
            case "nest":
                if (lighting < 0.3) {
                    return "K";
                }
                if (lighting < 0.5) {
                    return is_dither_pixel ? "Y" : "K";
                }
                return lighting > 0.82 ? "L" : "Y";
            default:
                return lighting > 0.75 ? "L" : lighting > 0.25 ? "Y" : "K";
        }
    }

    /** A dark line on the far side of each edge where one part of a crow passes in front of another. */
    private static _draw_contours(list_rows: PaletteKey[][], list_depths: number[][], list_materials: string[][]): void {
        const list_marked: [number, number][] = [];
        list_rows.forEach((row, y) => row.forEach((_, x) => {
            const material = list_materials[y]?.[x];
            if (material !== "body" && material !== "wing") {
                return;
            }
            const depth = list_depths[y]?.[x] ?? Infinity;
            for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]] as const) {
                const neighbor_depth = list_depths[y + dy]?.[x + dx] ?? Infinity;
                if (neighbor_depth < depth - SceneRenderer.CONTOUR_DEPTH) {
                    list_marked.push([x, y]);
                    return;
                }
            }
        }));
        for (const [x, y] of list_marked) {
            const row = list_rows[y];
            if (row !== undefined) {
                row[x] = "K";
            }
        }
    }

    /**
     * The eye on the side of the head facing the viewer, drawn on the grid where its centre projects, if no
     * nearer surface hides it.
     */
    private static _draw_eye(context: {
        options: SceneOptions;
        crow: CrowPlacement;
        crow_index: number;
        list_rows: PaletteKey[][];
        list_depths: number[][];
        list_owners: number[][];
    }): void {
        const { options, crow, crow_index, list_rows, list_depths, list_owners } = context;
        const pose = crow.pose;
        const head_centre = CrowModel.head_centre(pose);
        const rotation = CrowModel.head_rotation(pose);
        const list_candidates = [1, -1].map((side) => {
            const direction = { ...CrowModel.EYE_DIRECTION, z: CrowModel.EYE_DIRECTION.z * side };
            const local = Geometry.add(head_centre, Geometry.transform(rotation, Geometry.scale(direction, CrowModel.HEAD_RADII.y)));
            return SceneRenderer._project(options, SceneRenderer._from_crow(crow, local));
        });
        const eye = list_candidates.reduce((best, candidate) => (candidate.z < best.z ? candidate : best));
        const centre_x = Math.floor(eye.x);
        const centre_y = Math.floor(eye.y);
        const owner = list_owners[centre_y]?.[centre_x];
        const depth = list_depths[centre_y]?.[centre_x] ?? Infinity;
        if (owner !== crow_index || depth < eye.z - 0.1) {
            return;
        }
        const radius = options.size * SceneRenderer.EYE_RADIUS_FRACTION * crow.scale;
        const paint = (x: number, y: number, key: PaletteKey): void => {
            const row = list_rows[y];
            if (row !== undefined && x >= 0 && x < row.length && list_owners[y]?.[x] === crow_index) {
                row[x] = key;
            }
        };
        const reach = Math.ceil(radius) + 1;
        for (let y = centre_y - reach; y <= centre_y + reach; y += 1) {
            for (let x = centre_x - reach; x <= centre_x + reach; x += 1) {
                const dx = x + 0.5 - eye.x;
                const dy = y + 0.5 - eye.y;
                switch (pose.eye) {
                    case "open":
                        if (dx * dx + dy * dy <= radius * radius) {
                            paint(x, y, "L");
                        }
                        if ((dx - radius * (0.25 + 0.3 * pose.look_x)) ** 2 + (dy - radius * (0.15 - 0.3 * pose.look_y)) ** 2 <= (radius * 0.62) ** 2) {
                            paint(x, y, "K");
                        }
                        break;
                    case "closed":
                        if (Math.abs(dx) < radius && Math.abs(dy - radius * 0.3 + (dx * dx) / (radius * 3)) < 0.5) {
                            paint(x, y, "L");
                        }
                        break;
                    case "happy":
                        if (Math.abs(dx) < radius && Math.abs(dy + radius * 0.2 - (dx * dx) / (radius * 2.2)) < 0.55) {
                            paint(x, y, "L");
                        }
                        break;
                    case "cross":
                        if (Math.abs(dx) < radius && (Math.abs(dx - dy) < 0.6 || Math.abs(dx + dy) < 0.6)) {
                            paint(x, y, "L");
                        }
                        break;
                }
            }
        }
        if (pose.eye === "open") {
            const glint_x = Math.floor(eye.x + radius * 0.3 * pose.look_x);
            const glint_y = Math.floor(eye.y - radius * 0.3 - radius * 0.3 * pose.look_y);
            paint(glint_x, glint_y, "W");
            if (radius * 2 >= 5) {
                paint(glint_x + 1, glint_y, "W");
            }
        }
    }

    /** The places around a crow that floating marks are set against. */
    private static _anchors(options: SceneOptions, crow: CrowPlacement): CrowAnchors {
        const head_centre = CrowModel.head_centre(crow.pose);
        const head_top = SceneRenderer._project(options, SceneRenderer._from_crow(
            crow,
            Geometry.add(head_centre, { x: 0, y: CrowModel.HEAD_RADII.y + 0.1, z: 0 }),
        ));
        const beak_tip = SceneRenderer._project(options, SceneRenderer._from_crow(
            crow,
            Geometry.add(head_centre, Geometry.transform(CrowModel.head_rotation(crow.pose), { x: 0.83, y: -0.1, z: 0 })),
        ));
        return { head_top_x: head_top.x, head_top_y: head_top.y, beak_x: beak_tip.x, beak_y: beak_tip.y };
    }

    /** A dithered oval on the ground under a crow, smaller the higher it hops. */
    private static _draw_shadow(options: SceneOptions, crow: CrowPlacement, list_rows: PaletteKey[][]): void {
        const ground = SceneRenderer._project(options, SceneRenderer._from_crow(crow, { x: -0.02, y: CrowModel.GROUND_Y, z: 0 }));
        const shrink = 1 / (1 + crow.pose.lift * 2);
        const half_width = options.size * SceneRenderer.SHADOW_WIDTH * crow.scale * shrink;
        const half_height = options.size * SceneRenderer.SHADOW_HEIGHT * crow.scale * shrink;
        list_rows.forEach((row, y) => row.forEach((key, x) => {
            const inside = ((x + 0.5 - ground.x) / half_width) ** 2 + ((y + 0.5 - ground.y) / half_height) ** 2 <= 1;
            if (key === "." && inside && (x + y) % 2 === 0) {
                row[x] = "S";
            }
        }));
    }
}
