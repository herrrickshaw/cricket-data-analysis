# Cricket predictability analysis (IPL and ICC men's World Cups)

<!-- how-to-use-with-ai -->
> **New here?** See [How to use this repo with AI (Claude, Gemini, ChatGPT)](HOW_TO_USE_WITH_AI.md) — clone it, paste it into an AI tool, and ask in plain English.

A single R script that downloads match-level results for the Indian Premier League and both ICC men's
World Cups (ODI and T20) from Cricsheet via the `{cricketdata}` package, normalises franchise names,
and computes three simple "how predictable is this competition?" statistics: head-to-head pairing
dominance (an entropy-based score), a per-team venue "fortress" effect, and the toss-winner win rate.
It produces seven CSV files and prints summary tables to the console.

> Status: research-only snapshot. Data is scraped from third-party sites (Cricsheet, optionally
> ESPNCricinfo via `{cricketdata}`); see their terms before redistributing outputs. Not betting advice.

## What it does
- Downloads the Cricsheet CSV2 archives `ipl_male_csv2.zip` and `cup_male_csv2.zip` with a forced
  fresh download, size and zip-integrity checks, and actionable error messages (`robust_fetch_cricsheet`).
- Splits the combined World Cup archive into ODI and T20 editions using the `event` name (`split_world_cups`).
- Maps renamed IPL franchises to their current names and drops no-result matches (`clean_ipl`).
- Scores every team pairing with at least 3 meetings by `1 - H(p)`, where `p` is the dominant side's win
  share and `H` is binary entropy (`pairing_predictability`, `weighted_predictability`).
- Compares each IPL team's win rate at a venue (≥ 8 matches) with its win rate elsewhere (≥ 10) (`venue_fortress`).
- Reports the share of decisive IPL matches won by the toss winner (`toss_win_rate`).

## Quick start
```bash
git clone https://github.com/herrrickshaw/cricket-data-analysis.git
cd cricket-data-analysis
Rscript -e 'install.packages(c("cricketdata", "dplyr", "tidyr", "stringr", "readr"))'
Rscript fetch_and_analyze_cricket_data.R            # writes ./output/*.csv
Rscript fetch_and_analyze_cricket_data.R /tmp/out   # optional: custom output directory
```
Requires R 4.x and normal internet access to `cricsheet.org`.

## How it works
`fetch_and_analyze_cricket_data.R` is laid out as constants → fetch → tidy → analyse → write, with a thin
`main()` that runs only when the file is executed by `Rscript` (so tests can `source()` it safely).

| Stage | Function(s) | Output |
|---|---|---|
| Fetch | `robust_fetch_cricsheet`, `fetch_ipl_matches`, `fetch_world_cup_matches` | raw match tibbles |
| Tidy | `normalize_team`, `decisive_matches`, `clean_ipl`, `split_world_cups` | cleaned IPL; ODI / T20 World Cup tibbles |
| Analyse | `binary_entropy`, `predictability_score`, `pairing_predictability`, `weighted_predictability`, `venue_fortress`, `toss_win_rate` | summary tibbles |
| Write | `write_output`, `print_top` | `output/*.csv` + console tables |

Design notes:
- The download helper exists because `cricketdata::fetch_cricsheet()` silently reuses a stale or 0-byte zip
  in `tempdir()`; the helper deletes it, re-downloads with `method = "libcurl"`, verifies the archive, and
  then lets `fetch_cricsheet()` pick up the verified file.
- Thresholds (`MIN_PAIRING_MATCHES = 3`, `MIN_MATCHES_AT_VENUE = 8`, `MIN_MATCHES_ELSEWHERE = 10`) are
  named constants at the top of the script and function arguments, so they can be changed in one place.
- The optional ESPNCricinfo career-stats fetch (`fetch_cricinfo`) is left commented out inside `main()`;
  it is not needed for the match-outcome analysis and adds runtime.

## Repository layout
| Path | Purpose |
|---|---|
| `fetch_and_analyze_cricket_data.R` | the whole pipeline (functions + `main()`) |
| `tests/smoke.R` | network-free check of the pure functions on an inline fixture |
| `output/` | generated CSVs; gitignored, not tracked |
| `HOW_TO_USE_WITH_AI.md` | plain-language guide to using the repo with an AI assistant |
| `.github/workflows/quality-gates.yml` | gitleaks secret scan on push / PR |

Outputs written to `output/`: `ipl_matches.csv`, `odi_world_cup_matches.csv`, `t20_world_cup_matches.csv`,
`ipl_pairing_predictability.csv`, `t20wc_pairing_predictability.csv`, `odiwc_pairing_predictability.csv`,
`ipl_venue_fortress.csv`.

## Data sources
| Source | What is taken | Access route | Licence / caveat |
|---|---|---|---|
| [Cricsheet](https://cricsheet.org/downloads/) | IPL and ICC men's World Cup match-level CSV2 archives | `download.file()` + `cricketdata::fetch_cricsheet()` | Scraped/compiled ball-by-ball data; Cricsheet is a volunteer project — check its licence notes before redistributing |
| [ESPNCricinfo Statsguru](https://www.espncricinfo.com/) (optional, commented out) | T20I batting career stats | `cricketdata::fetch_cricinfo()` | Web scrape; subject to ESPNCricinfo terms of use |

## Configuration
No environment variables or secrets. The only option is the positional `output_dir` argument
(default `output`, relative to the working directory).

## Testing
```bash
Rscript -e 'invisible(parse("fetch_and_analyze_cricket_data.R"))'   # syntax check
Rscript tests/smoke.R                                                 # pure-function checks, no network
```

## Limitations and known issues
- The ODI/T20 split relies on the `event` string containing `T20` or `Twenty20`; the script prints the
  distinct event names it saw so the split can be audited after each run.
- Franchise renames are a hand-maintained map (`TEAM_RENAME_MAP`); new renames must be added by hand.
- Pairing predictability ignores match order and era, so a long-dead dominance still counts.
- No full end-to-end test: the pipeline needs network access; only the pure functions are covered.
- The script was extracted from stray copies found in `global-stock-screener` and `global-market-data`
  during a portfolio declutter; its git history before the extraction belongs to those repos.

## Licence
No licence file yet — all rights reserved.
