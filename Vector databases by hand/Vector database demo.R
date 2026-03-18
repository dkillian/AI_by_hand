# Vector database demo
# Jan 2026

# Prepare data ---- 

getwd()

h <- read_csv("Poetry/haikus.csv") %>%
    select(text) %>%
    rownames_to_column("id") %>%
    mutate(haiku = str_replace_all(text, " / ", "<br>")) 

nrow((h))

h_gt <- h %>%
    select(1,3) %>%
    filter(id %in% 1:4) %>%
    gt() %>%
    cols_width(id ~ px(20)) %>%
    fmt_markdown(haiku)

h_gt

h_long <- h %>%
    separate_rows(text, sep=" / ") %>%
    group_by(id) %>%
    mutate(line = row_number()) %>%
    ungroup() %>%
    mutate(id2 = paste(id, line, sep="-")) %>%
    select(id, line, id2, haiku=text)

head(h_long)

h_long_samp <- h_long %>%
    .[1:3000,]

# Generate embeddings ----

library(ragnar)

# embeds returned as a numeric matrix: rows = lines, cols = embedding dims
emb_mat <- ragnar::embed_openai(
    h_long_samp$haiku,
    model = "text-embedding-3-small",
    batch_size = 25L
)

# attach as a list-column (one numeric vector per row)
h_long_samp_emb <- h_long_samp |>
    mutate(vec = lapply(seq_len(nrow(emb_mat)), \(i) unname(emb_mat[i, ])))

str(h_long_samp_emb)
names(h_long_samp_emb)

# Create vector database ----

# h_long_samp_emb must have: one column that is the embedding (list-column),
# plus whatever metadata you want returned (e.g., haiku_id, line_id, line_text).

# 1) Identify the embedding column (edit if yours is named differently)

emb_col <- "vec"   # e.g., "emb" or "vector" if that's what you used

# 2) Build (X) embedding matrix and (meta) metadata table

X <- do.call(rbind, h_long_samp_emb[[emb_col]])
storage.mode(X) <- "double"

meta <- h_long_samp_emb
meta[[emb_col]] <- NULL

# 3) L2-normalize rows (so cosine = dot product)

row_l2 <- function(M) sqrt(rowSums(M * M))

Xn <- X / row_l2(X)

# 4) Core query: top-k cosine similarity

vd_query <- function(q_vec, k = 5) {
    q_vec <- as.numeric(q_vec)
    qn <- q_vec / sqrt(sum(q_vec * q_vec))
    sims <- drop(Xn %*% qn)
    idx <- order(sims, decreasing = TRUE)[seq_len(k)]
    cbind(meta[idx, , drop = FALSE], score = sims[idx])
}

# 5) "Dialogue" response: return the best-matching line (or sample from top-k)

vd_reply <- function(q_vec, k = 10, temp = 0) {
    hits <- vd_query(q_vec, k = k)
    if (temp <= 0) return(hits[1, , drop = FALSE])
    
    # softmax sampling over scores (higher temp = flatter)
    s <- hits$score / temp
    p <- exp(s - max(s)); p <- p / sum(p)
    hits[sample.int(nrow(hits), 1, prob = p), , drop = FALSE]
}




