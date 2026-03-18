# microgpt.R
# Translation of karpathy/microgpt.py to R
# The most atomic way to train and run inference for a GPT in pure R.
# Requires the R6 package.

library(R6)

set.seed(7391)

# ---- Dataset ----

if (!file.exists("input.txt")) {
  download.file(
    "https://raw.githubusercontent.com/karpathy/makemore/988aa59/names.txt",
    "input.txt"
  )
}
docs <- readLines("input.txt", warn = FALSE)
docs <- docs[nchar(trimws(docs)) > 0]
docs <- sample(docs)
cat(sprintf("num docs: %d\n", length(docs)))

# ---- Tokenizer ----

uchars     <- sort(unique(strsplit(paste(docs, collapse = ""), "")[[1]]))
BOS        <- length(uchars)       # 0-based token id for Beginning of Sequence
vocab_size <- length(uchars) + 1L
cat(sprintf("vocab size: %d\n", vocab_size))

# ---- Autograd ----
# Value is a node in the computation graph. Each node holds its scalar value
# and, after backward(), the gradient of the loss with respect to that node.

.vid <- 0L  # global node id counter

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

# S3 operator overloading so Value objects work with +, -, *, /, ^
`+.Value` <- function(a, b) { if (is.numeric(a)) a <- Value$new(a); if (is.numeric(b)) b <- Value$new(b); a$add(b) }
`*.Value` <- function(a, b) { if (is.numeric(a)) a <- Value$new(a); if (is.numeric(b)) b <- Value$new(b); a$mul(b) }
`-.Value` <- function(a, b) { if (missing(b)) return(a$neg()); if (is.numeric(b)) b <- Value$new(b); a$sub(b) }
`/.Value` <- function(a, b) { if (is.numeric(a)) a <- Value$new(a); if (is.numeric(b)) b <- Value$new(b); a$div(b) }
`^.Value` <- function(a, b) a$pow_val(b)

# ---- Model Parameters ----

n_layer    <- 1L
n_embd     <- 16L
block_size <- 16L
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

# Flatten all Value nodes into a single list (mirrors Python's list[Value])
params <- list()
for (mat in state_dict) {
  for (row in mat) {
    params <- c(params, row)
  }
}
cat(sprintf("num params: %d\n", length(params)))

# ---- Model Architecture ----

linear <- function(x, w) {
  # Matrix-vector multiply: one dot product per row of w
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

# gpt() returns a list(logits, keys, values) because R is pass-by-value,
# unlike Python where list.append() mutates in place.
gpt <- function(token_id, pos_id, keys, values) {
  tok_emb <- state_dict[["wte"]][[token_id + 1L]]   # token_id is 0-based
  pos_emb <- state_dict[["wpe"]][[pos_id  + 1L]]
  x <- Map("+", tok_emb, pos_emb)
  x <- rmsnorm(x)

  for (li in seq_len(n_layer) - 1L) {
    lk <- as.character(li)
    idx <- li + 1L  # 1-based index into keys / values lists

    # 1) Multi-head Attention
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

    # 2) MLP block
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

  doc    <- docs[(step - 1L) %% length(docs) + 1L]
  chars  <- strsplit(doc, "")[[1L]]
  tokens <- c(BOS, match(chars, uchars) - 1L, BOS)  # 0-based token ids
  n      <- min(block_size, length(tokens) - 1L)

  # Forward pass — build computation graph
  keys_fwd   <- lapply(seq_len(n_layer), function(i) list())
  values_fwd <- lapply(seq_len(n_layer), function(i) list())
  losses     <- list()

  for (pos_id in seq_len(n) - 1L) {
    token_id  <- tokens[pos_id + 1L]
    target_id <- tokens[pos_id + 2L]
    result    <- gpt(token_id, pos_id, keys_fwd, values_fwd)
    keys_fwd   <- result$keys
    values_fwd <- result$values
    probs  <- softmax(result$logits)
    loss_t <- probs[[target_id + 1L]]$log_val()$neg()
    losses <- c(losses, list(loss_t))
  }

  loss <- Reduce("+", losses) / n

  # Backward pass
  loss$backward()

  # Adam update with linear learning rate decay
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

temperature <- 0.5
cat("--- inference (new, hallucinated names) ---\n")

for (sample_idx in seq_len(20L)) {
  keys_inf   <- lapply(seq_len(n_layer), function(i) list())
  values_inf <- lapply(seq_len(n_layer), function(i) list())
  token_id   <- BOS
  sample_chars <- character(0)

  for (pos_id in seq_len(block_size) - 1L) {
    result     <- gpt(token_id, pos_id, keys_inf, values_inf)
    keys_inf   <- result$keys
    values_inf <- result$values
    probs      <- softmax(lapply(result$logits, function(l) l / temperature))
    weights    <- vapply(probs, function(p) p$data, numeric(1L))
    token_id   <- sample(seq_len(vocab_size) - 1L, size = 1L, prob = weights)
    if (token_id == BOS) break
    sample_chars <- c(sample_chars, uchars[token_id + 1L])
  }

  cat(sprintf("sample %2d: %s\n", sample_idx, paste(sample_chars, collapse = "")))
}
