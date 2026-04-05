# microgpt_haiku.R
# Adapts microgpt.R for haiku line-to-line generation.
# Each training document is a full haiku ("line1 / line2 / line3").
#
# A learned line embedding (wle) encodes narrative role:
#   line 0 -> setting  (5 syllables)
#   line 1 -> tension  (7 syllables)
#   line 2 -> release  (5 syllables)
#
# At inference, the syllable count of the prompt determines which line it is,
# and generation stops once the target syllable count for the response is reached.

library(R6)
library(tidyverse)

set.seed(8142)

# ---- Dataset ----
# Load the prepared file produced by prep_haiku.R.
# Each row is one haiku line with line_num (0/1/2) and narrative_arc already attached.

haiku_lines <- read_csv(
  "C:/Users/dkill/OneDrive/Documents/Embedded Poet/data/Poetry/haiku_lines.csv",
  show_col_types = FALSE
)

# Reconstruct full haiku strings in "line1 / line2 / line3" format,
# keeping the haiku_id so line_num can be recovered at training time.
haiku_docs <- haiku_lines |>
  arrange(haiku_id, line_num) |>
  group_by(haiku_id) |>
  summarise(
    text     = paste(line_text, collapse = " / "),
    line_ids = list(line_num),
    .groups  = "drop"
  ) |>
  filter(lengths(line_ids) == 3L)   # keep only complete 3-line haikus

haiku_docs <- haiku_docs[sample(nrow(haiku_docs)), ]   # shuffle

docs     <- haiku_docs$text
all_line_ids <- haiku_docs$line_ids   # pre-computed line_id per character position

cat(sprintf("num docs: %d\n", length(docs)))

# ---- Tokenizer ----

uchars     <- sort(unique(strsplit(paste(docs, collapse = ""), "")[[1]]))
BOS        <- length(uchars)
vocab_size <- length(uchars) + 1L
cat(sprintf("vocab size: %d\n", vocab_size))

# ---- Syllable Counter ----
# Uses the CMU Pronouncing Dictionary via nsyllable; falls back to 1 for unknown words.

library(nsyllable)

count_syllables <- function(text) {
  words  <- unlist(strsplit(trimws(text), "\\s+"))
  counts <- nsyllable(words)
  counts[is.na(counts)] <- 1L
  sum(counts)
}

# ---- Autograd ----

.vid <- 0L

Value <- R6Class("Value",
  cloneable = FALSE,
  public = list(
    id          = NULL,
    data        = NULL,
    grad        = NULL,
    children    = NULL,
    local_grads = NULL,

    initialize = function(data, children = list(), local_grads = list()) {
      .vid         <<- .vid + 1L
      self$id          <- .vid
      self$data        <- as.double(data)
      self$grad        <- 0.0
      self$children    <- children
      self$local_grads <- local_grads
    },

    add = function(other) {
      if (!inherits(other, "Value")) other <- Value$new(other)
      Value$new(self$data + other$data, list(self, other), list(1.0, 1.0))
    },

    mul = function(other) {
      if (!inherits(other, "Value")) other <- Value$new(other)
      Value$new(self$data * other$data, list(self, other), list(other$data, self$data))
    },

    pow_val = function(exp) {
      Value$new(self$data^exp, list(self), list(exp * self$data^(exp - 1)))
    },

    log_val = function() {
      Value$new(log(self$data), list(self), list(1.0 / self$data))
    },

    exp_val = function() {
      e <- exp(self$data)
      Value$new(e, list(self), list(e))
    },

    relu = function() {
      Value$new(max(0.0, self$data), list(self), list(as.double(self$data > 0)))
    },

    neg = function() self$mul(-1.0),

    sub = function(other) {
      if (!inherits(other, "Value")) other <- Value$new(other)
      self$add(other$neg())
    },

    div = function(other) {
      if (!inherits(other, "Value")) other <- Value$new(other)
      self$mul(other$pow_val(-1.0))
    },

    backward = function() {
      topo    <- list()
      visited <- new.env(hash = TRUE, parent = emptyenv())

      build_topo <- function(v) {
        id_str <- as.character(v$id)
        if (!exists(id_str, envir = visited, inherits = FALSE)) {
          assign(id_str, TRUE, envir = visited)
          for (child in v$children) build_topo(child)
          topo[[length(topo) + 1L]] <<- v
        }
      }

      build_topo(self)
      self$grad <- 1.0
      for (v in rev(topo)) {
        for (i in seq_along(v$children)) {
          v$children[[i]]$grad <- v$children[[i]]$grad + v$local_grads[[i]] * v$grad
        }
      }
    }
  )
)

