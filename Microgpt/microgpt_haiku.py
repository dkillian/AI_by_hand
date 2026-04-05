"""
microgpt_haiku.py
Adapts microgpt.py for haiku line-to-line generation.
Each training document is a full haiku ("line1 / line2 / line3").

A learned line embedding (wle) encodes narrative role:
  line 0 → setting  (5 syllables)
  line 1 → tension  (7 syllables)
  line 2 → release  (5 syllables)

At inference, the syllable count of the prompt determines which line it is,
and generation stops once the target syllable count for the response is reached.
"""

import os
import csv
import math
import random
random.seed(8142)

# ---- Dataset ----

haiku_path = os.path.join(
    os.path.dirname(__file__),
    "../../Embedded Poet/data/Poetry/haikus.csv"
)

docs = []
with open(haiku_path, newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for row in reader:
        text = row.get('text', '').strip()
        if text:
            docs.append(text)

random.shuffle(docs)
print(f"num docs: {len(docs)}")

# ---- Tokenizer ----

uchars     = sorted(set(''.join(docs)))
BOS        = len(uchars)        # Beginning-of-sequence token id
vocab_size = len(uchars) + 1
print(f"vocab size: {vocab_size}")

# ---- Syllable Counter ----
# Uses the CMU Pronouncing Dictionary via pronouncing; falls back to a
# vowel-group heuristic for words not in the dictionary.

import pronouncing

def _syllable_heuristic(word):
    count, prev_vowel = 0, False
    for ch in word.lower():
        is_vowel = ch in 'aeiouy'
        if is_vowel and not prev_vowel:
            count += 1
        prev_vowel = is_vowel
    if word.endswith('e') and not word.endswith('le') and count > 1:
        count -= 1
    return max(1, count)

def count_syllables(text):
    total = 0
    for word in text.strip().split():
        phones = pronouncing.phones_for_word(word.lower())
        if phones:
            total += pronouncing.syllable_count(phones[0])
        else:
            total += _syllable_heuristic(word)
    return total

# ---- Autograd ----

class Value:
    __slots__ = ('data', 'grad', '_children', '_local_grads')

    def __init__(self, data, children=(), local_grads=()):
        self.data         = data
        self.grad         = 0
        self._children    = children
        self._local_grads = local_grads

    def __add__(self, other):
        other = other if isinstance(other, Value) else Value(other)
        return Value(self.data + other.data, (self, other), (1, 1))

    def __mul__(self, other):
        other = other if isinstance(other, Value) else Value(other)
        return Value(self.data * other.data, (self, other), (other.data, self.data))

    def __pow__(self, other): return Value(self.data**other, (self,), (other * self.data**(other-1),))
    def log(self):  return Value(math.log(self.data), (self,), (1/self.data,))
    def exp(self):  return Value(math.exp(self.data), (self,), (math.exp(self.data),))
    def relu(self): return Value(max(0, self.data), (self,), (float(self.data > 0),))
    def __neg__(self):             return self * -1
    def __radd__(self, other):     return self + other
    def __sub__(self, other):      return self + (-other)
    def __rsub__(self, other):     return other + (-self)
    def __rmul__(self, other):     return self * other
    def __truediv__(self, other):  return self * other**-1
    def __rtruediv__(self, other): return other * self**-1

    def backward(self):
        topo, visited = [], set()
        def build_topo(v):
            if v not in visited:
                visited.add(v)
                for child in v._children:
                    build_topo(child)
                topo.append(v)
        build_topo(self)
        self.grad = 1
        for v in reversed(topo):
            for child, local_grad in zip(v._children, v._local_grads):
                child.grad += local_grad * v.grad

# ---- Model Parameters ----
# block_size is larger than microgpt.py to accommodate full haiku length (~120 chars max).

n_layer    = 1
n_embd     = 16
block_size = 128
n_head     = 4
head_dim   = n_embd // n_head

matrix     = lambda nout, nin, std=0.08: [[Value(random.gauss(0, std)) for _ in range(nin)] for _ in range(nout)]
state_dict = {
    'wte':     matrix(vocab_size, n_embd),
    'wpe':     matrix(block_size, n_embd),
    'wle':     matrix(3, n_embd),            # line embeddings: 0=setting, 1=tension, 2=release
    'lm_head': matrix(vocab_size, n_embd),
}
for i in range(n_layer):
    state_dict[f'layer{i}.attn_wq'] = matrix(n_embd, n_embd)
    state_dict[f'layer{i}.attn_wk'] = matrix(n_embd, n_embd)
    state_dict[f'layer{i}.attn_wv'] = matrix(n_embd, n_embd)
    state_dict[f'layer{i}.attn_wo'] = matrix(n_embd, n_embd)
    state_dict[f'layer{i}.mlp_fc1'] = matrix(4 * n_embd, n_embd)
    state_dict[f'layer{i}.mlp_fc2'] = matrix(n_embd, 4 * n_embd)

params = [p for mat in state_dict.values() for row in mat for p in row]
print(f"num params: {len(params)}")

# ---- Model Architecture ----

def linear(x, w):
    return [sum(wi * xi for wi, xi in zip(wo, x)) for wo in w]

def softmax(logits):
    max_val = max(val.data for val in logits)
    exps    = [(val - max_val).exp() for val in logits]
    total   = sum(exps)
    return [e / total for e in exps]

def rmsnorm(x):
    ms    = sum(xi * xi for xi in x) / len(x)
    scale = (ms + 1e-5) ** -0.5
    return [xi * scale for xi in x]

def gpt(token_id, pos_id, line_id, keys, values):
    tok_emb  = state_dict['wte'][token_id]
    pos_emb  = state_dict['wpe'][pos_id]
    line_emb = state_dict['wle'][line_id]
    x = [t + p + l for t, p, l in zip(tok_emb, pos_emb, line_emb)]
    x = rmsnorm(x)

    for li in range(n_layer):
        x_residual = x
        x = rmsnorm(x)
        q = linear(x, state_dict[f'layer{li}.attn_wq'])
        k = linear(x, state_dict[f'layer{li}.attn_wk'])
        v = linear(x, state_dict[f'layer{li}.attn_wv'])
        keys[li].append(k)
        values[li].append(v)

        x_attn = []
        for h in range(n_head):
            hs  = h * head_dim
            q_h = q[hs:hs+head_dim]
            k_h = [ki[hs:hs+head_dim] for ki in keys[li]]
            v_h = [vi[hs:hs+head_dim] for vi in values[li]]
            attn_logits  = [sum(q_h[j] * k_h[t][j] for j in range(head_dim)) / head_dim**0.5 for t in range(len(k_h))]
            attn_weights = softmax(attn_logits)
            head_out     = [sum(attn_weights[t] * v_h[t][j] for t in range(len(v_h))) for j in range(head_dim)]
            x_attn.extend(head_out)

        x = linear(x_attn, state_dict[f'layer{li}.attn_wo'])
        x = [a + b for a, b in zip(x, x_residual)]

        x_residual = x
        x = rmsnorm(x)
        x = linear(x, state_dict[f'layer{li}.mlp_fc1'])
        x = [xi.relu() for xi in x]
        x = linear(x, state_dict[f'layer{li}.mlp_fc2'])
        x = [a + b for a, b in zip(x, x_residual)]

    return linear(x, state_dict['lm_head'])

# ---- Line ID Helper ----

def get_line_ids(doc):
    """Assign line_id (0, 1, 2) to each token in [BOS] + doc_chars + [BOS].
    Increments after each '/' separator character."""
    line_id = 0
    ids = [0]           # BOS at start → line 0
    for ch in doc:
        ids.append(line_id)
        if ch == '/':
            line_id = min(line_id + 1, 2)
    ids.append(line_id) # BOS at end → last line
    return ids

# ---- Adam Optimizer ----

learning_rate, beta1, beta2, eps_adam = 0.01, 0.85, 0.99, 1e-8
m = [0.0] * len(params)
v = [0.0] * len(params)

# ---- Training Loop ----

num_steps = 1000
for step in range(num_steps):

    doc      = docs[step % len(docs)]
    tokens   = [BOS] + [uchars.index(ch) for ch in doc] + [BOS]
    line_ids = get_line_ids(doc)
    n        = min(block_size, len(tokens) - 1)

    keys_fwd   = [[] for _ in range(n_layer)]
    values_fwd = [[] for _ in range(n_layer)]
    losses     = []

    for pos_id in range(n):
        token_id, target_id = tokens[pos_id], tokens[pos_id + 1]
        line_id = line_ids[pos_id]
        logits  = gpt(token_id, pos_id, line_id, keys_fwd, values_fwd)
        probs   = softmax(logits)
        losses.append(-probs[target_id].log())

    loss = (1 / n) * sum(losses)
    loss.backward()

    lr_t = learning_rate * (1 - step / num_steps)
    for i, p in enumerate(params):
        m[i] = beta1 * m[i] + (1 - beta1) * p.grad
        v[i] = beta2 * v[i] + (1 - beta2) * p.grad ** 2
        m_hat = m[i] / (1 - beta1 ** (step + 1))
        v_hat = v[i] / (1 - beta2 ** (step + 1))
        p.data -= lr_t * m_hat / (v_hat ** 0.5 + eps_adam)
        p.grad  = 0

    print(f"step {step+1:4d} / {num_steps:4d} | loss {loss.data:.4f}", end='\r')

print()

# ---- Inference ----
# Prompt syllable count determines narrative position:
#   ≤5 syllables → line 1 (setting)  → generate line 2 (tension,  7 syl)
#   >5 syllables → line 2 (tension)  → generate line 3 (release,  5 syl)

def generate_response(prompt_line, temperature=0.5):
    prompt_syllables = count_syllables(prompt_line)
    if prompt_syllables <= 5:
        prompt_line_id   = 0   # setting
        response_line_id = 1   # tension
        target_syllables = 7
    else:
        prompt_line_id   = 1   # tension
        response_line_id = 2   # release
        target_syllables = 5

    keys_inf   = [[] for _ in range(n_layer)]
    values_inf = [[] for _ in range(n_layer)]

    # Tokenize: BOS + prompt chars + " / "
    prompt_str    = prompt_line + " / "
    prompt_tokens = [BOS] + [uchars.index(ch) for ch in prompt_str]

    # Teacher-force prompt, tagging all tokens with prompt_line_id
    for pos_id, token_id in enumerate(prompt_tokens):
        gpt(token_id, pos_id, prompt_line_id, keys_inf, values_inf)

    # Sample response one character at a time with response_line_id
    token_id       = prompt_tokens[-1]
    response_chars = []
    start_pos      = len(prompt_tokens)

    for pos_id in range(start_pos, block_size):
        logits   = gpt(token_id, pos_id, response_line_id, keys_inf, values_inf)
        probs    = softmax([l / temperature for l in logits])
        token_id = random.choices(range(vocab_size), weights=[p.data for p in probs])[0]
        if token_id == BOS:
            break
        ch = uchars[token_id]
        if ch == '/':
            break
        response_chars.append(ch)
        # Stop once the target syllable count is reached
        if count_syllables(''.join(response_chars)) >= target_syllables:
            break

    return ''.join(response_chars).strip()

# Demo: sample 5 prompt lines from the dataset and generate responses
print("\n--- inference (haiku line responses) ---")
for haiku in random.sample(docs, 5):
    lines       = [l.strip() for l in haiku.split('/')]
    prompt_line = lines[0]
    response    = generate_response(prompt_line)
    syl_in  = count_syllables(prompt_line)
    syl_out = count_syllables(response)
    print(f"prompt   ({syl_in} syl): {prompt_line}")
    print(f"response ({syl_out} syl): {response}\n")
