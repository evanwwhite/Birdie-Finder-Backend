# Catalog conflict review — 2026-10-03

Generated with `python3 scripts/import/review_existing_catalog.py`. The report reads the local CSVs only; it does not import or approve them. All generated UUIDs and exact-string matches are **candidates**, not published identities. Repeated runs with unchanged inputs produce identical reports.

| Input | Rows | SHA-256 |
| --- | ---: | --- |
| Web courses | 7008 | `c2044fb428acd3104a667b5049a5128f6569a56e31e765dab89fe1630c2d14f1` |
| App courses | 7008 | `6b7569e48a496aa6f0386871e515a087fd0bee701679b6107def78e05a4948bd` |
| Web discs | 1918 | `93ba798fb6a3f53fdd70d007572f996d8c6bb9051ecb847eabc1f2bb483f5e15` |
| App discs | 1147 | `265e502829a237a6d72837a9a44a1cc398383c8af5ba8abf9c2a78fc1190c098` |

## Course candidates

- 7008 slugs occur in both clients; 0 occur in only one. [Full candidate crosswalk](COURSE_ID_CANDIDATES.csv).
- **330 hole-count disagreements** and **235 coordinate-string disagreements** appear in [the field review queue](COURSE_FIELD_REVIEW.csv). 234 coordinate pairs differ numerically; 1 is formatting-only.
- Conflicting values stay unresolved. Neither client is declared authoritative by this comparison. A reviewer must verify each field from an approved source before publication.

## Disc mold candidates

- Brand plus mold normalization yields **774 unique exact-key candidate matches**, **4 ambiguous app rows**, and **369 unmatched app rows**. See [app-to-web review](DISC_MATCH_REVIEW.csv).
- **1144 web rows lack a unique accepted app match**; see [web unresolved](DISC_WEB_UNRESOLVED.csv). This includes web rows involved in ambiguous matches.
- Normalization folds case, punctuation and diacritics only. It does not decide whether a retool, renamed manufacturer, variant, or similar name is the same mold. Every candidate remains unapproved until the source rights and identity are reviewed.

These files are an internal comparison of rights-unresolved repository data. They must not be served as a public catalog or loaded into the public tables.
