# ============================================================================
# DIAGNOSTIC: Why were no calibration events detected?
# ============================================================================
# Run this to debug VeDBA parsing and detection thresholds

library(data.table)
library(tidyverse)
library(lubridate)

source("calibration_db_schema.R")
source("calibration_import_functions.R")

cat("\n")
cat("════════════════════════════════════════════════════════════════════════\n")
cat("  DIAGNOSTIC: Calibration Event Detection\n")
cat("════════════════════════════════════════════════════════════════════════\n\n")

# ============================================================================
# STEP 1: Parse raw CSV and inspect
# ============================================================================

cat("Step 1: Parsing Wildcloud CSV...\n\n")

# USER: Update this path to your actual file
csv_path <- 'C:/Users/ehurme/Dropbox/MPI/Noctyle/Plots/Fall26/Oder/8_29_2026_records_Oder.csv'

if (!file.exists(csv_path)) {
  cat("  ✗ File not found. Update csv_path in this script.\n")
  cat("    Current path:", csv_path, "\n")
  stop()
}

# Read raw
raw_csv <- fread(csv_path, sep = ";", stringsAsFactors = FALSE)

cat("  Dimensions:", nrow(raw_csv), "rows ×", ncol(raw_csv), "columns\n")
cat("  Column names:\n")
print(colnames(raw_csv))

cat("\n")

# ============================================================================
# STEP 2: Inspect VeDBA columns
# ============================================================================

cat("Step 2: Checking VeDBA columns...\n\n")

vedba_cols <- grep("VeDBA", colnames(raw_csv), value = TRUE)

cat(sprintf("  Found %d VeDBA columns:\n", length(vedba_cols)))
for (col in vedba_cols) {
  cat(sprintf("    • %s\n", col))
}

cat("\n  First 10 values of each VeDBA column:\n")
for (col in vedba_cols) {
  val <- raw_csv[[col]][1:10]
  n_na <- sum(is.na(val))
  cat(sprintf("    %s: %s [%d NAs]\n", col,
             paste(round(as.numeric(val), 2), collapse = ", "),
             n_na))
}

cat("\n")

# ============================================================================
# STEP 3: Check timestamp parsing
# ============================================================================

cat("Step 3: Checking timestamp parsing...\n\n")

# Show first few timestamps
cat("  First 5 'Time (UTC)' values:\n")
print(head(raw_csv$`Time (UTC)`, 5))

# Try parsing
tryCatch({
  parsed_ts <- parse_datetime(raw_csv$`Time (UTC)`[1:5], format = "%d.%m.%Y, %H:%M:%S")
  cat("  ✓ Successfully parsed timestamps\n")
  print(parsed_ts)
}, error = function(e) {
  cat("  ✗ Error parsing timestamps:\n")
  cat("    ", e$message, "\n")
})

cat("\n")

# ============================================================================
# STEP 4: Parse using import function and inspect
# ============================================================================

cat("Step 4: Parsing via calibration_import_functions...\n\n")

data <- import_wildcloud_csv(csv_path, decoder = "nanofox_finescalepressure")

cat(sprintf("  Parsed data: %d rows, %d columns\n", nrow(data), ncol(data)))
cat("  Columns:", paste(colnames(data), collapse = ", "), "\n\n")

# ============================================================================
# STEP 5: Inspect VeDBA distribution
# ============================================================================

cat("Step 5: VeDBA value distribution...\n\n")

cat("  Summary statistics (all rows):\n")
print(summary(data$vedba))

cat("\n  Distribution:\n")
cat(sprintf("    • Total records: %d\n", nrow(data)))
cat(sprintf("    • Non-NA records: %d\n", sum(!is.na(data$vedba))))
cat(sprintf("    • All NA: %s\n", all(is.na(data$vedba))))

if (!all(is.na(data$vedba))) {
  cat(sprintf("    • Min VeDBA: %.2f\n", min(data$vedba, na.rm = TRUE)))
  cat(sprintf("    • Max VeDBA: %.2f\n", max(data$vedba, na.rm = TRUE)))
  cat(sprintf("    • Median VeDBA: %.2f\n", median(data$vedba, na.rm = TRUE)))
  cat(sprintf("    • Mean VeDBA: %.2f\n", mean(data$vedba, na.rm = TRUE)))
}

cat("\n  VeDBA by tag:\n")
by_tag <- data %>%
  group_by(tag_id) %>%
  summarise(
    n = n(),
    n_na = sum(is.na(vedba)),
    min_vedba = min(vedba, na.rm = TRUE),
    max_vedba = max(vedba, na.rm = TRUE),
    median_vedba = median(vedba, na.rm = TRUE),
    .groups = "drop"
  ) %>%
  arrange(tag_id)

print(as.data.frame(by_tag))

cat("\n")

# ============================================================================
# STEP 6: Check time gaps
# ============================================================================

cat("Step 6: Time gaps between records (by tag)...\n\n")

