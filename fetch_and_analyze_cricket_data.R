# =============================================================================
# Cricket Predictability Analysis — Data Acquisition via {cricketdata}
# =============================================================================
# Purpose:
#   Pull canonical, complete match-level data for the IPL and both ICC men's
#   World Cups (ODI + T20) directly from Cricsheet, using the {cricketdata}
#   R package (https://github.com/robjhyndman/cricketdata), then compute
#   simple predictability statistics (pairing dominance, venue "fortress"
#   effect, toss impact).
#
#   This replaces the GitHub-mirror datasets used in an earlier pass of this
#   analysis (which were necessary because the sandbox that produced them
#   could not reach cricsheet.org directly). Run this script on a machine
#   with normal internet access.
#
# Requirements:
#   install.packages(c("cricketdata", "dplyr", "tidyr", "stringr", "readr"))
#   (cricketdata depends on: cli, dplyr, jsonlite, lubridate, readr, rvest,
#    stringr, tibble, tidyr, xml2 — installed automatically as dependencies)
#
# Usage:
#   Rscript fetch_and_analyze_cricket_data.R [output_dir]
#   output_dir defaults to ./output (relative to the working directory).
#
# Output (written to output_dir):
#     ipl_matches.csv
#     odi_world_cup_matches.csv
#     t20_world_cup_matches.csv
#     ipl_pairing_predictability.csv
#     t20wc_pairing_predictability.csv
#     odiwc_pairing_predictability.csv
#     ipl_venue_fortress.csv
#   Plus summary tables printed to the console.
#
# Layout of this file:
#   constants -> fetch -> tidy -> analyse -> report/write -> main()
#   main() runs only when the file is executed with Rscript; source()-ing it
#   (e.g. from tests/smoke.R) just defines the functions.
# =============================================================================

library(cricketdata)
library(dplyr)
library(tidyr)
library(stringr)
library(readr)

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

#' Default output directory, relative to the working directory.
DEFAULT_OUTPUT_DIR <- "output"

#' Base URL for Cricsheet CSV2 archives.
CRICSHEET_DOWNLOAD_BASE <- "https://cricsheet.org/downloads/"

#' A real Cricsheet zip is at minimum tens of KB; anything under this many
#' bytes is almost certainly an error page or empty response, not real data.
MIN_VALID_ZIP_BYTES <- 1000

#' Regex (case-insensitive) that identifies T20 World Cup events inside the
#' combined Cricsheet "cup" archive. Everything else is treated as ODI.
T20_EVENT_PATTERN <- "T20|Twenty20"

#' Franchise renames: old name -> current name.
TEAM_RENAME_MAP <- c(
  "Delhi Daredevils" = "Delhi Capitals",
  "Kings XI Punjab" = "Punjab Kings",
  "Royal Challengers Bangalore" = "Royal Challengers Bengaluru",
  "Rising Pune Supergiant" = "Rising Pune Supergiants"
)

#' Minimum meetings for a pairing to be scored.
MIN_PAIRING_MATCHES <- 3

#' Minimum sample sizes for the venue fortress comparison.
MIN_MATCHES_AT_VENUE <- 8
MIN_MATCHES_ELSEWHERE <- 10

#' Rows shown in each console summary table.
TOP_N <- 10

# -----------------------------------------------------------------------------
# Fetch
# -----------------------------------------------------------------------------

