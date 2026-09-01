# Wildcloud Import & Calibration Detection
# Processes Wildcloud CSV exports and automatically detects low-VeDBA periods

library(data.table)
library(tidyverse)
library(lubridate)
library(DBI)
library(digest)

#' Import Wildcloud CSV Data
#'
#' Parse Wildcloud-formatted CSV file and return as data frame with timestamps
#'
#' @param file_path Character path to Wildcloud CSV
#' @param decoder Character decoder type ("nanofox_finescalepressure" or other)
#'
#' @return Data frame with columns: tag_id, timestamp, vedba, pressure, temperature, etc.
#' @export
import_wildcloud_csv <- function(file_path, decoder = "nanofox_finescalepressure") {

  if (!file.exists(file_path)) {
    stop(sprintf("File not found: %s", file_path))
  }

  # Read CSV (handle semicolon delimiter from your example)
  raw_data <- fread(file_path, sep = ";", stringsAsFactors = FALSE)

  message(sprintf("[Import] Loaded %d records from %s", nrow(raw_data), basename(file_path)))

  # Standardize column names for different decoders
  data <- switch(decoder,
    "nanofox_finescalepressure" = .parse_nanofox_finescale(raw_data),
    "tinyfoxbatt" = .parse_tinyfoxbatt(raw_data),
    stop(sprintf("Unknown decoder: %s", decoder))
  )

  # Parse timestamp if not already POSIXct
  if (!inherits(data$timestamp, "POSIXct")) {
    data$timestamp <- parse_datetime(data$timestamp, format = "%d.%m.%Y, %H:%M:%S")
  }

  # Ensure vedba is numeric
  data$vedba <- as.numeric(data$vedba)

  # Sort by tag and timestamp
  data <- data[order(data$tag_id, data$timestamp), ]

  message(sprintf("[Import] Parsed %d records for %d unique tags",
                 nrow(data), n_distinct(data$tag_id)))

  return(data)
}

#' Parse NanoFox FinescalePressure Decoder
#'
#' Maps Wildcloud NanoFox columns to standard schema
#'
#' @param raw_data Data frame from fread
#' @return Data frame with standardized columns
#'
#' @keywords internal
.parse_nanofox_finescale <- function(raw_data) {

  # Map to standard schema (adjust column names based on your CSV header)
  parsed <- data.frame(
    tag_id = raw_data$Device,
    timestamp = raw_data$`Time (UTC)`,
    vedba = coalesce(
      raw_data$`VeDBA sum 0 min ago (m/s²)`,
      raw_data$`VeDBA sum 36 min ago (m/s²)`,  # fallback if latest unavailable
      raw_data$`VeDBA sum 72 min ago (m/s²)`
    ),
    pressure = raw_data$`Pressure 0 min ago (mbar)`,
    temperature = raw_data$`Max Temperature of last 3 hrs (°C)`,
    position = raw_data$Position,
    radius_m = as.numeric(gsub(" \\(.*", "", raw_data$`Radius (m) (Source/Status)`)),
    operator = raw_data$`Operator Name`,
    stringsAsFactors = FALSE
  )

  return(parsed)
}

#' Parse TinyFoxBatt Decoder
#'
#' Maps TinyFoxBatt columns to standard schema
#'
#' @param raw_data Data frame from fread
#' @return Data frame with standardized columns
#'
#' @keywords internal
.parse_tinyfoxbatt <- function(raw_data) {

  parsed <- data.frame(
    tag_id = raw_data$device_id,
    timestamp = raw_data$timestamp,
    vedba = raw_data$vedba_rate_h,  # or diff_vedba depending on your structure
    pressure = raw_data$pressure,
    temperature = raw_data$temperature,
    stringsAsFactors = FALSE
  )

  return(parsed)
}

