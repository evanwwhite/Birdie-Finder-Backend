#!/usr/bin/env python3
"""Compare the two checked-in catalogs for internal review; never imports them."""
from __future__ import annotations

import csv
import hashlib
from collections import defaultdict
from decimal import Decimal, InvalidOperation
from pathlib import Path
import re
import unicodedata
from uuid import UUID, uuid5

BACKEND = Path(__file__).resolve().parents[2]
ROOT = BACKEND.parent
REPORTS = BACKEND / "docs" / "reports"
NAMESPACE = UUID("a4028895-b718-4196-a32f-45ebf96f816b")


def rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as stream:
        return list(csv.DictReader(stream))


def write_csv(name: str, header: list[str], entries: list[list[str]]) -> None:
    with (REPORTS / name).open("w", newline="", encoding="utf-8") as stream:
        writer = csv.writer(stream)
        writer.writerow(header)
        writer.writerows(entries)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalized(value: str) -> str:
    ascii_value = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", ascii_value)


def coordinate(value: str) -> Decimal | None:
    try:
        return Decimal(value) if value else None
    except InvalidOperation:
        return None


def main() -> None:
    REPORTS.mkdir(parents=True, exist_ok=True)
    web_course_path = ROOT / "birdie_finder_web/data/courses.csv"
    app_course_path = ROOT / "birdie_finder_app/data/courses.csv"
    web_disc_path = ROOT / "birdie_finder_web/data/all_discs.csv"
    app_disc_path = ROOT / "birdie_finder_app/data/all_discs.csv"
    web_courses = {row["id"]: row for row in rows(web_course_path)}
    app_courses = {row["id"]: row for row in rows(app_course_path)}
    course_ids = sorted(set(web_courses) | set(app_courses))
    course_candidates: list[list[str]] = []
    course_conflicts: list[list[str]] = []
    hole_count_conflicts = coordinate_conflicts = coordinate_fact_conflicts = 0
    for course_id in course_ids:
        web, app = web_courses.get(course_id), app_courses.get(course_id)
        course_candidates.append([
            course_id, course_id if web and app else "",
            str(uuid5(NAMESPACE, "course:" + course_id)),
            "candidate_exact_slug" if web and app else "unmatched_source",
        ])
        if not web or not app:
            continue
        if web["holeCount"] != app["holeCount"]:
            hole_count_conflicts += 1
            course_conflicts.append([course_id, "reported_hole_count", web["holeCount"], app["holeCount"], "pending_review"])
        web_pair = (web["latitude"], web["longitude"])
        app_pair = (app["latitude"], app["longitude"])
        if web_pair != app_pair:
            coordinate_conflicts += 1
            numeric_different = tuple(map(coordinate, web_pair)) != tuple(map(coordinate, app_pair))
            coordinate_fact_conflicts += int(numeric_different)
            course_conflicts.append([
                course_id, "coordinate_pair", ",".join(web_pair), ",".join(app_pair),
                "pending_review" if numeric_different else "format_only",
            ])
    write_csv("COURSE_ID_CANDIDATES.csv", ["web_slug", "app_slug", "canonical_candidate_uuid", "status"], course_candidates)
    write_csv("COURSE_FIELD_REVIEW.csv", ["course_slug", "field", "web_value", "app_value", "status"], course_conflicts)

    web_discs = rows(web_disc_path)
    app_discs = rows(app_disc_path)
    web_by_key: dict[tuple[str, str], list[dict[str, str]]] = defaultdict(list)
    for row in web_discs:
        web_by_key[(normalized(row["manufacturer"]), normalized(row["name"]))].append(row)
    disc_rows: list[list[str]] = []
    matched_web_ids: set[str] = set()
    exact = ambiguous = unmatched = 0
    for app in sorted(app_discs, key=lambda row: row["id"]):
        options = sorted(web_by_key[(normalized(app["brand"]), normalized(app["name"]))], key=lambda row: row["id"])
        if len(options) == 1:
            exact += 1
            matched_web_ids.add(options[0]["id"])
            status = "candidate_exact_brand_mold"
            candidate_id = str(uuid5(NAMESPACE, "disc:web:" + options[0]["id"]))
        elif options:
            ambiguous += 1
            status = "ambiguous_duplicate_brand_mold"
            candidate_id = ""
        else:
            unmatched += 1
            status = "unmatched_app_mold"
            candidate_id = ""
        disc_rows.append([app["id"], app["brand"], app["name"], "|".join(row["id"] for row in options), candidate_id, status])
    write_csv("DISC_MATCH_REVIEW.csv", ["app_slug", "app_brand", "app_mold", "web_numeric_id_candidates", "canonical_candidate_uuid", "status"], disc_rows)
    web_only = [row for row in web_discs if row["id"] not in matched_web_ids]
    write_csv("DISC_WEB_UNRESOLVED.csv", ["web_numeric_id", "manufacturer", "mold", "status"],
              [[row["id"], row["manufacturer"], row["name"], "not_uniquely_matched"] for row in sorted(web_only, key=lambda row: row["id"])])

    summary = f"""# Catalog conflict review — 2026-10-03

Generated with `python3 scripts/import/review_existing_catalog.py`. The report reads the local CSVs only; it does not import or approve them. All generated UUIDs and exact-string matches are **candidates**, not published identities. Repeated runs with unchanged inputs produce identical reports.

| Input | Rows | SHA-256 |
| --- | ---: | --- |
| Web courses | {len(web_courses)} | `{digest(web_course_path)}` |
| App courses | {len(app_courses)} | `{digest(app_course_path)}` |
| Web discs | {len(web_discs)} | `{digest(web_disc_path)}` |
| App discs | {len(app_discs)} | `{digest(app_disc_path)}` |

## Course candidates

- {len(set(web_courses) & set(app_courses))} slugs occur in both clients; {len(set(web_courses) ^ set(app_courses))} occur in only one. [Full candidate crosswalk](COURSE_ID_CANDIDATES.csv).
- **{hole_count_conflicts} hole-count disagreements** and **{coordinate_conflicts} coordinate-string disagreements** appear in [the field review queue](COURSE_FIELD_REVIEW.csv). {coordinate_fact_conflicts} coordinate pairs differ numerically; {coordinate_conflicts - coordinate_fact_conflicts} is formatting-only.
- Conflicting values stay unresolved. Neither client is declared authoritative by this comparison. A reviewer must verify each field from an approved source before publication.

## Disc mold candidates

- Brand plus mold normalization yields **{exact} unique exact-key candidate matches**, **{ambiguous} ambiguous app rows**, and **{unmatched} unmatched app rows**. See [app-to-web review](DISC_MATCH_REVIEW.csv).
- **{len(web_only)} web rows lack a unique accepted app match**; see [web unresolved](DISC_WEB_UNRESOLVED.csv). This includes web rows involved in ambiguous matches.
- Normalization folds case, punctuation and diacritics only. It does not decide whether a retool, renamed manufacturer, variant, or similar name is the same mold. Every candidate remains unapproved until the source rights and identity are reviewed.

These files are an internal comparison of rights-unresolved repository data. They must not be served as a public catalog or loaded into the public tables.
"""
    (REPORTS / "CATALOG_REVIEW.md").write_text(summary, encoding="utf-8")
    print(f"Courses: {hole_count_conflicts} hole counts; {coordinate_conflicts} coordinate strings ({coordinate_fact_conflicts} numeric).")
    print(f"Discs: {exact} exact-key candidates; {ambiguous} ambiguous; {unmatched} app unmatched; {len(web_only)} web unresolved.")


if __name__ == "__main__":
    main()
