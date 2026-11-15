import { Geometry, type Mat3, type Vec3 } from "./geometry.ts";

/**
 * How the crow's eye is drawn: open with a pupil, closed in sleep, squeezed shut in delight, crossed out
 * when something broke, or open and looking up.
 */
export type EyeShape = "open" | "closed" | "happy" | "cross";

/**
 * Everything about the crow that an animation frame changes. Lengths are in the model's units, where the
 * crow stands about two tall; angles are in degrees.
 */
export interface CrowPose {
    /** The body and head rising and falling with a breath, the feet staying put. */
    bob: number;
    /** The whole crow off the ground, for a hop. */
    lift: number;
    /** The head tipped toward the back (positive) or the beak (negative). */
    head_tilt: number;
    /** The head turned toward the viewer (positive) or away. */
    head_turn: number;
    /** How far the lower beak drops. */
    beak_open: number;
    /** The near wing lifted from the body. */
    wing_raise: number;
    /** The body pressed down and spread, as a fraction of its height. */
    squash: number;
    eye: EyeShape;
    /** Where the pupil looks, in eye radii from the middle: right and up are positive. */
    look_x: number;
    look_y: number;
}

/**
 * What a point of the crow is made of, which picks how it is shaded.
 */
export type CrowMaterial = "body" | "wing" | "beak" | "feet";

/**
 * The distance from a point to the nearest surface, and what that surface is.
 */
export interface SurfaceSample {
    distance: number;
    material: CrowMaterial | "nest";
}

/**
 * The crow as a signed distance field in its own space: x toward the beak, y up, z toward its left side. The
 * body and an oversized head blend into one another; the beak is two cones, the wing, the tail and the tuft
 * flattened ellipsoids, and the feet small pads.
 */
export class CrowModel {
    /** The pose of a crow standing still and looking ahead. */
    static readonly REST_POSE: CrowPose = {
        bob: 0,
        lift: 0,
        head_tilt: 0,
        head_turn: 0,
        beak_open: 0,
        wing_raise: 0,
        squash: 0,
        eye: "open",
        look_x: 0,
        look_y: 0,
    };
    static readonly HEAD_CENTRE: Vec3 = { x: 0.28, y: 0.42, z: 0 };
    static readonly HEAD_RADII: Vec3 = { x: 0.43, y: 0.41, z: 0.41 };
    /** Where the eye sits on the head, as a direction from its centre, on the crow's left side. */
    static readonly EYE_DIRECTION: Vec3 = Geometry.normalize({ x: 0.62, y: 0.28, z: 0.73 });
    /** The ground the feet stand on. */
    static readonly GROUND_Y = -0.8;
    /** How much the body and head melt into each other at the neck. */
    static readonly NECK_BLEND = 0.12;

    private static readonly _BODY_ROTATION = Geometry.rotation("z", 12);
    private static readonly _WING_ROTATION = Geometry.multiply(Geometry.rotation("z", -18), Geometry.rotation("y", 10));
    private static readonly _TAIL_ROTATION = Geometry.rotation("z", 30);
    private static readonly _TUFT_ROTATIONS: readonly Mat3[] = [Geometry.rotation("z", 20), Geometry.rotation("z", 40)];

    /**
     * A pose from the changes to the rest pose.
     *
     * @param changes - the fields that differ from standing still
     * @returns the full pose
     */
    static pose(changes: Partial<CrowPose>): CrowPose {
        return { ...CrowModel.REST_POSE, ...changes };
    }

    /**
     * The rotation that turns and tips the head, about its centre.
     *
     * @param pose - the pose
     * @returns the head's rotation
     */
    static head_rotation(pose: CrowPose): Mat3 {
        return Geometry.multiply(Geometry.rotation("z", pose.head_tilt), Geometry.rotation("y", pose.head_turn));
    }

    /**
     * The centre of the head in the crow's space, raised with the breath and the hop.
     *
     * @param pose - the pose
     * @returns the head's centre
     */
    static head_centre(pose: CrowPose): Vec3 {
        return Geometry.add(CrowModel.HEAD_CENTRE, { x: 0, y: pose.bob + pose.lift, z: 0 });
    }

