# Lightweight smoke test (no testthat). Run from the repo root:
#   Rscript tests/smoke.R
# Sources the main script (which only defines functions when source()-d),
# then exercises the pure functions on a tiny inline data frame.
# No network access is needed.

suppressPackageStartupMessages(source("fetch_and_analyze_cricket_data.R"))

# --- normalize_team ---------------------------------------------------------
stopifnot(identical(
  normalize_team(c("Delhi Daredevils", "Mumbai Indians", "Kings XI Punjab")),
  c("Delhi Capitals", "Mumbai Indians", "Punjab Kings")
))

# --- entropy / predictability ---------------------------------------------
stopifnot(all.equal(binary_entropy(c(0, 0.5, 1)), c(0, 1, 0)))
stopifnot(all.equal(predictability_score(0.5), 0))
stopifnot(all.equal(predictability_score(1), 1))

# --- tiny fixture: A beats B twice, B beats A once; C vs D once (below min) ---
matches <- tibble::tibble(
  team1       = c("A", "B", "A", "C", "A"),
  team2       = c("B", "A", "B", "D", "B"),
  winner      = c("A", "A", "B", "C", NA),
  toss_winner = c("A", "B", "B", "D", "A"),
  venue       = c("V1", "V1", "V2", "V3", "V1"),
  event       = c("ICC World Cup", "ICC Men's T20 World Cup", "World Cup", "ICC World Twenty20", "ICC World Cup")
)

dec <- decisive_matches(matches)
stopifnot(nrow(dec) == 4)

pp <- pairing_predictability(dec, min_matches = 3)
stopifnot(nrow(pp) == 1)
stopifnot(pp$pairing == "A vs B", pp$n_matches == 3, pp$dominant_side == "A",
          pp$dominant_wins == 2, pp$dominance_pct == 66.7)
stopifnot(all.equal(pp$predictability_score, round(1 - binary_entropy(2 / 3), 3)))
stopifnot(all.equal(weighted_predictability(pp), pp$predictability_score))

# --- venue fortress with permissive thresholds -----------------------------
vf <- venue_fortress(dec, min_at_venue = 1, min_elsewhere = 1)
stopifnot(all(c("team", "venue", "matches_at_venue", "win_pct_at_venue",
                "win_pct_elsewhere", "lift_pct_pts") %in% names(vf)))
a_v1 <- vf[vf$team == "A" & vf$venue == "V1", ]
stopifnot(nrow(a_v1) == 1, a_v1$win_pct_at_venue == 100, a_v1$win_pct_elsewhere == 0,
          a_v1$lift_pct_pts == 100)
stopifnot(!is.unsorted(rev(vf$lift_pct_pts)))

# --- toss / world-cup split --------------------------------------------------
stopifnot(all.equal(toss_win_rate(dec), 0.5))
cups <- split_world_cups(matches)
stopifnot(nrow(cups$odi) == 3, nrow(cups$t20) == 2)

# --- input validation ----------------------------------------------------
stopifnot(inherits(try(decisive_matches(data.frame(x = 1)), silent = TRUE), "try-error"))

cat("smoke.R: all checks passed\n")
