"""
nova_parser.py -- NovaLang recursive-descent parser (reference).

Produces a plain-data AST: every node is a dict with a "k" (kind) field.
Dicts rather than classes, because the shipping parser is GDScript and
Dictionary is the one structure both languages express identically -- which
is what lets tools/check_parity.py compare the two node vocabularies, and
what lets the conformance goldens be plain JSON.

Grammar (v2). The v1 reactor DSL is a strict subset: every existing
.nova policy still parses, and `set` / rule bodies are now just ordinary
statement lists.

    program    := decl*
    decl       := 'reactor' STRING ['version' NUMBER]
                | 'params'  assignBlock
                | 'signals' assignBlock
                | 'effects' effectBlock
                | 'rule'  NAME {mods} '{' 'when' expr 'then' stmt* '}'
                | 'fault' NAME {mods} '{' stmt* '}'
                | statement

    statement  := 'let' IDENT '=' expr
                | 'set' expr '=' expr          (v1 spelling of assignment)
                | 'func' IDENT '(' params ')' block
                | 'import' STRING ['as' IDENT]
                | 'export' (letStmt | funcDecl)
                | 'if' expr block ['else' (ifStmt | block)]
                | 'while' expr block
                | 'return' [expr]
                | 'break' | 'continue'
                | block
                | expr ['=' expr]              (bare assignment)

    expr       := 'or' level, then 'and', 'not', comparison, additive,
                  multiplicative, unary, postfix (call / index / member),
                  primary

A `{` in statement position always opens a block, never a dict literal;
parenthesise a dict used as a statement. That is the only ambiguity in the
grammar and it is resolved the same way in both implementations.
"""

from __future__ import annotations

from nova_lexer import (NovaError, Token, token_text, tokenize, TOK_EOF,
                        TOK_IDENT, TOK_KEYWORD, TOK_NUMBER, TOK_OP,
                        TOK_STRING)

# ---------------------------------------------------------------------------
# Node kind vocabulary. check_parity.py asserts the GDScript parser declares
# exactly these, so a node added on one side and not the other is caught.
# ---------------------------------------------------------------------------

NODE_KINDS = [
    # expressions
    "num", "str", "bool", "null", "list", "dict", "var", "unary", "binary",
    "call", "index", "member", "func",
    # statements
    "let", "assign", "exprstmt", "if", "while", "return", "break",
    "continue", "block", "import",
]


class Program:
    """One parsed .nova file."""

    def __init__(self, name: str = "<source>"):
        self.name = name
        self.title = "UNNAMED REACTOR"
        self.version = 1
        self.params = []        # [(name, expr)]
        self.effects = []       # [(name, expr, persistent)]
        self.signal_defs = []   # [(name, expr)]
        self.rules = []
        self.faults = []
        self.statements = []    # top-level statements, run at load
        self.held_slots = 0
        self.exports = []       # names marked `export`


