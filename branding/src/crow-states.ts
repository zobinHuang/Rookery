import { CrowModel, type CrowPose } from "./crow-model.ts";
import type { ColorKey } from "./pixel-grid.ts";
import { type Sprite, Sprites } from "./sprites.ts";

/**
 * A sprite placed relative to a part of the crow, in grid pixels: right and down are positive.
 */
export interface SpriteStamp {
    sprite: Sprite;
    anchor: "head" | "beak";
    dx: number;
    dy: number;
}

/**
 * One frame of a crow's animation: its pose, and what floats around it.
 */
export interface FrameSpec {
    pose: CrowPose;
    list_stamps: readonly SpriteStamp[];
}

/**
 * Which events of one code agent harness put a session in a state.
 */
export interface HarnessSignal {
    harness: string;
    signal: string;
}

/**
 * A state a code agent session can be in, the same across harnesses, with the crow's looping animation for
 * it.
 */
export interface CrowState {
    name: string;
    title: string;
    /** The state's color: its outline and the marks around it. */
    tint: ColorKey;
    meaning: string;
    list_signals: readonly HarnessSignal[];
    list_frames: readonly FrameSpec[];
}

/**
 * The states of a code agent session, as the crow acts them out. Each animation loops: its last frame leads
 * back into its first. Motion moves whole pixels, given here in grid pixels and turned into the model's
 * units with `pixels()`.
 */
export class CrowStates {
    static readonly FRAMES_PER_SECOND = 10;
    /** Three seconds a loop. */
    static readonly FRAME_COUNT = 30;
    /** The grid the single crow is drawn on, and how much of the world it shows. */
    static readonly GRID_SIZE = 64;
    static readonly CAMERA_ZOOM = 1.5;
    static readonly CAMERA_CENTRE_X = -0.0011;
    static readonly CAMERA_CENTRE_Y = 0.0147;
    /** Grid pixels the marks over the head sit lower than drawn, so they stay in the frame above a centred crow. */
    static readonly HEAD_MARK_DROP = 3;

    /** Session open, nothing asked yet or the last answer read: breathing, blinking, looking about. */
    static readonly IDLE: CrowState = {
        name: "idle",
        tint: "Y",
        title: "Idle",
        meaning: "Open and waiting for a prompt.",
        list_signals: [
            { harness: "Claude Code", signal: "SessionStart, or after Stop once the answer has been seen" },
            { harness: "Codex", signal: "Session started, no turn running" },
        ],
        list_frames: CrowStates._frames((index) => ({
            pose: CrowModel.pose({
                bob: CrowStates._breath(index, 3),
                eye: index === 11 || index === 12 ? "closed" : "open",
                head_tilt: index >= 18 && index < 25 ? 12 : 0,
                look_y: index >= 18 && index < 25 ? 0.6 : 0,
            }),
            list_stamps: [],
        })),
    };

    /** The model is working out its reply: looking up in thought while the dots of a thought fill in. */
    static readonly THINKING: CrowState = {
        name: "thinking",
        tint: "B",
        title: "Thinking",
        meaning: "The model is working out a reply.",
        list_signals: [
            { harness: "Claude Code", signal: "UserPromptSubmit, until the first tool or the answer" },
            { harness: "Codex", signal: "Turn started, model reasoning" },
        ],
        list_frames: CrowStates._frames((index) => {
            const dot_count = index < 3 ? 0 : index < 8 ? 1 : index < 13 ? 2 : index < 24 ? 3 : 0;
            return {
                pose: CrowModel.pose({
                    bob: CrowStates._breath(index, 5),
                    head_tilt: 10,
                    look_x: -0.2,
                    look_y: 0.9,
                }),
                list_stamps: [
                    { sprite: Sprites.DOT, anchor: "head" as const, dx: 4, dy: -5 },
                    { sprite: Sprites.DOT, anchor: "head" as const, dx: 9, dy: -8 },
                    { sprite: Sprites.DOT, anchor: "head" as const, dx: 14, dy: -11 },
                ].slice(0, dot_count),
            };
        }),
    };

    /** Running a tool or editing files: pecking away, sparks flying from the beak, code above. */
    static readonly WORKING: CrowState = {
        name: "working",
        tint: "T",
        title: "Working",
        meaning: "Running a tool or editing files.",
        list_signals: [
            { harness: "Claude Code", signal: "PreToolUse until PostToolUse" },
            { harness: "Codex", signal: "Running a command or applying a patch" },
        ],
        list_frames: CrowStates._frames((index) => {
            const is_peck = index % 6 === 2 || index % 6 === 3;
            return {
                pose: CrowModel.pose({
                    head_tilt: is_peck ? -16 : 0,
                    bob: is_peck ? -CrowStates.pixels(1) : 0,
                    look_y: is_peck ? -0.6 : 0,
                }),
                list_stamps: [
                    { sprite: Sprites.CODE, anchor: "head" as const, dx: 2, dy: -10 },
                    ...(index % 6 === 3 ? [{ sprite: Sprites.SPARK, anchor: "beak" as const, dx: 1, dy: -1 }] : []),
                ],
            };
        }),
    };

