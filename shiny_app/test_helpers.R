source("helpers.R")

allowed_codes <- c("02G", "04J")
result <- parse_llm_result(
  '```json\n{"violation_code":"02g","symptoms_observed":"Food is warm","confidence":"high","reasoning":"Display reads 55F"}\n```',
  allowed_codes
)
stopifnot(result$violation_code == "02G")
stopifnot(is.character(anthropic_model()))

invalid_code_error <- tryCatch({
  parse_llm_result('{"violation_code":"99Z","symptoms_observed":"Food is warm","confidence":"medium","reasoning":"Display reads 55F"}', allowed_codes)
  FALSE
}, error = function(e) grepl("outside the supplied DOHMH codebook", conditionMessage(e)))
stopifnot(invalid_code_error)

null_result <- parse_llm_result(
  '{"violation_code":null,"symptoms_observed":"No visible issue","confidence":"low","reasoning":"The condition cannot be determined from the provided information."}',
  allowed_codes
)
stopifnot(is.null(null_result$violation_code))

invalid_confidence_error <- tryCatch({
  parse_llm_result('{"violation_code":"02G","symptoms_observed":"Food is warm","confidence":"certain","reasoning":"Display reads 55F"}', allowed_codes)
  FALSE
}, error = function(e) grepl("invalid confidence", conditionMessage(e)))
stopifnot(invalid_confidence_error)

pest_remediation <- get_remediation("04K", "PEST CONTROL")
stopifnot(identical(pest_remediation$service_query, "commercial pest control"))

food_worker_remediation <- get_remediation("99Z", "FOOD WORKERS")
stopifnot(identical(food_worker_remediation$service_query, "food safety training"))

local_codebook <- load_local_codebook()
stopifnot(nrow(local_codebook) >= 100)
stopifnot(all(c("violation_code", "health_code_citation", "description", "category") %in% names(local_codebook)))

test_image_path <- tempfile(fileext = ".jpg")
writeBin(as.raw(rep(1, 32)), test_image_path)
image_input <- normalize_image_upload(list(
  datapath = test_image_path,
  name = "test.jpg",
  type = ""
))
stopifnot(image_input$ok, identical(image_input$mime_type, "image/jpeg"))

unsupported_image <- normalize_image_upload(list(
  datapath = test_image_path,
  name = "test.heic",
  type = "image/heic"
))
stopifnot(!unsupported_image$ok)
stopifnot(identical(
  clean_error_message("\033[38;5;232mHTTP 404 Not Found.\033[39m"),
  "HTTP 404 Not Found."
))

cat("Helper tests passed.\n")
