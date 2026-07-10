# NYC Restaurant Health Code Diagnoser — hackathon MVP
#
# Flow: photo upload -> vision LLM call (grounded in real DOHMH codes
# pulled from Postgres) -> severity + remediation lookup -> results.
#
# Required env vars (set in .Renviron or your shell before launching):
#   ANTHROPIC_API_KEY
#   PGHOST      (default: localhost)
#   PGPORT      (default: 5433 — matches the Postgres.app instance you're using)
#   PGDATABASE  (default: dohmh_hackathon)
#   PGUSER      (default: postgres)
#   PGPASSWORD
#
# Before running this app, run test_pipeline.R in the Console to verify
# each piece (DB connection, codebook, vision LLM call) works in isolation.

library(shiny)
library(htmltools)
source("helpers.R")

# ---- UI -----------------------------------------------------------------

# Built fresh each time the input is (re)rendered so "Remove photo" /
# "Start over" can mount a clean, empty file input.
build_photo_input <- function() {
  tagQuery(
    fileInput("photo", "Take or upload a restaurant photo", accept = "image/*")
  )$find("input")$addAttrs(capture = "environment")$allTags()
}

# Warm the codebook cache once per R process so the first analysis click
# doesn't pay the DB/CSV load; a failure here is retried at analysis time.
try(load_violation_codebook_cached(), silent = TRUE)

