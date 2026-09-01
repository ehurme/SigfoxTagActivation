# ============================================================================
# CALIBRATION DATABASE - QUICK SETUP SCRIPT
# ============================================================================
# Run this once to initialize the system and check dependencies

cat("\n")
cat("════════════════════════════════════════════════════════════════════════\n")
cat("  SigFox Tag Calibration Database - Setup\n")
cat("════════════════════════════════════════════════════════════════════════\n")
cat("\n")

# Step 1: Check and install dependencies
cat("[1/3] Checking dependencies...\n")

required_packages <- c(
  "DBI",           # Database interface
  "RSQLite",       # SQLite driver
  "data.table",    # Fast data parsing
  "tidyverse",     # dplyr, ggplot2
  "lubridate",     # Date/time handling
  "shiny",         # Web framework
  "shinyjs",       # JavaScript bindings
  "DT",            # DataTables for Shiny
  "ggplot2",       # Plotting
  "digest"         # File hashing
)

missing_packages <- setdiff(required_packages, rownames(installed.packages()))

if (length(missing_packages) > 0) {
  cat("  ⚠️  Missing packages. Installing...\n")
  install.packages(missing_packages, quiet = TRUE)
  cat(sprintf("     Installed: %s\n", paste(missing_packages, collapse = ", ")))
} else {
  cat("  ✓ All dependencies found.\n")
}

cat("\n")

# Step 2: Load modules
cat("[2/3] Loading modules...\n")

source("calibration_db_schema.R")
source("calibration_import_functions.R")

cat("  ✓ Schema functions loaded\n")
cat("  ✓ Import functions loaded\n")

cat("\n")

# Step 3: Initialize database
cat("[3/3] Initializing database...\n")

db_path <- "calibration_events.db"

if (!file.exists(db_path)) {
  init_calibration_db(db_path)
  cat(sprintf("  ✓ Created new database: %s\n", db_path))
} else {
  cat(sprintf("  ✓ Database already exists: %s\n", db_path))
}

conn <- get_db_connection(db_path)

# Check tables
tables <- dbListTables(conn)
cat(sprintf("  ✓ Database contains %d tables\n", length(tables)))

dbDisconnect(conn)

cat("\n")
cat("════════════════════════════════════════════════════════════════════════\n")
cat("  SETUP COMPLETE!\n")
cat("════════════════════════════════════════════════════════════════════════\n")
cat("\n")

cat("NEXT STEPS:\n")
cat("  1. Quick import test:\n")
cat("     source('calibration_import_functions.R')\n")
cat("     result <- process_wildcloud_import(\n")
cat("       get_db_connection(),\n")
cat("       'path/to/your/wildcloud_export.csv',\n")
cat("       imported_by = 'your.name@email.com'\n")
cat("     )\n")
cat("\n")
cat("  2. Launch Shiny app:\n")
cat("     source('calibration_shiny_app.R')\n")
cat("     shiny::runApp()\n")
cat("\n")
cat("  3. Read the documentation:\n")
cat("     file.show('CALIBRATION_DB_README.md')\n")
cat("\n")
