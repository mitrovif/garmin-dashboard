# garmin-dashboard

R script to pull and visualise Garmin Connect activity data.

## Modes
- **live** — authenticates directly to Garmin Connect (no API key needed)
- **csv** — reads an exported `Activities.csv` from Garmin Connect

## Setup

```r
install.packages(c("httr2", "jsonlite", "dplyr", "ggplot2",
                   "lubridate", "readr", "scales", "patchwork",
                   "keyring", "glue"))
```

Store credentials securely (run once):
```r
keyring::key_set("garmin", username = "your@email.com")
```

## Usage

Set `MODE <- "live"` or `MODE <- "csv"` at the top of `garmin_dashboard.R`, then source the script.

## Known issues / TODO
- [ ] Fix cookie/session persistence for live mode (httr2 does not share cookies across `request()` calls)
- [ ] Fix URL construction in `fetch_activities` (`glue()` with two args inserts a space)
- [ ] Fix nested JSON column access (`activityType$typeKey`) after `simplifyVector = TRUE`
- [ ] Fix CSV `duration_min` parsing (`sapply` inside `ifelse` inside `mutate`)
