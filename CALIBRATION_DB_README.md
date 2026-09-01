# SigFox Tag Calibration Database

A comprehensive SQLite-based system for tracking tag activation/deactivation periods and managing calibration data for bat migration research with Wildcloud imports.

## Overview

This system helps you:

- **Import Wildcloud-formatted tag data** (NanoFox, TinyFoxBatt, etc.)
- **Automatically detect calibration periods** (3+ hours at rest with low VeDBA)
- **Prevent duplicate uploads** via file-hash deduplication
- **Label calibration events** interactively (location, description, notes)
- **Group co-occurring tags** (tags activated together on same shelf)
- **Export analysis-ready datasets** for further processing

## Key Features

### Automated Detection

Tags showing **median VeDBA < 20 m/s² for 3+ consecutive hours** are flagged as calibration periods. This typically indicates:
- Tags sitting on a shelf together
- Environmental/sensor testing
- Pre-deployment calibration

### Duplicate Detection

Every imported file is hashed (SHA256) to prevent accidental re-uploads. The database logs:
- File path and hash
- Date range covered
- Tags included
- Import timestamp and user

### Interactive Labeling

Use the Shiny web app to:
- Review auto-detected events in a sortable table
- Label with location ("2nd floor, office, shelf corner")
- Add brief descriptions and detailed notes
- Mark as confirmed, rejected, or pending
- Track who labeled what and when

### Co-occurrence Grouping

Automatically identify tags that were low-activity simultaneously (within 60 minutes of each other), indicating they were likely on the same shelf during activation.

## Installation

### Prerequisites

```r
install.packages(c(
  "DBI",           # Database interface
  "RSQLite",       # SQLite driver
  "data.table",    # Fast CSV parsing
  "tidyverse",     # Data manipulation & viz
  "lubridate",     # Time handling
  "shiny",         # Web app framework
  "shinyjs",       # JavaScript bindings for Shiny
  "DT",            # DataTable integration
  "ggplot2",       # Plotting
  "digest",        # File hashing
  "bslib"          # Bootstrap theming
))
```

### Setup

1. **Clone or copy files to your project directory**:
   ```
   your_project/
   ├── calibration_db_schema.R
   ├── calibration_import_functions.R
   ├── calibration_shiny_app.R
   ├── CALIBRATION_DB_README.md
   └── calibration_events.db (created on first run)
   ```

2. **Initialize the database**:
   ```r
   source("calibration_db_schema.R")
   
   # Create database (if first time)
   init_calibration_db("calibration_events.db")
   ```

## Usage

### 1. Quick Start (R Console)

```r
# Load all modules
source("calibration_db_schema.R")
source("calibration_import_functions.R")

# Connect to database
conn <- get_db_connection("calibration_events.db")

# Import a Wildcloud CSV file
result <- process_wildcloud_import(
  conn,
  file_path = "path/to/wildcloud_export.csv",
  decoder = "nanofox_finescalepressure",
  imported_by = "your.name@email.com"
)

# View results
cat(sprintf("Imported: %d events\n", result$n_events_inserted))
print(result$calibration_events)

# Export confirmed events
export_calibration_report(conn, "calibration_summary.csv", status = "confirmed")
```

### 2. Using the Shiny Web App

```r
# Load Shiny app
source("calibration_shiny_app.R")

# Run in browser
shiny::runApp("calibration_shiny_app.R")
```

Then:
1. Click **"Import Wildcloud CSV"** to upload data
2. Navigate to **"Events"** tab to review auto-detected calibration periods
3. Click on a row and go to **"Label Event"** to add metadata
4. Check **"Groups & Patterns"** for co-occurrence analysis
5. Use **"Export Report"** to save labeled events

### 3. Workflow Example: Multi-file Import

```r
source("calibration_db_schema.R")
source("calibration_import_functions.R")

conn <- get_db_connection("calibration_events.db")

# Import multiple files
csv_files <- list.files("data/wildcloud_exports/", pattern = "*.csv", full.names = TRUE)

for (file in csv_files) {
  result <- process_wildcloud_import(
    conn,
    file_path = file,
    decoder = "nanofox_finescalepressure",
    imported_by = "batch_import"
  )
  
  if (!result$is_duplicate) {
    cat(sprintf("✓ %s: %d events added\n", basename(file), result$n_events_inserted))
  } else {
    cat(sprintf("⊘ %s: already imported (import_id: %d)\n", basename(file), result$import_id))
  }
}

# View all pending events
events <- get_calibration_events(conn, status = "pending")
cat(sprintf("Total pending: %d\n", nrow(events)))
```