#' Download a Cricsheet archive with explicit diagnostics, then parse it.
#'
#' cricketdata::fetch_cricsheet() can fail with "cannot open the connection" if
#'   (a) a previous failed attempt left a corrupt/0-byte zip in tempdir(),
#'       which the package then tries to reuse instead of re-downloading;
#'   (b) the default download.file() method has trouble with HTTPS on this
#'       machine/R build;
#'   (c) something between you and cricsheet.org (proxy, firewall) is
#'       blocking or altering the request.
#' This helper downloads the zip itself with a forced re-download and clear
#' error messages, verifies it is a real zip, and only then calls
#' fetch_cricsheet(), which finds the verified file in tempdir() and skips its
#' own download step.
#'
#' @param competition Cricsheet competition code, e.g. "ipl" or "cup".
#' @param gender "male" or "female".
#' @param type Cricsheet CSV2 table to return: "match", "bbb" or "player".
#' @return A tibble as returned by cricketdata::fetch_cricsheet().
robust_fetch_cricsheet <- function(competition, gender = "male", type = "match") {
  stopifnot(is.character(competition), length(competition) == 1)
  destfile_name <- paste0(competition, "_", gender, "_csv2.zip")
  url <- paste0(CRICSHEET_DOWNLOAD_BASE, destfile_name)
  local_path <- file.path(tempdir(), destfile_name)

  # Always force a fresh download — clears out any stale/corrupt file from
  # a previous failed attempt, which is the most common cause of this error.
  if (file.exists(local_path)) {
    cat("Removing stale cached file:", local_path, "\n")
    unlink(local_path)
  }

  cat("Downloading:", url, "\n")
  status <- tryCatch(
    download.file(url, local_path, mode = "wb", method = "libcurl", quiet = FALSE),
    error = function(e) {
      cat("download.file() raised an error:\n  ", conditionMessage(e), "\n")
      return(NA)
    }
  )

  if (is.na(status) || !file.exists(local_path)) {
    stop(
      "Download failed before a local file was created.\n",
      "Things to check:\n",
      "  1. Can you open this URL in a normal web browser right now? ", url, "\n",
      "  2. Are you behind a corporate VPN/proxy/firewall that might block cricsheet.org?\n",
      "  3. Try running: download.file('", url, "', 'test.zip', mode='wb', method='libcurl')\n",
      "     directly in your R console and see what error appears.\n"
    )
  }

  file_size <- file.info(local_path)$size
  cat("Downloaded file size:", file_size, "bytes\n")

  if (is.na(file_size) || file_size < MIN_VALID_ZIP_BYTES) {
    first_lines <- tryCatch(readLines(local_path, n = 5, warn = FALSE), error = function(e) "")
    stop(
      "Downloaded file is suspiciously small (", file_size, " bytes) — ",
      "this is very likely an error page, not a real zip file.\n",
      "First lines of the file:\n  ", paste(first_lines, collapse = "\n  "), "\n",
      "This usually means the URL is wrong, the file has moved, or a proxy ",
      "intercepted the request. Check ", url, " in a browser to confirm it's a working link.\n"
    )
  }

  # Confirm it's actually a valid zip before handing off to fetch_cricsheet's
  # internal unzip logic, so any failure is caught here with a clear message
  # instead of surfacing later as a cryptic "cannot open the connection".
  valid_zip <- tryCatch({
    unzip(local_path, list = TRUE)
    TRUE
  }, error = function(e) FALSE)

  if (!valid_zip) {
    stop(
      "The downloaded file is not a valid zip archive (failed unzip() test).\n",
      "File path: ", local_path, " (", file_size, " bytes)\n",
      "Try deleting it and re-downloading manually in a browser to inspect what came through.\n"
    )
  }

  cat("Zip file verified OK. Proceeding with fetch_cricsheet()...\n\n")
  fetch_cricsheet(type = type, gender = gender, competition = competition)
}

#' Fetch IPL match data from Cricsheet, with console progress.
#' @return Tibble of IPL matches (one row per match).
fetch_ipl_matches <- function() {
  cat("Fetching IPL match data from Cricsheet...\n")
  ipl_matches <- robust_fetch_cricsheet(competition = "ipl", gender = "male", type = "match")
  cat("IPL matches fetched:", nrow(ipl_matches), "\n")
  cat("Seasons covered:", paste(range(ipl_matches$season, na.rm = TRUE), collapse = " to "), "\n\n")
  ipl_matches
}

