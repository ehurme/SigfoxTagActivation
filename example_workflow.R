# ============================================================================
# EXAMPLE WORKFLOW: Calibration Database
# ============================================================================
# This script demonstrates the complete workflow:
# 1. Initialize database
# 2. Import Wildcloud CSV
# 3. Review detected events
# 4. Label events programmatically
# 5. Export results

cat("\n")
cat("════════════════════════════════════════════════════════════════════════\n")
cat("  CALIBRATION DATABASE - EXAMPLE WORKFLOW\n")
cat("════════════════════════════════════════════════════════════════════════\n\n")

# ============================================================================
# SETUP
# ============================================================================

cat("Step 1: Loading modules and initializing database...\n")

source("calibration_db_schema.R")
source("calibration_import_functions.R")

# Initialize or connect to database
db_path <- "example_calibration.db"

if (file.exists(db_path)) {
  cat("  ✓ Using existing database:", db_path, "\n")
  conn <- get_db_connection(db_path)
} else {
  cat("  ✓ Creating new database:", db_path, "\n")
  init_calibration_db(db_path)
  conn <- get_db_connection(db_path)
}

cat("\n")

# ============================================================================
# IMPORT YOUR DATA
# ============================================================================

cat("Step 2: Importing Wildcloud CSV...\n")
cat("  (Using your attached file: 31_08_2026_records.csv)\n\n")

# Use the file you uploaded
csv_file <- "/root/.claude/uploads/aa8e359b-2efe-587b-b113-c92b6a3ad083/3ab94e4f-31_08_2026_records.csv"

if (file.exists(csv_file)) {
  result <- process_wildcloud_import(
    conn,
    file_path = csv_file,
    decoder = "nanofox_finescalepressure",
    imported_by = "example_workflow",
    min_duration_hours = 3,
    vedba_threshold = 20
  )

  cat(sprintf("\n  Import Results:\n"))
  cat(sprintf("    • Import ID: %d\n", result$import_id))
  cat(sprintf("    • Is duplicate: %s\n", result$is_duplicate))
  cat(sprintf("    • Events detected: %d\n", result$n_events_inserted))
  cat(sprintf("    • Unique tags: %d\n", n_distinct(result$calibration_events$tag_id)))

  if (nrow(result$calibration_events) > 0) {
    cat("\n  Sample detected events:\n")
    sample_events <- head(result$calibration_events, 3)
    for (i in 1:nrow(sample_events)) {
      evt <- sample_events[i, ]
      cat(sprintf(
        "    • Tag %s: %s to %s (%.1fh, median VeDBA=%.1f m/s²)\n",
        evt$tag_id,
        format(evt$start_time, "%Y-%m-%d %H:%M"),
        format(evt$end_time, "%Y-%m-%d %H:%M"),
        evt$duration_hours,
        evt$median_vedba
      ))
    }
  }

} else {
  cat("  ⚠️  File not found:", csv_file, "\n")
  cat("  Skipping import. Use your own Wildcloud CSV instead.\n")
}

cat("\n")

# ============================================================================
# RETRIEVE AND REVIEW EVENTS
# ============================================================================

cat("Step 3: Retrieving calibration events from database...\n\n")

# Get all pending events
pending_events <- get_calibration_events(conn, status = "pending", exclude_duplicates = TRUE)

cat(sprintf("  Found %d pending events\n", nrow(pending_events)))

if (nrow(pending_events) > 0) {
  cat("\n  Pending Events Summary:\n")

  # Group by tag
  by_tag <- pending_events %>%
    group_by(tag_id) %>%
    summarise(
      n_events = n(),
      date_range = sprintf("%s to %s",
                          min(as.Date(start_time)),
                          max(as.Date(start_time))),
      median_vedba_mean = round(mean(median_vedba, na.rm = TRUE), 1),
      .groups = "drop"
    )

  for (i in 1:nrow(by_tag)) {
    cat(sprintf("    • Tag %s: %d events (%s), avg median VeDBA=%.1f m/s²\n",
               by_tag$tag_id[i], by_tag$n_events[i], by_tag$date_range[i],
               by_tag$median_vedba_mean[i]))
  }

  # Show details of first few events
  cat("\n  First 3 Events (detailed):\n")
  for (i in 1:min(3, nrow(pending_events))) {
    evt <- pending_events[i, ]
    cat(sprintf("    [%d] Tag %s\n", i, evt$tag_id))
    cat(sprintf("        Start: %s\n", format(evt$start_time, "%Y-%m-%d %H:%M:%S")))
    cat(sprintf("        End:   %s\n", format(evt$end_time, "%Y-%m-%d %H:%M:%S")))
    cat(sprintf("        Duration: %.2f hours\n", evt$duration_hours))
    cat(sprintf("        VeDBA: median=%.1f, mean=%.1f, max=%.1f m/s²\n",
               evt$median_vedba, evt$mean_vedba, evt$max_vedba))
    cat(sprintf("        Samples: %d\n", evt$n_samples))
    cat("\n")
  }
}

cat("\n")

# ============================================================================
# PROGRAMMATICALLY LABEL EVENTS
# ============================================================================

cat("Step 4: Labeling events programmatically...\n\n")