## Database Schema

### Tables

#### `tags`
Core table of all tags in the study.

| Column | Type | Notes |
|--------|------|-------|
| `tag_id` | TEXT (PK) | Device identifier (e.g., "120D915") |
| `tag_type` | TEXT | Decoder used (e.g., "nanofox_finescalepressure") |
| `study_id` | TEXT | Study/project identifier |
| `first_seen` | DATE | First data point for this tag |
| `last_seen` | DATE | Most recent data point |
| `notes` | TEXT | User notes (species, capture location, etc.) |

#### `calibration_events`
Main table: detected or labeled calibration periods.

| Column | Type | Notes |
|--------|------|-------|
| `event_id` | INTEGER (PK) | Auto-increment |
| `tag_id` | TEXT (FK) | Link to tags table |
| `start_time` | TIMESTAMP | Event start |
| `end_time` | TIMESTAMP | Event end |
| `duration_hours` | REAL | Computed end - start |
| `median_vedba` | REAL | Median activity (m/s²) |
| `mean_vedba` | REAL | Mean activity |
| `max_vedba` | REAL | Peak activity |
| `n_samples` | INTEGER | Records in event |
| `detection_method` | TEXT | "auto_detect" or "manual" |
| `status` | TEXT | "pending", "confirmed", or "rejected" |
| `label_location` | TEXT | User label: location (e.g., "2nd floor, shelf") |
| `label_description` | TEXT | Brief description |
| `label_notes` | TEXT | Detailed notes |
| `labeled_by` | TEXT | Username of labeler |
| `labeled_at` | TIMESTAMP | When labeled |
| `duplicate_of_event_id` | INTEGER (FK) | Links to canonical event if duplicate |

#### `wildcloud_imports`
Import log for deduplication tracking.

| Column | Type | Notes |
|--------|------|-------|
| `import_id` | INTEGER (PK) | Auto-increment |
| `file_path` | TEXT | Original file location |
| `file_hash` | TEXT (UNIQUE) | SHA256 of file content |
| `n_records` | INTEGER | Records in file |
| `date_range_start` | DATE | First record date |
| `date_range_end` | DATE | Last record date |
| `tags_included` | TEXT | Pipe-delimited list of tag IDs |
| `imported_by` | TEXT | Username |
| `import_notes` | TEXT | Decoder, thresholds used |

#### `co_occurrence_groups`
Groups of tags activated together (within 60 minutes).

| Column | Type | Notes |
|--------|------|-------|
| `group_id` | INTEGER (PK) | Auto-increment |
| `group_name` | TEXT (UNIQUE) | Human-readable name |
| `start_time` | TIMESTAMP | Group start (min of all events) |
| `end_time` | TIMESTAMP | Group end (max of all events) |
| `location` | TEXT | Shared location label |
| `n_tags` | INTEGER | Number of tags in group |
| `confidence` | REAL | Group cohesion score |

#### `group_members`
Many-to-many link: calibration events ↔ co-occurrence groups.

| Column | Type | Notes |
|--------|------|-------|
| `group_member_id` | INTEGER (PK) | Auto-increment |
| `group_id` | INTEGER (FK) | Co-occurrence group |
| `event_id` | INTEGER (FK) | Calibration event |

#### `raw_sensor_data` (optional)
Stores raw measurements for trending/analysis (can be disabled for storage efficiency).

| Column | Type | Notes |
|--------|------|-------|
| `record_id` | INTEGER (PK) | Auto-increment |
| `tag_id` | TEXT (FK) | Tag identifier |
| `timestamp` | TIMESTAMP | Measurement time |
| `vedba` | REAL | VeDBA (m/s²) |
| `pressure` | REAL | Barometric pressure |
| `temperature` | REAL | Temperature (°C) |
| `import_id` | INTEGER (FK) | Which import this came from |

## Wildcloud CSV Format

Expected format for NanoFox FinescalePressure (semicolon-delimited):

```
Device;Time (UTC);Raw Data;Position;Radius (m) (Source/Status);...;VeDBA sum 0 min ago (m/s²);...;Pressure 0 min ago (mbar);...
120D915;31.08.2026, 12:50:42;0000000000cbcbcbcbcb1314;46.070553, 6.49601;4900 (2/1);...;0.000000;...;972.7;...
```

