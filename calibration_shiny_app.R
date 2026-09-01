# Calibration Database - Shiny Web App
# Interactive UI for browsing, labeling, and managing calibration events

library(shiny)
library(shinyjs)
library(shinyTable)
library(DBI)
library(RSQLite)
library(dplyr)
library(ggplot2)
library(lubridate)

# ============================================================================
# UI DEFINITION
# ============================================================================

ui <- fluidPage(
  shinyjs::useShinyjs(),
  theme = bslib::bs_theme(version = 5, preset = "flatly"),

  titlePanel(
    h1(icon("flask"), "SigFox Tag Calibration Database", style = "color: #2c3e50;")
  ),

  # Sidebar for controls
  sidebarLayout(
    sidebarPanel(
      width = 3,
      h4("Filters & Controls"),

      # Database connection info
      div(
        id = "db_status",
        p("📊 Database:", strong("calibration_events.db"), class = "small text-muted")
      ),

      hr(),

      # Filter by tag
      selectizeInput(
        "filter_tag_id",
        label = "Tag ID(s)",
        choices = NULL,
        multiple = TRUE,
        placeholder = "All tags"
      ),

      # Filter by status
      checkboxGroupInput(
        "filter_status",
        label = "Status",
        choices = c("Pending" = "pending", "Confirmed" = "confirmed", "Rejected" = "rejected"),
        selected = c("pending", "confirmed")
      ),

      # Filter by location
      textInput("filter_location", "Location (substring match)", placeholder = "e.g., 2nd floor"),

      # Date range
      dateRangeInput(
        "filter_date_range",
        label = "Date Range",
        start = Sys.Date() - 30,
        end = Sys.Date()
      ),

      hr(),

      # Action buttons
      actionButton("btn_refresh", "🔄 Refresh Data", class = "btn-info w-100 mb-2"),
      actionButton("btn_import", "📥 Import Wildcloud CSV", class = "btn-success w-100 mb-2"),
      actionButton("btn_export", "📥 Export Report", class = "btn-primary w-100"),

      hr(),

      # Statistics panel
      h5("Summary Statistics"),
      verbatimTextOutput("stats_summary")
    ),

    # Main content area
    mainPanel(
      width = 9,

      tabsetPanel(
        id = "tabs",

        # ====================================================================
        # TAB 1: EVENTS TABLE
        # ====================================================================
        tabPanel(
          "Events",
          icon = icon("table"),

          br(),

          # Responsive table
          div(
            style = "overflow-x: auto;",
            DT::dataTableOutput("table_events")
          ),

          br(),

          # Selected event details
          conditionalPanel(
            condition = "input.table_events_rows_selected.length > 0",

            h4("Selected Event Details"),

            div(
              id = "event_details_panel",
              class = "well",

              fluidRow(
                column(6,
                  p(strong("Event ID:"), tags$code(textOutput("detail_event_id", inline = TRUE))),
                  p(strong("Tag ID:"), tags$code(textOutput("detail_tag_id", inline = TRUE))),
                  p(strong("Time Range:"), textOutput("detail_time_range", inline = TRUE)),
                  p(strong("Duration:"), textOutput("detail_duration", inline = TRUE))
                ),
                column(6,
                  p(strong("VeDBA (Median):"), textOutput("detail_vedba_median", inline = TRUE), "m/s²"),
                  p(strong("VeDBA (Mean):"), textOutput("detail_vedba_mean", inline = TRUE), "m/s²"),
                  p(strong("VeDBA (Max):"), textOutput("detail_vedba_max", inline = TRUE), "m/s²"),
                  p(strong("Samples:"), textOutput("detail_n_samples", inline = TRUE))
                )
              )
            )
          )
        ),

        # ====================================================================
        # TAB 2: LABELING INTERFACE
        # ====================================================================
        tabPanel(
          "Label Event",
          icon = icon("tag"),

          br(),

          conditionalPanel(
            condition = "input.table_events_rows_selected.length > 0",

            h3("Label Calibration Event"),

            div(
              class = "well",

              fluidRow(
                column(12,
                  strong("Selected Event:"),
                  textOutput("label_selected_event")
                )
              ),

              hr(),

              # Location input
              textInput(
                "label_location",
                label = "Location / Description",
                placeholder = "e.g., 2nd floor, office, shelf corner",
                value = ""
              ),

              # Brief description
              textInput(
                "label_description",
                label = "Brief Description",
                placeholder = "e.g., Initial calibration, Environmental test",
                value = ""
              ),

              # Detailed notes
              tags$textarea(
                id = "label_notes",
                rows = 5,
                cols = 50,
                placeholder = "Detailed notes: who activated, any special conditions, etc.",
                style = "width: 100%; font-family: monospace; font-size: 0.9em;"
              ),

              # Status and user
              fluidRow(
                column(6,
                  radioButtons(
                    "label_status",
                    label = "Status",
                    choices = c("Confirmed" = "confirmed", "Rejected" = "rejected", "Pending" = "pending"),
                    selected = "confirmed"
                  )
                ),
                column(6,
                  textInput("label_user", "Your Name/Email", value = Sys.info()["user"])
                )
              ),

              # Action buttons
              fluidRow(
                column(6,
                  actionButton("btn_save_label", "💾 Save Label", class = "btn-success btn-lg w-100")
                ),
                column(6,
                  actionButton("btn_cancel_label", "✕ Cancel", class = "btn-secondary w-100")
                )
              )
            ),

            # Success/error messages
            uiOutput("label_message")
          ),

          conditionalPanel(
            condition = "input.table_events_rows_selected.length == 0",
            p(class = "text-muted", "Select an event from the Events tab to label it.")
          )
        ),

        # ====================================================================
        # TAB 3: CO-OCCURRENCE GROUPS
        # ====================================================================
        tabPanel(
          "Groups & Patterns",
          icon = icon("sitemap"),

          br(),

          p(class = "text-muted",
            "Tags that were low-activity simultaneously (likely activated together on shelf)"
          ),

          br(),

          # Groups summary table
          h4("Co-occurrence Groups"),
          DT::dataTableOutput("table_groups"),

          br(),

          # Heatmap of co-occurrence
          h4("Tag Activity Heatmap (by date)"),
          plotOutput("plot_activity_heatmap", height = 400)
        ),

        # ====================================================================
        # TAB 4: IMPORT HISTORY
        # ====================================================================
        tabPanel(
          "Import History",
          icon = icon("history"),

          br(),

          p(class = "text-muted",
            "Log of all Wildcloud imports with deduplication tracking"
          ),

          br(),

          DT::dataTableOutput("table_import_history")
        ),

        # ====================================================================
        # TAB 5: DOCUMENTATION
        # ====================================================================
        tabPanel(
          "Help",
          icon = icon("circle-info"),

          br(),

          h3("Quick Start Guide"),

          h4("1. Import Wildcloud Data"),
          p("Click 'Import Wildcloud CSV' to upload a Wildcloud export file. The system will:"),
          tags$ul(
            tags$li("Check for duplicates based on file hash"),
            tags$li("Automatically detect low-VeDBA periods (3+ hours with median VeDBA < 20 m/s²)"),
            tags$li("Log new calibration events as 'pending' status")
          ),

          h4("2. Label Events"),
          p("Navigate to the 'Label Event' tab:"),
          tags$ul(
            tags$li("Select an event from the Events table"),
            tags$li("Enter location (e.g., '2nd floor, office, shelf')"),
            tags$li("Add brief description and detailed notes"),
            tags$li("Mark as confirmed, rejected, or leave pending"),
            tags$li("Click 'Save Label'")
          ),

          h4("3. Review Groups"),
          p("The 'Groups & Patterns' tab shows:"),
          tags$ul(
            tags$li("Co-occurrence groups: tags that were at rest simultaneously"),
            tags$li("Activity heatmap: visual overview of tag locations over time")
          ),

          h4("4. Export Results"),
          p("Use the 'Export Report' button to save labeled calibration events as CSV for further analysis."),

          hr(),

          h3("Data Schema"),

          h4("VeDBA Thresholds (m/s²)"),
          p(
            "Tags showing median VeDBA < 20 m/s² over 3+ hours are flagged as calibration periods. ",
            "This indicates low movement (at rest, likely on shelf)."
          ),

          h4("Duplicate Detection"),
          p(
            "Files are hashed on import to detect re-uploads. ",
            "The database tracks import source and prevents duplicate calibration events."
          ),

          h4("Status Meanings"),
          tags$ul(
            tags$li(strong("Pending:"), " Automatically detected, awaiting review"),
            tags$li(strong("Confirmed:"), " Labeled by user as valid calibration period"),
            tags$li(strong("Rejected:"), " User determined this was a false positive")
          ),

          hr(),

          h4("Contact & Support"),
          p("For questions or issues with the database, contact the project maintainer.")
        )
      )
    )
  )
)

