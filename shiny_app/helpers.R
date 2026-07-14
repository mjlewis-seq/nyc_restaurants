# Shared helper functions for the restaurant health-code diagnoser: DB access,
# remediation lookup, and the vision LLM call. Kept separate from app.R so
# these can be tested in isolation without launching the Shiny app.

library(httr2)
library(base64enc)
library(DBI)
library(RPostgres)
library(jsonlite)

# ---- DB helpers -------------------------------------------------------

get_con <- function() {
  dbConnect(
    RPostgres::Postgres(),
    dbname   = Sys.getenv("PGDATABASE", "dohmh_hackathon"),
    host     = Sys.getenv("PGHOST", "localhost"),
    port     = as.integer(Sys.getenv("PGPORT", "5433")),
    user     = Sys.getenv("PGUSER", "postgres"),
    password = Sys.getenv("PGPASSWORD", "")
  )
}

get_violation_codebook <- function(con) {
  dbGetQuery(con, "
    SELECT violation_code, health_code_citation, description, category
    FROM violation_health_code_mapping
    ORDER BY violation_code
  ")
}

load_local_codebook <- function(path = "data/Violation-Health-Code-Mapping.csv") {
  if (!file.exists(path)) {
    stop("Local codebook file is missing: ", path)
  }

  raw_codebook <- suppressWarnings(read.csv(
    path,
    check.names = FALSE,
    stringsAsFactors = FALSE,
    na.strings = c("", "NA")
  ))
  code_column <- grep("Violation_Code$", names(raw_codebook), value = TRUE)[1]
  required_columns <- c(
    code_column,
    "Health_Code",
    "Violation_Summary",
    "Category_Description"
  )

  if (any(is.na(required_columns)) || !all(required_columns %in% names(raw_codebook))) {
    stop("Local codebook has an unexpected column layout.")
  }

  codebook <- data.frame(
    violation_code = toupper(trimws(raw_codebook[[code_column]])),
    health_code_citation = trimws(raw_codebook$Health_Code),
    description = trimws(raw_codebook$Violation_Summary),
    category = trimws(raw_codebook$Category_Description),
    stringsAsFactors = FALSE
  )
  codebook <- codebook[
    nzchar(codebook$violation_code) & nzchar(codebook$description),
    ,
    drop = FALSE
  ]
  codebook <- codebook[!duplicated(codebook$violation_code), , drop = FALSE]

  if (nrow(codebook) < 100) {
    stop("Local codebook appears incomplete; expected at least 100 violation codes.")
  }
  codebook
}

load_violation_codebook <- function() {
  database_codebook <- tryCatch({
    con <- get_con()
    on.exit(dbDisconnect(con), add = TRUE)
    codebook <- get_violation_codebook(con)
    if (nrow(codebook) < 100) stop("Database codebook appears incomplete.")
    codebook
  }, error = function(e) NULL)

  if (!is.null(database_codebook)) {
    return(list(data = database_codebook, source = "PostgreSQL database"))
  }

  list(data = load_local_codebook(), source = "bundled DOHMH reference CSV")
}

# ---- Session caches ----------------------------------------------------
# The codebook and the resolved model id are stable for the lifetime of the
# R process. Caching them avoids a DB/CSV load plus an extra Anthropic API
# round trip on every analysis click. Only successes are cached, so a
# transient failure is retried on the next attempt.

.helpers_cache <- new.env(parent = emptyenv())

load_violation_codebook_cached <- function() {
  if (is.null(.helpers_cache$codebook)) {
    .helpers_cache$codebook <- load_violation_codebook()
  }
  .helpers_cache$codebook
}

get_critical_flag <- function(con, code) {
  res <- dbGetQuery(con, "
    SELECT CASE
      WHEN bool_or(critical_flag = 'Critical') THEN 'Critical'
      WHEN bool_or(critical_flag = 'Not Critical') THEN 'Not Critical'
      ELSE NULL
    END AS critical_flag
    FROM inspections
    WHERE violation_code = $1
  ", params = list(code))
  if (nrow(res) == 0) NA_character_ else res$critical_flag[1]
}

get_critical_flag_safely <- function(code) {
  tryCatch({
    con <- get_con()
    on.exit(dbDisconnect(con), add = TRUE)
    get_critical_flag(con, code)
  }, error = function(e) NA_character_)
}

normalize_image_upload <- function(file_input, max_bytes = 5 * 1024^2) {
  if (is.null(file_input)) return(list(ok = TRUE, image_b64 = NULL, mime_type = NULL))

  supported_types <- c("image/jpeg", "image/png", "image/gif", "image/webp")
  extension_to_mime <- c(jpg = "image/jpeg", jpeg = "image/jpeg", png = "image/png", gif = "image/gif", webp = "image/webp")
  file_size <- file.info(file_input$datapath)$size
  extension <- tolower(tools::file_ext(file_input$name))
  mime_type <- if (is.null(file_input$type) || is.na(file_input$type)) "" else trimws(file_input$type)
  if (!nzchar(mime_type) && extension %in% names(extension_to_mime)) {
    mime_type <- extension_to_mime[[extension]]
  }

  if (is.na(file_size) || file_size <= 0) {
    return(list(ok = FALSE, message = "The uploaded file could not be read. Please try another image."))
  }
  if (file_size > max_bytes) {
    return(list(ok = FALSE, message = "Image is larger than 5 MB. Please upload a smaller JPG, PNG, GIF, or WebP image."))
  }
  if (!mime_type %in% supported_types) {
    return(list(ok = FALSE, message = "Unsupported image format. Please use JPG, PNG, GIF, or WebP (not HEIC)."))
  }

  list(ok = TRUE, image_b64 = base64encode(file_input$datapath), mime_type = mime_type)
}

# ---- NYC Health Code knowledge base (RAG) ------------------------------
# Loads the portable KB bundle exported from the team's RAGFlow instance
# (see rag/export in the nyc_restaurants repo): 2,866 health-code chunks
# with pre-normalized Voyage embeddings, converted once to data/kb/kb.rds.
# Retrieval = embed the query with Voyage AI, then a plain dot product.
# Requires VOYAGE_API_KEY in .Renviron; callers should treat a NULL/error
# result as "no excerpts available" and render nothing.

load_health_code_kb_cached <- function(path = "data/kb/kb.rds") {
  if (is.null(.helpers_cache$kb_checked)) {
    .helpers_cache$kb <- if (file.exists(path)) {
      tryCatch(readRDS(path), error = function(e) NULL)
    } else NULL
    .helpers_cache$kb_checked <- TRUE
  }
  .helpers_cache$kb
}

embed_query_voyage <- function(text) {
  api_key <- trimws(Sys.getenv("VOYAGE_API_KEY"))
  if (!nzchar(api_key)) {
    stop("VOYAGE_API_KEY is not configured. Add it to .Renviron and restart R.")
  }

  # Cache embeddings per query text: repeat analyses of the same violation
  # produce identical queries, and the free Voyage tier allows only 3
  # requests/minute — cached queries cost nothing.
  if (is.null(.helpers_cache$query_embeddings)) {
    .helpers_cache$query_embeddings <- new.env(parent = emptyenv())
  }
  cached <- .helpers_cache$query_embeddings[[text]]
  if (!is.null(cached)) return(cached)

  req <- request("https://api.voyageai.com/v1/embeddings") |>
    req_headers(
      "Authorization" = paste("Bearer", api_key),
      "content-type"  = "application/json"
    ) |>
    req_body_json(list(
      model      = "voyage-4",  # query-time model per the KB bundle README
      input      = list(text),
      input_type = "query"
    ))

  resp <- perform_anthropic_request(req, "Could not reach Voyage AI to embed the query")
  if (resp_status(resp) >= 300) {
    stop("Voyage AI request failed (HTTP ", resp_status(resp), "): ",
         clean_error_message(resp_body_string(resp)))
  }
  embedding <- as.numeric(unlist(resp_body_json(resp)$data[[1]]$embedding))
  .helpers_cache$query_embeddings[[text]] <- embedding
  embedding
}

retrieve_health_code_chunks <- function(query, k = 3, min_score = 0.45, min_chars = 80) {
  kb <- load_health_code_kb_cached()
  if (is.null(kb) || is.null(query) || !nzchar(trimws(query))) return(NULL)

  query_vector <- embed_query_voyage(trimws(query))
  if (length(query_vector) != ncol(kb$vectors)) {
    stop("Query embedding dimension does not match the knowledge base.")
  }

  # Voyage vectors are pre-normalized, so dot product == cosine similarity.
  scores <- as.vector(kb$vectors %*% query_vector)
  ranked <- order(scores, decreasing = TRUE)

  picked <- integer(0)
  for (i in ranked) {
    if (scores[i] < min_score) break
    content <- trimws(kb$chunks$content[i])
    # Skip heading-only fragments ("s15.01 Definition.") that carry no text.
    if (nchar(content) < min_chars) next
    # Skip penalty-schedule table debris (rows of "$200 $200 $200..." from
    # chopped PDF tables) — mangled text that reads poorly as an excerpt.
    if (lengths(regmatches(content, gregexpr("\\$", content))) >= 2) next
    picked <- c(picked, i)
    if (length(picked) >= k) break
  }
  if (length(picked) == 0) return(NULL)

  data.frame(
    doc     = kb$chunks$doc[picked],
    content = trimws(kb$chunks$content[picked]),
    score   = scores[picked],
    stringsAsFactors = FALSE
  )
}

# "pdf/health-code-article81.pdf" -> "NYC Health Code, Article 81"
# "health-code-chapter23.pdf"     -> "NYC Health Code, Chapter 23"
format_kb_source <- function(doc) {
  match <- regmatches(doc, regexpr("(article|chapter)[0-9]+[a-zA-Z]*", doc, ignore.case = TRUE))
  if (length(match) == 1 && nzchar(match)) {
    kind <- if (grepl("^article", match, ignore.case = TRUE)) "Article" else "Chapter"
    number <- toupper(sub("^(article|chapter)", "", match, ignore.case = TRUE))
    paste0("NYC Health Code, ", kind, " ", number)
  } else {
    basename(doc)
  }
}

# ---- Remediation knowledge base (hand-curated, scope to a few codes) --
# Fill in real codes/descriptions once you've loaded the codebook table
# and confirmed exact codes for your target scenarios.

remediation_kb <- list(
  "02G" = list(
    diy = c(
      "Measure the warmest food with a calibrated probe thermometer; cold potentially hazardous food must be held at or below 41°F",
      "Move food to another verified cold unit or use ice while you investigate; label and discard food when time/temperature safety cannot be verified",
      "Check that doors close fully, vents are clear, and the condenser area is not blocked by dust or boxes"
    ),
    call_pro_if = c(
      "The unit cannot hold 41°F or below after the basic checks",
      "The compressor runs constantly, does not run, or there is ice buildup or a refrigerant leak",
      "Food may have been above safe temperatures long enough that its safety is uncertain"
    ),
    service_query = "commercial refrigeration repair"
  ),
  "02H" = list(
    diy = c(
      "Divide cooked food into shallow pans, use an ice bath, and leave space around containers for airflow",
      "Track cooling with a calibrated probe thermometer: 140°F to 70°F within 2 hours, then to 41°F or below within 4 more hours",
      "Discard food that cannot meet the required cooling time and temperature limits"
    ),
    call_pro_if = c(
      "The refrigerator cannot maintain 41°F or below",
      "Cooling is slow even when food is portioned correctly and airflow is unobstructed"
    ),
    service_query = "commercial refrigeration repair"
  ),
  "04J" = list(
    diy = c(
      "Use a calibrated probe thermometer to check food temperatures",
      "Keep an accurate thermometer or temperature-monitoring device in each cold unit",
      "Replace cracked, inaccurate, or unreadable thermometers"
    ),
    call_pro_if = c(
      "The unit display and an accurate probe thermometer disagree",
      "A technician is needed to calibrate or repair the unit's temperature controls"
    ),
    service_query = "commercial kitchen equipment repair"
  ),
  "05F" = list(
    diy = c(
      "Move potentially hazardous food to a working, verified cold-holding unit",
      "Avoid overfilling units and keep vents clear so cold air can circulate",
      "Use an accurate thermometer to verify each unit is holding the required temperature"
    ),
    call_pro_if = c(
      "There is no functioning equipment capable of safely cold-holding the food",
      "The repair requires electrical, compressor, or sealed-system work"
    ),
    service_query = "commercial refrigeration repair"
  ),
  "DEFAULT" = list(
    diy = c(
      "Document the condition, remove affected food or equipment from use when safety is uncertain, and correct the visible issue",
      "Clean and sanitize affected food-contact surfaces before returning them to service",
      "Review the applicable DOHMH requirement with the person in charge and record the corrective action"
    ),
    call_pro_if = c(
      "The issue involves food safety, plumbing, electrical work, pests, or equipment repair beyond routine cleaning",
      "The condition cannot be corrected immediately or keeps returning"
    ),
    service_query = "restaurant health code consultant"
  )
)

category_remediation_kb <- list(
  "COLD HOLDING" = list(
    diy = c("Verify food temperatures with a calibrated probe and move food to safe cold holding", "Discard food when its time out of temperature cannot be verified", "Keep doors closed and vents clear while correcting the issue"),
    call_pro_if = c("The unit cannot maintain the required temperature", "A compressor, thermostat, electrical, or sealed-system repair is needed"),
    service_query = "commercial refrigeration repair"
  ),
  "HOT HOLDING" = list(
    diy = c("Measure food with a calibrated probe thermometer", "Reheat, rapidly cool, or discard food according to your food-safety procedures", "Keep hot-holding equipment covered and at the required temperature"),
    call_pro_if = c("The hot-holding unit cannot maintain a safe temperature", "Controls, heating elements, or electrical systems need repair"),
    service_query = "commercial kitchen equipment repair"
  ),
  "COOLING & REFRIGERATION" = list(
    diy = c("Use shallow pans, ice baths, and airflow to cool food safely", "Track cooling temperatures and times with a calibrated probe", "Discard food that cannot meet the required cooling limits"),
    call_pro_if = c("Cold-holding equipment cannot maintain safe temperatures", "A refrigeration or equipment repair is required"),
    service_query = "commercial refrigeration repair"
  ),
  "REHEATING & HOT HOLDING" = list(
    diy = c("Use a calibrated probe thermometer to verify reheating and holding temperatures", "Reheat food using an approved method before placing it in hot holding", "Discard food when its safety cannot be verified"),
    call_pro_if = c("Heating or hot-holding equipment is not operating correctly", "An equipment repair is required"),
    service_query = "commercial kitchen equipment repair"
  ),
  "COOKING" = list(
    diy = c("Verify internal temperatures with a calibrated probe thermometer", "Continue cooking or discard food that does not meet the required minimum temperature", "Keep thermometer calibration and cooking logs current"),
    call_pro_if = c("Cooking equipment cannot reach or hold safe temperatures", "A qualified equipment technician is needed"),
    service_query = "commercial kitchen equipment repair"
  ),
  "PEST CONTROL" = list(
    diy = c("Protect or discard exposed food and clean evidence of pest activity", "Seal food, remove standing water, and remove clutter that can harbor pests", "Document sightings and cleaning actions"),
    call_pro_if = c("Live pests, recurring evidence, or entry points are present", "A licensed pest-control professional is needed"),
    service_query = "commercial pest control"
  ),
  "PLUMBING" = list(
    diy = c("Stop using affected sinks, drains, or water sources when sewage or contamination is present", "Protect food and sanitize contaminated areas", "Post handwashing alternatives only when approved by your operating procedures"),
    call_pro_if = c("There is a leak, sewage backup, no hot water, or unsafe water supply", "A licensed commercial plumber is needed"),
    service_query = "commercial plumbing services"
  ),
  "HANDWASH/TOILET" = list(
    diy = c("Restore soap, paper towels, hot and cold water, and clear handwashing access", "Instruct food workers to wash hands at required times", "Keep restrooms and hand sinks clean and unobstructed"),
    call_pro_if = c("A sink, drain, water supply, or restroom fixture needs repair", "Handwashing access cannot be restored immediately"),
    service_query = "commercial plumbing services"
  ),
  "WAREWASHING" = list(
    diy = c("Stop using improperly washed or sanitized utensils", "Wash, rinse, sanitize, and air-dry equipment using verified concentrations and temperatures", "Check sanitizer test strips and warewashing logs"),
    call_pro_if = c("The dish machine, sanitizer dispenser, or plumbing is not functioning", "A commercial warewashing technician is needed"),
    service_query = "commercial dishwashing equipment repair"
  ),
  "EQUIPMENT" = list(
    diy = c("Remove unsafe or damaged equipment from food service", "Clean and sanitize surrounding areas and food-contact surfaces", "Use approved equipment and maintain it according to manufacturer guidance"),
    call_pro_if = c("Repair involves electrical, mechanical, or refrigeration work", "Replacement equipment is needed to operate safely"),
    service_query = "commercial kitchen equipment repair"
  ),
  "TEMPERATURE REGULATING" = list(
    diy = c("Verify temperatures with a calibrated probe thermometer", "Replace inaccurate or missing thermometers", "Keep temperature records for each affected unit"),
    call_pro_if = c("The unit cannot maintain safe temperatures", "Controls, sensors, or refrigeration components need service"),
    service_query = "commercial refrigeration repair"
  ),
  "FOOD PROTECTION" = list(
    diy = c("Protect food from contamination and store it covered and off the floor", "Separate raw and ready-to-eat foods", "Clean and sanitize affected food-contact surfaces"),
    call_pro_if = c("The issue requires equipment, facility, or pest remediation", "Food safety cannot be restored immediately"),
    service_query = "restaurant cleaning and sanitation services"
  ),
  "CONTAMINATION" = list(
    diy = c("Discard contaminated food and clean and sanitize affected surfaces", "Separate raw and ready-to-eat foods", "Correct the source of contamination before resuming food preparation"),
    call_pro_if = c("Contamination is caused by plumbing, pests, or structural damage", "The source cannot be corrected immediately"),
    service_query = "restaurant cleaning and sanitation services"
  ),
  "ADULTERATED" = list(
    diy = c("Remove adulterated or contaminated food from service", "Clean and sanitize affected areas and equipment", "Identify and correct the source before restocking food"),
    call_pro_if = c("The source is pests, sewage, a chemical hazard, or equipment failure", "A specialist is needed to correct the cause"),
    service_query = "restaurant cleaning and sanitation services"
  ),
  "FACILITY" = list(
    diy = c("Clean the affected area and remove unnecessary clutter", "Repair minor damage that can be safely corrected in-house", "Keep food, equipment, and exits protected and accessible"),
    call_pro_if = c("Structural, electrical, ventilation, or major maintenance work is needed", "The condition creates an immediate safety risk"),
    service_query = "commercial restaurant maintenance"
  ),
  "MAINTENANCE" = list(
    diy = c("Clean and maintain affected surfaces and equipment", "Remove damaged items from food service until repaired", "Document the corrective action and preventive maintenance"),
    call_pro_if = c("The repair requires a licensed trade or replacement equipment", "The condition affects food safety or employee safety"),
    service_query = "commercial restaurant maintenance"
  ),
  "FOOD WORKERS" = list(
    diy = c("Stop unsafe food-handling practices immediately", "Review illness reporting, glove use, and hygiene procedures with staff", "Document retraining and supervisory follow-up"),
    call_pro_if = c("A food safety manager or compliance specialist is needed for retraining", "The issue cannot be corrected through immediate supervision"),
    service_query = "food safety training"
  ),
  "LABELING" = list(
    diy = c("Correct labels, dates, and required consumer information", "Verify allergens and ingredients before food is served", "Review labels during receiving and preparation"),
    call_pro_if = c("A compliance or food-safety specialist is needed to review a recurring labeling issue", "The issue involves product recalls or supplier documentation"),
    service_query = "food safety consultant"
  )
)

get_remediation <- function(code, category = NULL) {
  if (!is.null(remediation_kb[[code]])) return(remediation_kb[[code]])
  if (!is.null(category) && !is.null(category_remediation_kb[[category]])) {
    return(category_remediation_kb[[category]])
  }
  remediation_kb[["DEFAULT"]]
}

# ---- Vision LLM call ---------------------------------------------------

anthropic_model <- function() {
  trimws(Sys.getenv("ANTHROPIC_MODEL"))
}

clean_error_message <- function(message, max_characters = 500) {
  cleaned <- gsub("\033\\[[0-9;]*m", "", as.character(message))
  cleaned <- gsub("[[:space:]]+", " ", trimws(cleaned))
  substr(cleaned, 1, max_characters)
}

anthropic_error_message <- function(resp) {
  raw_body <- resp_body_string(resp)
  parsed_body <- tryCatch(fromJSON(raw_body), error = function(e) NULL)
  api_message <- tryCatch(parsed_body$error$message, error = function(e) NULL)
  clean_error_message(if (is.character(api_message) && nzchar(api_message)) api_message else raw_body)
}

perform_anthropic_request <- function(req, context) {
  tryCatch(
    req |>
      req_error(is_error = function(resp) FALSE) |>
      req_perform(),
    error = function(e) stop(context, ": ", clean_error_message(conditionMessage(e)))
  )
}

available_anthropic_models <- function(api_key) {
  req <- request("https://api.anthropic.com/v1/models") |>
    req_headers(
      "x-api-key" = api_key,
      "anthropic-version" = "2023-06-01"
    )
  resp <- perform_anthropic_request(req, "Could not contact Anthropic to select a model")

  if (resp_status(resp) >= 300) {
    stop("Could not list Anthropic models (HTTP ", resp_status(resp), "): ",
         anthropic_error_message(resp))
  }

  model_data <- tryCatch(resp_body_json(resp)$data, error = function(e) NULL)
  if (is.null(model_data) || length(model_data) == 0) {
    stop("Anthropic returned no available models for this API key.")
  }
  vapply(model_data, function(model) model$id, character(1))
}

resolve_anthropic_model <- function(api_key) {
  configured_model <- anthropic_model()
  if (nzchar(configured_model)) return(configured_model)

  model_ids <- available_anthropic_models(api_key)
  sonnet_models <- model_ids[grepl("sonnet", model_ids, ignore.case = TRUE)]
  if (length(sonnet_models) > 0) return(sonnet_models[1])
  if (length(model_ids) > 0) return(model_ids[1])

  stop("No Anthropic models are available for this API key.")
}

resolve_anthropic_model_cached <- function(api_key) {
  configured_model <- anthropic_model()
  if (nzchar(configured_model)) return(configured_model)
  if (is.null(.helpers_cache$model)) {
    .helpers_cache$model <- resolve_anthropic_model(api_key)
  }
  .helpers_cache$model
}

parse_llm_result <- function(raw_text, allowed_codes) {
  cleaned <- gsub("^```(json)?\\s*|\\s*```\\s*$", "", trimws(raw_text))
  parsed <- tryCatch(
    fromJSON(cleaned),
    error = function(e) stop(
      "Failed to parse model output as JSON: ", conditionMessage(e),
      "\nRaw text was: ", substr(cleaned, 1, 800)
    )
  )

  required_fields <- c("symptoms_observed", "confidence", "reasoning")
  if (!is.list(parsed) || !all(required_fields %in% names(parsed))) {
    stop("Model response is missing one or more required fields.")
  }
  for (field in required_fields) {
    field_value <- parsed[[field]]
    if (!is.character(field_value) || length(field_value) != 1 || !nzchar(trimws(field_value))) {
      stop("Model response contains an invalid ", field, " field.")
    }
    parsed[[field]] <- trimws(field_value)
  }

  parsed$confidence <- tolower(parsed$confidence)
  if (!parsed$confidence %in% c("high", "medium", "low")) {
    stop("Model response contains an invalid confidence value.")
  }

  if (is.null(parsed$violation_code)) return(parsed)

  parsed$violation_code <- toupper(trimws(as.character(parsed$violation_code)))
  if (!parsed$violation_code %in% allowed_codes) {
    stop("Model returned a code outside the supplied DOHMH codebook: ", parsed$violation_code)
  }
  parsed
}

call_vision_llm <- function(image_b64 = NULL, mime_type = NULL, codebook_df, user_notes = NULL) {
  api_key <- trimws(Sys.getenv("ANTHROPIC_API_KEY"))
  if (!nzchar(api_key)) {
    stop("ANTHROPIC_API_KEY is not configured. Add it to .Renviron and restart R.")
  }

  if (is.null(image_b64) && (is.null(user_notes) || !nzchar(trimws(user_notes)))) {
    stop("Provide a restaurant photo or a written description of the condition.")
  }

  if (!is.null(image_b64) && (is.null(mime_type) || !nzchar(mime_type))) {
    stop("The uploaded image is missing a MIME type. Please upload a PNG or JPEG photo.")
  }
  
  codebook_text <- paste(
    sprintf("- %s: %s", codebook_df$violation_code, codebook_df$description),
    collapse = "\n"
  )
  
  notes_section <- if (!is.null(user_notes) && nzchar(trimws(user_notes))) {
    paste0("\nThe restaurant owner also described the problem in their own words: \"",
           trimws(user_notes), "\"\n")
  } else ""
  
  system_prompt <- paste0(
    "You are helping a restaurant owner identify a possible restaurant health-code violation ",
    "from a photo, an owner description, or both, for informational purposes only (not an official inspection). ",
    "Only choose a violation_code from this real NYC DOHMH list — never invent one:\n",
    codebook_text,
    notes_section,
    "\n\nRespond with ONLY valid JSON, no other text, no markdown code fences, ",
    "in this exact shape:\n",
    '{"violation_code": "...", "symptoms_observed": "...", ',
    '"confidence": "high|medium|low", "reasoning": "..."}\n',
    "When only text is provided, describe it as owner-reported rather than visually observed. ",
    "If nothing in the photo matches any code above, set violation_code to null."
  )

  request_text <- if (!is.null(user_notes) && nzchar(trimws(user_notes))) {
    paste("Analyze this restaurant condition. Owner description:", trimws(user_notes))
  } else {
    "Analyze this restaurant photo for a possible health-code violation."
  }

  user_content <- list(list(type = "text", text = request_text))
  if (!is.null(image_b64)) {
    user_content <- c(
      list(list(type = "image", source = list(type = "base64", media_type = mime_type, data = image_b64))),
      user_content
    )
  }
  
  req <- request("https://api.anthropic.com/v1/messages") |>
    req_headers(
      "x-api-key"         = api_key,
      "anthropic-version" = "2023-06-01",
      "content-type"      = "application/json"
    ) |>
    req_body_json(list(
      model      = resolve_anthropic_model_cached(api_key),
      max_tokens = 500,
      system     = system_prompt,
      messages   = list(list(
        role = "user",
        content = user_content
      ))
    ))
  
  resp <- perform_anthropic_request(req, "Could not send the analysis request to Anthropic")
  if (resp_status(resp) >= 300) {
    stop("Anthropic API request failed (HTTP ", resp_status(resp), "): ",
         anthropic_error_message(resp))
  }
  body <- resp_body_json(resp)
  
  # Defensively extract the text block instead of assuming content[[1]]$text
  # always exists in that shape — surfaces the real response if it doesn't,
  # instead of a cryptic "is.character(txt) is not TRUE" error.
  raw_text <- tryCatch(body$content[[1]]$text, error = function(e) NULL)
  if (is.null(raw_text) || !is.character(raw_text)) {
    stop("Unexpected API response shape (no text content found). Raw response: ",
         substr(jsonlite::toJSON(body, auto_unbox = TRUE), 1, 800))
  }
  
  parse_llm_result(raw_text, codebook_df$violation_code)
}