    /** Waiting for the user to allow a tool: hopping and flapping under a blinking mark. */
    static readonly NEEDS_APPROVAL: CrowState = {
        name: "needs-approval",
        tint: "O",
        title: "Needs approval",
        meaning: "Asking to be allowed to run a tool.",
        list_signals: [
            { harness: "Claude Code", signal: "Notification, permission prompt" },
            { harness: "Codex", signal: "Approval request for a command or a patch" },
        ],
        list_frames: CrowStates._frames((index) => {
            const hop = [0, 0, 0, 0, 2, 3, 2, 0][index % 15] ?? 0;
            return {
                pose: CrowModel.pose({
                    lift: CrowStates.pixels(hop),
                    wing_raise: hop > 0 ? 24 : 0,
                    head_turn: 18,
                    look_x: -0.4,
                }),
                list_stamps: index % 10 < 7 ? [{ sprite: Sprites.EXCLAMATION, anchor: "head" as const, dx: 4, dy: -12 }] : [],
            };
        }),
    };

    /** Waiting for an answer to a question it asked: head tipping one way then the other. */
    static readonly NEEDS_INPUT: CrowState = {
        name: "needs-input",
        tint: "P",
        title: "Needs input",
        meaning: "Asked a question and is waiting for the answer.",
        list_signals: [
            { harness: "Claude Code", signal: "Notification, waiting for input" },
            { harness: "Codex", signal: "Turn complete with a question for the user" },
        ],
        list_frames: CrowStates._frames((index) => {
            const tilt = index < 8 ? 14 : index < 15 ? 0 : index < 23 ? -10 : 0;
            return {
                pose: CrowModel.pose({
                    head_tilt: tilt,
                    bob: CrowStates._breath(index, 5),
                    look_x: tilt > 0 ? -0.3 : 0.3,
                    look_y: 0.4,
                }),
                list_stamps: [{ sprite: Sprites.QUESTION, anchor: "head" as const, dx: 4, dy: -11 + (index % 10 < 5 ? 0 : -1) }],
            };
        }),
    };

    /** Summarizing the conversation to free context: squeezing up tight as specks are drawn in. */
    static readonly COMPACTING: CrowState = {
        name: "compacting",
        tint: "C",
        title: "Compacting",
        meaning: "Summarizing the conversation to free up context.",
        list_signals: [
            { harness: "Claude Code", signal: "PreCompact, until the next prompt" },
            { harness: "Codex", signal: "Compacting the conversation" },
        ],
        list_frames: CrowStates._frames((index) => {
            const phase = index % 15;
            const squash = [0, 0.03, 0.06, 0.09, 0.11, 0.12, 0.12, 0.12, 0.1, 0.07, 0.04, 0.02, 0, 0, 0][phase] ?? 0;
            const reach = Math.max(14 - phase * 2, 2);
            return {
                pose: CrowModel.pose({ squash, eye: phase >= 3 && phase <= 9 ? "happy" : "open" }),
                list_stamps: phase < 7
                    ? [
                        { sprite: Sprites.SPECK, anchor: "head" as const, dx: -reach, dy: 6 },
                        { sprite: Sprites.SPECK, anchor: "head" as const, dx: reach + 2, dy: 6 },
                        { sprite: Sprites.SPECK, anchor: "head" as const, dx: 1, dy: 6 - reach },
                    ]
                    : [],
            };
        }),
    };

    /** Finished the task: a caw, a happy hop, and a tick. */
    static readonly DONE: CrowState = {
        name: "done",
        tint: "N",
        title: "Done",
        meaning: "Finished the turn; the answer is ready to read.",
        list_signals: [
            { harness: "Claude Code", signal: "Stop" },
            { harness: "Codex", signal: "Turn complete" },
        ],
        list_frames: CrowStates._frames((index) => {
            const is_caw = index === 4 || index === 5;
            const hop = [0, 2, 3, 3, 2, 0][index - 12] ?? 0;
            const list_stamps: SpriteStamp[] = [];
            if (index >= 4 && index < 10) {
                list_stamps.push({ sprite: Sprites.WAVE, anchor: "beak", dx: 2, dy: -3 });
            }
            if (index >= 6 && index < 10) {
                list_stamps.push({ sprite: Sprites.WAVE, anchor: "beak", dx: 5, dy: -3 });
            }
            if (index >= 10 && index < 28) {
                list_stamps.push({ sprite: Sprites.CHECK, anchor: "head", dx: 3, dy: -11 });
            }
            return {
                pose: CrowModel.pose({
                    beak_open: is_caw ? 0.1 : 0,
                    head_tilt: is_caw ? 10 : 0,
                    lift: CrowStates.pixels(hop),
                    wing_raise: hop > 0 ? 20 : 0,
                    eye: index >= 8 && index < 22 ? "happy" : "open",
                }),
                list_stamps,
            };
        }),
    };

