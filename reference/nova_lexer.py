"""
nova_lexer.py -- NovaLang tokenizer (reference implementation).

This file is the *specification* half of a pair. The shipping interpreter
is godot/scripts/nova/nova_lexer.gd; this one exists so the language has a
runnable oracle that CI can test against, and so tools/check_parity.py can
diff the two token vocabularies mechanically. Nothing in the game imports
it, and no Godot build contains it.

Keep the two files structurally aligned: same token kinds, same keyword
set, same operator set, same escape sequences, same error wording.
"""

from __future__ import annotations

import math


class NovaError(Exception):
    """Any lexer, parser or runtime problem in a .nova program."""


def number_text(v: float) -> str:
    """Integers print without a decimal point; everything else gets up to
    six decimal places with trailing zeros trimmed.

    Defined explicitly, here where numbers are parsed, because '%g',
    str(float) and GDScript's str() all disagree -- and a diagnostic that
    reads differently in the two runtimes is a parity failure.
    """
    if v != v:
        return "nan"
    if v == float("inf"):
        return "inf"
    if v == float("-inf"):
        return "-inf"
    if v == math.floor(v) and abs(v) < 1e15:
        return str(int(v))
    s = "%.6f" % v
    while s.endswith("0"):
        s = s[:-1]
    if s.endswith("."):
        s = s[:-1]
    return s


def token_text(value) -> str:
    """How a token appears inside a parser diagnostic."""
    if value is None:
        return "eof"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        return number_text(value)
    return str(value)


# Keywords. Anything here can still be used as a *rule* or *fault* name --
# the parser accepts a keyword token where a declaration name is expected --
# but not as a variable.
KEYWORDS = {
    # v1 reactor DSL
    "reactor", "version", "params", "effects", "signals", "rule", "fault",
    "when", "then", "set", "priority", "once", "edge", "weight", "duration",
    "label", "persistent",
    # operators that read as words
    "and", "or", "not",
    # literals
    "true", "false", "null",
    # v2 imperative core
    "let", "func", "return", "if", "else", "while", "break", "continue",
    "import", "export", "as",
}

# Longest-first, so "<=" wins over "<".
OPERATORS = [
    "==", "!=", "<=", ">=",
    "+", "-", "*", "/", "%", "<", ">", "=",
    "(", ")", "{", "}", "[", "]", ",", ".", ":",
]

ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}

TOK_NUMBER = "number"
TOK_STRING = "string"
TOK_IDENT = "ident"
TOK_KEYWORD = "keyword"
TOK_OP = "op"
TOK_EOF = "eof"


class Token:
    __slots__ = ("kind", "value", "line")

    def __init__(self, kind, value, line):
        self.kind = kind
        self.value = value
        self.line = line

    def __repr__(self):  # pragma: no cover - debugging aid
        return "Token(%s, %r, line %d)" % (self.kind, self.value, self.line)


def _is_digit(c: str) -> bool:
    return "0" <= c <= "9"


def _is_alpha(c: str) -> bool:
    return c == "_" or ("a" <= c <= "z") or ("A" <= c <= "Z")


def _is_alnum(c: str) -> bool:
    return _is_alpha(c) or _is_digit(c)


def tokenize(src: str) -> list:
    """Hand-written scanner -- no regex, because the GDScript half has no
    equivalent regex dialect and the two must agree character for
    character."""
    tokens = []
    i = 0
    line = 1
    n = len(src)

    while i < n:
        c = src[i]

        if c in " \t\r\n":
            if c == "\n":
                line += 1
            i += 1
            continue

        # Comments: `#` and `//` both run to end of line.
        if c == "#" or (c == "/" and i + 1 < n and src[i + 1] == "/"):
            while i < n and src[i] != "\n":
                i += 1
            continue

        if _is_digit(c) or (c == "." and i + 1 < n and _is_digit(src[i + 1])):
            start = i
            while i < n and _is_digit(src[i]):
                i += 1
            if i < n and src[i] == ".":
                i += 1
                while i < n and _is_digit(src[i]):
                    i += 1
            if i < n and src[i] in "eE":
                save = i
                i += 1
                if i < n and src[i] in "+-":
                    i += 1
                if i < n and _is_digit(src[i]):
                    while i < n and _is_digit(src[i]):
                        i += 1
                else:
                    i = save        # "2e" is the number 2 followed by `e`
            tokens.append(Token(TOK_NUMBER, float(src[start:i]), line))
            continue

        if c == '"':
            i += 1
            buf = []
            while i < n and src[i] != '"':
                ch = src[i]
                if ch == "\\" and i + 1 < n:
                    i += 1
                    buf.append(ESCAPES.get(src[i], src[i]))
                else:
                    if ch == "\n":
                        line += 1
                    buf.append(ch)
                i += 1
            if i >= n:
                raise NovaError("line %d: unterminated string literal" % line)
            i += 1
            tokens.append(Token(TOK_STRING, "".join(buf), line))
            continue

        if _is_alpha(c):
            start = i
            while i < n and _is_alnum(src[i]):
                i += 1
            word = src[start:i]
            kind = TOK_KEYWORD if word in KEYWORDS else TOK_IDENT
            tokens.append(Token(kind, word, line))
            continue

        matched = None
        for op in OPERATORS:
            if src.startswith(op, i):
                matched = op
                break
        if matched is None:
            raise NovaError("line %d: unexpected character '%s'" % (line, c))
        tokens.append(Token(TOK_OP, matched, line))
        i += len(matched)

    tokens.append(Token(TOK_EOF, None, line))
    return tokens