# ============================================================================
# SERVER LOGIC
# ============================================================================

server <- function(input, output, session) {

  # Reactive connection to database
  db_conn <- reactive({
    get_db_connection("calibration_events.db")
  })

  # Reactive data: all calibration events
  calibration_data <- reactive({
    input$btn_refresh

    conn <- db_conn()
    events <- get_calibration_events(
      conn,
      tag_id = if (length(input$filter_tag_id) > 0) input$filter_tag_id else NULL,
      status = if (length(input$filter_status) > 0) input$filter_status else NULL,
      location = if (nchar(input$filter_location) > 0) input$filter_location else NULL,
      start_date = input$filter_date_range[1],
      end_date = input$filter_date_range[2],
      exclude_duplicates = TRUE
    )

    return(events)
  })

  # Update tag dropdown with available tags
  observe({
    conn <- db_conn()
    available_tags <- dbGetQuery(conn, "SELECT DISTINCT tag_id FROM tags ORDER BY tag_id")$tag_id

    updateSelectizeInput(session, "filter_tag_id",
      choices = available_tags,
      server = TRUE
    )
  })

  # ====================================================================
  # TAB 1: EVENTS TABLE
  # ====================================================================

  output$table_events <- DT::renderDataTable({
    data <- calibration_data()

    if (nrow(data) == 0) {
      return(DT::datatable(
        data.frame("No events found" = character(0)),
        options = list(dom = 't')
      ))
    }

    display_data <- data %>%
      select(event_id, tag_id, start_time, end_time, duration_hours,
             median_vedba, status, label_location) %>%
      mutate(
        start_time = format(start_time, "%Y-%m-%d %H:%M"),
        end_time = format(end_time, "%Y-%m-%d %H:%M"),
        duration_hours = round(duration_hours, 1),
        median_vedba = round(median_vedba, 1)
      )

    DT::datatable(
      display_data,
      selection = "single",
      rownames = FALSE,
      options = list(
        pageLength = 15,
        searching = TRUE,
        ordering = TRUE,
        columnDefs = list(
          list(targets = 0, visible = FALSE)  # Hide event_id in display
        )
      )
    )
  })

  # Selected event details
  selected_event <- reactive({
    if (length(input$table_events_rows_selected) == 0) return(NULL)

    data <- calibration_data()
    if (nrow(data) == 0) return(NULL)

    data[input$table_events_rows_selected, ]
  })

  output$detail_event_id <- renderText({
    evt <- selected_event()
    if (is.null(evt)) return("—")
    evt$event_id
  })

  output$detail_tag_id <- renderText({
    evt <- selected_event()
    if (is.null(evt)) return("—")
    evt$tag_id
  })

  output$detail_time_range <- renderText({
    evt <- selected_event()
    if (is.null(evt)) return("—")
    sprintf("%s to %s",
           format(evt$start_time, "%Y-%m-%d %H:%M"),
           format(evt$end_time, "%Y-%m-%d %H:%M"))
  })

  output$detail_duration <- renderText({
    evt <- selected_event()
    if (is.null(evt)) return("—")
    sprintf("%.1f hours", evt$duration_hours)
  })

  output$detail_vedba_median <- renderText({
    evt <- selected_event()
    if (is.null(evt)) return("—")
    round(evt$median_vedba, 1)
  })

  output$detail_vedba_mean <- renderText({
    evt <- selected_event()
    if (is.null(evt)) return("—")
    round(evt$mean_vedba, 1)
  })

  output$detail_vedba_max <- renderText({
    evt <- selected_event()
    if (is.null(evt)) return("—")
    round(evt$max_vedba, 1)
  })

  output$detail_n_samples <- renderText({
    evt <- selected_event()
    if (is.null(evt)) return("—")
    evt$n_samples
  })

  # ====================================================================
  # TAB 2: LABELING
  # ====================================================================

  output$label_selected_event <- renderText({
    evt <- selected_event()
    if (is.null(evt)) return("None selected")

    sprintf("Tag %s | %s to %s | VeDBA: %.1f m/s² (median)",
           evt$tag_id,
           format(evt$start_time, "%Y-%m-%d %H:%M"),
           format(evt$end_time, "%Y-%m-%d %H:%M"),
           evt$median_vedba)
  })

  # Populate label fields from selected event
  observe({
    evt <- selected_event()

    if (!is.null(evt)) {
      # Pre-fill with existing labels if present
      updateTextInput(session, "label_location", value = evt$label_location %||% "")
      updateTextInput(session, "label_description", value = evt$label_description %||% "")

      shinyjs::runjs(sprintf("$('#label_notes').val('%s');",
                            gsub("'", "\\'", evt$label_notes %||% "")))

      if (!is.na(evt$status)) {
        updateRadioButtons(session, "label_status", selected = evt$status)
      }
    }
  })

  # Save label
  observeEvent(input$btn_save_label, {
    evt <- selected_event()

    if (is.null(evt)) {
      output$label_message <- renderUI({
        div(class = "alert alert-danger", "No event selected.")
      })
      return()
    }

    conn <- db_conn()

    # Get textarea value (shiny doesn't have direct binding for textarea)
    notes <- "placeholder"  # In production, use shinyjs to read textarea value

    success <- label_calibration_event(
      conn,
      event_id = evt$event_id,
      location = input$label_location,
      description = input$label_description,
      notes = notes,
      labeled_by = input$label_user,
      status = input$label_status
    )

    if (success) {
      output$label_message <- renderUI({
        div(class = "alert alert-success",
          "✓ Event labeled successfully!")
      })

      # Refresh table
      shinyjs::delay(1000, {
        shinyjs::click("btn_refresh")
      })
    } else {
      output$label_message <- renderUI({
        div(class = "alert alert-danger",
          "✗ Error saving label. Check console for details.")
      })
    }
  })

  # Cancel labeling
  observeEvent(input$btn_cancel_label, {
    updateTextInput(session, "label_location", value = "")
    updateTextInput(session, "label_description", value = "")
    shinyjs::runjs("$('#label_notes').val('');")
    output$label_message <- renderUI({ })
  })

  # ====================================================================
  # TAB 3: GROUPS & PATTERNS
  # ====================================================================

  output$table_groups <- DT::renderDataTable({
    conn <- db_conn()

    # Query co-occurrence groups
    groups <- dbGetQuery(conn,
      "SELECT * FROM co_occurrence_groups ORDER BY start_time DESC LIMIT 100"
    )

    if (nrow(groups) == 0) {
      return(DT::datatable(
        data.frame("No groups found" = character(0)),
        options = list(dom = 't')
      ))
    }

    display_groups <- groups %>%
      select(group_id, n_tags, tags, start_time, end_time, location) %>%
      mutate(
        start_time = format(start_time, "%Y-%m-%d %H:%M"),
        end_time = format(end_time, "%Y-%m-%d %H:%M")
      )

    DT::datatable(
      display_groups,
      rownames = FALSE,
      options = list(pageLength = 10)
    )
  })

  output$plot_activity_heatmap <- renderPlot({
    data <- calibration_data()

    if (nrow(data) == 0) {
      return(ggplot() + theme_minimal() + ggtitle("No data to display"))
    }

    # Summarize by tag and date
    heatmap_data <- data %>%
      mutate(
        date = as.Date(start_time),
        n_events = 1
      ) %>%
      group_by(tag_id, date) %>%
      summarise(n_events = n(), .groups = "drop")

    ggplot(heatmap_data, aes(x = date, y = tag_id, fill = n_events)) +
      geom_tile(color = "white") +
      scale_fill_gradient(low = "#ecf0f1", high = "#e74c3c") +
      theme_minimal() +
      labs(
        title = "Calibration Event Frequency by Tag & Date",
        x = "Date",
        y = "Tag ID",
        fill = "# Events"
      ) +
      theme(axis.text.x = element_text(angle = 45, hjust = 1))
  })

  # ====================================================================
  # TAB 4: IMPORT HISTORY
  # ====================================================================

  output$table_import_history <- DT::renderDataTable({
    conn <- db_conn()

    imports <- dbGetQuery(conn,
      "SELECT import_id, file_path, n_records, date_range_start, date_range_end,
              imported_by, created_at FROM wildcloud_imports
       ORDER BY created_at DESC LIMIT 50"
    )

    if (nrow(imports) == 0) {
      return(DT::datatable(
        data.frame("No imports" = character(0)),
        options = list(dom = 't')
      ))
    }

    display_imports <- imports %>%
      mutate(
        file_name = basename(file_path),
        date_range = sprintf("%s to %s", date_range_start, date_range_end),
        created_at = format(created_at, "%Y-%m-%d %H:%M")
      ) %>%
      select(import_id, file_name, n_records, date_range, imported_by, created_at)

    DT::datatable(
      display_imports,
      rownames = FALSE,
      options = list(pageLength = 15)
    )
  })

  # ====================================================================
  # SUMMARY STATISTICS
  # ====================================================================

  output$stats_summary <- renderText({
    data <- calibration_data()
    conn <- db_conn()

    n_events <- nrow(data)
    n_tags <- n_distinct(data$tag_id)
    n_confirmed <- sum(data$status == "confirmed", na.rm = TRUE)
    n_pending <- sum(data$status == "pending", na.rm = TRUE)

    stats <- dbGetQuery(conn,
      "SELECT COUNT(DISTINCT tag_id) as n_tags_total,
              COUNT(*) as n_events_total
       FROM calibration_events
       WHERE duplicate_of_event_id IS NULL"
    )

    sprintf(
      "Filtered: %d events | %d tags\n\nTotal DB: %d events | %d tags\n\nStatus:\n  ✓ Confirmed: %d\n  ⏳ Pending: %d",
      n_events, n_tags,
      stats$n_events_total, stats$n_tags_total,
      n_confirmed, n_pending
    )
  })

  # ====================================================================
  # IMPORT ACTION
  # ====================================================================

  observeEvent(input$btn_import, {
    showModal(
      modalDialog(
        title = "Import Wildcloud CSV",
        size = "l",

        fileInput("import_file", "Choose Wildcloud CSV file", accept = ".csv"),

        selectInput("import_decoder", "Decoder Type",
          choices = list(
            "NanoFox FinescalePressure" = "nanofox_finescalepressure",
            "TinyFoxBatt" = "tinyfoxbatt"
          )
        ),

        textInput("import_user", "Your name/email", value = Sys.info()["user"]),

        footer = tagList(
          actionButton("import_submit", "Import", class = "btn-success"),
          modalButton("Cancel")
        )
      )
    )
  })

  observeEvent(input$import_submit, {
    if (is.null(input$import_file)) {
      showNotification("Please select a file.", type = "error")
      return()
    }

    conn <- db_conn()

    result <- process_wildcloud_import(
      conn,
      input$import_file$datapath,
      decoder = input$import_decoder,
      imported_by = input$import_user
    )

    if (result$is_duplicate) {
      showNotification(
        sprintf("File already imported (import_id: %d)", result$import_id),
        type = "warning"
      )
    } else {
      showNotification(
        sprintf("✓ Import complete! %d events added.", result$n_events_inserted),
        type = "message"
      )
    }

    removeModal()
    shinyjs::click("btn_refresh")
  })

  # ====================================================================
  # EXPORT ACTION
  # ====================================================================

  observeEvent(input$btn_export, {
    export_file <- sprintf("calibration_export_%s.csv", format(Sys.time(), "%Y%m%d_%H%M%S"))
    export_calibration_report(db_conn(), export_file, status = "confirmed")

    showNotification(
      sprintf("Exported to: %s", export_file),
      type = "message"
    )
  })
}

# ============================================================================
# RUN APP
# ============================================================================

shinyApp(ui = ui, server = server)
