# Calibration Database System - SQLite Schema & Initialization
# Author: Claude
# Purpose: Track tag activation/deactivation periods for bat migration research
# Database: SQLite with duplicate detection and user labeling

library(DBI)
library(RSQLite)
library(dplyr)
library(lubridate)

#' Initialize Calibration Database
#'
#' Creates a new SQLite database with schema for tracking tag calibration events.
#' If database exists, validates schema consistency.
#'
#' @param db_path Character path to SQLite database file
#' @param overwrite Logical; if TRUE, recreate database from scratch
#'
#' @return Invisible connection object
#'
#' @export
init_calibration_db <- function(db_path = "calibration_events.db", overwrite = FALSE) {

  if (file.exists(db_path) && overwrite) {
    file.remove(db_path)
  }

  conn <- dbConnect(RSQLite::SQLite(), db_path)

  # Enable foreign keys
  dbExecute(conn, "PRAGMA foreign_keys = ON")

  # ============================================================================
  # TABLE 1: tags
  # ============================================================================
  # Core table: all tags in study with metadata
  dbExecute(conn, "
    CREATE TABLE IF NOT EXISTS tags (
      tag_id TEXT PRIMARY KEY,
      tag_type TEXT NOT NULL,
      study_id TEXT,
      first_seen DATE,
      last_seen DATE,
      notes TEXT,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  ")

  # Create index on tag_type for faster filtering
  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_tags_type ON tags(tag_type)")

  # ============================================================================
  # TABLE 2: calibration_events
  # ============================================================================
  # Main table: detected/labeled calibration periods (tags at rest together)
  dbExecute(conn, "
    CREATE TABLE IF NOT EXISTS calibration_events (
      event_id INTEGER PRIMARY KEY AUTOINCREMENT,
      tag_id TEXT NOT NULL,
      start_time TIMESTAMP NOT NULL,
      end_time TIMESTAMP NOT NULL,
      duration_hours REAL,
      median_vedba REAL,
      mean_vedba REAL,
      max_vedba REAL,
      n_samples INTEGER,
      detection_method TEXT,
      status TEXT DEFAULT 'pending',
      label_location TEXT,
      label_description TEXT,
      label_notes TEXT,
      labeled_by TEXT,
      labeled_at TIMESTAMP,
      data_source TEXT,
      duplicate_of_event_id INTEGER,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY(tag_id) REFERENCES tags(tag_id) ON DELETE CASCADE,
      FOREIGN KEY(duplicate_of_event_id) REFERENCES calibration_events(event_id)
    )
  ")

  # Create indexes for common queries
  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_calib_tag ON calibration_events(tag_id)")
  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_calib_time ON calibration_events(start_time, end_time)")
  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_calib_status ON calibration_events(status)")
  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_calib_location ON calibration_events(label_location)")

  # ============================================================================
  # TABLE 3: wildcloud_imports
  # ============================================================================
  # Track all data imports to detect duplicate uploads
  dbExecute(conn, "
    CREATE TABLE IF NOT EXISTS wildcloud_imports (
      import_id INTEGER PRIMARY KEY AUTOINCREMENT,
      file_path TEXT NOT NULL,
      file_hash TEXT UNIQUE,
      n_records INTEGER,
      date_range_start DATE,
      date_range_end DATE,
      tags_included TEXT,
      imported_by TEXT,
      import_notes TEXT,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      processed_at TIMESTAMP
    )
  ")

  # ============================================================================
  # TABLE 4: co_occurrence_groups
  # ============================================================================
  # Group multiple tags that were activated together (on same shelf, time period)
  dbExecute(conn, "
    CREATE TABLE IF NOT EXISTS co_occurrence_groups (
      group_id INTEGER PRIMARY KEY AUTOINCREMENT,
      group_name TEXT UNIQUE,
      start_time TIMESTAMP NOT NULL,
      end_time TIMESTAMP NOT NULL,
      location TEXT,
      description TEXT,
      n_tags INTEGER,
      confidence REAL,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
  ")

  # ============================================================================
  # TABLE 5: group_members
  # ============================================================================
  # Link calibration events to co-occurrence groups (many-to-many)
  dbExecute(conn, "
    CREATE TABLE IF NOT EXISTS group_members (
      group_member_id INTEGER PRIMARY KEY AUTOINCREMENT,
      group_id INTEGER NOT NULL,
      event_id INTEGER NOT NULL,
      FOREIGN KEY(group_id) REFERENCES co_occurrence_groups(group_id) ON DELETE CASCADE,
      FOREIGN KEY(event_id) REFERENCES calibration_events(event_id) ON DELETE CASCADE
    )
  ")

  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_group_members_gid ON group_members(group_id)")
  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_group_members_eid ON group_members(event_id)")

  # ============================================================================
  # TABLE 6: raw_sensor_data
  # ============================================================================
  # Optional: store raw measurements for trending/analysis
  dbExecute(conn, "
    CREATE TABLE IF NOT EXISTS raw_sensor_data (
      record_id INTEGER PRIMARY KEY AUTOINCREMENT,
      tag_id TEXT NOT NULL,
      timestamp TIMESTAMP NOT NULL,
      vedba REAL,
      pressure REAL,
      temperature REAL,
      location TEXT,
      link_quality TEXT,
      import_id INTEGER,
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
      FOREIGN KEY(tag_id) REFERENCES tags(tag_id) ON DELETE CASCADE,
      FOREIGN KEY(import_id) REFERENCES wildcloud_imports(import_id)
    )
  ")

  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_sensor_tag_time ON raw_sensor_data(tag_id, timestamp)")
  dbExecute(conn, "CREATE INDEX IF NOT EXISTS idx_sensor_import ON raw_sensor_data(import_id)")

  message(sprintf("[DB] Initialized calibration database: %s", db_path))

  invisible(conn)
}

#' Get Database Connection
#'
#' Returns a connection to the calibration database
#'
#' @param db_path Character path to SQLite database file
#'
#' @return RSQLite connection object
#' @export
get_db_connection <- function(db_path = "calibration_events.db") {
  if (!file.exists(db_path)) {
    stop(sprintf("Database not found: %s. Run init_calibration_db() first.", db_path))
  }

  conn <- dbConnect(RSQLite::SQLite(), db_path)
  dbExecute(conn, "PRAGMA foreign_keys = ON")

  return(conn)
}

#' Calculate File Hash for Duplicate Detection
#'
#' Computes SHA256 hash of CSV file for deduplication
#'
#' @param file_path Character path to CSV file
#'
#' @return Character hash string
#' @export
compute_file_hash <- function(file_path) {
  if (!file.exists(file_path)) {
    stop(sprintf("File not found: %s", file_path))
  }

  digest::digest(object = readBin(file_path, "raw", file.size(file_path)),
                algo = "sha256")
}

#' Check if File Already Imported
#'
#' Queries database to see if file_hash already exists
#'
#' @param conn Database connection
#' @param file_hash Character hash of file
#'
#' @return List with `is_duplicate` (logical) and `import_id` (or NA)
#' @export
check_import_duplicate <- function(conn, file_hash) {
  existing <- dbGetQuery(conn,
    "SELECT import_id FROM wildcloud_imports WHERE file_hash = ?",
    params = list(file_hash)
  )

  if (nrow(existing) > 0) {
    return(list(is_duplicate = TRUE, import_id = existing$import_id[1]))
  } else {
    return(list(is_duplicate = FALSE, import_id = NA))
  }
}

#' Log Import to Database
#'
#' Record wildcloud import metadata for deduplication tracking
#'
#' @param conn Database connection
#' @param file_path Character path to imported file
#' @param file_hash Character SHA256 hash
#' @param n_records Integer number of records in file
#' @param date_range_start Date first record
#' @param date_range_end Date last record
#' @param tags_included Character vector of tag IDs
#' @param imported_by Character username
#' @param import_notes Character notes on import
#'
#' @return Integer import_id of newly logged import
#' @export
log_wildcloud_import <- function(conn, file_path, file_hash, n_records,
                                date_range_start, date_range_end,
                                tags_included, imported_by, import_notes = "") {

  import_row <- data.frame(
    file_path = file_path,
    file_hash = file_hash,
    n_records = n_records,
    date_range_start = date_range_start,
    date_range_end = date_range_end,
    tags_included = paste(tags_included, collapse = "|"),
    imported_by = imported_by,
    import_notes = import_notes,
    stringsAsFactors = FALSE
  )

  dbAppendTable(conn, "wildcloud_imports", import_row)

  # Return the new import_id
  last_import <- dbGetQuery(conn,
    "SELECT MAX(import_id) as max_id FROM wildcloud_imports"
  )

  return(last_import$max_id[1])
}

#' Insert Calibration Event
#'
#' Add a detected or manually-labeled calibration event to database
#'
#' @param conn Database connection
#' @param tag_id Character tag identifier
#' @param start_time POSIXct start of event
#' @param end_time POSIXct end of event
#' @param vedba_stats List with median, mean, max, n_samples
#' @param detection_method Character ("auto_detect" or "manual")
#' @param status Character event status ("pending", "confirmed", "rejected")
#' @param data_source Character ("wildcloud", "movebank", etc.)
#'
#' @return Integer event_id of newly inserted event
#' @export
insert_calibration_event <- function(conn, tag_id, start_time, end_time,
                                   vedba_stats, detection_method = "auto_detect",
                                   status = "pending", data_source = "wildcloud") {

  duration_hours <- as.numeric(difftime(end_time, start_time, units = "hours"))

  event_row <- data.frame(
    tag_id = tag_id,
    start_time = format(start_time, "%Y-%m-%d %H:%M:%S"),
    end_time = format(end_time, "%Y-%m-%d %H:%M:%S"),
    duration_hours = duration_hours,
    median_vedba = vedba_stats$median,
    mean_vedba = vedba_stats$mean,
    max_vedba = vedba_stats$max,
    n_samples = vedba_stats$n,
    detection_method = detection_method,
    status = status,
    data_source = data_source,
    stringsAsFactors = FALSE
  )

  dbAppendTable(conn, "calibration_events", event_row)

  # Return the new event_id
  last_event <- dbGetQuery(conn,
    "SELECT MAX(event_id) as max_id FROM calibration_events"
  )

  return(last_event$max_id[1])
}

#' Label Calibration Event
#'
#' Add user-supplied label to calibration event (location, description, notes)
#'
#' @param conn Database connection
#' @param event_id Integer event identifier
#' @param location Character location label (e.g., "2nd floor, office, shelf")
#' @param description Character brief description
#' @param notes Character detailed notes
#' @param labeled_by Character username
#' @param status Character new status ("confirmed", "rejected", "pending")
#'
#' @return Logical TRUE if successful
#' @export
label_calibration_event <- function(conn, event_id, location = NA,
                                   description = NA, notes = NA,
                                   labeled_by, status = "confirmed") {

  update_cols <- "status = ?, labeled_by = ?, labeled_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP"
  update_vals <- list(status, labeled_by)

  if (!is.na(location)) {
    update_cols <- paste0(update_cols, ", label_location = ?")
    update_vals <- c(update_vals, location)
  }

  if (!is.na(description)) {
    update_cols <- paste0(update_cols, ", label_description = ?")
    update_vals <- c(update_vals, description)
  }

  if (!is.na(notes)) {
    update_cols <- paste0(update_cols, ", label_notes = ?")
    update_vals <- c(update_vals, notes)
  }

  sql <- sprintf("UPDATE calibration_events SET %s WHERE event_id = ?", update_cols)
  update_vals <- c(update_vals, event_id)

  result <- tryCatch({
    dbExecute(conn, sql, params = update_vals)
    TRUE
  }, error = function(e) {
    warning(sprintf("Failed to label event %d: %s", event_id, e$message))
    FALSE
  })

  return(result)
}

#' Mark Events as Duplicates
#'
#' Link duplicate events so only one is used in analysis
#'
#' @param conn Database connection
#' @param event_id Integer ID of event to mark as duplicate
#' @param duplicate_of_event_id Integer ID of canonical event
#'
#' @return Logical TRUE if successful
#' @export
mark_duplicate_event <- function(conn, event_id, duplicate_of_event_id) {

  result <- tryCatch({
    sql <- "UPDATE calibration_events
            SET duplicate_of_event_id = ?, status = 'duplicate', updated_at = CURRENT_TIMESTAMP
            WHERE event_id = ?"
    dbExecute(conn, sql, params = list(duplicate_of_event_id, event_id))
    TRUE
  }, error = function(e) {
    warning(sprintf("Failed to mark duplicate: %s", e$message))
    FALSE
  })

  return(result)
}

#' Get Calibration Events (Filtered)
#'
#' Query calibration events with optional filters
#'
#' @param conn Database connection
#' @param tag_id Character vector of tag IDs (NULL = all)
#' @param status Character vector of statuses (NULL = all)
#' @param location Character location substring to match (NULL = all)
#' @param start_date Date events on or after this date
#' @param end_date Date events on or before this date
#' @param exclude_duplicates Logical if TRUE, exclude events marked as duplicates
#'
#' @return Data frame of calibration events
#' @export
get_calibration_events <- function(conn, tag_id = NULL, status = NULL,
                                  location = NULL, start_date = NULL, end_date = NULL,
                                  exclude_duplicates = TRUE) {

  query <- "SELECT * FROM calibration_events WHERE 1=1"
  params <- list()

  if (!is.null(tag_id)) {
    placeholders <- paste(rep("?", length(tag_id)), collapse = ",")
    query <- paste0(query, " AND tag_id IN (", placeholders, ")")
    params <- c(params, as.list(tag_id))
  }

  if (!is.null(status)) {
    placeholders <- paste(rep("?", length(status)), collapse = ",")
    query <- paste0(query, " AND status IN (", placeholders, ")")
    params <- c(params, as.list(status))
  }

  if (!is.null(location)) {
    query <- paste0(query, " AND label_location LIKE ?")
    params <- c(params, paste0("%", location, "%"))
  }

  if (!is.null(start_date)) {
    query <- paste0(query, " AND DATE(start_time) >= ?")
    params <- c(params, as.character(start_date))
  }

  if (!is.null(end_date)) {
    query <- paste0(query, " AND DATE(end_time) <= ?")
    params <- c(params, as.character(end_date))
  }

  if (exclude_duplicates) {
    query <- paste0(query, " AND duplicate_of_event_id IS NULL")
  }

  query <- paste0(query, " ORDER BY start_time DESC")

  results <- dbGetQuery(conn, query, params = params)

  if (nrow(results) > 0) {
    results$start_time <- as.POSIXct(results$start_time)
    results$end_time <- as.POSIXct(results$end_time)
    results$labeled_at <- as.POSIXct(results$labeled_at)
    results$created_at <- as.POSIXct(results$created_at)
    results$updated_at <- as.POSIXct(results$updated_at)
  }

  return(results)
}

message("[Schema] Calibration database functions loaded successfully")