    /**
     * The surface nearest a point in the crow's space.
     *
     * @param point - the point
     * @param pose - the pose
     * @returns the distance and the material there
     */
    static sample(point: Vec3, pose: CrowPose): SurfaceSample {
        const rise = pose.bob + pose.lift;
        const lifted = { x: point.x, y: point.y - pose.lift, z: point.z };
        const squash_y = 1 - pose.squash;
        const squash_xz = 1 + pose.squash * 0.5;
        const body = CrowModel._ellipsoid(
            lifted,
            { x: -0.05, y: -0.18 + pose.bob - pose.squash * 0.25, z: 0 },
            { x: 0.6 * squash_xz, y: 0.5 * squash_y, z: 0.48 * squash_xz },
            CrowModel._BODY_ROTATION,
        );
        const head_centre = CrowModel.head_centre(pose);
        const head_centre_squashed = { ...head_centre, y: head_centre.y - pose.squash * 0.35 };
        const head = CrowModel._ellipsoid(point, head_centre_squashed, CrowModel.HEAD_RADII, Geometry.IDENTITY);
        const torso = CrowModel._smooth_min(body, head, CrowModel.NECK_BLEND);
        const head_space = Geometry.add(
            Geometry.transform(Geometry.transpose(CrowModel.head_rotation(pose)), Geometry.sub(point, head_centre_squashed)),
            head_centre_squashed,
        );
        const beak_base = Geometry.add(head_centre_squashed, { x: 0.27, y: -0.02, z: 0 });
        const upper_beak = CrowModel._cone(
            head_space,
            Geometry.add(beak_base, { x: 0, y: 0.02, z: 0 }),
            Geometry.add(beak_base, { x: 0.56, y: -0.08 - pose.beak_open * 0.5, z: 0 }),
            0.19,
        );
        const lower_beak = CrowModel._cone(
            head_space,
            Geometry.add(beak_base, { x: 0, y: -0.08, z: 0 }),
            Geometry.add(beak_base, { x: 0.4, y: -0.16 - pose.beak_open * 1.6, z: 0 }),
            0.12,
        );
        const tuft = Math.min(
            CrowModel._ellipsoid(
                head_space,
                Geometry.add(head_centre_squashed, { x: -0.05, y: 0.42, z: 0 }),
                { x: 0.05, y: 0.12, z: 0.05 },
                CrowModel._TUFT_ROTATIONS[0] ?? Geometry.IDENTITY,
            ),
            CrowModel._ellipsoid(
                head_space,
                Geometry.add(head_centre_squashed, { x: -0.15, y: 0.38, z: 0 }),
                { x: 0.045, y: 0.1, z: 0.045 },
                CrowModel._TUFT_ROTATIONS[1] ?? Geometry.IDENTITY,
            ),
        );
        const wing = CrowModel._ellipsoid(
            point,
            { x: -0.18, y: -0.12 + rise - pose.squash * 0.2, z: 0.36 * squash_xz },
            { x: 0.46, y: 0.3, z: 0.12 },
            Geometry.multiply(Geometry.rotation("z", pose.wing_raise), CrowModel._WING_ROTATION),
        );
        const tail = CrowModel._ellipsoid(
            point,
            { x: -0.72, y: -0.42 + rise - pose.squash * 0.2, z: 0 },
            { x: 0.36, y: 0.09, z: 0.2 },
            CrowModel._TAIL_ROTATION,
        );
        let feet = Infinity;
        for (const side of [1, -1]) {
            feet = Math.min(
                feet,
                CrowModel._ellipsoid(lifted, { x: 0.08, y: -0.76, z: 0.16 * side }, { x: 0.15, y: 0.045, z: 0.08 }, Geometry.IDENTITY),
                CrowModel._ellipsoid(lifted, { x: 0, y: -0.66, z: 0.16 * side }, { x: 0.05, y: 0.12, z: 0.05 }, Geometry.IDENTITY),
            );
        }
        let sample: SurfaceSample = { distance: torso, material: "body" };
        for (const candidate of [
            { distance: Math.min(upper_beak, lower_beak), material: "beak" as const },
            { distance: tuft, material: "body" as const },
            { distance: wing, material: "wing" as const },
            { distance: tail, material: "body" as const },
            { distance: feet, material: "feet" as const },
        ]) {
            if (candidate.distance < sample.distance) {
                sample = candidate;
            }
        }
        return sample;
    }

    /** The distance to an ellipsoid, close enough near its surface; the rotation turns it into place. */
    private static _ellipsoid(point: Vec3, centre: Vec3, radii: Vec3, rotation: Mat3): number {
        const local = Geometry.transform(Geometry.transpose(rotation), Geometry.sub(point, centre));
        const k0 = Math.hypot(local.x / radii.x, local.y / radii.y, local.z / radii.z);
        const k1 = Math.hypot(local.x / (radii.x * radii.x), local.y / (radii.y * radii.y), local.z / (radii.z * radii.z));
        return (k0 * (k0 - 1)) / Math.max(k1, 1e-9);
    }

    /** The distance to a cone narrowing from a round base to a point. */
    private static _cone(point: Vec3, base: Vec3, tip: Vec3, radius: number): number {
        const axis = Geometry.sub(tip, base);
        const length = Geometry.length(axis);
        const along = Math.min(Math.max(Geometry.dot(Geometry.sub(point, base), axis) / (length * length), 0), 1);
        const nearest = Geometry.add(base, Geometry.scale(axis, along));
        return Geometry.length(Geometry.sub(point, nearest)) - radius * (1 - along) * 0.9;
    }

    /** The union of two distances, rounded where they meet. */
    private static _smooth_min(a: number, b: number, blend: number): number {
        const h = Math.min(Math.max(0.5 + (0.5 * (b - a)) / blend, 0), 1);
        return b * (1 - h) + a * h - blend * h * (1 - h);
    }
}
