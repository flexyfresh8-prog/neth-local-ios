"""Token accounting.

The host ships without a model-specific tokenizer to keep the executable small;
counts use the standard ~4 characters-per-token estimate, which tracks GPT-OSS
within a useful margin for budgeting. The backend's own usage numbers are
preferred whenever a response includes them.
"""
from __future__ import annotations

import math

CHARS_PER_TOKEN = 4


def estimate_tokens(text: str) -> int:
    if not text:
        return 0
    return max(1, math.ceil(len(text) / CHARS_PER_TOKEN))