if (nrow(pending_events) > 0) {

  # Example: Label first event with full metadata
  first_event <- pending_events[1, ]

  cat(sprintf("  Labeling event %d (Tag %s):\n", first_event$event_id, first_event$tag_id))

  success <- label_calibration_event(
    conn,
    event_id = first_event$event_id,
    location = "Lab, shelf 2, window side",
    description = "Pre-deployment calibration session",
    notes = "Tags placed on shelf for 3+ hours before field deployment. Initial sensor checks complete.",
    labeled_by = "example_workflow@system",
    status = "confirmed"
  )

  if (success) {
    cat("    ✓ Successfully labeled\n")
  } else {
    cat("    ✗ Failed to label (see warnings above)\n")
  }

  # Optionally label a few more
  if (nrow(pending_events) > 1) {
    cat("\n  Labeling remaining events...\n")

    for (i in 2:min(5, nrow(pending_events))) {
      evt <- pending_events[i, ]

      label_calibration_event(
        conn,
        event_id = evt$event_id,
        location = "Lab, shelf 2",
        description = "Calibration batch",
        labeled_by = "example_workflow@system",
        status = "confirmed"
      )
    }

    cat(sprintf("    ✓ Labeled %d additional events\n", min(4, nrow(pending_events) - 1)))
  }
}

cat("\n")

# ============================================================================
# QUERY LABELED EVENTS
# ============================================================================

cat("Step 5: Querying labeled (confirmed) events...\n\n")

confirmed <- get_calibration_events(conn, status = "confirmed")

cat(sprintf("  Confirmed events in database: %d\n", nrow(confirmed)))

if (nrow(confirmed) > 0) {
  cat("\n  Statistics:\n")
  cat(sprintf("    • Tags: %d\n", n_distinct(confirmed$tag_id)))
  cat(sprintf("    • Date range: %s to %s\n",
             min(as.Date(confirmed$start_time)),
             max(as.Date(confirmed$start_time))))
  cat(sprintf("    • Total duration: %.1f hours\n", sum(confirmed$duration_hours)))
  cat(sprintf("    • Avg VeDBA (median): %.1f m/s²\n", mean(confirmed$median_vedba, na.rm = TRUE)))

  cat("\n  By location:\n")
  by_location <- confirmed %>%
    group_by(label_location) %>%
    summarise(n = n(), .groups = "drop")

  for (i in 1:nrow(by_location)) {
    cat(sprintf("    • %s: %d events\n", by_location$label_location[i], by_location$n[i]))
  }
}

cat("\n")

# ============================================================================
# FIND CO-OCCURRENCE GROUPS
# ============================================================================

cat("Step 6: Identifying co-occurrence groups (tags at rest together)...\n\n")

if (nrow(confirmed) > 0) {
  groups <- identify_co_occurrence_groups(confirmed, overlap_minutes = 60)

  if (nrow(groups) > 0) {
    cat(sprintf("  Found %d co-occurrence group(s):\n\n", nrow(groups)))

    for (i in 1:nrow(groups)) {
      grp <- groups[i, ]
      tags <- strsplit(grp$tags, "\\|")[[1]]

      cat(sprintf("  Group %d: %d tags\n", grp$group_id, grp$n_tags))
      cat(sprintf("    Tags: %s\n", paste(tags, collapse = ", ")))
      cat(sprintf("    Time: %s to %s\n",
                 format(grp$start_time, "%Y-%m-%d %H:%M"),
                 format(grp$end_time, "%Y-%m-%d %H:%M")))
      cat(sprintf("    Avg VeDBA (cohesion): %.1f m/s²\n\n", grp$overlap_score))
    }
  } else {
    cat("  No co-occurrence groups found (events too far apart in time)\n")
  }
}

cat("\n")

# ============================================================================
# EXPORT RESULTS
# ============================================================================

cat("Step 7: Exporting results...\n\n")

export_file <- "calibration_export_example.csv"

export_calibration_report(conn, export_file, status = "confirmed")

if (file.exists(export_file)) {
  exported_data <- read.csv(export_file)
  cat(sprintf("  ✓ Exported %d events to: %s\n", nrow(exported_data), export_file))
  cat(sprintf("  Columns: %s\n", paste(colnames(exported_data), collapse = ", "))
}

cat("\n")

# ============================================================================
# SUMMARY
# ============================================================================

cat("════════════════════════════════════════════════════════════════════════\n")
cat("  WORKFLOW COMPLETE\n")
cat("════════════════════════════════════════════════════════════════════════\n\n")

cat("What you've seen:\n")
cat("  ✓ Database initialization\n")
cat("  ✓ Automatic calibration period detection\n")
cat("  ✓ Event retrieval and filtering\n")
cat("  ✓ Programmatic labeling (location, description, notes)\n")
cat("  ✓ Co-occurrence grouping (tags activated together)\n")
cat("  ✓ Export to CSV for downstream analysis\n\n")

cat("Next steps:\n")
cat("  1. Launch the interactive Shiny app:\n")
cat("     source('calibration_shiny_app.R')\n")
cat("     shiny::runApp()\n\n")
cat("  2. Review the README for more details:\n")
cat("     file.show('CALIBRATION_DB_README.md')\n\n")
cat("  3. Import your own Wildcloud data:\n")
cat("     result <- process_wildcloud_import(\n")
cat("       get_db_connection(),\n")
cat("       'path/to/your/wildcloud.csv',\n")
cat("       imported_by = 'your.name@email.com'\n")
cat("     )\n\n")

# Cleanup
dbDisconnect(conn)

cat("Database connection closed.\n\n")