class Parser:
    def __init__(self, tokens, program: Program):
        self.toks = tokens
        self.i = 0
        self.prog = program

    # -- token helpers ------------------------------------------------------

    @property
    def cur(self) -> Token:
        return self.toks[self.i]

    def at(self, kind, value=None) -> bool:
        t = self.toks[self.i]
        return t.kind == kind and (value is None or t.value == value)

    def accept(self, kind, value=None):
        if self.at(kind, value):
            self.i += 1
            return True
        return False

    def expect(self, kind, value=None) -> Token:
        if self.at(kind, value):
            t = self.toks[self.i]
            self.i += 1
            return t
        want = value if value is not None else kind
        raise NovaError("line %d: expected '%s', got '%s'"
                        % (self.cur.line, want, token_text(self.cur.value)))

    def name_token(self) -> Token:
        """Rule and fault names may look like keywords."""
        t = self.cur
        if t.kind in (TOK_IDENT, TOK_KEYWORD):
            self.i += 1
            return t
        raise NovaError("line %d: expected a name, got '%s'"
                        % (t.line, token_text(t.value)))

    # -- top level ----------------------------------------------------------

    def parse(self) -> Program:
        while not self.at(TOK_EOF):
            if self.accept(TOK_KEYWORD, "reactor"):
                self.prog.title = self.expect(TOK_STRING).value
                if self.accept(TOK_KEYWORD, "version"):
                    self.prog.version = int(self.expect(TOK_NUMBER).value)
            elif self.accept(TOK_KEYWORD, "params"):
                self.prog.params.extend(self._assign_block())
            elif self.accept(TOK_KEYWORD, "signals"):
                self.prog.signal_defs.extend(self._assign_block())
            elif self.accept(TOK_KEYWORD, "effects"):
                self.prog.effects.extend(self._effect_block())
            elif self.accept(TOK_KEYWORD, "rule"):
                self.prog.rules.append(self._rule())
            elif self.accept(TOK_KEYWORD, "fault"):
                self.prog.faults.append(self._fault())
            else:
                self.prog.statements.append(self._statement())
        self.prog.rules.sort(key=lambda r: -r["priority"])
        return self.prog

    def _assign_block(self):
        self.expect(TOK_OP, "{")
        out = []
        while not self.accept(TOK_OP, "}"):
            if self.at(TOK_EOF):
                raise NovaError("line %d: unterminated block" % self.cur.line)
            name = self.expect(TOK_IDENT).value
            self.expect(TOK_OP, "=")
            out.append((name, self.expr()))
        return out

    def _effect_block(self):
        self.expect(TOK_OP, "{")
        out = []
        while not self.accept(TOK_OP, "}"):
            if self.at(TOK_EOF):
                raise NovaError("line %d: unterminated effects block"
                                % self.cur.line)
            name = self.expect(TOK_IDENT).value
            self.expect(TOK_OP, "=")
            value = self.expr()
            persistent = self.accept(TOK_KEYWORD, "persistent")
            out.append((name, value, persistent))
        return out

    def _rule(self):
        line = self.cur.line
        name = self.name_token().value
        priority, once, edge = 0.0, False, False
        while True:
            if self.accept(TOK_KEYWORD, "priority"):
                priority = self.expect(TOK_NUMBER).value
            elif self.accept(TOK_KEYWORD, "once"):
                once = True
            elif self.accept(TOK_KEYWORD, "edge"):
                edge = True
            else:
                break
        self.expect(TOK_OP, "{")
        self.expect(TOK_KEYWORD, "when")
        cond = self.expr()
        self.expect(TOK_KEYWORD, "then")
        body = self._statements_until_brace()
        return {"name": name, "priority": priority, "once": once, "edge": edge,
                "cond": cond, "body": body, "fired": False, "was_true": False,
                "line": line}

    def _fault(self):
        line = self.cur.line
        name = self.name_token().value
        weight = 1.0
        duration = {"k": "num", "v": 30.0}
        label = name.replace("_", " ").upper()
        while True:
            if self.accept(TOK_KEYWORD, "weight"):
                weight = self.expect(TOK_NUMBER).value
            elif self.accept(TOK_KEYWORD, "duration"):
                duration = self.expr()
            elif self.accept(TOK_KEYWORD, "label"):
                label = self.expect(TOK_STRING).value
            else:
                break
        self.expect(TOK_OP, "{")
        body = self._statements_until_brace()
        return {"name": name, "weight": weight, "duration": duration,
                "label": label, "body": body, "line": line}

    def _statements_until_brace(self):
        out = []
        while not self.accept(TOK_OP, "}"):
            if self.at(TOK_EOF):
                raise NovaError("line %d: unterminated block" % self.cur.line)
            out.append(self._statement())
        return out

    # -- statements ---------------------------------------------------------

    def _block(self):
        self.expect(TOK_OP, "{")
        return {"k": "block", "body": self._statements_until_brace()}

    def _statement(self):
        line = self.cur.line

        if self.accept(TOK_KEYWORD, "let"):
            return self._let(line, False)

        if self.accept(TOK_KEYWORD, "func"):
            return self._func_decl(line, False)

        if self.accept(TOK_KEYWORD, "export"):
            if self.accept(TOK_KEYWORD, "let"):
                return self._let(line, True)
            if self.accept(TOK_KEYWORD, "func"):
                return self._func_decl(line, True)
            raise NovaError("line %d: export must be followed by let or func"
                            % line)

        if self.accept(TOK_KEYWORD, "import"):
            path = self.expect(TOK_STRING).value
            alias = ""
            if self.accept(TOK_KEYWORD, "as"):
                alias = self.expect(TOK_IDENT).value
            return {"k": "import", "path": path, "alias": alias, "line": line}

        if self.accept(TOK_KEYWORD, "set"):
            target = self.expr()
            self.expect(TOK_OP, "=")
            return {"k": "assign", "target": target, "expr": self.expr(),
                    "line": line}

        if self.accept(TOK_KEYWORD, "if"):
            return self._if(line)

        if self.accept(TOK_KEYWORD, "while"):
            cond = self.expr()
            return {"k": "while", "cond": cond, "body": self._block(),
                    "line": line}

        if self.accept(TOK_KEYWORD, "return"):
            value = None
            if not self.at(TOK_OP, "}") and not self.at(TOK_EOF):
                value = self.expr()
            return {"k": "return", "expr": value, "line": line}

        if self.accept(TOK_KEYWORD, "break"):
            return {"k": "break", "line": line}

        if self.accept(TOK_KEYWORD, "continue"):
            return {"k": "continue", "line": line}

        if self.at(TOK_OP, "{"):
            return self._block()

        # Expression statement, or a bare assignment to an lvalue.
        node = self.expr()
        if self.accept(TOK_OP, "="):
            return {"k": "assign", "target": node, "expr": self.expr(),
                    "line": line}
        return {"k": "exprstmt", "expr": node, "line": line}

    def _let(self, line, exported):
        name = self.expect(TOK_IDENT).value
        self.expect(TOK_OP, "=")
        if exported:
            self.prog.exports.append(name)
        return {"k": "let", "name": name, "expr": self.expr(),
                "exported": exported, "line": line}

    def _func_decl(self, line, exported):
        name = self.expect(TOK_IDENT).value
        params = self._param_list()
        body = self._block()
        if exported:
            self.prog.exports.append(name)
        fn = {"k": "func", "name": name, "params": params, "body": body,
              "line": line}
        # A named function declaration is sugar for `let <name> = func...`,
        # which is what makes recursion and closures fall out for free.
        return {"k": "let", "name": name, "expr": fn, "exported": exported,
                "line": line}

    def _param_list(self):
        self.expect(TOK_OP, "(")
        params = []
        if not self.at(TOK_OP, ")"):
            params.append(self.expect(TOK_IDENT).value)
            while self.accept(TOK_OP, ","):
                params.append(self.expect(TOK_IDENT).value)
        self.expect(TOK_OP, ")")
        return params

    def _if(self, line):
        cond = self.expr()
        then_block = self._block()
        else_block = None
        if self.accept(TOK_KEYWORD, "else"):
            if self.accept(TOK_KEYWORD, "if"):
                else_block = {"k": "block", "body": [self._if(self.cur.line)]}
            else:
                else_block = self._block()
        return {"k": "if", "cond": cond, "then": then_block,
                "else": else_block, "line": line}

    # -- expressions --------------------------------------------------------

    def expr(self):
        return self._or()

    def _or(self):
        node = self._and()
        while self.accept(TOK_KEYWORD, "or"):
            node = {"k": "binary", "op": "or", "a": node, "b": self._and()}
        return node

    def _and(self):
        node = self._not()
        while self.accept(TOK_KEYWORD, "and"):
            node = {"k": "binary", "op": "and", "a": node, "b": self._not()}
        return node

    def _not(self):
        if self.accept(TOK_KEYWORD, "not"):
            return {"k": "unary", "op": "not", "a": self._not()}
        return self._comparison()

    def _comparison(self):
        node = self._additive()
        while self.cur.kind == TOK_OP and self.cur.value in (
                "<", ">", "<=", ">=", "==", "!="):
            op = self.cur.value
            self.i += 1
            node = {"k": "binary", "op": op, "a": node, "b": self._additive()}
        return node

    def _additive(self):
        node = self._multiplicative()
        while self.cur.kind == TOK_OP and self.cur.value in ("+", "-"):
            op = self.cur.value
            self.i += 1
            node = {"k": "binary", "op": op, "a": node,
                    "b": self._multiplicative()}
        return node

    def _multiplicative(self):
        node = self._unary()
        while self.cur.kind == TOK_OP and self.cur.value in ("*", "/", "%"):
            op = self.cur.value
            self.i += 1
            node = {"k": "binary", "op": op, "a": node, "b": self._unary()}
        return node

    def _unary(self):
        if self.accept(TOK_OP, "-"):
            return {"k": "unary", "op": "-", "a": self._unary()}
        if self.accept(TOK_OP, "+"):
            return self._unary()
        return self._postfix()

    def _postfix(self):
        node = self._primary()
        while True:
            line = self.cur.line
            if self.accept(TOK_OP, "("):
                args = self._arg_list()
                slot = -1
                # held() is a special form: it needs a stable per-call-site
                # timer, allocated once here at parse time.
                if node.get("k") == "var" and node.get("name") == "held":
                    slot = self.prog.held_slots
                    self.prog.held_slots += 1
                node = {"k": "call", "callee": node, "args": args,
                        "slot": slot, "line": line}
            elif self.accept(TOK_OP, "["):
                idx = self.expr()
                self.expect(TOK_OP, "]")
                node = {"k": "index", "obj": node, "idx": idx, "line": line}
            elif self.accept(TOK_OP, "."):
                name = self.name_token().value
                node = {"k": "member", "obj": node, "name": name, "line": line}
            else:
                return node

    def _arg_list(self):
        args = []
        if not self.at(TOK_OP, ")"):
            args.append(self.expr())
            while self.accept(TOK_OP, ","):
                if self.at(TOK_OP, ")"):
                    break            # tolerate a trailing comma
                args.append(self.expr())
        self.expect(TOK_OP, ")")
        return args

    def _primary(self):
        t = self.cur
        line = t.line

        if t.kind == TOK_NUMBER:
            self.i += 1
            return {"k": "num", "v": t.value}
        if t.kind == TOK_STRING:
            self.i += 1
            return {"k": "str", "v": t.value}
        if self.accept(TOK_KEYWORD, "true"):
            return {"k": "bool", "v": True}
        if self.accept(TOK_KEYWORD, "false"):
            return {"k": "bool", "v": False}
        if self.accept(TOK_KEYWORD, "null"):
            return {"k": "null"}

        if self.accept(TOK_KEYWORD, "func"):        # anonymous function
            params = self._param_list()
            body = self._block()
            return {"k": "func", "name": "", "params": params, "body": body,
                    "line": line}

        if self.accept(TOK_OP, "("):
            node = self.expr()
            self.expect(TOK_OP, ")")
            return node

        if self.accept(TOK_OP, "["):
            items = []
            if not self.at(TOK_OP, "]"):
                items.append(self.expr())
                while self.accept(TOK_OP, ","):
                    if self.at(TOK_OP, "]"):
                        break
                    items.append(self.expr())
            self.expect(TOK_OP, "]")
            return {"k": "list", "items": items}

        if self.accept(TOK_OP, "{"):
            pairs = []
            if not self.at(TOK_OP, "}"):
                pairs.append(self._dict_pair())
                while self.accept(TOK_OP, ","):
                    if self.at(TOK_OP, "}"):
                        break
                    pairs.append(self._dict_pair())
            self.expect(TOK_OP, "}")
            return {"k": "dict", "pairs": pairs}

        if t.kind == TOK_IDENT:
            self.i += 1
            return {"k": "var", "name": t.value, "line": line}

        raise NovaError("line %d: unexpected '%s' in expression"
                        % (line, token_text(t.value)))

    def _dict_pair(self):
        """Keys may be bare identifiers, string literals, or a bracketed
        expression for a computed key."""
        if self.accept(TOK_OP, "["):
            key = self.expr()
            self.expect(TOK_OP, "]")
        elif self.cur.kind == TOK_STRING:
            key = {"k": "str", "v": self.expect(TOK_STRING).value}
        else:
            key = {"k": "str", "v": self.name_token().value}
        self.expect(TOK_OP, ":")
        return [key, self.expr()]


def parse(src: str, name: str = "<source>") -> Program:
    prog = Program(name)
    return Parser(tokenize(src), prog).parse()
