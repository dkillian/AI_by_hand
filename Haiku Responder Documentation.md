# Project Memory — AI by Hand

## Overview
This project is a from-scratch GPT implementation ("microgpt") built for learning purposes, with a haiku-specific variant for collaborative poetry generation.

## Project Structure
- `Microgpt/microgpt.py` — base microgpt in Python (pure autograd, no PyTorch)
- `Microgpt/microgpt.R` — base microgpt in R (R6-based autograd)
- `Microgpt/microgpt_haiku.py` — haiku-specific variant in Python
- `Microgpt/microgpt_haiku.R` — haiku-specific variant in R (primary working file)
- `Microgpt/prep_haiku.R` — data preparation script
- `Microgpt/microgpt_tutorial.qmd` — tutorial/explainer document

## Data
- Haiku lines: `C:/Users/dkill/OneDrive/Documents/Embedded Poet/data/Poetry/haiku_lines.csv`
- 147,043 rows; one row per haiku line
- Columns: `haiku_id`, `source`, `line_num` (0/1/2), `narrative_arc` (setting/tension/release), `line_text`, `syllables`, `syllable_check`, `syl_match`, `is_5_7_5`, `full_text`
- Haikus are stored as full strings in "line1 / line2 / line3" format in the `docs` variable

## Model Architecture (microgpt_haiku.R)
- Pure R autograd using R6 `Value` class (no external ML libraries)
- Character-level tokenizer; vocab built from training docs + BOS token
- Hyperparameters: `n_layer=1`, `n_embd=16`, `block_size=128`, `n_head=4`
- Learned line embedding (`wle`) encodes narrative role (setting/tension/release)
- Syllable counting via `nsyllable` package with CMU Pronouncing Dictionary
- Optimizer: Adam

## Narrative Structure
- Line 0 → setting (5 syllables)
- Line 1 → tension (7 syllables)
- Line 2 → release (5 syllables)
- Prompt syllable count determines position: ≤5 syl → line 0, >5 syl → line 1

## Training Status (as of 2026-04-05)
- ~70 steps completed
- Loss is oscillating wildly (not converging) — likely learning rate too high
- `learning_rate` variable is set in session; consider reducing by 10x
- Losses stored as list of R6 `Value` objects; extract with `sapply(losses, function(l) l$data)`

## Inference
- `generate_response(prompt_line, temperature=0.5)` — character-by-character generation
- Since model is undertrained, output is currently nonsense
- Retrieval-based alternative: filter `haiku_lines` by `line_num` and `syllables`, sample randomly

## Next Steps
1. Fix training instability — lower learning rate, consider gradient clipping
2. Build collaborative haiku Shiny app (Option A flow):
   - Human writes Line 1 (5 syl, setting)
   - Computer retrieves/generates Line 2 (7 syl, tension)
   - Human writes Line 3 (5 syl, release)
   - App validates syllable counts and displays final haiku
3. Once model converges, revisit model-scored retrieval or semantic search

## Notes
- Prevent Windows sleep during long training runs via Settings → Power & Sleep → set to Never
- The R session uses `reticulate` to interop with Python objects (losses list contains Python Value objects)