ui <- fluidPage(
  tags$head(
    tags$meta(name = "viewport", content = "width=device-width, initial-scale=1"),
    tags$style(HTML("\
      :root { --ink: #1d1c19; --muted: #6c675f; --ground: #e7e2d9; --paper: #f7f4ee; --oxide: #a84a2b; --line: #bcb5ab; --fine-line: #d5cfc5; }
      body { background: var(--ground); color: var(--ink); font-family: Arial, Helvetica, sans-serif; }
      .container-fluid { max-width: 1320px; padding: 20px 32px 70px; }
      .hero { border-bottom: 1px solid var(--ink); border-top: 4px solid var(--ink); display: grid; gap: 24px; grid-template-columns: minmax(0, 1fr) 260px; margin-bottom: 42px; padding: 22px 0 28px; }
      .hero-kicker, .result-eyebrow { color: var(--oxide); font-size: 11px; font-weight: 700; letter-spacing: 1.35px; margin: 0 0 14px; text-transform: uppercase; }
      .hero h1 { font-family: Georgia, \"Times New Roman\", serif; font-size: clamp(43px, 6vw, 78px); font-weight: 400; letter-spacing: -3.2px; line-height: 0.93; margin: 0; max-width: 790px; }
      .hero p { font-size: 16px; line-height: 1.5; margin: 20px 0 0; max-width: 570px; }
      .hero-meta { align-self: end; border-left: 1px solid var(--line); color: var(--muted); font-size: 12px; letter-spacing: 0.45px; line-height: 1.55; padding: 2px 0 2px 18px; text-transform: uppercase; }
      .hero-meta strong { color: var(--ink); display: block; font-size: 12px; letter-spacing: 0.8px; margin-bottom: 8px; }
      .well { background: transparent; border: 0; box-shadow: none; margin: 0; padding: 0; }
      .sidebar { border-top: 1px solid var(--ink); padding: 17px 0 0; }
      .sidebar h3 { font-family: Georgia, \"Times New Roman\", serif; font-size: 27px; font-weight: 400; letter-spacing: -0.7px; margin: 0 0 9px; }
      .sidebar-intro { color: var(--muted); font-size: 14px; line-height: 1.5; margin-bottom: 28px; }
      .control-label { color: var(--ink); font-size: 11px; font-weight: 700; letter-spacing: 0.9px; margin-bottom: 8px; text-transform: uppercase; }
      .form-control { background: transparent; border: 0; border-bottom: 1px solid var(--line); border-radius: 0; box-shadow: none; color: var(--ink); min-height: 42px; padding-left: 0; }
      textarea.form-control { border: 1px solid var(--line); min-height: 112px; padding: 10px; }
      .form-control:focus { border-color: var(--ink); box-shadow: none; }
      .form-group { margin-bottom: 24px; }
      .btn-primary { background: var(--ink); border: 1px solid var(--ink); border-radius: 0; font-size: 12px; font-weight: 700; letter-spacing: 1px; padding: 13px 16px; text-transform: uppercase; transition: background 0.16s ease, color 0.16s ease; width: 100%; }
      .btn-primary:hover, .btn-primary:focus { background: var(--oxide); border-color: var(--oxide); }
      .upload-help { color: var(--muted); font-size: 12px; line-height: 1.4; margin: -10px 0 22px; }
      .photo-preview { border: 1px solid var(--line); margin: 0 0 22px; padding: 10px; }
      .photo-preview img { display: block; max-height: 220px; max-width: 100%; }
      .photo-preview-meta { align-items: baseline; color: var(--muted); display: flex; font-size: 12px; gap: 14px; justify-content: space-between; margin-top: 9px; word-break: break-all; }
      .photo-preview-meta a { color: var(--oxide); font-weight: 700; letter-spacing: 0.7px; text-transform: uppercase; white-space: nowrap; }
      .photo-error { color: #a03025; font-size: 13px; margin: 0 0 22px; }
      .btn-primary[disabled] { cursor: wait; opacity: 0.55; }
      .start-over-wrap { border-top: 1px solid var(--fine-line); margin-top: 36px; padding-top: 15px; }
      .start-over-wrap a { color: var(--oxide); font-size: 12px; font-weight: 700; letter-spacing: 0.7px; text-decoration: none; text-transform: uppercase; }
      .main-panel { border-left: 1px solid var(--line); min-height: 480px; padding-left: 42px; }
      .results-card, .results-empty { border-top: 1px solid var(--ink); padding-top: 17px; }
      .results-empty { color: var(--muted); max-width: 520px; padding-top: 19px; }
      .results-empty .empty-icon { display: none; }
      .results-empty h3 { color: var(--ink); font-family: Georgia, \"Times New Roman\", serif; font-size: 30px; font-weight: 400; letter-spacing: -0.7px; margin: 0 0 10px; }
      .results-card h3 { font-family: Georgia, \"Times New Roman\", serif; font-size: clamp(30px, 4vw, 46px); font-weight: 400; letter-spacing: -1.25px; line-height: 1.04; margin: 0 0 27px; max-width: 800px; }
      .result-meta { border-bottom: 1px solid var(--fine-line); border-top: 1px solid var(--fine-line); display: grid; gap: 0 25px; grid-template-columns: repeat(2, minmax(0, 1fr)); margin: 0 0 29px; padding: 13px 0; }
      .result-meta p { font-size: 14px; line-height: 1.45; margin: 3px 0; }
      .result-meta a { border-bottom: 1px solid var(--line); color: var(--ink); text-decoration: none; }
      .result-meta a:after { content: \" ↗\"; color: var(--muted); }
      .result-meta a:hover { border-color: var(--oxide); color: var(--oxide); }
      .results-card h5 { color: var(--oxide); font-size: 11px; font-weight: 700; letter-spacing: 1px; margin: 29px 0 12px; text-transform: uppercase; }
      .results-card ul { margin-bottom: 0; max-width: 720px; padding-left: 19px; }
      .results-card li { line-height: 1.55; margin-bottom: 9px; }
      .service-links { display: flex; flex-wrap: wrap; gap: 0 22px; list-style: none; padding-left: 0 !important; }
      .service-links li { margin: 0; }
      .service-links a { border-bottom: 1px solid var(--ink); color: var(--ink); display: inline-block; font-size: 12px; font-weight: 700; letter-spacing: 0.7px; padding-bottom: 3px; text-decoration: none; text-transform: uppercase; }
      .service-links a:after { content: \" ↗\"; }
      .service-links a:hover { border-color: var(--oxide); color: var(--oxide); }
      .severity-critical { color: #a03025; font-weight: 700; } .severity-noncritical { color: #7a5416; font-weight: 700; } .severity-unknown { color: var(--muted); font-weight: 700; }
      @media (max-width: 767px) { .container-fluid { padding: 16px 18px 45px; } .hero { display: block; margin-bottom: 30px; } .hero h1 { letter-spacing: -2px; } .hero-meta { border-left: 0; border-top: 1px solid var(--line); margin-top: 25px; padding: 14px 0 0; } .main-panel { border-left: 0; border-top: 1px solid var(--line); margin-top: 30px; min-height: 0; padding: 30px 0 0; } .result-meta { grid-template-columns: 1fr; } }
    ")),
    tags$script(HTML("
      // Instant feedback: disable the button the moment it's clicked; the
      // server re-enables it (custom message) when the analysis finishes.
      function setAnalyzeBusy(busy) {
        var btn = document.getElementById('analyze_btn');
        if (!btn) return;
        btn.disabled = busy;
        btn.textContent = busy ? 'Analyzing…' : 'Analyze condition';
      }
      document.addEventListener('click', function(e) {
        if (e.target && e.target.id === 'analyze_btn') setAnalyzeBusy(true);
      });
      $(function() {
        Shiny.addCustomMessageHandler('analyzeBusy', setAnalyzeBusy);
      });
    "))
  ),
  div(
    class = "hero",
    div(
      h1("Know the condition. Make the call."),
      p("A practical field tool for restaurant owners: upload a photo or describe a concern, then get a clear next step.")
    ),
    div(
      class = "hero-meta",
      strong("The working sequence"),
      "Photo → finding → action\n",
      "Reference: 131 DOHMH codes"
    )
  ),
  sidebarLayout(
    sidebarPanel(
      div(
        class = "sidebar",
        h3("Start with the evidence."),
        div(class = "sidebar-intro", "Use one close, well-lit photo, a written description, or both. Exact temperatures, locations, and timing improve the result."),
        uiOutput("photo_input_ui"),
        div(class = "upload-help", "A photo is optional when you provide a detailed description. This is not an official inspection."),
        uiOutput("photo_preview"),
        textAreaInput("notes", "Describe the condition (optional if photo attached)",
                      placeholder = "e.g. food is uncovered, hand sink has no soap, pests near dry storage, refrigerator reads 55°F...",
                      rows = 4),
        textInput("zip", "Your ZIP code (optional)", ""),
        actionButton("analyze_btn", "Analyze condition", class = "btn-primary")
      )
    ),
    mainPanel(
      uiOutput("results", inline = FALSE)
    )
  )
)

# ---- Server ---------------------------------------------------------------

server <- function(input, output, session) {

  # Shiny's fileInput never clears itself, so the accepted photo lives in a
  # reactiveVal instead of input$photo; remounting the input (upload_nonce)
  # gives the user a fresh picker without a stale server-side value.
  photo_data   <- reactiveVal(NULL)  # list(image_b64, mime_type, name)
  photo_error  <- reactiveVal(NULL)
  upload_nonce <- reactiveVal(0)
  analysis     <- reactiveVal(NULL)

  output$photo_input_ui <- renderUI({
    upload_nonce()
    build_photo_input()
  })

  observeEvent(input$photo, {
    normalized <- normalize_image_upload(input$photo)
    if (isTRUE(normalized$ok) && !is.null(normalized$image_b64)) {
      photo_data(list(
        image_b64 = normalized$image_b64,
        mime_type = normalized$mime_type,
        name = input$photo$name
      ))
      photo_error(NULL)
    } else if (!isTRUE(normalized$ok)) {
      photo_data(NULL)
      photo_error(normalized$message)
      upload_nonce(upload_nonce() + 1)
    }
  })

  observeEvent(input$remove_photo, {
    photo_data(NULL)
    photo_error(NULL)
    upload_nonce(upload_nonce() + 1)
  })

  observeEvent(input$start_over, {
    photo_data(NULL)
    photo_error(NULL)
    analysis(NULL)
    upload_nonce(upload_nonce() + 1)
    updateTextAreaInput(session, "notes", value = "")
    updateTextInput(session, "zip", value = "")
  })

  output$photo_preview <- renderUI({
    if (!is.null(photo_error())) {
      return(div(class = "photo-error", photo_error()))
    }
    pd <- photo_data()
    if (is.null(pd)) return(NULL)
    div(
      class = "photo-preview",
      img(src = paste0("data:", pd$mime_type, ";base64,", pd$image_b64),
          alt = "Photo that will be analyzed"),
      div(
        class = "photo-preview-meta",
        span(pd$name),
        actionLink("remove_photo", "Remove photo")
      )
    )
  })

  observeEvent(input$analyze_btn, {
    on.exit(session$sendCustomMessage("analyzeBusy", FALSE), add = TRUE)

    pd <- photo_data()
    notes <- if (is.null(input$notes)) "" else trimws(input$notes)

    if (is.null(pd) && !nzchar(notes)) {
      analysis(list(kind = "error", heading = "Nothing to analyze yet",
                    message = "Upload a restaurant photo or describe the condition before analyzing."))
      return()
    }
    if (nchar(notes) > 2000) {
      analysis(list(kind = "error", heading = "Description too long",
                    message = "Keep the written description under 2,000 characters."))
      return()
    }

    outcome <- withProgress(message = "Analyzing the condition", value = 0, {
      incProgress(0.15, detail = "Loading DOHMH reference codes")
      codebook_result <- tryCatch(
        load_violation_codebook_cached(),
        error = function(e) list(error = conditionMessage(e))
      )

      if (!is.null(codebook_result$error)) {
        list(kind = "error", heading = "Reference data unavailable",
             message = paste("Could not load the DOHMH reference data:", codebook_result$error))
      } else {
        codebook_df <- codebook_result$data

        incProgress(0.35, detail = "Reviewing...")
        llm_result <- tryCatch(
          call_vision_llm(
            if (is.null(pd)) NULL else pd$image_b64,
            if (is.null(pd)) NULL else pd$mime_type,
            codebook_df,
            user_notes = notes
          ),
          error = function(e) list(violation_code = NULL, reasoning = paste("Analysis failed:", conditionMessage(e)), failed = TRUE)
        )

        if (is.null(llm_result$violation_code)) {
          list(kind = "unmatched", failed = isTRUE(llm_result$failed), llm = llm_result)
        } else {
          incProgress(0.35, detail = "Preparing recommendations")
          critical_flag <- get_critical_flag_safely(llm_result$violation_code)
          code_details <- codebook_df[codebook_df$violation_code == llm_result$violation_code, , drop = FALSE]
          remediation <- get_remediation(llm_result$violation_code, code_details$category[1])

          list(
            kind = "matched",
            llm = llm_result,
            critical_flag = critical_flag,
            remediation = remediation,
            health_code_citation = code_details$health_code_citation[1],
            violation_description = code_details$description[1]
          )
        }
      }
    })
    analysis(outcome)
  })

  output$results <- renderUI({
    r <- analysis()

    if (is.null(r)) {
      return(div(
        class = "results-empty",
        div(class = "result-eyebrow", "Awaiting evidence"),
        h3("No analysis yet."),
        p("Add a photo or a written description on the left, then press Analyze condition.")
      ))
    }

    if (identical(r$kind, "error")) {
      return(div(
        class = "results-empty",
        div(class = "result-eyebrow", "Analysis note"),
        h3(r$heading),
        p(r$message)
      ))
    }

    if (identical(r$kind, "unmatched")) {
      heading <- if (isTRUE(r$failed)) "Analysis unavailable" else "No clear match found"
      detail <- if (isTRUE(r$failed)) {
        paste(r$llm$reasoning, "Check your internet connection and API configuration, then try again.")
      } else {
        r$llm$reasoning %||% "Try a clearer, closer photo of the affected area or add more detail in the notes."
      }
      return(tagList(
        div(
          class = "results-empty",
          div(class = "result-eyebrow", "Analysis note"),
          h3(heading),
          p(detail)
        )
      ))
    }
    
    severity_label <- if (identical(r$critical_flag, "Critical")) {
      span("Critical violation", class = "severity-critical")
    } else if (identical(r$critical_flag, "Not Critical")) {
      span("Non-critical violation", class = "severity-noncritical")
    } else {
      span("Severity unknown", class = "severity-unknown")
    }
    
    location <- if (grepl("^[0-9]{5}$", trimws(input$zip))) trimws(input$zip) else "New York, NY"
    service_type <- r$remediation$service_query %||% "restaurant health code consultant"
    service_query <- utils::URLencode(paste(service_type, location))
    google_maps_url <- paste0("https://www.google.com/maps/search/?api=1&query=", service_query)
    yelp_url <- paste0(
      "https://www.yelp.com/search?find_desc=", utils::URLencode(service_type),
      "&find_loc=", utils::URLencode(location)
    )
    
    tagList(
      div(
        class = "results-card",
        div(class = "result-eyebrow", "Likely match"),
        h3(paste(r$llm$violation_code, "—", r$violation_description)),
        div(
          class = "result-meta",
          p(
            strong("Health code: "),
            a(r$health_code_citation,
              href = "https://www.nyc.gov/assets/doh/downloads/pdf/about/healthcode/health-code-article81.pdf",
              target = "_blank", rel = "noopener",
              title = "Read the official NYC Health Code, Article 81 (Food Preparation and Food Establishments)")
          ),
          p(strong("Typical severity: "), severity_label),
          p(strong("What we saw: "), r$llm$symptoms_observed),
          p(strong("Confidence: "), r$llm$confidence)
        ),
        h5("Try this first"),
        tags$ul(lapply(r$remediation$diy, tags$li)),
        h5("Bring in a professional when"),
        tags$ul(lapply(r$remediation$call_pro_if, tags$li)),
        h5(paste("Find local", service_type)),
        p("Search results are not endorsements. Confirm licensing, availability, and relevant restaurant experience before booking."),
        tags$ul(
          class = "service-links",
          tags$li(a("Google Maps", href = google_maps_url, target = "_blank", rel = "noopener")),
          tags$li(a("Yelp", href = yelp_url, target = "_blank", rel = "noopener"))
        ),
        div(
          class = "start-over-wrap",
          actionLink("start_over", "Start a new analysis")
        )
      )
    )
  })
}

shinyApp(ui, server)