#' Detect Calibration Periods (Auto)
#'
#' Identify consecutive 3+ hour periods with median VeDBA < 20 m/s²
#' Indicates tags at rest (e.g., on shelf during activation/calibration)
#'
#' @param data Data frame with tag_id, timestamp, vedba columns
#' @param min_duration_hours Numeric minimum period length (default 3)
#' @param vedba_threshold Numeric maximum median VeDBA to qualify (default 20)
#' @param min_samples Numeric minimum records in period (default 5)
#'
#' @return Data frame with columns:
#'   tag_id, start_time, end_time, duration_hours, median_vedba, mean_vedba, max_vedba, n_samples
#' @export
detect_calibration_periods <- function(data,
                                      min_duration_hours = 3,
                                      vedba_threshold = 20,
                                      min_samples = 5) {

  if (nrow(data) == 0) {
    return(data.frame(tag_id = character(),
                     start_time = as.POSIXct(character()),
                     end_time = as.POSIXct(character()),
                     duration_hours = numeric(),
                     median_vedba = numeric(),
                     mean_vedba = numeric(),
                     max_vedba = numeric(),
                     n_samples = integer()))
  }

  # Remove rows with missing vedba
  data <- data[!is.na(data$vedba), ]

  events <- list()

  # Process each tag separately
  for (tag in unique(data$tag_id)) {
    tag_data <- data[data$tag_id == tag, ]
    tag_data <- tag_data[order(tag_data$timestamp), ]

    if (nrow(tag_data) < min_samples) {
      next
    }

    # Sort by timestamp and compute gaps
    tag_data$time_gap_hours <- c(NA, as.numeric(diff(tag_data$timestamp, units = "hours")))

    # Identify continuous blocks (where gap < 1 hour between consecutive samples)
    tag_data$block <- cumsum(c(1, ifelse(is.na(tag_data$time_gap_hours[-1]), 0,
                                          ifelse(tag_data$time_gap_hours[-1] > 1, 1, 0))))

    # For each block, check if it qualifies as low-activity period
    for (blk in unique(tag_data$block)) {
      block_data <- tag_data[tag_data$block == blk, ]

      block_data <- block_data[order(block_data$timestamp), ]

      start_time <- block_data$timestamp[1]
      end_time <- block_data$timestamp[nrow(block_data)]
      duration <- as.numeric(difftime(end_time, start_time, units = "hours"))

      if (duration >= min_duration_hours && nrow(block_data) >= min_samples) {
        median_vedba <- median(block_data$vedba, na.rm = TRUE)

        if (median_vedba < vedba_threshold) {
          events[[length(events) + 1]] <- data.frame(
            tag_id = tag,
            start_time = start_time,
            end_time = end_time,
            duration_hours = duration,
            median_vedba = median_vedba,
            mean_vedba = mean(block_data$vedba, na.rm = TRUE),
            max_vedba = max(block_data$vedba, na.rm = TRUE),
            n_samples = nrow(block_data),
            stringsAsFactors = FALSE
          )
        }
      }
    }
  }

  if (length(events) == 0) {
    return(data.frame(tag_id = character(),
                     start_time = as.POSIXct(character()),
                     end_time = as.POSIXct(character()),
                     duration_hours = numeric(),
                     median_vedba = numeric(),
                     mean_vedba = numeric(),
                     max_vedba = numeric(),
                     n_samples = integer()))
  }

  result <- do.call(rbind, events)
  rownames(result) <- NULL

  message(sprintf("[Detection] Found %d calibration periods across %d tags",
                 nrow(result), n_distinct(result$tag_id)))

  return(result)
}