#' Fetch the combined ICC men's World Cup archive (ODI + T20) from Cricsheet.
#' @return Tibble of World Cup matches, both formats mixed.
fetch_world_cup_matches <- function() {
  cat("Fetching ICC Men's World Cup match data from Cricsheet (ODI + T20 combined)...\n")
  cup_matches <- robust_fetch_cricsheet(competition = "cup", gender = "male", type = "match")
  cat("Total ICC men's World Cup matches fetched:", nrow(cup_matches), "\n")
  # Print the actual event names present, so the split stays auditable even
  # if Cricsheet's naming changes slightly across seasons.
  cat("Distinct event names found:\n")
  print(sort(unique(cup_matches$event)))
  cup_matches
}

# -----------------------------------------------------------------------------
# Tidy
# -----------------------------------------------------------------------------

#' Map historical franchise names to their current names.
#' @param x Character vector of team names.
#' @return Character vector of the same length with renames applied.
normalize_team <- function(x) {
  ifelse(x %in% names(TEAM_RENAME_MAP), TEAM_RENAME_MAP[x], x)
}

#' Keep only decisive matches (a non-missing, non-empty winner).
#' @param df Match tibble with a `winner` column.
decisive_matches <- function(df) {
  stopifnot("winner" %in% names(df))
  df %>% filter(!is.na(winner), winner != "")
}

#' Normalise franchise names and drop no-result matches.
#' @param ipl_matches Raw IPL match tibble (team1, team2, winner, toss_winner).
#' @return Cleaned tibble.
clean_ipl <- function(ipl_matches) {
  stopifnot(all(c("team1", "team2", "winner", "toss_winner") %in% names(ipl_matches)))
  ipl_matches %>%
    mutate(
      team1 = normalize_team(team1),
      team2 = normalize_team(team2),
      winner = normalize_team(winner),
      toss_winner = normalize_team(toss_winner)
    ) %>%
    decisive_matches()
}

#' Split the combined Cricsheet "cup" archive into ODI and T20 World Cups.
#'
#' Cricsheet typically labels these:
#'   "ICC World Cup"        -> ODI World Cup (older editions sometimes just "World Cup")
#'   "ICC Men's T20 World Cup" / "ICC World Twenty20" -> T20 World Cup
#'
#' @param cup_matches Tibble with an `event` column.
#' @return list(odi = tibble, t20 = tibble).
split_world_cups <- function(cup_matches) {
  stopifnot("event" %in% names(cup_matches))
  is_t20 <- str_detect(cup_matches$event, regex(T20_EVENT_PATTERN, ignore_case = TRUE))
  list(
    odi = cup_matches %>% filter(is_t20 == FALSE),
    t20 = cup_matches %>% filter(is_t20 == TRUE)
  )
}

# -----------------------------------------------------------------------------
# Analyse (pure functions: data in, data out)
# -----------------------------------------------------------------------------

#' Binary entropy H(p) in bits; 0 at p = 0 or p = 1.
#' @param p Numeric vector of probabilities in [0, 1].
binary_entropy <- function(p) {
  ifelse(p <= 0 | p >= 1, 0, -(p * log2(p) + (1 - p) * log2(1 - p)))
}

#' Predictability score = 1 - H(p). 0 = coin flip, 1 = one side always wins.
#' @param p Win share of the more successful side.
predictability_score <- function(p) 1 - binary_entropy(p)

#' Head-to-head predictability per team pairing.
#'
#' @param df Decisive matches with team1, team2, winner.
#' @param min_matches Minimum meetings for a pairing to be included.
#' @return Tibble: pairing, n_matches, dominant_side, dominant_wins,
#'   dominance_pct, predictability_score; sorted most predictable first.
pairing_predictability <- function(df, min_matches = MIN_PAIRING_MATCHES) {
  stopifnot(all(c("team1", "team2", "winner") %in% names(df)))
  df <- df %>%
    rowwise() %>%
    mutate(pairing = paste(sort(c(team1, team2)), collapse = " vs ")) %>%
    ungroup()

  df %>%
    group_by(pairing) %>%
    filter(n() >= min_matches) %>%
    count(winner, name = "wins", pairing) %>%
    group_by(pairing) %>%
    mutate(n_matches = sum(wins)) %>%
    slice_max(wins, n = 1, with_ties = FALSE) %>%
    ungroup() %>%
    mutate(
      dominance_pct = round(100 * wins / n_matches, 1),
      predictability_score = round(predictability_score(wins / n_matches), 3)
    ) %>%
    rename(dominant_side = winner, dominant_wins = wins) %>%
    select(pairing, n_matches, dominant_side, dominant_wins, dominance_pct, predictability_score) %>%
    arrange(desc(predictability_score), desc(n_matches))
}