`+.Value` <- function(a, b) { if (is.numeric(a)) a <- Value$new(a); if (is.numeric(b)) b <- Value$new(b); a$add(b) }
`*.Value` <- function(a, b) { if (is.numeric(a)) a <- Value$new(a); if (is.numeric(b)) b <- Value$new(b); a$mul(b) }
`-.Value` <- function(a, b) { if (missing(b)) return(a$neg()); if (is.numeric(b)) b <- Value$new(b); a$sub(b) }
`/.Value` <- function(a, b) { if (is.numeric(a)) a <- Value$new(a); if (is.numeric(b)) b <- Value$new(b); a$div(b) }
`^.Value` <- function(a, b) a$pow_val(b)

# ---- Model Parameters ----
# block_size is larger than microgpt.R to accommodate full haiku length (~120 chars max).

n_layer    <- 1L
n_embd     <- 16L
block_size <- 128L
n_head     <- 4L
head_dim   <- n_embd %/% n_head

make_matrix <- function(nout, nin, std = 0.08) {
  lapply(seq_len(nout), function(i)
    lapply(seq_len(nin), function(j) Value$new(rnorm(1L, 0, std)))
  )
}

state_dict <- list(
  wte     = make_matrix(vocab_size, n_embd),
  wpe     = make_matrix(block_size, n_embd),
  wle     = make_matrix(3L, n_embd),           # line embeddings: 0=setting, 1=tension, 2=release
  lm_head = make_matrix(vocab_size, n_embd)
)
for (i in seq_len(n_layer) - 1L) {
  li <- as.character(i)
  state_dict[[paste0("layer", li, ".attn_wq")]] <- make_matrix(n_embd, n_embd)
  state_dict[[paste0("layer", li, ".attn_wk")]] <- make_matrix(n_embd, n_embd)
  state_dict[[paste0("layer", li, ".attn_wv")]] <- make_matrix(n_embd, n_embd)
  state_dict[[paste0("layer", li, ".attn_wo")]] <- make_matrix(n_embd, n_embd)
  state_dict[[paste0("layer", li, ".mlp_fc1")]] <- make_matrix(4L * n_embd, n_embd)
  state_dict[[paste0("layer", li, ".mlp_fc2")]] <- make_matrix(n_embd, 4L * n_embd)
}

params <- list()
for (mat in state_dict) {
  for (row in mat) {
    params <- c(params, row)
  }
}
cat(sprintf("num params: %d\n", length(params)))

# ---- Model Architecture ----

linear <- function(x, w) {
  lapply(w, function(wo) Reduce("+", Map("*", wo, x)))
}

softmax <- function(logits) {
  max_val <- max(vapply(logits, function(v) v$data, numeric(1L)))
  exps    <- lapply(logits, function(val) (val - max_val)$exp_val())
  total   <- Reduce("+", exps)
  lapply(exps, function(e) e / total)
}

rmsnorm <- function(x) {
  ms    <- Reduce("+", lapply(x, function(xi) xi * xi)) / length(x)
  scale <- (ms + 1e-5)^(-0.5)
  lapply(x, function(xi) xi * scale)
}

