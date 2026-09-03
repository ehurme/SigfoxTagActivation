# AGENTS.md — SigfoxTagActivation

Guidance for AI coding agents working in this repository. All project code and documentation is in English.

## Project overview

This is an **R project** (RStudio project, `SigfoxTagActivation.Rproj`) for **bat migration research**: a SQLite-backed system that tracks SigFox tag activation/calibration periods. It imports Wildcloud CSV exports, auto-detects calibration periods (tags at rest: median VeDBA < 20 m/s² for 3+ consecutive hours), prevents duplicate uploads via SHA256 file hashing, lets users label events (location, description, notes, status) through a Shiny web app or programmatically, groups co-occurring tags, and exports analysis-ready CSVs.

It is **not an R package** — there is no `DESCRIPTION`, no `NAMESPACE`, no `tests/`. It is a collection of plain R scripts that are `source()`-ed into the session, sharing a SQLite database (`calibration_events.db`, committed to the repo, schema version 1.0).

## File map

| File | Role |
|------|------|
| `01_setup.R` | One-time setup: installs missing packages, `source()`s the two modules, creates the DB if absent |
| `calibration_db_schema.R` | SQLite schema creation (`init_calibration_db`), connection helper, and all DB-level functions (insert/label/query events, dedup, import logging) |
| `calibration_import_functions.R` | Wildcloud CSV parsing (per-decoder), calibration-period detection, co-occurrence grouping, the end-to-end `process_wildcloud_import()` pipeline, CSV export |
| `calibration_shiny_app.R` | Full Shiny app (calls `shinyApp()` at the bottom) — events table, labeling UI, groups/heatmap, import history |
| `example_workflow.R` | End-to-end demo script (init → import → label → group → export); uses its own `example_calibration.db` |
| `diagnostic_import_1.R` | Debug script for "no events detected" cases: inspects VeDBA columns/timestamps/gaps and sweeps detection thresholds |
| `CALIBRATION_DB_README.md` | User-facing documentation: full schema, API reference, troubleshooting |
| `calibration_events.db` | Live SQLite database (6 tables, see README for schema) |

## Technology stack and dependencies

R 4.0+, SQLite 3.0+. Required packages: `DBI`, `RSQLite`, `data.table`, `tidyverse`, `lubridate`, `shiny`, `shinyjs`, `DT`, `ggplot2`, `digest`, `bslib`.

There is no dependency lockfile or `renv`; `01_setup.R` installs anything missing from CRAN. Known dependency quirks:

- `calibration_shiny_app.R` calls `library(shinyTable)` (line 6), but `shinyTable` is **not** in the setup/README package list and is not on CRAN — the app will fail at load unless the package is installed or the line removed. `shinyTable` does not appear to be used anywhere in the file.
- `bslib` is used (`bslib::bs_theme()`) but never `library()`-ed in the app.
- `%||%` (used in the app's label pre-fill observer) comes from `rlang`/tidyverse.

## Build, run, and test

There is no build step and **no automated test suite** (no testthat). Verification is by running the scripts in R:

```r
# Setup (once)
source("01_setup.R")

# Launch the web app (from the project root; the app expects cwd = project root
# because it opens "calibration_events.db" by relative path)
source("calibration_shiny_app.R")
shiny::runApp()

# Headless end-to-end check (creates example_calibration.db)
source("example_workflow.R")

# Debug an import that detects no events
source("diagnostic_import_1.R")   # edit csv_path at the top first
```

R is not on this machine's PATH in Git Bash; run scripts in RStudio/Positron or a full R terminal. The user works on Windows.

## Architecture and code organization

- **Module pattern**: `calibration_db_schema.R` and `calibration_import_functions.R` are loaded with `source()` and each ends with a `message("[...] ... loaded successfully")`. They must be sourced before the Shiny app or any pipeline use — the app itself does **not** source them, so load them first in the session.
- **Layering**: import/parsing/detection (pure functions on data frames) → DB write/read functions (all take `conn` as first arg) → Shiny UI/server on top. All SQL goes through `DBI` with parameterized queries (`params = list(...)`); `PRAGMA foreign_keys = ON` is set on every connection.
- **Decoder abstraction**: `import_wildcloud_csv()` dispatches on `decoder` to private parsers (`.parse_nanofox_finescale`, `.parse_tinyfoxbatt`) that map Wildcloud columns to the standard schema. Wildcloud CSVs are semicolon-delimited; timestamps parse as `"DD.MM.YYYY, HH:%M:%S"`. Adding a new tag type = adding a parser + a `switch` branch.
- **Detection logic**: records are split into continuous blocks (gap ≤ 1 h); a block ≥ `min_duration_hours` (default 3) with ≥ `min_samples` (default 5) records and median VeDBA < `vedba_threshold` (default 20) becomes a `pending` event. Deduplication is two-level: SHA256 of the whole file (`wildcloud_imports.file_hash`) plus exact tag/start/end match against existing events.
- **Status lifecycle**: `pending` (auto-detected) → `confirmed`/`rejected` (user-labeled) via `label_calibration_event()`; duplicates get `status = 'duplicate'` plus `duplicate_of_event_id`. `get_calibration_events(..., exclude_duplicates = TRUE)` is the default query path.
- The default DB path everywhere is the relative string `"calibration_events.db"`, so scripts assume the working directory is the project root.

## Code style conventions

- Functions use `snake_case` and carry roxygen-style comment blocks (`#'` with `@param`/`@return`/`@export`), even though no package is built — keep this habit.
- DB-domain functions live in the schema file; import/detection/export functions in the import file. Keep that split.
- Scripts use heavy banner comments (`# ====` blocks), progress output via `cat()`/`message()` with emoji checkmarks (✓/✗/⚠️), and `sprintf` formatting.
- Private helpers are prefixed with a dot (`.parse_nanofox_finescale`).
- RStudio project settings: 2-space indentation, UTF-8.
- `.gitignore` covers only RStudio artifacts (`.Rproj.user`, `.Rhistory`, `.RData`, `.Ruserdata`) — database files and CSV exports are tracked/left untracked by default.

## Known gaps and gotchas (verify before "fixing silently")

- **Shiny label saving writes placeholder notes**: in `calibration_shiny_app.R` the textarea has no input binding, so `notes` is hardcoded to the string `"placeholder"` in the save observer. A real fix requires a proper input binding (e.g. `shiny::textAreaInput`).
- **Co-occurrence groups are never persisted**: `identify_co_occurrence_groups()` returns a data frame, but nothing writes to the `co_occurrence_groups`/`group_members` tables; the app's "Groups" tab queries those tables and therefore always shows "No groups found".
- **Hardcoded paths**: `example_workflow.R` points at a `/root/.claude/uploads/...` path that does not exist on this machine (the import step skips gracefully); `diagnostic_import_1.R` has a user-specific Dropbox path. Both are intended to be edited before running.
- `01_setup.R` calls `init_calibration_db(db_path)` and `get_db_connection(db_path)` without loading `DBI`/`RSQLite` itself in some paths — run it after the module `source()` lines (the script does source the modules first, which loads the libraries).

## Security and data considerations

- The SQLite files (`calibration_events.db`) are real research data — do not delete or recreate them; `init_calibration_db(overwrite = TRUE)` destroys data.
- The DB stores user emails/names in `labeled_by`/`imported_by`; exports written by the app (`calibration_export_*.csv`) land in the project root.
- Wildcloud CSV inputs live outside the repo (Dropbox paths); never commit them.
- No secrets, credentials, or network calls exist in the codebase.

## Documentation

`CALIBRATION_DB_README.md` is the authoritative user documentation (schema tables, full API reference, configuration thresholds, troubleshooting). If you change the schema, detection defaults, or public function signatures, update that README too.