#' Identify Co-occurrence Groups
#'
#' Find tags that were low-activity simultaneously (likely activated together on shelf)
#'
#' @param calibration_events Data frame of detected calibration events
#' @param overlap_minutes Numeric maximum minutes between event start/end times to consider "together"
#'
#' @return Data frame with group_id, tags, start_time, end_time, n_tags, overlap_score
#' @export
identify_co_occurrence_groups <- function(calibration_events,
                                         overlap_minutes = 60) {

  if (nrow(calibration_events) == 0) {
    return(data.frame())
  }

  # Simple clustering: find events with overlapping time windows
  events_sorted <- calibration_events[order(calibration_events$start_time), ]

  groups <- list()
  used_events <- integer()

  for (i in seq_len(nrow(events_sorted))) {
    if (i %in% used_events) next

    event_i <- events_sorted[i, ]
    cluster_indices <- c(i)

    # Find all events overlapping with event i (within overlap_minutes)
    for (j in (i + 1):nrow(events_sorted)) {
      if (j %in% used_events) next

      event_j <- events_sorted[j, ]

      # Check overlap: start within overlap_minutes of end, or vice versa
      time_between_start <- as.numeric(difftime(event_j$start_time,
                                               event_i$start_time, units = "mins"))
      time_between_end <- as.numeric(difftime(event_j$end_time,
                                             event_i$end_time, units = "mins"))

      if (abs(time_between_start) <= overlap_minutes || abs(time_between_end) <= overlap_minutes) {
        cluster_indices <- c(cluster_indices, j)
      }
    }

    if (length(cluster_indices) > 1) {
      cluster_events <- events_sorted[cluster_indices, ]

      groups[[length(groups) + 1]] <- data.frame(
        group_id = length(groups) + 1,
        tags = paste(unique(cluster_events$tag_id), collapse = "|"),
        n_tags = n_distinct(cluster_events$tag_id),
        start_time = min(cluster_events$start_time),
        end_time = max(cluster_events$end_time),
        overlap_score = mean(cluster_events$median_vedba),
        stringsAsFactors = FALSE
      )

      used_events <- c(used_events, cluster_indices)
    }
  }

  if (length(groups) == 0) {
    message("[Grouping] No co-occurrence groups found")
    return(data.frame())
  }

  result <- do.call(rbind, groups)
  rownames(result) <- NULL

  message(sprintf("[Grouping] Identified %d co-occurrence groups", nrow(result)))

  return(result)
}