gpt <- function(token_id, pos_id, line_id, keys, values) {
  tok_emb  <- state_dict[["wte"]][[token_id + 1L]]
  pos_emb  <- state_dict[["wpe"]][[pos_id  + 1L]]
  line_emb <- state_dict[["wle"]][[line_id + 1L]]
  x <- Map(function(t, p, l) t$add(p)$add(l), tok_emb, pos_emb, line_emb)
  x <- rmsnorm(x)

  for (li in seq_len(n_layer) - 1L) {
    lk  <- as.character(li)
    idx <- li + 1L

    x_residual <- x
    x  <- rmsnorm(x)
    q  <- linear(x, state_dict[[paste0("layer", lk, ".attn_wq")]])
    k  <- linear(x, state_dict[[paste0("layer", lk, ".attn_wk")]])
    vp <- linear(x, state_dict[[paste0("layer", lk, ".attn_wv")]])

    keys[[idx]]   <- c(keys[[idx]],   list(k))
    values[[idx]] <- c(values[[idx]], list(vp))

    T_len  <- length(keys[[idx]])
    x_attn <- list()

    for (h in seq_len(n_head) - 1L) {
      hs  <- h * head_dim
      q_h <- q[(hs + 1L):(hs + head_dim)]
      k_h <- lapply(keys[[idx]],   function(ki) ki[(hs + 1L):(hs + head_dim)])
      v_h <- lapply(values[[idx]], function(vi) vi[(hs + 1L):(hs + head_dim)])

      attn_logits  <- lapply(seq_len(T_len), function(t) {
        Reduce("+", Map("*", q_h, k_h[[t]])) / sqrt(head_dim)
      })
      attn_weights <- softmax(attn_logits)

      head_out <- lapply(seq_len(head_dim), function(j) {
        Reduce("+", lapply(seq_len(T_len), function(t) attn_weights[[t]] * v_h[[t]][[j]]))
      })
      x_attn <- c(x_attn, head_out)
    }

    x <- linear(x_attn, state_dict[[paste0("layer", lk, ".attn_wo")]])
    x <- Map("+", x, x_residual)

    x_residual <- x
    x <- rmsnorm(x)
    x <- linear(x, state_dict[[paste0("layer", lk, ".mlp_fc1")]])
    x <- lapply(x, function(xi) xi$relu())
    x <- linear(x, state_dict[[paste0("layer", lk, ".mlp_fc2")]])
    x <- Map("+", x, x_residual)
  }

  logits <- linear(x, state_dict[["lm_head"]])
  list(logits = logits, keys = keys, values = values)
}

# ---- Line ID Helper ----

get_line_ids <- function(doc, line_ids_for_doc) {
  # Build token-level line_ids from the per-line line_ids stored in haiku_docs.
  # line_ids_for_doc is a length-3 integer vector (always 0L, 1L, 2L).
  # We assign each character the line_id of the line it belongs to.
  chars   <- strsplit(doc, "")[[1L]]
  line_id <- 0L
  seg     <- 0L   # which line segment we are in (0, 1, 2)
  ids     <- line_ids_for_doc[1L]   # BOS at start -> line 0
  for (ch in chars) {
    ids <- c(ids, line_ids_for_doc[seg + 1L])
    if (ch == "/") seg <- min(seg + 1L, 2L)
  }
  ids <- c(ids, line_ids_for_doc[seg + 1L])  # BOS at end -> last line
  ids
}

# ---- Adam Optimizer ----

learning_rate <- 0.01
beta1         <- 0.85
beta2         <- 0.99
eps_adam      <- 1e-8
m_buf <- rep(0.0, length(params))
v_buf <- rep(0.0, length(params))

# ---- Training Loop ----

num_steps <- 1000L
cat("Training...\n")