#' Match-weighted mean predictability across pairings.
#' @param pred_df Output of pairing_predictability().
#' @return Single number in [0, 1].
weighted_predictability <- function(pred_df) {
  stopifnot(all(c("predictability_score", "n_matches") %in% names(pred_df)))
  sum(pred_df$predictability_score * pred_df$n_matches) / sum(pred_df$n_matches)
}

#' Venue "fortress" effect: win rate at a venue minus win rate elsewhere.
#'
#' Large positive lift = home advantage; large negative lift = a ground that
#' genuinely seems to disadvantage the team.
#'
#' @param df Decisive matches with team1, team2, winner, venue.
#' @param min_at_venue Minimum matches the team played at the venue.
#' @param min_elsewhere Minimum matches the team played at other venues.
#' @return Tibble sorted by lift_pct_pts descending.
venue_fortress <- function(df, min_at_venue = MIN_MATCHES_AT_VENUE,
                           min_elsewhere = MIN_MATCHES_ELSEWHERE) {
  stopifnot(all(c("team1", "team2", "winner", "venue") %in% names(df)))
  teams <- union(unique(df$team1), unique(df$team2))
  results <- list()

  for (team in teams) {
    team_matches <- df %>% filter(team1 == team | team2 == team) %>%
      mutate(team_won = winner == team)

    venues <- unique(team_matches$venue)
    for (v in venues) {
      at_venue <- team_matches %>% filter(venue == v)
      elsewhere <- team_matches %>% filter(venue != v)
      if (nrow(at_venue) < min_at_venue || nrow(elsewhere) < min_elsewhere) next

      results[[length(results) + 1]] <- tibble(
        team = team,
        venue = v,
        matches_at_venue = nrow(at_venue),
        win_pct_at_venue = round(100 * mean(at_venue$team_won), 1),
        win_pct_elsewhere = round(100 * mean(elsewhere$team_won), 1)
      )
    }
  }

  bind_rows(results) %>%
    mutate(lift_pct_pts = round(win_pct_at_venue - win_pct_elsewhere, 1)) %>%
    arrange(desc(lift_pct_pts))
}

#' Share of decisive matches won by the toss winner (0.5 = no effect).
#' @param df Decisive matches with toss_winner and winner.
toss_win_rate <- function(df) {
  stopifnot(all(c("toss_winner", "winner") %in% names(df)))
  mean(df$toss_winner == df$winner, na.rm = TRUE)
}

# -----------------------------------------------------------------------------
# Report / write
# -----------------------------------------------------------------------------

#' Print a titled head() of a tibble to the console.
print_top <- function(title, df, n = TOP_N) {
  cat(title, "\n", sep = "")
  print(head(df, n))
}

#' Write a tibble to <output_dir>/<name>, creating nothing else.
write_output <- function(df, output_dir, name) {
  write_csv(df, file.path(output_dir, name))
}

# -----------------------------------------------------------------------------
# main()
# -----------------------------------------------------------------------------

