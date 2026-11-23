#!/usr/bin/env python3
"""Generate a synthetic landmark CSV for the replay harness.

This is a *synthetic* session, not a recording of a real person. It exists so
the replay path can be exercised without a camera. BD-10 still requires a real
hand-labelled session from the user.
"""
import math
import os

FPS = 30
DURATION = 20.0
BLINK_TIMES = [5.0, 10.0, 15.0]
BLINK_FRAMES = 4
EYE_WIDTH = 0.1
HEADER = "timestamp,faceFound,bboxX,bboxY,bboxW,bboxH,yaw,roll,leftEye,rightEye"


def eye(ratio, cx, cy):
    height = ratio * EYE_WIDTH
    points = [
        (cx - EYE_WIDTH / 2, cy),
        (cx - EYE_WIDTH / 4, cy + height / 2),
        (cx + EYE_WIDTH / 4, cy + height / 2),
        (cx + EYE_WIDTH / 2, cy),
        (cx + EYE_WIDTH / 4, cy - height / 2),
        (cx - EYE_WIDTH / 4, cy - height / 2),
    ]
    return " ".join(f"{x:.6f} {y:.6f}" for x, y in points)


def main():
    out = [HEADER]
    frame_count = int(DURATION * FPS)
    blink_starts = [round(t * FPS) for t in BLINK_TIMES]

    for index in range(frame_count):
        timestamp = index / FPS
        in_blink = any(start <= index < start + BLINK_FRAMES for start in blink_starts)
        noise = 0.006 * math.sin(index * 0.9) + 0.003 * math.cos(index * 2.3)
        ratio = 0.02 if in_blink else max(0.05, 0.30 + noise)
        near_blink = any(abs(index - start) <= 8 for start in blink_starts)
        face_found = 1 if (near_blink or index % 97 != 0) else 0

        out.append(
            ",".join(
                [
                    f"{timestamp:.6f}",
                    str(face_found),
                    "0.250000",
                    "0.250000",
                    "0.300000",
                    "0.400000",
                    "0.000000",
                    "0.000000",
                    eye(ratio, 0.36, 0.5),
                    eye(ratio, 0.64, 0.5),
                ]
            )
        )

    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "Fixtures", "synthetic_session.csv")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(out) + "\n")
    print(f"wrote {path} ({len(out) - 1} frames)")


if __name__ == "__main__":
    main()
