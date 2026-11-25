#!/usr/bin/env python3
"""Print import<TAB>file<TAB>module<TAB>scope for each import of the files under <root> named on stdin.

Usage: python3 -I -S py_imports.py <root> <NUL-separated file names | --stdlib
Scopes are module, function, optional and typing; files that do not parse give error<TAB>file<TAB>message.
--stdlib prints the modules of the standard library, also those built into the interpreter, as sys.
"""

import ast
import os
import sys

OPTIONAL_ERRORS = {"ImportError", "ModuleNotFoundError", "Exception", "BaseException"}
PLATFORM = {"sys.platform": "linux", "os.name": "posix", "platform.system()": "Linux"}


def dotted(node):
    """Return the dotted name of a Name or Attribute chain, or None."""
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if not isinstance(node, ast.Name):
        return None
    parts.append(node.id)
    return ".".join(reversed(parts))


def catches_import_errors(handler):
    """Return True when an except clause catches the errors of a failed import."""
    if handler.type is None:
        return True
    types = handler.type.elts if isinstance(handler.type, ast.Tuple) else [handler.type]
    return any((dotted(t) or "").split(".")[-1] in OPTIONAL_ERRORS for t in types)


def suppresses_import_errors(item):
    """Return True for a with item suppress(ImportError) or contextlib.suppress(...)."""
    call = item.context_expr
    if not isinstance(call, ast.Call) or dotted(call.func) not in ("suppress", "contextlib.suppress"):
        return False
    return any((dotted(arg) or "").split(".")[-1] in OPTIONAL_ERRORS for arg in call.args)


def operand(node):
    """Return the value of an operand of a test, or a marker for an unknown one."""
    if isinstance(node, ast.Constant) and isinstance(node.value, (str, int)):
        return node.value
    if isinstance(node, ast.Tuple):
        values = [operand(e) for e in node.elts]
        return tuple(values) if all(v is not UNKNOWN for v in values) else UNKNOWN
    name = dotted(node)
    if name == "sys.version_info":
        return tuple(sys.version_info)
    if name in PLATFORM:
        return PLATFORM[name]
    if isinstance(node, ast.Call) and not node.args and dotted(node.func) == "platform.system":
        return PLATFORM["platform.system()"]
    if isinstance(node, ast.Subscript) and dotted(node.value) == "sys.version_info":
        index = node.slice
        if isinstance(index, ast.Slice) and index.lower is None and index.step is None:
            stop = operand(index.upper) if index.upper is not None else len(sys.version_info)
            if isinstance(stop, int):
                return tuple(sys.version_info)[:stop]
    return UNKNOWN


UNKNOWN = object()
COMPARE = {
    ast.Eq: lambda a, b: a == b,
    ast.NotEq: lambda a, b: a != b,
    ast.Lt: lambda a, b: a < b,
    ast.LtE: lambda a, b: a <= b,
    ast.Gt: lambda a, b: a > b,
    ast.GtE: lambda a, b: a >= b,
}


def evaluate(test):
    """Return True or False for a test this file knows, else None."""
    if isinstance(test, ast.BoolOp):
        values = [evaluate(v) for v in test.values]
        if isinstance(test.op, ast.And):
            return False if False in values else (None if None in values else True)
        return True if True in values else (None if None in values else False)
    if isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not):
        value = evaluate(test.operand)
        return None if value is None else not value
    if isinstance(test, ast.Compare) and len(test.ops) == 1 and type(test.ops[0]) in COMPARE:
        left, right = operand(test.left), operand(test.comparators[0])
        if left is UNKNOWN or right is UNKNOWN or type(left) is not type(right):
            return None
        return COMPARE[type(test.ops[0])](left, right)
    if isinstance(test, ast.Call) and isinstance(test.func, ast.Attribute) and test.func.attr == "startswith":
        text = operand(test.func.value)
        prefixes = operand(test.args[0]) if len(test.args) == 1 else UNKNOWN
        if isinstance(prefixes, str):
            prefixes = (prefixes,)
        if isinstance(text, str) and isinstance(prefixes, tuple) and all(isinstance(p, str) for p in prefixes):
            return text.startswith(prefixes)
    return None


class Imports(ast.NodeVisitor):
    """Collect the imports of one file with the scope each runs in."""

    def __init__(self, path):
        self.path = path
        # pkg/sub/mod.py and pkg/sub/__init__.py both lie in package pkg.sub
        self.package = path[:-3].split("/")[:-1] if path.endswith(".py") else []
        self.scopes = ["module"]
        self.lines = []

    def scope(self):
        for name in ("typing", "function", "optional"):
            if name in self.scopes:
                return name
        return "module"

    def emit(self, module):
        self.lines.append(f"import\t{self.path}\t{module}\t{self.scope()}")

    def within(self, scope, nodes):
        self.scopes.append(scope)
        for node in nodes:
            self.visit(node)
        self.scopes.pop()

    def visit_Import(self, node):
        for alias in node.names:
            self.emit(alias.name)

    def visit_ImportFrom(self, node):
        if node.level:
            base = self.package[: len(self.package) - node.level + 1]
            module = ".".join(base + ([node.module] if node.module else []))
        else:
            module = node.module or ""
        if module:
            self.emit(module)
        for alias in node.names:
            if alias.name != "*":
                self.emit(f"{module}.{alias.name}" if module else alias.name)

    def visit_FunctionDef(self, node):
        for item in node.decorator_list:
            self.visit(item)
        self.within("function", node.body)

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_Lambda(self, node):
        self.within("function", [node.body])

    def visit_Try(self, node):
        scope = "optional" if any(catches_import_errors(h) for h in node.handlers) else "module"
        self.within(scope, node.body + node.handlers)
        for item in node.orelse + node.finalbody:
            self.visit(item)

    visit_TryStar = visit_Try

    def visit_With(self, node):
        scope = "optional" if any(suppresses_import_errors(i) for i in node.items) else "module"
        self.within(scope, node.body)

    visit_AsyncWith = visit_With

    def visit_If(self, node):
        # typing can be imported under another name, as in import typing as t
        if (dotted(node.test) or "").split(".")[-1] == "TYPE_CHECKING":
            self.within("typing", node.body)
            for item in node.orelse:
                self.visit(item)
            return
        value = evaluate(node.test)
        # Either branch of a test this file cannot decide may never run
        if value is None:
            self.within("optional", node.body + node.orelse)
            return
        for item in node.body if value else node.orelse:
            self.visit(item)


def main(argv):
    # File names outside UTF-8 go out as their bytes, as os.fsdecode read them
    sys.stdout.reconfigure(errors="surrogateescape")
    if argv[1:] == ["--stdlib"]:
        for name in sorted(sys.stdlib_module_names):
            print(name)
        return 0
    if len(argv) != 2 or not os.path.isdir(argv[1]):
        print("Usage: python3 -I -S py_imports.py <root> <NUL-separated file names", file=sys.stderr)
        return 2
    root = argv[1]
    # The names come on stdin, since Linux limits the length of the arguments
    for name in sys.stdin.buffer.read().split(b"\0"):
        if not name:
            continue
        path = os.fsdecode(name)
        try:
            with open(os.path.join(root, path), "rb") as handle:
                tree = ast.parse(handle.read(), path)
        except (OSError, SyntaxError, ValueError, RecursionError, MemoryError) as error:
            message = " ".join(str(error).split())
            print(f"error\t{path}\t{message}")
            continue
        visitor = Imports(path)
        try:
            visitor.visit(tree)
        except RecursionError:
            print(f"error\t{path}\tnested too deep")
            continue
        for line in visitor.lines:
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