for (step in seq_len(num_steps)) {

  idx      <- (step - 1L) %% length(docs) + 1L
  doc      <- docs[idx]
  chars    <- strsplit(doc, "")[[1L]]
  tokens   <- c(BOS, match(chars, uchars) - 1L, BOS)
  line_ids <- get_line_ids(doc, all_line_ids[[idx]])
  n        <- min(block_size, length(tokens) - 1L)

  keys_fwd   <- lapply(seq_len(n_layer), function(i) list())
  values_fwd <- lapply(seq_len(n_layer), function(i) list())
  losses     <- list()

  for (pos_id in seq_len(n) - 1L) {
    token_id  <- tokens[pos_id + 1L]
    target_id <- tokens[pos_id + 2L]
    line_id   <- line_ids[pos_id + 1L]
    result    <- gpt(token_id, pos_id, line_id, keys_fwd, values_fwd)
    keys_fwd   <- result$keys
    values_fwd <- result$values
    probs  <- softmax(result$logits)
    loss_t <- probs[[target_id + 1L]]$log_val()$neg()
    losses <- c(losses, list(loss_t))
  }

  loss <- Reduce("+", losses) / n
  loss$backward()

  lr_t <- learning_rate * (1 - step / num_steps)
  for (i in seq_along(params)) {
    g        <- params[[i]]$grad
    m_buf[i] <- beta1 * m_buf[i] + (1 - beta1) * g
    v_buf[i] <- beta2 * v_buf[i] + (1 - beta2) * g^2
    m_hat    <- m_buf[i] / (1 - beta1^step)
    v_hat    <- v_buf[i] / (1 - beta2^step)
    params[[i]]$data <- params[[i]]$data - lr_t * m_hat / (sqrt(v_hat) + eps_adam)
    params[[i]]$grad <- 0.0
  }

  cat(sprintf("\rstep %4d / %4d | loss %.4f", step, num_steps, loss$data))
}
cat("\n")

# ---- Inference ----
# Prompt syllable count determines narrative position:
#   <=5 syllables -> line 1 (setting) -> generate line 2 (tension,  7 syl)
#   > 5 syllables -> line 2 (tension) -> generate line 3 (release,  5 syl)

generate_response <- function(prompt_line, temperature = 0.5) {
  prompt_syllables <- count_syllables(prompt_line)
  if (prompt_syllables <= 5L) {
    prompt_line_id   <- 0L   # setting
    response_line_id <- 1L   # tension
    target_syllables <- 7L
  } else {
    prompt_line_id   <- 1L   # tension
    response_line_id <- 2L   # release
    target_syllables <- 5L
  }

  keys_inf   <- lapply(seq_len(n_layer), function(i) list())
  values_inf <- lapply(seq_len(n_layer), function(i) list())

  # Build prompt token sequence: BOS + prompt chars + " / "
  prompt_str    <- paste0(prompt_line, " / ")
  prompt_chars  <- strsplit(prompt_str, "")[[1L]]
  prompt_tokens <- c(BOS, match(prompt_chars, uchars) - 1L)

  # Teacher-force prompt, tagging all tokens with prompt_line_id
  for (pos_id in seq_along(prompt_tokens) - 1L) {
    token_id   <- prompt_tokens[pos_id + 1L]
    result     <- gpt(token_id, pos_id, prompt_line_id, keys_inf, values_inf)
    keys_inf   <- result$keys
    values_inf <- result$values
  }

  # Sample response one character at a time with response_line_id
  token_id       <- prompt_tokens[length(prompt_tokens)]
  response_chars <- character(0)
  start_pos      <- length(prompt_tokens)

  for (pos_id in start_pos:(block_size - 1L)) {
    result     <- gpt(token_id, pos_id, response_line_id, keys_inf, values_inf)
    keys_inf   <- result$keys
    values_inf <- result$values
    probs      <- softmax(lapply(result$logits, function(l) l / temperature))
    weights    <- vapply(probs, function(p) p$data, numeric(1L))
    token_id   <- sample(seq_len(vocab_size) - 1L, size = 1L, prob = weights)
    if (token_id == BOS) break
    ch <- uchars[token_id + 1L]
    if (ch == "/") break
    response_chars <- c(response_chars, ch)
    # Stop once the target syllable count is reached
    if (count_syllables(paste(response_chars, collapse = "")) >= target_syllables) break
  }

  trimws(paste(response_chars, collapse = ""))
}

# Demo: sample 5 prompt lines from the dataset and generate responses
cat("--- inference (haiku line responses) ---\n")
sample_haikus <- sample(docs, 5)
for (haiku in sample_haikus) {
  lines       <- trimws(strsplit(haiku, "/")[[1L]])
  prompt_line <- lines[1]
  response    <- generate_response(prompt_line)
  syl_in  <- count_syllables(prompt_line)
  syl_out <- count_syllables(response)
  cat(sprintf("prompt   (%d syl): %s\nresponse (%d syl): %s\n\n",
              syl_in, prompt_line, syl_out, response))
}
