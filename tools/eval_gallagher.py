#!/usr/bin/env python3
"""Host-side match-quality evaluation on the Gallagher Collection Person Dataset (Task 2.2).

Uses OpenCV's reference YuNet/SFace with the app's pinned models and mirrors the app's
suggestion rule (SuggestionEngine): a person's score is the maximum cosine over their anchors,
a suggestion needs score >= min_score, and a candidate is ambiguous when the second-best person
is within min_margin. People already anchored in the candidate's photo are excluded.

The dataset is research-only and never redistributed: photos and ground truth stay under the
gitignored private/test-data/gallagher/. Output holds counts and rates only.

Usage: python tools/eval_gallagher.py [--root private/test-data/gallagher] [--out .logs/...json]
Requires opencv-python >= 4.8 (FaceDetectorYN, FaceRecognizerSF).
"""
from __future__ import annotations

import argparse
import json
import logging
import random
import sys
from collections import defaultdict
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
LOG = logging.getLogger("eval_gallagher")
CANVAS = 640            # YuNetTensorDecoder.canvasDimension
CONFIDENCE = 0.9        # YuNetTensorDecoder.confidenceThreshold
NMS_IOU = 0.3           # YuNetTensorDecoder.nmsIoUThreshold
MIN_SCORE, MIN_MARGIN, ANCHOR_CAP = 0.45, 0.05, 50   # SuggestionPolicy.evaluationDefault


def detect(detector, recognizer, path: Path):
    """Return [(landmarks 5x2 in source pixels, unit embedding)] for one photo."""
    image = cv2.imread(str(path))
    if image is None:
        raise ValueError(f"unreadable image: {path.name}")
    height, width = image.shape[:2]
    scale = CANVAS / max(height, width)
    canvas = np.zeros((CANVAS, CANVAS, 3), np.uint8)
    resized = cv2.resize(image, (round(width * scale), round(height * scale)), interpolation=cv2.INTER_AREA)
    canvas[:resized.shape[0], :resized.shape[1]] = resized
    _, faces = detector.detect(canvas)
    results = []
    for face in faces if faces is not None else []:
        source = face.copy()
        source[:14] /= scale                      # box and landmarks back to source pixels
        aligned = recognizer.alignCrop(image, source)
        vector = recognizer.feature(aligned).flatten().astype(np.float32)
        results.append((source[4:14].reshape(5, 2), vector / np.linalg.norm(vector)))
    return results


def match(truth, detections):
    """Pair ground-truth eyes (viewer's left, right) with YuNet eyes; returns {gt index: det index}."""
    pairs = []
    for t, (left, right) in enumerate(truth):
        iod = max(1.0, float(np.linalg.norm(np.subtract(left, right))))
        for d, (marks, _) in enumerate(detections):
            # YuNet landmark 0 is the subject's right eye, which is the viewer's left.
            error = (np.linalg.norm(marks[0] - left) + np.linalg.norm(marks[1] - right)) / 2
            if error < 0.5 * iod:
                pairs.append((error / iod, t, d))
    used_t, used_d, result = set(), set(), {}
    for _, t, d in sorted(pairs):
        if t not in used_t and d not in used_d:
            used_t.add(t); used_d.add(d); result[t] = d
    return result


def rank(candidate, photo, anchors, anchor_photos):
    """App rule: returns ('below'|'ambiguous'|'suggest', person or None, score)."""
    scores = []
    for person, vectors in anchors.items():
        if photo in anchor_photos[person]:
            continue
        scores.append((float(np.max(vectors @ candidate)), person))
    if not scores:
        return "none", None, None
    scores.sort(key=lambda item: -item[0])
    best, person = scores[0]
    if best < MIN_SCORE:
        return "below", None, best
    if len(scores) > 1 and best - scores[1][0] < MIN_MARGIN:
        return "ambiguous", None, best
    return "suggest", person, best


