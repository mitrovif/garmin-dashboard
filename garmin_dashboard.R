# =============================================================================
# garmin_dashboard.R
# Pull & display your Garmin Connect data in R
#
# Two modes:
#   1. LIVE  - scrapes Garmin Connect via httr2 (no API approval needed)
#   2. CSV   - reads an exported CSV from Garmin Connect (always works)
#
# Dependencies:
#   install.packages(c("httr2", "jsonlite", "dplyr", "ggplot2",
#                      "lubridate", "readr", "scales", "patchwork",
#                      "keyring", "glue"))
# =============================================================================

library(httr2)
library(jsonlite)
library(dplyr)
library(ggplot2)
library(lubridate)
library(readr)
library(scales)
library(patchwork)
library(glue)
library(keyring)

# ── Optional: store credentials securely with keyring ──────────────────────
# Run once to save:
#   keyring::key_set("garmin", username = "your@email.com")
# Then the script reads them without hardcoding passwords.
# ── OR just paste credentials directly (less secure) ────────────────────────

MODE <- "live"   # "live" or "csv"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — CREDENTIALS & CONFIG
# ─────────────────────────────────────────────────────────────────────────────

GARMIN_EMAIL    <- keyring::key_list("garmin")$username  # or: "your@email.com"
GARMIN_PASSWORD <- keyring::key_get("garmin", GARMIN_EMAIL) # or: "yourpassword"

CSV_PATH    <- "~/Downloads/Activities.csv"  # path to Garmin CSV export
DAYS_BACK   <- 30                            # how many days to pull
ACTIVITY_TYPES <- c("running", "cycling", "strength_training",
                    "indoor_rowing", "indoor_cycling", "hiking")


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — GARMIN CONNECT LOGIN (LIVE MODE)
# ─────────────────────────────────────────────────────────────────────────────