for (tag in unique(data$tag_id)[1:3]) {  # Show first 3 tags
  tag_data <- data[data$tag_id == tag, ] %>%
    arrange(timestamp)

  if (nrow(tag_data) > 1) {
    time_gaps <- as.numeric(diff(tag_data$timestamp, units = "hours"))

    cat(sprintf("  Tag %s (%d records):\n", tag, nrow(tag_data)))
    cat(sprintf("    • Time range: %s to %s\n",
               format(tag_data$timestamp[1], "%Y-%m-%d %H:%M"),
               format(tag_data$timestamp[nrow(tag_data)], "%Y-%m-%d %H:%M")))
    cat(sprintf("    • Time gaps: min=%.1f, max=%.1f, median=%.1f hours\n",
               min(time_gaps, na.rm = TRUE),
               max(time_gaps, na.rm = TRUE),
               median(time_gaps, na.rm = TRUE)))
    cat(sprintf("    • Gaps > 1 hour: %d\n", sum(time_gaps > 1, na.rm = TRUE)))
    cat("\n")
  }
}

cat("\n")

# ============================================================================
# STEP 7: Try detection with DIFFERENT THRESHOLDS
# ============================================================================

cat("Step 7: Testing detection with different thresholds...\n\n")

thresholds <- list(
  list(duration = 3, vedba = 20, name = "DEFAULT (3h, VeDBA<20)"),
  list(duration = 2, vedba = 30, name = "RELAXED (2h, VeDBA<30)"),
  list(duration = 1, vedba = 50, name = "VERY RELAXED (1h, VeDBA<50)"),
  list(duration = 3, vedba = 50, name = "HIGH VeDBA (3h, VeDBA<50)"),
  list(duration = 6, vedba = 20, name = "LONG DURATION (6h, VeDBA<20)")
)

for (thresh in thresholds) {
  events <- detect_calibration_periods(
    data,
    min_duration_hours = thresh$duration,
    vedba_threshold = thresh$vedba,
    min_samples = 3
  )

  status <- if (nrow(events) > 0) "✓ FOUND" else "✗ NOT FOUND"
  cat(sprintf("  %s: %s (%d events)\n", thresh$name, status, nrow(events)))

  if (nrow(events) > 0) {
    cat(sprintf("     Sample: Tag %s, %.1f-%.1f hours, median VeDBA %.1f m/s²\n",
               events$tag_id[1], events$duration_hours[1], events$duration_hours[1],
               events$median_vedba[1]))
  }
}

cat("\n")

# ============================================================================
# STEP 8: RECOMMENDATIONS
# ============================================================================

cat("════════════════════════════════════════════════════════════════════════\n")
cat("  RECOMMENDATIONS\n")
cat("════════════════════════════════════════════════════════════════════════\n\n")

# Analyze the situation
all_na_vedba <- all(is.na(data$vedba))
some_na_vedba <- any(is.na(data$vedba))
median_vedba <- median(data$vedba, na.rm = TRUE)

if (all_na_vedba) {
  cat("❌ PROBLEM: All VeDBA values are NA\n\n")
  cat("This likely means the column names don't match what the parser expects.\n")
  cat("Check that your CSV has columns named exactly:\n")
  cat("  • 'VeDBA sum 0 min ago (m/s²)'\n")
  cat("  • or other VeDBA columns with values like '0.000000'\n\n")
  cat("FIX: Look at the actual column names above (Step 1).\n")
  cat("Update the .parse_nanofox_finescale() function in calibration_import_functions.R\n")
  cat("to match your CSV's actual column names.\n")

} else if (some_na_vedba) {
  cat("⚠️  WARNING: Some VeDBA values are NA\n\n")
  cat("This is expected if some records don't have VeDBA data.\n")
  cat("The detection algorithm filters these out automatically.\n\n")

} else {
  cat("✓ VeDBA values parsed successfully\n\n")
}

if (median_vedba < 5) {
  cat("⚠️  VeDBA values are very low (median=%.1f m/s²)\n\n", median_vedba)
  cat("This might indicate:\n")
  cat("  • Tags in very low-activity state (unlikely for bats)\n")
  cat("  • Sensor scaling issue (check VEDBA_IMPORT_CODE_REVIEW.md in project)\n")
  cat("  • Wrong column being used for VeDBA\n\n")
} else if (median_vedba > 200) {
  cat("✓ VeDBA values look reasonable (high activity)\n\n")
  cat("Try relaxing thresholds for calibration detection:\n")
  cat("  • Increase vedba_threshold to 50-100 m/s²\n")
  cat("  • Or decrease min_duration_hours to 1-2 hours\n\n")
}

cat("To re-import with custom thresholds:\n\n")
cat("  result <- process_wildcloud_import(\n")
cat("    get_db_connection(),\n")
cat("    csv_path,\n")
cat("    imported_by = 'ehurme@ab.mpg.de',\n")
cat("    min_duration_hours = 2,      # Adjust this\n")
cat("    vedba_threshold = 30         # Adjust this\n")
cat("  )\n")

cat("\n")
