import React from "react";

const KW = new Set([
  "def", "return", "if", "else", "elif", "for", "while", "import", "from",
  "as", "with", "try", "except", "class", "lambda", "pass", "break",
  "continue", "not", "and", "or", "in", "is", "None", "True", "False",
  "walker", "node", "edge", "obj", "can", "has", "visit", "spawn", "report",
  "here", "root", "entry", "exit", "impl", "glob", "test", "yield", "del",
  "global", "assert", "raise", "async", "await",
]);

const TYPE = new Set([
  "int", "float", "str", "list", "dict", "bool", "tuple", "set", "any",
]);

const BI = new Set([
  "print", "len", "range", "sum", "min", "max", "sorted", "enumerate",
  "zip", "abs", "round", "append", "pop",
]);

const TOKEN_RE = /(#[^\n]*)|("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')|(\b\d+(?:\.\d+)?\b)|([A-Za-z_][A-Za-z0-9_]*)/g;

export function highlight(code: string): React.ReactNode[] {
  const nodes: React.ReactNode[] = [];
  let last = 0;
  let m: RegExpExecArray | null;
  let key = 0;

  TOKEN_RE.lastIndex = 0;
  while ((m = TOKEN_RE.exec(code)) !== null) {
    // text before match
    if (m.index > last) {
      nodes.push(code.slice(last, m.index));
    }
    const [full, com, str, num, word] = m;
    if (com) {
      nodes.push(React.createElement("span", { key: key++, className: "tok-com" }, full));
    } else if (str) {
      nodes.push(React.createElement("span", { key: key++, className: "tok-str" }, full));
    } else if (num) {
      nodes.push(React.createElement("span", { key: key++, className: "tok-num" }, full));
    } else if (word) {
      let cls: string | null = null;
      if (KW.has(word)) cls = "tok-kw";
      else if (TYPE.has(word)) cls = "tok-type";
      else if (BI.has(word)) cls = "tok-bi";
      if (cls) {
        nodes.push(React.createElement("span", { key: key++, className: cls }, full));
      } else {
        nodes.push(full);
      }
    } else {
      nodes.push(full);
    }
    last = m.index + full.length;
  }

  if (last < code.length) {
    nodes.push(code.slice(last));
  }

  return nodes;
}