**Key columns used:**
- `Device` → tag_id
- `Time (UTC)` → timestamp (parsed as "DD.MM.YYYY, HH:MM:SS")
- `VeDBA sum X min ago` → vedba (uses most recent non-zero value)
- `Pressure X min ago` → pressure
- `Temperature` → temperature

## API Reference

### Database Functions

#### Initialization & Connection

```r
# Create or validate database
init_calibration_db(db_path, overwrite = FALSE)

# Get connection object
conn <- get_db_connection(db_path)
```

#### Import & Detection

```r
# Import single file with auto-detection
result <- process_wildcloud_import(
  conn, 
  file_path, 
  decoder = "nanofox_finescalepressure",
  imported_by = "user@email.com",
  min_duration_hours = 3,
  vedba_threshold = 20
)

# Low-level: parse CSV only
raw_data <- import_wildcloud_csv(file_path, decoder)

# Low-level: detect periods in data
events <- detect_calibration_periods(
  raw_data,
  min_duration_hours = 3,
  vedba_threshold = 20,
  min_samples = 5
)

# Low-level: find tags activated together
groups <- identify_co_occurrence_groups(
  calibration_events,
  overlap_minutes = 60
)
```

#### Labeling & Management

```r
# Add label to event
label_calibration_event(
  conn,
  event_id,
  location = "2nd floor, office, shelf",
  description = "Pre-deployment calibration",
  notes = "Activated by Edward at 10:30 AM",
  labeled_by = "edward@example.com",
  status = "confirmed"
)

# Mark as duplicate
mark_duplicate_event(conn, event_id, duplicate_of_event_id)
```

#### Querying

```r
# Get filtered events
events <- get_calibration_events(
  conn,
  tag_id = c("120D915", "9ED555"),
  status = "confirmed",
  location = "2nd floor",
  start_date = "2026-08-25",
  end_date = "2026-08-31",
  exclude_duplicates = TRUE
)

# Export to CSV
export_calibration_report(conn, "export.csv", status = "confirmed")
```

#### Deduplication

```r
# Compute file hash
hash <- compute_file_hash("path/to/file.csv")

# Check if already imported
dup_result <- check_import_duplicate(conn, hash)
if (dup_result$is_duplicate) {
  cat("File already imported:", dup_result$import_id)
}

# Log import metadata
import_id <- log_wildcloud_import(
  conn,
  file_path = "path/to/file.csv",
  file_hash = hash,
  n_records = nrow(data),
  date_range_start = min(data$timestamp),
  date_range_end = max(data$timestamp),
  tags_included = unique(data$tag_id),
  imported_by = "edward@example.com"
)
```

## Configuration

### Detection Thresholds

Adjust these when importing:

- **`min_duration_hours`**: Minimum consecutive hours to qualify as calibration (default: 3)
- **`vedba_threshold`**: Maximum median VeDBA to be considered "at rest" (default: 20 m/s²)
- **`min_samples`**: Minimum data points required in period (default: 5)

**Rationale**:
- 3 hours captures typical calibration/testing windows
- VeDBA < 20 m/s² reliably indicates stationary or very slow movement
- 5+ samples ensures minimum temporal coverage

### Grouping Parameters

In `identify_co_occurrence_groups()`:

- **`overlap_minutes`**: Time window for "simultaneous" activation (default: 60)
  - Accounts for setup/teardown time variation
  - 60 min accommodates person placing tags on shelf sequentially

## Example Workflow: Bat Migration Study

