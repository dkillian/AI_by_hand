# prep_haiku.R
# Reads the raw haiku CSV, splits each haiku into individual lines,
# and adds line number, narrative arc label, and syllable count.
# Outputs a tidy CSV with one row per haiku line.


# ---- Syllable counter ----
# Builds a lookup table from the full word vocabulary in one nsyllable() call,
# then sums counts per line — much faster than calling nsyllable() row by row.

library(nsyllable)

make_syllable_lookup <- function(all_text) {
  words  <- unique(unlist(strsplit(tolower(trimws(all_text)), "\\s+")))
  counts <- nsyllable(words)
  counts[is.na(counts)] <- 1L
  setNames(counts, words)
}



# ---- Load raw data ----

haiku_path <- "C:/Users/dkill/OneDrive/Documents/Embedded Poet/data/Poetry/haikus.csv"

haikus_raw <- read_csv(haiku_path, show_col_types = FALSE) |>
  filter(!is.na(text), text != "") |>
  mutate(haiku_id = row_number())

cat(sprintf("Raw haikus loaded: %d\n", nrow(haikus_raw)))

# ---- Split into lines ----

arc_labels <- c("setting", "tension", "release")

haiku_lines <- haikus_raw |>
  select(haiku_id, source, text) |>
  mutate(lines = str_split(text, "\\s*/\\s*")) |>
  unnest(lines) |>
  rename(full_text = text, line_text = lines) |>
  mutate(line_text = trimws(line_text)) |>
  filter(line_text != "") |>
  group_by(haiku_id) |>
  mutate(
    line_num      = row_number() - 1L,
    narrative_arc = arc_labels[line_num + 1L]
  ) |>
  ungroup()

# Build syllable lookup once across all words, then join — fully vectorized
cat("Building syllable lookup...\n")
syl_lookup <- make_syllable_lookup(haiku_lines$line_text)
cat(sprintf("Unique words in vocabulary: %d\n", length(syl_lookup)))

syl_df <- tibble(word = names(syl_lookup), syllables = syl_lookup)

word_counts <- haiku_lines |>
  mutate(row_id = row_number()) |>
  select(row_id, line_text) |>
  mutate(word = str_split(tolower(trimws(line_text)), "\\s+")) |>
  unnest(word) |>
  left_join(syl_df, by = "word") |>
  mutate(syllables = replace_na(syllables, 1L)) |>
  group_by(row_id) |>
  summarise(syllables = sum(syllables), .groups = "drop")

haiku_lines <- haiku_lines |>
  mutate(row_id = row_number()) |>
  left_join(word_counts, by = "row_id") |>
  select(-row_id)

# ---- Syllables: fixed target + computed check ----

expected_syllables <- c("0" = 5L, "1" = 7L, "2" = 5L)

haiku_lines <- haiku_lines |>
  rename(syllable_check = syllables) |>
  mutate(
    syllables  = expected_syllables[as.character(line_num)],  # canonical 5-7-5
    syl_match  = syllable_check == syllables
  ) |>
  group_by(haiku_id) |>
  mutate(is_5_7_5 = all(syl_match)) |>
  ungroup() |>
  select(haiku_id, source, line_num, narrative_arc, line_text,
         syllables, syllable_check, syl_match, is_5_7_5, full_text)

# ---- Summary ----

n_haikus      <- n_distinct(haiku_lines$haiku_id)
n_complete    <- haiku_lines |> filter(is_5_7_5) |> distinct(haiku_id) |> nrow()
n_three_lines <- haiku_lines |>
  group_by(haiku_id) |>
  filter(n() == 3L) |>
  distinct(haiku_id) |>
  nrow()

cat(sprintf("Total haikus:              %d\n", n_haikus))
cat(sprintf("Haikus with 3 lines:       %d\n", n_three_lines))
cat(sprintf("Haikus matching 5-7-5:     %d (%.1f%%)\n",
            n_complete, 100 * n_complete / n_haikus))

# Syllable distribution by line position
cat("\nSyllable counts by line:\n")
haiku_lines |>
  group_by(narrative_arc, line_num) |>
  summarise(
    mean_syl   = round(mean(syllables), 1),
    pct_match  = round(100 * mean(syl_match), 1),
    .groups = "drop"
  ) |>
  arrange(line_num) |>
  print()

# ---- Save ----

out_path <- "C:/Users/dkill/OneDrive/Documents/Embedded Poet/data/Poetry/haiku_lines.csv"
write_csv(haiku_lines, out_path)
cat(sprintf("\nSaved to: %s\n", out_path))