garmin_login <- function(email, password) {
  message("Logging in to Garmin Connect...")

  sso_base  <- "https://sso.garmin.com/sso"
  login_url <- glue("{sso_base}/signin?service=https://connect.garmin.com/modern/")

  # Step 1: get CSRF token from sign-in page
  resp_get <- request(login_url) |>
    req_headers(
      "User-Agent" = "Mozilla/5.0 (compatible; R/garmin-tool)",
      "Accept"     = "text/html"
    ) |>
    req_perform()

  csrf <- resp_get |>
    resp_body_string() |>
    regmatches(regexpr('name="_csrf"\\s+value="([^"]+)"', x = _)) |>
    regmatches(regexpr('"([^"]+)"$', x = _)) |>
    gsub('"', '', x = _)

  cookies_init <- resp_get |> resp_headers("set-cookie")

  # Step 2: POST credentials
  resp_post <- request(glue("{sso_base}/login")) |>
    req_headers(
      "User-Agent"   = "Mozilla/5.0 (compatible; R/garmin-tool)",
      "Content-Type" = "application/x-www-form-urlencoded",
      "Referer"      = login_url
    ) |>
    req_body_form(
      username = email,
      password = password,
      embed    = "false",
      `_csrf`  = csrf
    ) |>
    req_perform()

  if (resp_status(resp_post) != 200) {
    stop("Login failed - check credentials.")
  }

  message("Login successful.")

  # Return a session object (httr2 handles cookies automatically via req_perform)
  list(
    base_url = "https://connectapi.garmin.com",
    logged_in = TRUE
  )
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — FETCH ACTIVITIES (LIVE MODE)
# ─────────────────────────────────────────────────────────────────────────────

fetch_activities <- function(session, days = 30, limit = 100) {
  message(glue("Fetching last {days} days of activities..."))

  start_date <- format(Sys.Date() - days, "%Y-%m-%d")
  end_date   <- format(Sys.Date(), "%Y-%m-%d")

  url <- glue(
    "https://connect.garmin.com/activitylist-service/activities/search/activities",
    "?startDate={start_date}&endDate={end_date}&limit={limit}&start=0"
  )

  resp <- request(url) |>
    req_headers(
      "NK"          = "NT",
      "Accept"      = "application/json",
      "User-Agent"  = "Mozilla/5.0 (compatible; R/garmin-tool)",
      "X-app-ver"   = "4.65.2.0",
      "DI-Backend"  = "connectapi.garmin.com"
    ) |>
    req_perform()

  if (resp_status(resp) != 200) {
    stop(glue("Failed to fetch activities: HTTP {resp_status(resp)}"))
  }

  raw <- resp |> resp_body_json(simplifyVector = TRUE)

  if (length(raw) == 0) {
    message("No activities found in this date range.")
    return(tibble())
  }

  # Parse into tidy tibble
  activities <- raw |>
    as_tibble() |>
    transmute(
      activity_id   = as.character(activityId),
      name          = activityName,
      type          = activityType$typeKey,
      date          = as_date(startTimeLocal),
      datetime      = ymd_hms(startTimeLocal),
      duration_min  = round(duration / 60, 1),
      distance_km   = round(coalesce(distance, 0) / 1000, 2),
      avg_hr        = averageHR,
      max_hr        = maxHR,
      calories      = calories,
      avg_pace_minkm = ifelse(
        !is.na(averageSpeed) & averageSpeed > 0,
        round(1000 / averageSpeed / 60, 2),
        NA_real_
      ),
      training_load  = coalesce(activityTrainingLoad, NA_real_),
      aerobic_te     = coalesce(aerobicTrainingEffect, NA_real_),
      anaerobic_te   = coalesce(anaerobicTrainingEffect, NA_real_),
      vo2max         = coalesce(vO2MaxValue, NA_real_),
      steps          = coalesce(steps, NA_integer_),
      avg_cadence    = coalesce(averageRunningCadenceInStepsPerMinute, NA_real_)
    ) |>
    arrange(desc(date))

  message(glue("Found {nrow(activities)} activities."))
  activities
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — READ FROM CSV (CSV MODE)
# Garmin Connect > Activities > Export CSV
# ─────────────────────────────────────────────────────────────────────────────

read_garmin_csv <- function(path) {
  message(glue("Reading Garmin CSV from: {path}"))

  raw <- read_csv(path, show_col_types = FALSE, name_repair = "minimal")

  # Garmin CSV columns vary by locale - handle common names
  activities <- raw |>
    rename_with(tolower) |>
    rename_with(~ gsub("[^a-z0-9_]", "_", .x)) |>
    mutate(
      date         = mdy(coalesce(date, `activity_date`)),
      type         = coalesce(activity_type, type),
      name         = coalesce(activity_name, title, name),
      duration_min = {
        d <- coalesce(time, elapsed_time, duration)
        # handle "h:mm:ss" or numeric seconds
        ifelse(
          grepl(":", d),
          sapply(d, function(x) {
            parts <- as.numeric(strsplit(x, ":")[[1]])
            if (length(parts) == 3) parts[1]*60 + parts[2] + parts[3]/60
            else parts[1] + parts[2]/60
          }),
          as.numeric(d) / 60
        )
      },
      distance_km  = round(as.numeric(coalesce(distance, `distance__km_`)), 2),
      avg_hr       = as.numeric(coalesce(avg_hr, `avg_heart_rate__bpm_`)),
      max_hr       = as.numeric(coalesce(max_hr, `max_heart_rate__bpm_`)),
      calories     = as.numeric(coalesce(calories, `total_calories`)),
      avg_pace_minkm = as.numeric(coalesce(avg_pace, `avg_pace__min_km_`))
    ) |>
    select(date, type, name, duration_min, distance_km,
           avg_hr, max_hr, calories, avg_pace_minkm) |>
    filter(!is.na(date)) |>
    arrange(desc(date))

  message(glue("Loaded {nrow(activities)} activities from CSV."))
  activities
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — DISPLAY: CLEAN DASHBOARD PLOTS
# ─────────────────────────────────────────────────────────────────────────────

athx_theme <- function() {
  theme_minimal(base_size = 12) +
    theme(
      plot.background    = element_rect(fill = "#0f0f0f", color = NA),
      panel.background   = element_rect(fill = "#1a1a1a", color = NA),
      panel.grid.major   = element_line(color = "#2a2a2a"),
      panel.grid.minor   = element_blank(),
      text               = element_text(color = "#d4d4d4"),
      axis.text          = element_text(color = "#888888", size = 9),
      axis.title         = element_text(color = "#aaaaaa", size = 10),
      plot.title         = element_text(color = "#ffffff", size = 13,
                                        face = "bold", margin = margin(b=8)),
      plot.subtitle      = element_text(color = "#666666", size = 9),
      legend.background  = element_rect(fill = "#1a1a1a", color = NA),
      legend.text        = element_text(color = "#aaaaaa"),
      strip.text         = element_text(color = "#aaaaaa"),
      plot.margin        = margin(12, 16, 12, 16)
    )
}

type_palette <- c(
  running           = "#ef4444",
  cycling           = "#3b82f6",
  strength_training = "#f97316",
  indoor_rowing     = "#8b5cf6",
  indoor_cycling    = "#06b6d4",
  hiking            = "#22c55e",
  other             = "#6b7280"
)

normalize_type <- function(type_col) {
  type_col |>
    tolower() |>
    gsub("road_running|trail_running|treadmill_running", "running", x = _) |>
    gsub("road_biking|indoor_biking|virtual_ride", "cycling", x = _) |>
    gsub("strength|weight_training|gym", "strength_training", x = _) |>
    (\(x) ifelse(x %in% names(type_palette), x, "other"))()
}


plot_activity_timeline <- function(df) {
  df |>
    mutate(type_clean = normalize_type(type)) |>
    ggplot(aes(x = date, y = duration_min, fill = type_clean)) +
    geom_col(width = 0.8, alpha = 0.85) +
    scale_fill_manual(values = type_palette, name = "Activity") +
    scale_x_date(date_breaks = "1 week", date_labels = "%b %d") +
    scale_y_continuous(labels = scales::label_number(suffix = "m")) +
    labs(
      title    = "Activity Timeline",
      subtitle = "Duration per session",
      x = NULL, y = "Duration (min)"
    ) +
    athx_theme()
}


plot_weekly_load <- function(df) {
  df |>
    mutate(week = floor_date(date, "week", week_start = 1)) |>
    group_by(week) |>
    summarise(
      total_min     = sum(duration_min, na.rm = TRUE),
      total_km      = sum(distance_km, na.rm = TRUE),
      sessions      = n(),
      .groups = "drop"
    ) |>
    ggplot(aes(x = week)) +
    geom_col(aes(y = total_min), fill = "#3b82f6", alpha = 0.7, width = 5) +
    geom_line(aes(y = sessions * 20), color = "#ef4444",
              linewidth = 1, linetype = "dashed") +
    geom_point(aes(y = sessions * 20), color = "#ef4444", size = 2) +
    scale_y_continuous(
      name = "Total duration (min)",
      sec.axis = sec_axis(~ . / 20, name = "Sessions / week",
                          breaks = seq(0, 10, 1))
    ) +
    scale_x_date(date_breaks = "1 week", date_labels = "W%V") +
    labs(
      title    = "Weekly Training Load",
      subtitle = "Blue = total minutes  |  Red dashed = sessions",
      x = NULL
    ) +
    athx_theme()
}


plot_hr_zones <- function(df) {
  df |>
    filter(!is.na(avg_hr)) |>
    mutate(
      hr_zone = case_when(
        avg_hr < 115 ~ "Z1 Recovery",
        avg_hr < 136 ~ "Z2 Aerobic",
        avg_hr < 155 ~ "Z3 Tempo",
        avg_hr < 171 ~ "Z4 Threshold",
        TRUE          ~ "Z5 VO2Max"
      ),
      hr_zone = factor(hr_zone, levels = c("Z1 Recovery","Z2 Aerobic",
                                            "Z3 Tempo","Z4 Threshold",
                                            "Z5 VO2Max"))
    ) |>
    count(hr_zone) |>
    ggplot(aes(x = hr_zone, y = n, fill = hr_zone)) +
    geom_col(alpha = 0.85) +
    scale_fill_manual(values = c("#22c55e","#3b82f6","#f59e0b",
                                  "#ef4444","#8b5cf6"),
                      guide = "none") +
    geom_text(aes(label = n), vjust = -0.5, color = "#888888", size = 3.5) +
    labs(
      title    = "Heart Rate Zone Distribution",
      subtitle = "Sessions by average HR",
      x = NULL, y = "Sessions"
    ) +
    athx_theme()
}


plot_activity_split <- function(df) {
  df |>
    mutate(type_clean = normalize_type(type)) |>
    group_by(type_clean) |>
    summarise(total_min = sum(duration_min, na.rm = TRUE), .groups = "drop") |>
    arrange(desc(total_min)) |>
    ggplot(aes(x = reorder(type_clean, total_min), y = total_min,
               fill = type_clean)) +
    geom_col(alpha = 0.85) +
    coord_flip() +
    scale_fill_manual(values = type_palette, guide = "none") +
    scale_y_continuous(labels = scales::label_number(suffix = "m")) +
    labs(
      title    = "Time by Activity Type",
      subtitle = "Total minutes in period",
      x = NULL, y = "Minutes"
    ) +
    athx_theme()
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 — SUMMARY STATS PRINTOUT
# ─────────────────────────────────────────────────────────────────────────────

print_summary <- function(df) {
  cat("\n", strrep("─", 50), "\n")
  cat("  GARMIN ACTIVITY SUMMARY\n")
  cat("  Period:", format(min(df$date)), "to", format(max(df$date)), "\n")
  cat(strrep("─", 50), "\n\n")

  cat(glue("  Total sessions   : {nrow(df)}\n"))
  cat(glue("  Total time       : {round(sum(df$duration_min, na.rm=T)/60, 1)} hrs\n"))
  cat(glue("  Total distance   : {round(sum(df$distance_km, na.rm=T), 1)} km\n"))
  cat(glue("  Avg session      : {round(mean(df$duration_min, na.rm=T), 0)} min\n"))
  cat(glue("  Avg HR           : {round(mean(df$avg_hr, na.rm=T), 0)} bpm\n"))
  cat(glue("  Total calories   : {round(sum(df$calories, na.rm=T), 0)}\n\n"))

  cat("  By activity type:\n")
  df |>
    mutate(type_clean = normalize_type(type)) |>
    group_by(type_clean) |>
    summarise(
      sessions = n(),
      hours    = round(sum(duration_min, na.rm=T)/60, 1),
      .groups  = "drop"
    ) |>
    arrange(desc(hours)) |>
    glue_data("  {formatC(type_clean, width=22, flag='-')} {sessions} sessions  {hours} hrs\n") |>
    cat()

  cat("\n", strrep("─", 50), "\n\n")
}


# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 — MAIN RUN
# ─────────────────────────────────────────────────────────────────────────────

main <- function() {

  # 1. Pull data
  activities <- if (MODE == "live") {
    session <- garmin_login(GARMIN_EMAIL, GARMIN_PASSWORD)
    fetch_activities(session, days = DAYS_BACK)
  } else {
    read_garmin_csv(CSV_PATH)
  }

  if (nrow(activities) == 0) {
    stop("No activities to display. Check your credentials or CSV path.")
  }

  # Optionally filter to last N days for CSV mode too
  activities <- activities |>
    filter(date >= Sys.Date() - DAYS_BACK)

  # 2. Print text summary
  print_summary(activities)

  # 3. Build plots
  p1 <- plot_activity_timeline(activities)
  p2 <- plot_weekly_load(activities)
  p3 <- plot_hr_zones(activities)
  p4 <- plot_activity_split(activities)

  # 4. Combine with patchwork
  dashboard <- (p1 / p2) | (p3 / p4)

  dashboard_titled <- dashboard +
    plot_annotation(
      title   = "GARMIN TRAINING DASHBOARD",
      caption = glue("Generated {format(Sys.time(), '%Y-%m-%d %H:%M')}  |  Last {DAYS_BACK} days"),
      theme   = theme(
        plot.background = element_rect(fill = "#0f0f0f", color = NA),
        plot.title      = element_text(color = "#ffffff", size = 18,
                                       face = "bold", hjust = 0.5,
                                       margin = margin(t=10, b=6)),
        plot.caption    = element_text(color = "#444444", size = 8,
                                       hjust = 0.5)
      )
    )

  # 5. Save + show
  output_file <- glue("garmin_dashboard_{format(Sys.Date(), '%Y%m%d')}.png")
  ggsave(output_file, dashboard_titled,
         width = 16, height = 10, dpi = 150, bg = "#0f0f0f")
  message(glue("Dashboard saved to: {output_file}"))

  # Show in RStudio viewer
  print(dashboard_titled)

  invisible(activities)
}

# Run it
activities <- main()
