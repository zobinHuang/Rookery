/**
 * A point or direction in 3D.
 */
export interface Vec3 {
    x: number;
    y: number;
    z: number;
}

/**
 * A 3 by 3 matrix, row by row.
 */
export type Mat3 = readonly [number, number, number, number, number, number, number, number, number];

/**
 * The vector and matrix arithmetic the renderer needs.
 */
export class Geometry {
    static readonly IDENTITY: Mat3 = [1, 0, 0, 0, 1, 0, 0, 0, 1];

    /** A vector from its components. */
    static vec(x: number, y: number, z: number): Vec3 {
        return { x, y, z };
    }

    /** The sum of two vectors. */
    static add(a: Vec3, b: Vec3): Vec3 {
        return { x: a.x + b.x, y: a.y + b.y, z: a.z + b.z };
    }

    /** The first vector less the second. */
    static sub(a: Vec3, b: Vec3): Vec3 {
        return { x: a.x - b.x, y: a.y - b.y, z: a.z - b.z };
    }

    /** A vector times a number. */
    static scale(a: Vec3, factor: number): Vec3 {
        return { x: a.x * factor, y: a.y * factor, z: a.z * factor };
    }

    /** The dot product. */
    static dot(a: Vec3, b: Vec3): number {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    /** A vector's length. */
    static length(a: Vec3): number {
        return Math.hypot(a.x, a.y, a.z);
    }

    /** A vector of length one in the same direction. */
    static normalize(a: Vec3): Vec3 {
        const length = Geometry.length(a);
        return length === 0 ? a : Geometry.scale(a, 1 / length);
    }

    /**
     * A rotation about one of the axes.
     *
     * @param axis - the axis to turn about
     * @param degrees - the angle, counterclockwise looking down the axis
     * @returns the rotation, which turns a vector when it multiplies it from the left
     */
    static rotation(axis: "x" | "y" | "z", degrees: number): Mat3 {
        const radians = (degrees * Math.PI) / 180;
        const c = Math.cos(radians);
        const s = Math.sin(radians);
        switch (axis) {
            case "x":
                return [1, 0, 0, 0, c, -s, 0, s, c];
            case "y":
                return [c, 0, s, 0, 1, 0, -s, 0, c];
            case "z":
                return [c, -s, 0, s, c, 0, 0, 0, 1];
        }
    }

    /** The product of two matrices, the right one applied first. */
    static multiply(m: Mat3, n: Mat3): Mat3 {
        const cell = (row: number, column: number): number => (m[row * 3] ?? 0) * (n[column] ?? 0)
            + (m[row * 3 + 1] ?? 0) * (n[3 + column] ?? 0)
            + (m[row * 3 + 2] ?? 0) * (n[6 + column] ?? 0);
        return [cell(0, 0), cell(0, 1), cell(0, 2), cell(1, 0), cell(1, 1), cell(1, 2), cell(2, 0), cell(2, 1), cell(2, 2)];
    }

    /** A matrix applied to a vector. */
    static transform(m: Mat3, v: Vec3): Vec3 {
        return {
            x: m[0] * v.x + m[1] * v.y + m[2] * v.z,
            y: m[3] * v.x + m[4] * v.y + m[5] * v.z,
            z: m[6] * v.x + m[7] * v.y + m[8] * v.z,
        };
    }

    /** The transpose, which undoes a rotation. */
    static transpose(m: Mat3): Mat3 {
        return [m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]];
    }
}