```r
# ============================================================================
# 1. INITIALIZE SYSTEM
# ============================================================================

source("calibration_db_schema.R")
source("calibration_import_functions.R")

# Create database
init_calibration_db("bat_migration_calibration.db")
conn <- get_db_connection("bat_migration_calibration.db")

# ============================================================================
# 2. IMPORT WILDCLOUD DATA FROM ACTIVATION DAY
# ============================================================================

# August 25, 2026: Activated 10 NanoFox tags on lab shelf
result <- process_wildcloud_import(
  conn,
  "data/2026-08-25_activation_batch1.csv",
  decoder = "nanofox_finescalepressure",
  imported_by = "edward.hurme@gmail.com"
)

# Check for duplicates (person accidentally re-uploaded?)
cat(sprintf("Duplicate: %s, Events added: %d\n",
           result$is_duplicate, result$n_events_inserted))

# ============================================================================
# 3. LABEL DETECTED EVENTS
# ============================================================================

# Get all pending events from this import
pending <- get_calibration_events(conn, status = "pending", 
                                 start_date = "2026-08-25")

# Label first event (example)
if (nrow(pending) > 0) {
  first_event <- pending[1, ]
  
  label_calibration_event(
    conn,
    event_id = first_event$event_id,
    location = "Lab, 2nd floor, shelf near window",
    description = "Batch 1: 10 NanoFox tags pre-deployment calibration",
    notes = "Deployed on bats the same day at 18:00 UTC. Tags sat on shelf 08:00-15:00.",
    labeled_by = "edward.hurme@gmail.com",
    status = "confirmed"
  )
}

# ============================================================================
# 4. FIND CO-OCCURRENCE GROUPS
# ============================================================================

# Which tags were activated together?
all_events <- get_calibration_events(conn, status = "confirmed")
groups <- identify_co_occurrence_groups(all_events, overlap_minutes = 60)

print(groups)
# group_id | tags (pipe-delimited) | n_tags | start_time | ...
# 1        | 120D915|9ED555|120D916|...     | 10     | 2026-08-25 08:15:00

# ============================================================================
# 5. EXPORT FOR ANALYSIS
# ============================================================================

# Export all confirmed calibration events
export_calibration_report(conn, 
                         "calibration_summary_2026-08-25.csv",
                         status = "confirmed")

# Use in downstream analysis: sensor calibration, tag validation, etc.
data <- read.csv("calibration_summary_2026-08-25.csv")
```

## Troubleshooting

### Problem: "Database not found" error

**Solution**: Run `init_calibration_db()` first to create the database.

```r
source("calibration_db_schema.R")
init_calibration_db("calibration_events.db")
```

### Problem: File showing as duplicate but shouldn't

**Cause**: File has same content hash (byte-for-byte identical).

**Solution**: Re-export Wildcloud CSV from the source, or confirm it's truly a duplicate and use the existing import_id.

```r
# Check which import it matches
existing_import <- dbGetQuery(conn, 
  "SELECT * FROM wildcloud_imports WHERE file_hash = ?",
  params = list(file_hash)
)
print(existing_import)
```

### Problem: Few/no calibration events detected

**Cause**: Thresholds too strict, or tags weren't at rest during expected window.

**Solution**: Lower thresholds or check raw data:

```r
# Re-import with looser thresholds
result <- process_wildcloud_import(
  conn, file_path,
  decoder = "nanofox_finescalepressure",
  imported_by = "user@email.com",
  min_duration_hours = 2,      # Lowered from 3
  vedba_threshold = 25         # Raised from 20
)

# Or inspect raw data directly
raw <- import_wildcloud_csv(file_path, decoder = "nanofox_finescalepressure")
summary(raw$vedba)  # Check distribution
table(raw$tag_id)   # Which tags were included?
```

### Problem: Shiny app crashes or won't start

**Check**:
1. Is the database initialized?
2. Are all required packages installed?
3. Check console error messages.

**Solution**:
```r
# Reinstall dependencies
install.packages("shiny", "DT", "ggplot2", "DBI", "RSQLite")

# Restart R session and try again
source("calibration_shiny_app.R")
shiny::runApp()
```

## Future Enhancements

Potential additions:

- [ ] **Real-time sensor monitoring**: Stream Wildcloud API data directly
- [ ] **Mobile app**: React Native app for field labeling
- [ ] **Pressure/temperature analysis**: Automatic environmental calibration detection
- [ ] **Sensor drift tracking**: Trend VeDBA over time for each tag
- [ ] **Batch operations**: Label multiple events at once
- [ ] **Comments/discussions**: Collaborative notes on calibration events
- [ ] **Version control**: Track changes to event labels over time

## References

- **VeDBA documentation**: See `vedba_calculation_guide.md` in project
- **Tag specifications**: NanoFox and TinyFoxBatt hardware manuals
- **Wildcloud export format**: Contact your Wildcloud data provider

## License & Contact

Developed for bat migration research. Questions or contributions? Contact the project maintainer.

---

**Last updated**: August 31, 2026  
**Database schema version**: 1.0  
**Compatible with**: R 4.0+, SQLite 3.0+