    /** A request failed: shaking its head, feathers ruffled, under a bolt. */
    static readonly ERROR: CrowState = {
        name: "error",
        tint: "R",
        title: "Error",
        meaning: "A request or a tool failed.",
        list_signals: [
            { harness: "Claude Code", signal: "Stop after an API error, or a failed tool" },
            { harness: "Codex", signal: "Error event" },
        ],
        list_frames: CrowStates._frames((index) => {
            const shake = [0, 0, 0, 16, -16, 16, -16, 10, 0][index - 2] ?? 0;
            return {
                pose: CrowModel.pose({
                    head_turn: shake,
                    wing_raise: index % 4 < 2 && index < 12 ? 10 : 0,
                    eye: "cross",
                    bob: CrowStates._breath(index, 5),
                }),
                list_stamps: index % 8 < 5 ? [{ sprite: Sprites.BOLT, anchor: "head" as const, dx: 4, dy: -12 }] : [],
            };
        }),
    };

    /** Hit the plan's usage limit: sitting low beside an hourglass that keeps running out. */
    static readonly RATE_LIMITED: CrowState = {
        name: "rate-limited",
        tint: "I",
        title: "Limit reached",
        meaning: "Paused until the plan's usage limit resets.",
        list_signals: [
            { harness: "Claude Code", signal: "Usage limit message, until the reset time" },
            { harness: "Codex", signal: "Rate limit reached" },
        ],
        list_frames: CrowStates._frames((index) => {
            const phase = index % 15;
            const hourglass = phase < 5 ? Sprites.HOURGLASS_FULL : phase < 10 ? Sprites.HOURGLASS_HALF : Sprites.HOURGLASS_EMPTY;
            return {
                pose: CrowModel.pose({
                    squash: 0.05,
                    look_x: 0.4,
                    look_y: 0.7,
                    eye: index === 20 || index === 21 ? "closed" : "open",
                    bob: CrowStates._breath(index, 5),
                }),
                list_stamps: [{ sprite: hourglass, anchor: "head" as const, dx: 4, dy: -12 }],
            };
        }),
    };

    /** The session has exited: asleep, with z's drifting up. */
    static readonly ENDED: CrowState = {
        name: "ended",
        tint: "A",
        title: "Ended",
        meaning: "The session has exited.",
        list_signals: [
            { harness: "Claude Code", signal: "SessionEnd" },
            { harness: "Codex", signal: "Process exited" },
        ],
        list_frames: CrowStates._frames((index) => {
            const list_stamps: SpriteStamp[] = [];
            for (const offset of [0, 15]) {
                const age = (index + offset) % 30;
                if (age < 20) {
                    list_stamps.push({
                        sprite: age < 10 ? Sprites.SMALL_Z : Sprites.LARGE_Z,
                        anchor: "head",
                        dx: 3 + Math.floor(age / 4),
                        dy: -4 - Math.floor(age / 2),
                    });
                }
            }
            return {
                pose: CrowModel.pose({
                    squash: 0.08,
                    eye: "closed",
                    head_tilt: -6,
                    bob: CrowStates._breath(index, 15),
                }),
                list_stamps,
            };
        }),
    };

    /** Every state, in the order the preview shows them. */
    static readonly LIST_STATES: readonly CrowState[] = [
        CrowStates.IDLE,
        CrowStates.THINKING,
        CrowStates.WORKING,
        CrowStates.NEEDS_APPROVAL,
        CrowStates.NEEDS_INPUT,
        CrowStates.COMPACTING,
        CrowStates.DONE,
        CrowStates.ERROR,
        CrowStates.RATE_LIMITED,
        CrowStates.ENDED,
    ];

    /**
     * A distance on the single crow's grid in the model's units.
     *
     * @param count - how many grid pixels
     * @returns the distance
     */
    static pixels(count: number): number {
        return (count * 2 * CrowStates.CAMERA_ZOOM) / CrowStates.GRID_SIZE;
    }

    /** A loop's frames, one per index. */
    private static _frames(frame_at: (index: number) => FrameSpec): readonly FrameSpec[] {
        return Array.from({ length: CrowStates.FRAME_COUNT }, (_, index) => frame_at(index));
    }

    /** A breath: up a pixel and back down, holding each for some frames; twice the hold divides a loop. */
    private static _breath(index: number, hold: number): number {
        return Math.floor(index / hold) % 2 === 1 ? CrowStates.pixels(1) : 0;
    }
}