def evaluate(faces, unlabeled, k: int, seed: int):
    """Name k faces per person (people with more than k faces), score every other face."""
    by_person = defaultdict(list)
    for face in faces:
        by_person[face["person"]].append(face)
    rng = random.Random(seed)
    anchors, anchor_photos, anchor_ids = {}, defaultdict(set), set()
    for person, items in by_person.items():
        if len(items) <= k:
            continue
        chosen = rng.sample(items, min(k, ANCHOR_CAP))
        anchors[person] = np.stack([f["vector"] for f in chosen])
        anchor_photos[person] = {f["photo"] for f in chosen}
        anchor_ids.update(id(f) for f in chosen)
    counts = defaultdict(int)
    for face in faces:
        if id(face) in anchor_ids:
            continue
        known = face["person"] in anchors
        outcome, person, _ = rank(face["vector"], face["photo"], anchors, anchor_photos)
        counts["candidates" if known else "candidates_unknown_person"] += 1
        if outcome == "suggest":
            counts["suggested"] += 1
            counts["correct" if person == face["person"] else "wrong"] += 1
        else:
            counts[outcome] += 1
    for face in unlabeled:
        outcome, _, _ = rank(face["vector"], face["photo"], anchors, anchor_photos)
        counts["unlabeled_suggested" if outcome == "suggest" else "unlabeled_not_suggested"] += 1
    counts["people_named"] = len(anchors)
    return dict(counts)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=ROOT / "private/test-data/gallagher")
    parser.add_argument("--out", type=Path, default=ROOT / ".logs/verification/task2.2-gallagher/summary.json")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO, format="%(message)s")

    truth = defaultdict(list)
    for line in (args.root / "GallagherDatasetGT.txt").read_text().splitlines():
        name, lx, ly, rx, ry, person = line.split("\t")[:6]
        truth[name].append(((float(lx), float(ly)), (float(rx), float(ry)), int(person)))
    photos = sorted(p for p in (args.root / "photos").iterdir() if p.suffix.lower() in (".jpg", ".jpeg"))
    detector = cv2.FaceDetectorYN.create(str(ROOT / "models/face_detection_yunet_2023mar.onnx"), "",
                                         (CANVAS, CANVAS), CONFIDENCE, NMS_IOU, 5000)
    recognizer = cv2.FaceRecognizerSF.create(str(ROOT / "models/face_recognition_sface_2021dec.onnx"), "")

    faces, unlabeled, detected = [], [], 0
    for number, path in enumerate(photos, 1):
        detections = detect(detector, recognizer, path)
        detected += len(detections)
        rows = truth.get(path.name) or truth.get(path.stem + ".JPG") or truth.get(path.stem + ".jpg", [])
        pairs = match([(r[0], r[1]) for r in rows], detections)
        for t, d in pairs.items():
            faces.append({"photo": path.name, "person": rows[t][2], "vector": detections[d][1]})
        matched = set(pairs.values())
        unlabeled += [{"photo": path.name, "vector": v} for i, (_, v) in enumerate(detections) if i not in matched]
        if number % 50 == 0 or number == len(photos):
            LOG.info("processed %d/%d photos, %d faces detected", number, len(photos), detected)

    labeled_total = sum(len(rows) for rows in truth.values())
    summary = {"photos": len(photos), "detected_faces": detected, "labeled_faces": labeled_total,
               "labeled_faces_detected": len(faces), "unlabeled_detections": len(unlabeled),
               "policy": {"min_score": MIN_SCORE, "min_margin": MIN_MARGIN, "anchor_cap": ANCHOR_CAP},
               "runs": {}}
    for k in (1, 3, 5, 10):
        runs = [evaluate(faces, unlabeled, k, seed) for seed in range(5)]
        keys = sorted({key for run in runs for key in run})
        summary["runs"][f"k{k}"] = {key: round(sum(r.get(key, 0) for r in runs) / len(runs), 1) for key in keys}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(summary, indent=1))
    LOG.info("wrote %s", args.out.relative_to(ROOT) if args.out.is_relative_to(ROOT) else args.out)
    print(json.dumps(summary, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
