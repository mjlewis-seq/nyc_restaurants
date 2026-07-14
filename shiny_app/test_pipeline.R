# Run this in the RStudio Console before launching app.R.
#
# Usage: setwd() to the project root first, then:
#   source("test_pipeline.R")

source("helpers.R")

cat("\n== 1. DOHMH reference data ==\n")
codebook_result <- tryCatch(
  load_violation_codebook(),
  error = function(e) {
    cat("FAILED to load the reference data:", conditionMessage(e), "\n")
    NULL
  }
)

if (is.null(codebook_result)) {
  stop("Fix the bundled codebook CSV before continuing.")
}

codebook_df <- codebook_result$data
cat("OK —", nrow(codebook_df), "violation codes loaded from", codebook_result$source, "\n")

cat("\n== 2. Optional database enrichment ==\n")
con <- tryCatch(get_con(), error = function(e) NULL)
if (is.null(con)) {
  cat("SKIPPED — PostgreSQL is unavailable. The app will still analyze conditions using the bundled codebook, but historical severity will show as unknown.\n")
} else {
  on.exit(dbDisconnect(con), add = TRUE)
  test_code <- codebook_df$violation_code[1]
  cat("OK — connected. Code", test_code, "historical severity:", get_critical_flag(con, test_code), "\n")
}

cat("\n== 3. Anthropic model access ==\n")
api_key <- trimws(Sys.getenv("ANTHROPIC_API_KEY"))
if (!nzchar(api_key)) {
  cat("SKIPPED — ANTHROPIC_API_KEY is not set in this R session. Add it to .Renviron and restart R.\n")
} else {
  model <- tryCatch(resolve_anthropic_model(api_key), error = function(e) e)
  if (inherits(model, "error")) {
    cat("FAILED:", conditionMessage(model), "\n")
  } else {
    cat("OK — using model:", model, "\n")
  }
}

cat("\n== 4. Text-only analysis ==\n")
if (!nzchar(api_key)) {
  cat("SKIPPED — API key required.\n")
} else {
  text_result <- tryCatch(
    call_vision_llm(
      codebook_df = codebook_df,
      user_notes = "The hand sink has no soap or paper towels."
    ),
    error = function(e) e
  )
  if (inherits(text_result, "error")) {
    cat("FAILED:", conditionMessage(text_result), "\n")
  } else {
    cat("OK — text-only analysis returned:\n")
    str(text_result)
  }
}

cat("\n== 5. Image analysis ==\n")
test_image_path <- "data/test_fridge.png"
if (!nzchar(api_key)) {
  cat("SKIPPED — API key required.\n")
} else if (!file.exists(test_image_path)) {
  cat("SKIPPED — no test image at", test_image_path, "\n")
} else {
  image_input <- normalize_image_upload(list(
    datapath = test_image_path,
    name = basename(test_image_path),
    type = "image/png"
  ))
  if (!image_input$ok) {
    cat("FAILED:", image_input$message, "\n")
  } else {
    image_result <- tryCatch(
      call_vision_llm(
        image_b64 = image_input$image_b64,
        mime_type = image_input$mime_type,
        codebook_df = codebook_df
      ),
      error = function(e) e
    )
    if (inherits(image_result, "error")) {
      cat("FAILED:", conditionMessage(image_result), "\n")
    } else {
      cat("OK — image analysis returned:\n")
      str(image_result)
    }
  }
}

cat("\n== Done ==\n")