#' Run the whole pipeline: fetch -> tidy -> analyse -> write CSVs + summaries.
#' @param output_dir Directory for the CSV outputs (created if missing).
main <- function(output_dir = DEFAULT_OUTPUT_DIR) {
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)

  # 1. IPL
  ipl_matches <- fetch_ipl_matches()
  write_output(ipl_matches, output_dir, "ipl_matches.csv")

  # 2. World Cups (ODI + T20 are bundled together by Cricsheet)
  cup_matches <- fetch_world_cup_matches()
  cups <- split_world_cups(cup_matches)
  odi_world_cup <- cups$odi
  t20_world_cup <- cups$t20

  cat("\nODI World Cup matches:", nrow(odi_world_cup),
      "| seasons:", paste(range(odi_world_cup$season, na.rm = TRUE), collapse = "-"), "\n")
  cat("T20 World Cup matches:", nrow(t20_world_cup),
      "| seasons:", paste(range(t20_world_cup$season, na.rm = TRUE), collapse = "-"), "\n\n")

  write_output(odi_world_cup, output_dir, "odi_world_cup_matches.csv")
  write_output(t20_world_cup, output_dir, "t20_world_cup_matches.csv")

  # 3. OPTIONAL: supplementary career stats from ESPNCricinfo (Statsguru).
  #    Useful for player-level context (e.g. weighting predictability by squad
  #    strength), not required for the match-outcome analysis itself.
  #    Commented out by default since it adds runtime; uncomment to use.
  # cat("Fetching ESPNCricinfo T20I men's batting career data...\n")
  # t20i_batting <- fetch_cricinfo(matchtype = "t20", sex = "men",
  #                                 activity = "batting", type = "career")
  # write_output(t20i_batting, output_dir, "espncricinfo_t20i_batting_career.csv")

  # 4. Cleaning
  ipl_clean <- clean_ipl(ipl_matches)
  cat("IPL matches after cleaning (decisive only):", nrow(ipl_clean), "\n\n")

  # 5. Pairing predictability
  ipl_pairing_pred <- pairing_predictability(ipl_clean)
  t20wc_pairing_pred <- pairing_predictability(decisive_matches(t20_world_cup))
  odiwc_pairing_pred <- pairing_predictability(decisive_matches(odi_world_cup))

  print_top("=== Top 10 most predictable IPL pairings (min 3 meetings) ===", ipl_pairing_pred)
  print_top("\n=== Top 10 most predictable T20 World Cup pairings (min 3 meetings) ===", t20wc_pairing_pred)
  print_top("\n=== Top 10 most predictable ODI World Cup pairings (min 3 meetings) ===", odiwc_pairing_pred)

  cat("\n=== Overall match-weighted predictability (0 = coinflip, 1 = certain) ===\n")
  cat("IPL:           ", round(weighted_predictability(ipl_pairing_pred), 3), "\n")
  cat("T20 World Cup: ", round(weighted_predictability(t20wc_pairing_pred), 3), "\n")
  cat("ODI World Cup: ", round(weighted_predictability(odiwc_pairing_pred), 3), "\n\n")

  write_output(ipl_pairing_pred, output_dir, "ipl_pairing_predictability.csv")
  write_output(t20wc_pairing_pred, output_dir, "t20wc_pairing_predictability.csv")
  write_output(odiwc_pairing_pred, output_dir, "odiwc_pairing_predictability.csv")

  # 6. Venue fortress (IPL)
  ipl_fortress <- venue_fortress(ipl_clean)
  print_top("=== Top 10 IPL home-fortress effects (win rate at venue minus elsewhere) ===", ipl_fortress)
  cat("\n=== Top 10 IPL venue disadvantages ===\n")
  print(tail(ipl_fortress, TOP_N))
  write_output(ipl_fortress, output_dir, "ipl_venue_fortress.csv")

  # 7. Toss impact (IPL) — sanity check against the earlier mirror-data finding
  cat("\nIPL toss-winner win rate:", round(100 * toss_win_rate(ipl_clean), 1), "% (50% = no effect)\n")

  cat("\nDone. CSVs written to ./", output_dir, "/\n", sep = "")
  cat("Re-upload these files to continue the analysis, or proceed locally using\n")
  cat("the predictability_score() and venue_fortress() functions defined above.\n")
  invisible(NULL)
}

# Run only when executed as a script (Rscript ...), not when source()-d.
if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  main(output_dir = if (length(args) >= 1) args[[1]] else DEFAULT_OUTPUT_DIR)
}
