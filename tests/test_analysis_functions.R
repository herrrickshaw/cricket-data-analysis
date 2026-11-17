# Offline tests for the analysis functions in fetch_and_analyze_cricket_data.R.
# The script downloads from Cricsheet at top level, so we parse it and evaluate ONLY
# the pure definitions below (no network, no files written). Base R + dplyr only.
# Run from the repo root:  Rscript tests/test_analysis_functions.R
suppressPackageStartupMessages({ library(dplyr); library(tibble) })

wanted <- c("rename_map", "normalize_team", "binary_entropy", "predictability_score",
            "pairing_predictability", "weighted_predictability", "venue_fortress")
exprs <- parse("fetch_and_analyze_cricket_data.R")
env <- new.env()
for (e in exprs) {
  if (is.call(e) && identical(e[[1]], as.name("<-")) && as.character(e[[2]]) %in% wanted) eval(e, env)
}
stopifnot(all(wanted %in% ls(env)))
attach(env)

n_ok <- 0
check <- function(name, cond) {
  if (!isTRUE(cond)) stop("FAILED: ", name)
  n_ok <<- n_ok + 1
  cat("ok -", name, "\n")
}
near <- function(a, b, tol = 1e-6) isTRUE(all.equal(a, b, tolerance = tol))

# --- predictability = 1 - binary entropy of the dominant side's win share
check("coin flip is 0", predictability_score(0.5) == 0)
check("clean sweep is 1", predictability_score(1) == 1 && predictability_score(0) == 1)
check("3-1 hand computed", near(predictability_score(0.75), 1 - (-(0.75 * log2(0.75) + 0.25 * log2(0.25)))))
check("entropy symmetric", near(binary_entropy(0.3), binary_entropy(0.7)))

# --- franchise renames
check("renames merge old names",
      identical(normalize_team(c("Delhi Daredevils", "Kings XI Punjab", "Royal Challengers Bangalore",
                                 "Rising Pune Supergiant", "Mumbai Indians", NA)),
                c("Delhi Capitals", "Punjab Kings", "Royal Challengers Bengaluru",
                  "Rising Pune Supergiants", "Mumbai Indians", NA)))

# --- pairing predictability on a synthetic fixture
m <- tibble(
  team1  = c("A", "B", "A", "B", "C", "A", "A", "C"),
  team2  = c("B", "A", "B", "A", "A", "C", "D", "D"),
  winner = c("A", "A", "B", "A", "C", "A", "A", "D")
)
p <- pairing_predictability(m, min_matches = 2)
ab <- p[p$pairing == "A vs B", ]
check("pairing is order-independent and counts 4 A-B meetings", nrow(ab) == 1 && ab$n_matches == 4)
check("dominant side and share", ab$dominant_side == "A" && ab$dominant_wins == 3 && ab$dominance_pct == 75)
check("score rounded to 3dp", ab$predictability_score == round(predictability_score(0.75), 3))
ac <- p[p$pairing == "A vs C", ]
check("1-1 pairing scores 0", nrow(ac) == 1 && ac$predictability_score == 0)
check("pairings under min_matches dropped", !any(p$pairing %in% c("A vs D", "C vs D")))
check("sorted by score desc", !is.unsorted(rev(p$predictability_score)))
check("match-weighted predictability",
      near(weighted_predictability(p), (ab$predictability_score * 4 + 0 * 2) / 6))

# --- venue fortress: win rate at venue minus elsewhere, with sample floors
v <- tibble(
  team1  = rep("A", 10), team2 = rep("B", 10),
  venue  = c(rep("Home", 4), rep("Away", 6)),
  winner = c("A", "A", "A", "B", "A", "B", "B", "B", "B", "A")
)
f <- venue_fortress(v, min_at_venue = 4, min_elsewhere = 4)
fa <- f[f$team == "A" & f$venue == "Home", ]
check("home lift hand computed", fa$win_pct_at_venue == 75 && near(fa$win_pct_elsewhere, round(100 * 2 / 6, 1)) &&
        near(fa$lift_pct_pts, round(75 - round(100 * 2 / 6, 1), 1)))
fb <- f[f$team == "B" & f$venue == "Home", ]
check("lift is antisymmetric for the opponent", near(fb$lift_pct_pts, -fa$lift_pct_pts))
check("sample floor excludes venues", nrow(venue_fortress(v, min_at_venue = 5, min_elsewhere = 4) %>%
                                             filter(venue == "Home")) == 0)

cat(n_ok, "passed\n")