#' Import and Process Wildcloud Data
#'
#' Complete pipeline: import CSV → detect calibrations → check duplicates → populate database
#'
#' @param conn Database connection
#' @param file_path Character path to Wildcloud CSV
#' @param decoder Character decoder type
#' @param imported_by Character username performing import
#' @param min_duration_hours Numeric threshold for calibration period
#' @param vedba_threshold Numeric VeDBA threshold (m/s²)
#'
#' @return List with:
#'   - import_id: Integer ID of import record
#'   - n_events_inserted: Integer count of calibration events added
#'   - duplicate_check: List with is_duplicate, import_id
#'   - calibration_events: Data frame of detected events
#'
#' @export
process_wildcloud_import <- function(conn, file_path, decoder = "nanofox_finescalepressure",
                                   imported_by, min_duration_hours = 3, vedba_threshold = 20) {

  # Step 1: Check for duplicate file
  file_hash <- compute_file_hash(file_path)
  dup_check <- check_import_duplicate(conn, file_hash)

  if (dup_check$is_duplicate) {
    message(sprintf("[Import] ⚠️  File already imported (import_id: %d). Skipping.",
                   dup_check$import_id))
    return(list(
      import_id = dup_check$import_id,
      is_duplicate = TRUE,
      n_events_inserted = 0,
      calibration_events = data.frame()
    ))
  }

  # Step 2: Parse Wildcloud CSV
  raw_data <- import_wildcloud_csv(file_path, decoder)

  # Step 3: Ensure tags exist in database
  unique_tags <- unique(raw_data$tag_id)
  existing_tags <- dbGetQuery(conn, "SELECT tag_id FROM tags")$tag_id

  new_tags <- setdiff(unique_tags, existing_tags)
  if (length(new_tags) > 0) {
    new_tag_rows <- data.frame(
      tag_id = new_tags,
      tag_type = decoder,
      first_seen = min(raw_data$timestamp[raw_data$tag_id %in% new_tags]),
      last_seen = max(raw_data$timestamp[raw_data$tag_id %in% new_tags]),
      stringsAsFactors = FALSE
    )

    dbAppendTable(conn, "tags", new_tag_rows)
    message(sprintf("[Tags] Added %d new tags to database", nrow(new_tag_rows)))
  }

  # Step 4: Detect calibration periods
  calibration_events <- detect_calibration_periods(
    raw_data,
    min_duration_hours = min_duration_hours,
    vedba_threshold = vedba_threshold
  )

  # Step 5: Insert calibration events (if not duplicates)
  n_inserted <- 0
  event_ids <- integer()

  if (nrow(calibration_events) > 0) {
    for (i in seq_len(nrow(calibration_events))) {
      evt <- calibration_events[i, ]

      # Check if exact duplicate event already exists
      existing <- dbGetQuery(conn,
        "SELECT event_id FROM calibration_events
         WHERE tag_id = ? AND start_time = ? AND end_time = ?
         AND duplicate_of_event_id IS NULL",
        params = list(evt$tag_id, evt$start_time, evt$end_time)
      )

      if (nrow(existing) == 0) {
        # New event
        event_id <- insert_calibration_event(
          conn,
          tag_id = evt$tag_id,
          start_time = evt$start_time,
          end_time = evt$end_time,
          vedba_stats = list(
            median = evt$median_vedba,
            mean = evt$mean_vedba,
            max = evt$max_vedba,
            n = evt$n_samples
          ),
          detection_method = "auto_detect",
          status = "pending",
          data_source = "wildcloud"
        )

        event_ids <- c(event_ids, event_id)
        n_inserted <- n_inserted + 1
      } else {
        message(sprintf("[Duplicate] Event for tag %s [%s - %s] already exists",
                       evt$tag_id,
                       format(evt$start_time, "%Y-%m-%d %H:%M"),
                       format(evt$end_time, "%Y-%m-%d %H:%M")))
      }
    }
  }

  # Step 6: Log import
  date_range <- range(raw_data$timestamp, na.rm = TRUE)
  import_id <- log_wildcloud_import(
    conn,
    file_path = file_path,
    file_hash = file_hash,
    n_records = nrow(raw_data),
    date_range_start = as.Date(date_range[1]),
    date_range_end = as.Date(date_range[2]),
    tags_included = unique_tags,
    imported_by = imported_by,
    import_notes = sprintf("Decoder: %s; Min duration: %dh; VeDBA threshold: %.1f",
                          decoder, min_duration_hours, vedba_threshold)
  )

  message(sprintf("[Import] ✓ Completed: import_id=%d, events_inserted=%d", import_id, n_inserted))

  return(list(
    import_id = import_id,
    is_duplicate = FALSE,
    n_events_inserted = n_inserted,
    calibration_events = calibration_events,
    event_ids = event_ids
  ))
}

#' Export Calibration Summary Report
#'
#' Generate CSV summary of labeled calibration events
#'
#' @param conn Database connection
#' @param output_file Character path for output CSV
#' @param status Character vector of statuses to include (NULL = all)
#'
#' @return Invisible TRUE
#' @export
export_calibration_report <- function(conn, output_file, status = "confirmed") {

  events <- get_calibration_events(conn, status = status, exclude_duplicates = TRUE)

  if (nrow(events) > 0) {
    events <- events %>%
      select(event_id, tag_id, start_time, end_time, duration_hours,
            median_vedba, mean_vedba, n_samples,
            label_location, label_description, label_notes,
            labeled_by, labeled_at, data_source)
  }

  write.csv(events, output_file, row.names = FALSE, quote = TRUE)

  message(sprintf("[Export] Saved %d calibration events to %s", nrow(events), output_file))

  invisible(TRUE)
}

message("[Import] Wildcloud import functions loaded successfully")
