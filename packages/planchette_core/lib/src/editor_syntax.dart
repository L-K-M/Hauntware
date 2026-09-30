/// Basic syntax highlighting for the built-in text editor.
///
/// This is deliberately not a full grammar engine: one generic scanner covers
/// comments, strings, numbers and keywords, and a per-language regex adds
/// "meta" tokens (YAML keys, INI sections, shell variables, tags). That is
/// enough to make config files and scripts readable without pulling in a
/// highlighting dependency or paying for a real parser on every keystroke.
/// Dotenv uses a small assignment-aware scanner so quotes in bare values
/// cannot consume later lines.
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'line_operations.dart';

part 'diff_syntax.dart';
part 'dotenv_syntax.dart';
part 'pattern_search.dart';

/// Above this size the editor skips syntax highlighting (and the precise
/// scroll-to-match layout): tokenizing stays linear, but building and painting
/// hundreds of thousands of spans per frame does not.
const int syntaxHighlightingMaxChars = 200 * 1000;

/// Search stops counting matches here; the find bar shows "1000+" instead of
/// building an unbounded highlight list for a one-letter query in a huge file.
const int searchMatchLimit = 1000;

enum SyntaxTokenType { comment, string, number, keyword, meta }

/// A non-overlapping half-open range `[start, end)` of one token type.
class SyntaxToken {
  final int start;
  final int end;
  final SyntaxTokenType type;

  const SyntaxToken(this.start, this.end, this.type);

  @override
  bool operator ==(Object other) =>
      other is SyntaxToken &&
      other.start == start &&
      other.end == end &&
      other.type == type;

  @override
  int get hashCode => Object.hash(start, end, type);

  @override
  String toString() => 'SyntaxToken($start, $end, ${type.name})';
}

/// What the generic scanner needs to know about one language family.
class SyntaxLanguage {
  final String id;
  final Set<String> keywords;
  final bool caseInsensitiveKeywords;

  /// Markers that start a comment running to the end of the line.
  final List<String> lineComments;

  /// When true a line comment only starts at the beginning of a line or after
  /// whitespace — correct for `#` in shell and YAML (`foo#bar` is not a
  /// comment there), wrong for Python or C-family markers.
  final bool lineCommentNeedsBoundary;

  /// `[open, close]` pairs, e.g. `['/*', '*/']` or `['<!--', '-->']`.
  final List<List<String>> blockComments;

  /// Delimiters of strings that may span lines (`'''`, `"""`, '`').
  final List<String> multilineStrings;

  /// `[open, close]` pairs for multiline strings whose delimiters differ
  /// (06 §7's lua `[[ ]]` — the only addition that needs an asymmetric
  /// closer; long strings take no escapes, so a plain indexOf scan is
  /// correct). Scanned in the same slot as [multilineStrings] — after
  /// block comments, before line comments.
  final List<List<String>> multilineStringPairs;

  /// Single-line string quotes; a missing closer ends the token at newline.
  final List<String> strings;

  /// Quotes from [strings] whose contents take no backslash escapes, such as
  /// shell and SQL single quotes: `'C:\'` closes at its second quote.
  final List<String> rawQuotes;

  /// Prefixes that open a raw string: the prefix, any number of `#`, then
  /// `"`. It closes at `"` and the same number of `#`, with no escapes, and
  /// may span lines, as Rust's `r"…"`, `r#"…"#` and `br"…"` do.
  final List<String> rawStringPrefixes;

  /// Whether `'` opens a one-character literal rather than a string, as in
  /// Rust and Go. A `'` that does not close as a character (a Rust lifetime
  /// or label such as `'a` or `'static`) highlights its name as meta.
  final bool charLiterals;

  /// Whether a quoted string followed by `:` is a key (meta), as in JSON.
  final bool quotedKeys;

  /// Optional extra pattern matched over the whole text (use `multiLine` for
  /// anchors); matches that don't overlap scanner tokens become [meta] tokens.
  final RegExp? metaPattern;

  /// Which group of [metaPattern] is the token; null highlights group 0.
  final int? metaGroup;

  /// Prose-like formats (Markdown, plain config values) skip number
  /// highlighting — digits in text are content, not literals.
  final bool highlightNumbers;

  /// Whether a line ending in `:` opens an indented block (Python, YAML).
  final bool indentAfterColon;

  const SyntaxLanguage({
    required this.id,
    this.keywords = const {},
    this.caseInsensitiveKeywords = false,
    this.lineComments = const [],
    this.lineCommentNeedsBoundary = false,
    this.blockComments = const [],
    this.multilineStrings = const [],
    this.multilineStringPairs = const [],
    this.strings = const [],
    this.rawQuotes = const [],
    this.rawStringPrefixes = const [],
    this.charLiterals = false,
    this.quotedKeys = false,
    this.metaPattern,
    this.metaGroup,
    this.highlightNumbers = true,
    this.indentAfterColon = false,
  });
}

/// The language families the editor recognizes. Kept intentionally small:
/// the files edited over SFTP are overwhelmingly configs and scripts.
class SyntaxLanguages {
  /// Dotenv's value boundaries require the dedicated assignment scanner.
  // Its own tokenizer finds the comments; the marker is for Toggle Comment.
  static const dotenv = SyntaxLanguage(
    id: 'dotenv',
    highlightNumbers: false,
    lineComments: ['#'],
  );

  static final shell = SyntaxLanguage(
    id: 'shell',
    keywords: const {
      'if',
      'then',
      'else',
      'elif',
      'fi',
      'for',
      'while',
      'until',
      'do',
      'done',
      'case',
      'esac',
      'in',
      'function',
      'select',
      'time',
      'local',
      'export',
      'readonly',
      'declare',
      'unset',
      'shift',
      'return',
      'exit',
      'break',
      'continue',
      'source',
      'alias',
      'eval',
      'exec',
      'set',
      'trap',
      'test',
      'echo',
      'cd',
    },
    lineComments: const ['#'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
    rawQuotes: const ["'"],
    metaPattern: RegExp(r'\$\{?[A-Za-z_][A-Za-z0-9_]*\}?|\$[0-9@#?*!$-]'),
  );

  static final python = SyntaxLanguage(
    id: 'python',
    keywords: const {
      'def',
      'class',
      'if',
      'elif',
      'else',
      'for',
      'while',
      'try',
      'except',
      'finally',
      'with',
      'as',
      'import',
      'from',
      'return',
      'yield',
      'lambda',
      'pass',
      'break',
      'continue',
      'raise',
      'global',
      'nonlocal',
      'del',
      'assert',
      'async',
      'await',
      'and',
      'or',
      'not',
      'in',
      'is',
      'None',
      'True',
      'False',
      'match',
      'case',
      'self',
    },
    // Decorators; the line anchor keeps `a @ b` matrix products plain.
    metaPattern: RegExp(r'^[ \t]*@[A-Za-z_][\w.]*', multiLine: true),
    lineComments: const ['#'],
    multilineStrings: const ["'''", '"""'],
    strings: const ["'", '"'],
    indentAfterColon: true,
  );

  static final javascript = SyntaxLanguage(
    id: 'javascript',
    keywords: const {
      'function',
      'const',
      'let',
      'var',
      'if',
      'else',
      'for',
      'while',
      'do',
      'switch',
      'case',
      'default',
      'break',
      'continue',
      'return',
      'new',
      'delete',
      'typeof',
      'instanceof',
      'in',
      'of',
      'class',
      'extends',
      'super',
      'this',
      'import',
      'export',
      'from',
      'as',
      'async',
      'await',
      'try',
      'catch',
      'finally',
      'throw',
      'yield',
      'static',
      'get',
      'set',
      'null',
      'undefined',
      'true',
      'false',
      'void',
      'interface',
      'type',
      'enum',
      'implements',
      'readonly',
      'public',
      'private',
      'protected',
    },
    lineComments: const ['//'],
    blockComments: const [
      ['/*', '*/'],
    ],
    multilineStrings: const ['`'],
    strings: const ["'", '"'],
  );

  static final dart = SyntaxLanguage(
    id: 'dart',
    keywords: const {
      'abstract',
      'as',
      'assert',
      'async',
      'await',
      'base',
      'break',
      'case',
      'catch',
      'class',
      'const',
      'continue',
      'covariant',
      'default',
      'do',
      'dynamic',
      'else',
      'enum',
      'export',
      'extends',
      'extension',
      'external',
      'factory',
      'false',
      'final',
      'finally',
      'for',
      'get',
      'if',
      'implements',
      'import',
      'in',
      'interface',
      'is',
      'late',
      'library',
      'mixin',
      'new',
      'null',
      'on',
      'operator',
      'part',
      'required',
      'rethrow',
      'return',
      'sealed',
      'set',
      'show',
      'static',
      'super',
      'switch',
      'sync',
      'this',
      'throw',
      'true',
      'try',
      'typedef',
      'var',
      'void',
      'when',
      'while',
      'with',
      'yield',
    },
    lineComments: const ['//'],
    blockComments: const [
      ['/*', '*/'],
    ],
    multilineStrings: const ["'''", '"""'],
    strings: const ["'", '"'],
  );

  static final json = SyntaxLanguage(
    id: 'json',
    keywords: const {'true', 'false', 'null'},
    strings: const ['"'],
    quotedKeys: true,
  );

  static final yaml = SyntaxLanguage(
    id: 'yaml',
    keywords: const {'true', 'false', 'null'},
    rawQuotes: const ["'"],
    quotedKeys: true,
    lineComments: const ['#'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
    metaPattern: RegExp(
      r'^[ \t]*(?:-[ \t]+)*([^\s#-][^:\n]*?)[ \t]*:(?=[ \t]|$)',
      multiLine: true,
    ),
    metaGroup: 1,
    indentAfterColon: true,
  );

  static final ini = SyntaxLanguage(
    id: 'ini',
    keywords: const {'true', 'false', 'yes', 'no', 'on', 'off'},
    caseInsensitiveKeywords: true,
    lineComments: const ['#', ';'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
    metaPattern: RegExp(r'^[ \t]*\[[^\]\n]+\]', multiLine: true),
    highlightNumbers: true,
  );

  static final dockerfile = SyntaxLanguage(
    id: 'dockerfile',
    keywords: const {
      'from',
      'run',
      'cmd',
      'label',
      'maintainer',
      'expose',
      'env',
      'add',
      'copy',
      'entrypoint',
      'volume',
      'user',
      'workdir',
      'arg',
      'onbuild',
      'stopsignal',
      'healthcheck',
      'shell',
      'as',
    },
    caseInsensitiveKeywords: true,
    lineComments: const ['#'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
    rawQuotes: const ["'"],
    metaPattern: RegExp(r'\$\{?[A-Za-z_][A-Za-z0-9_]*\}?'),
  );

  static final sql = SyntaxLanguage(
    id: 'sql',
    keywords: const {
      'select',
      'from',
      'where',
      'insert',
      'into',
      'values',
      'update',
      'delete',
      'create',
      'drop',
      'alter',
      'table',
      'index',
      'view',
      'join',
      'inner',
      'left',
      'right',
      'outer',
      'on',
      'as',
      'and',
      'or',
      'not',
      'null',
      'is',
      'in',
      'like',
      'between',
      'order',
      'by',
      'group',
      'having',
      'limit',
      'offset',
      'distinct',
      'union',
      'all',
      'exists',
      'primary',
      'key',
      'foreign',
      'references',
      'default',
      'unique',
      'constraint',
      'begin',
      'commit',
      'rollback',
      'transaction',
      'grant',
      'revoke',
      'set',
    },
    caseInsensitiveKeywords: true,
    lineComments: const ['--'],
    blockComments: const [
      ['/*', '*/'],
    ],
    strings: const ["'", '"'],
    rawQuotes: const ["'", '"'],
  );

  static final cFamily = SyntaxLanguage(
    id: 'c-family',
    keywords: const {
      'if',
      'else',
      'for',
      'while',
      'do',
      'switch',
      'case',
      'default',
      'break',
      'continue',
      'return',
      'goto',
      'struct',
      'class',
      'enum',
      'union',
      'typedef',
      'const',
      'static',
      'void',
      'int',
      'long',
      'short',
      'char',
      'float',
      'double',
      'bool',
      'unsigned',
      'signed',
      'true',
      'false',
      'new',
      'delete',
      'public',
      'private',
      'protected',
      'virtual',
      'override',
      'namespace',
      'using',
      'template',
      'typename',
      'func',
      'fn',
      'let',
      'var',
      'mut',
      'impl',
      'trait',
      'match',
      'mod',
      'pub',
      'use',
      'crate',
      'package',
      'import',
      'interface',
      'extends',
      'implements',
      'final',
      'abstract',
      'throws',
      'throw',
      'try',
      'catch',
      'finally',
      'null',
      'nullptr',
      'nil',
      'this',
      'self',
      'defer',
      'go',
      'chan',
      'map',
      'range',
      'type',
    },
    lineComments: const ['//'],
    blockComments: const [
      ['/*', '*/'],
    ],
    strings: const ["'", '"'],
    // Preprocessor directives (C, C++, C#'s #nullable, Swift's #elseif, GCC's
    // #include_next). Named, so that a PHP `# comment` at the start of a line
    // is not mistaken for one.
    metaPattern: RegExp(
      r'^[ \t]*#[ \t]*(?:if|ifdef|ifndef|elif|elseif|elifdef|elifndef|else|'
      r'endif|define|undef|include|include_next|import|embed|pragma|line|'
      r'error|warning|region|endregion|nullable)\b',
      multiLine: true,
    ),
  );

  static final rust = SyntaxLanguage(
    id: 'rust',
    keywords: const {
      'as',
      'async',
      'await',
      'break',
      'const',
      'continue',
      'crate',
      'dyn',
      'else',
      'enum',
      'extern',
      'false',
      'fn',
      'for',
      'if',
      'impl',
      'in',
      'let',
      'loop',
      'match',
      'mod',
      'move',
      'mut',
      'pub',
      'ref',
      'return',
      'self',
      'Self',
      'static',
      'struct',
      'super',
      'trait',
      'true',
      'type',
      'unsafe',
      'use',
      'where',
      'while',
    },
    lineComments: const ['//'],
    blockComments: const [
      ['/*', '*/'],
    ],
    strings: const ["'", '"'],
    rawStringPrefixes: const ['r', 'br'],
    charLiterals: true,
    // Attributes: #[derive(Debug)] and #![allow(...)]. An attribute holding a
    // string literal (#[cfg(feature = "x")]) keeps only the string's color:
    // meta matches that overlap scanner tokens are dropped when merging.
    // The body stops at the next '[' too, so a line of unclosed '#[' costs
    // linear time; bare nested brackets in an attribute go uncolored.
    metaPattern: RegExp(r'#!?\[[^\[\]\n]*\]'),
  );

  /// Go: backquoted raw strings may span lines and take no escapes.
  static final go = SyntaxLanguage(
    id: 'go',
    keywords: const {
      'break',
      'case',
      'chan',
      'const',
      'continue',
      'default',
      'defer',
      'else',
      'fallthrough',
      'false',
      'for',
      'func',
      'go',
      'goto',
      'if',
      'import',
      'interface',
      'iota',
      'map',
      'nil',
      'package',
      'range',
      'return',
      'select',
      'struct',
      'switch',
      'true',
      'type',
      'var',
    },
    lineComments: const ['//'],
    blockComments: const [
      ['/*', '*/'],
    ],
    multilineStringPairs: const [
      ['`', '`'],
    ],
    strings: const ["'", '"'],
    charLiterals: true,
  );

  /// Unified diffs and patches use a dedicated line scanner.
  static const diff = SyntaxLanguage(id: 'diff', highlightNumbers: false);

  static final xml = SyntaxLanguage(
    id: 'xml',
    blockComments: const [
      ['<!--', '-->'],
    ],
    strings: const ["'", '"'],
    metaPattern: RegExp(r'</?[A-Za-z][A-Za-z0-9:._-]*'),
    highlightNumbers: false,
  );

  static final markdown = SyntaxLanguage(
    id: 'markdown',
    multilineStrings: const ['```'],
    strings: const ['`'],
    metaPattern: RegExp(r'^#{1,6}[ \t].*$', multiLine: true),
    highlightNumbers: false,
  );

  // 06 §7's data-only additions for the file-manager audience — new
  // declarative families only; the tokenizer and controller are untouched.

  /// CSS/SCSS/LESS: declaration-style property names highlight via the
  /// meta group. The `//` line comments `.scss`/`.less` allow are an
  /// accepted gap (06 §7): a `//` rule would tokenize unquoted
  /// `url(http://…)` values as comments. The meta pattern also fires on
  /// selector pseudos (`a:hover`) and media features (`max-width:`) —
  /// the declarative rule has no context scoping to tell a declaration
  /// from a selector preamble; that gap is accepted too.
  static final css = SyntaxLanguage(
    id: 'css',
    keywords: const {
      'media',
      'supports',
      'keyframes',
      'import',
      'charset',
      'namespace',
      'page',
      'important',
      'inherit',
      'initial',
      'unset',
      'revert',
      'auto',
      'none',
    },
    caseInsensitiveKeywords: true,
    blockComments: const [
      ['/*', '*/'],
    ],
    strings: const ["'", '"'],
    // Start once per identifier; retrying every suffix makes missing colons
    // quadratic on long selectors and values.
    metaPattern: RegExp(r'(?<![-a-zA-Z])([-a-zA-Z]+)[ \t]*:'),
    metaGroup: 1,
  );

  /// Ruby: `#` comments carry the boundary flag per 06 §7's declaration;
  /// `=begin`/`=end` BOL-anchored block comments sit outside the engine's
  /// declarative shape — an accepted gap, not an engine change.
  static final ruby = SyntaxLanguage(
    id: 'ruby',
    keywords: const {
      'alias',
      'and',
      'begin',
      'BEGIN',
      'break',
      'case',
      'class',
      'def',
      'defined',
      'do',
      'else',
      'elsif',
      'end',
      'END',
      'ensure',
      'false',
      'for',
      'if',
      'in',
      'module',
      'next',
      'nil',
      'not',
      'or',
      'redo',
      'rescue',
      'retry',
      'return',
      'self',
      'super',
      'then',
      'true',
      'undef',
      'unless',
      'until',
      'when',
      'while',
      'yield',
      'require',
      'require_relative',
      'attr_accessor',
      'attr_reader',
      'attr_writer',
      'include',
      'extend',
      'private',
      'protected',
      'public',
      'raise',
      'lambda',
      'proc',
      'puts',
      'print',
    },
    lineComments: const ['#'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
  );

  /// Perl: a `#` counts as a comment only at a line start or after
  /// whitespace, as for ruby — glued to a sigil or a delimiter it is
  /// syntax (`$#list`, `s#a#b#`, `qw#a b#`, `s/#.*//`), and without the
  /// boundary each greyed out the rest of its line. The cost is that a
  /// comment glued to code (`1;# note`) renders as code. POD
  /// (`=pod`…`=cut`) is omitted for the same BOL-anchored reason as
  /// ruby's `=begin` (06 §7). Kept identical to Séance's rule.
  static final perl = SyntaxLanguage(
    id: 'perl',
    keywords: const {
      'my',
      'our',
      'local',
      'sub',
      'use',
      'package',
      'require',
      'if',
      'elsif',
      'else',
      'unless',
      'while',
      'until',
      'for',
      'foreach',
      'last',
      'next',
      'redo',
      'return',
      'goto',
      'do',
      'eval',
      'die',
      'warn',
      'print',
      'say',
      'chomp',
      'chop',
      'push',
      'pop',
      'shift',
      'unshift',
      'splice',
      'grep',
      'map',
      'sort',
      'keys',
      'values',
      'each',
      'exists',
      'defined',
      'undef',
      'ref',
      'bless',
      'tie',
      'scalar',
      'wantarray',
      'caller',
      'exit',
      'open',
      'close',
      'read',
      'and',
      'or',
      'not',
      'xor',
      'eq',
      'ne',
      'lt',
      'gt',
      'le',
      'ge',
      'cmp',
    },
    lineComments: const ['#'],
    lineCommentNeedsBoundary: true,
    strings: const ["'", '"'],
  );

  /// Lua: the `--[[ ]]` block-comment rule is declared so the scanner —
  /// which checks block comments before BOTH line comments and
  /// multiline strings — never consumes `--[[` as a `--`-to-EOL comment
  /// (stranding `]]`) nor `[[` inside it as a string (06 §7).
  /// Equality-level long brackets (`[==[`, `--[==[`) are an accepted
  /// gap: `--[==[` falls to the `--` line rule, a bare `[==[` matches
  /// nothing.
  static final lua = SyntaxLanguage(
    id: 'lua',
    keywords: const {
      'and',
      'break',
      'do',
      'else',
      'elseif',
      'end',
      'false',
      'for',
      'function',
      'goto',
      'if',
      'in',
      'local',
      'nil',
      'not',
      'or',
      'repeat',
      'return',
      'then',
      'true',
      'until',
      'while',
      'require',
      'module',
      'print',
      'pairs',
      'ipairs',
      'type',
      'tostring',
      'tonumber',
      'error',
      'pcall',
      'xpcall',
      'select',
      'rawget',
      'rawset',
      'rawequal',
      'setmetatable',
      'getmetatable',
      'next',
      'unpack',
      'self',
    },
    blockComments: const [
      ['--[[', ']]'],
    ],
    lineComments: const ['--'],
    multilineStringPairs: const [
      ['[[', ']]'],
    ],
    strings: const ["'", '"'],
  );
}

const Map<String, String> _extensionLanguages = {
  'sh': 'shell', 'bash': 'shell', 'zsh': 'shell', 'ksh': 'shell',
  'py': 'python', 'pyw': 'python',
  'js': 'javascript', 'mjs': 'javascript', 'cjs': 'javascript',
  'jsx': 'javascript', 'ts': 'javascript', 'tsx': 'javascript',
  'dart': 'dart',
  'json': 'json', 'jsonc': 'json',
  'yaml': 'yaml', 'yml': 'yaml',
  'toml': 'ini', 'ini': 'ini', 'cfg': 'ini', 'conf': 'ini',
  'properties': 'ini', 'env': 'dotenv', 'desktop': 'ini', 'service': 'ini',
  'socket': 'ini', 'timer': 'ini',
  'sql': 'sql',
  'c': 'c-family', 'h': 'c-family', 'cpp': 'c-family', 'cc': 'c-family',
  'cxx': 'c-family', 'hpp': 'c-family', 'hh': 'c-family', 'go': 'go',
  'rs': 'rust', 'java': 'c-family', 'kt': 'c-family', 'kts': 'c-family',
  'swift': 'c-family', 'cs': 'c-family', 'scala': 'c-family',
  'php': 'c-family',
  'xml': 'xml', 'html': 'xml', 'htm': 'xml', 'xhtml': 'xml', 'svg': 'xml',
  'plist': 'xml',
  'md': 'markdown', 'markdown': 'markdown',
  'diff': 'diff', 'patch': 'diff',
  // 06 §7's additions.
  'css': 'css', 'scss': 'css', 'less': 'css',
  'rb': 'ruby', 'rake': 'ruby', 'gemspec': 'ruby',
  'pl': 'perl', 'pm': 'perl',
  'lua': 'lua',
};

const Map<String, String> _basenameLanguages = {
  'dockerfile': 'dockerfile', 'containerfile': 'dockerfile',
  'makefile': 'shell', 'gnumakefile': 'shell',
  '.bashrc': 'shell', '.bash_profile': 'shell', '.bash_aliases': 'shell',
  '.bash_logout': 'shell', '.zshrc': 'shell', '.zshenv': 'shell',
  '.zprofile': 'shell', '.profile': 'shell',
  '.gitignore': 'ini', '.dockerignore': 'ini', '.gitconfig': 'ini',
  '.gitmodules': 'ini', '.editorconfig': 'ini', '.npmrc': 'ini',
  // The files an SSH client edits most.
  'config': 'ini', 'ssh_config': 'ini', 'sshd_config': 'ini',
  'authorized_keys': 'ini', 'known_hosts': 'ini', 'hosts': 'ini',
  'fstab': 'ini', 'crontab': 'shell',
  // 06 §7's additions: ruby's convention basenames and the Apache
  // dot-configs. `.htpasswd` (`user:hash` lines) matches no ini rule —
  // it is mapped only so it opens as text rather than unknown, an
  // accepted gap the detection tests must not imply coverage of.
  'gemfile': 'ruby', 'rakefile': 'ruby', 'config.ru': 'ruby',
  '.htaccess': 'ini', '.htpasswd': 'ini',
};

SyntaxLanguage? _languageById(String id) => switch (id) {
  'dotenv' => SyntaxLanguages.dotenv,
  'shell' => SyntaxLanguages.shell,
  'python' => SyntaxLanguages.python,
  'javascript' => SyntaxLanguages.javascript,
  'dart' => SyntaxLanguages.dart,
  'json' => SyntaxLanguages.json,
  'yaml' => SyntaxLanguages.yaml,
  'ini' => SyntaxLanguages.ini,
  'dockerfile' => SyntaxLanguages.dockerfile,
  'sql' => SyntaxLanguages.sql,
  'c-family' => SyntaxLanguages.cFamily,
  'rust' => SyntaxLanguages.rust,
  'go' => SyntaxLanguages.go,
  'diff' => SyntaxLanguages.diff,
  'xml' => SyntaxLanguages.xml,
  'markdown' => SyntaxLanguages.markdown,
  'css' => SyntaxLanguages.css,
  'ruby' => SyntaxLanguages.ruby,
  'perl' => SyntaxLanguages.perl,
  'lua' => SyntaxLanguages.lua,
  _ => null,
};

/// Pick a language for [path], preferring a well-known basename, then the
/// extension, then a `#!` interpreter line from [firstLine]. Returns null for
/// unrecognized files, which render as plain text.
SyntaxLanguage? syntaxLanguageFor(String path, {String? firstLine}) {
  // Remote paths use POSIX separators; local Windows paths use backslashes.
  final separator = path.lastIndexOf(RegExp(r'[/\\]'));
  final basename = path.substring(separator + 1).toLowerCase();
  if (basename == '.env' || basename.startsWith('.env.')) {
    return SyntaxLanguages.dotenv;
  }
  final byBasename = _basenameLanguages[basename];
  if (byBasename != null) return _languageById(byBasename);
  if (basename.startsWith('dockerfile.') || basename.endsWith('.dockerfile')) {
    return SyntaxLanguages.dockerfile;
  }
  final dot = basename.lastIndexOf('.');
  if (dot > 0 && dot < basename.length - 1) {
    final byExtension = _extensionLanguages[basename.substring(dot + 1)];
    if (byExtension != null) return _languageById(byExtension);
  }
  final shebang = firstLine?.trim();
  if (shebang != null && shebang.startsWith('#!')) {
    if (shebang.contains('python')) return SyntaxLanguages.python;
    if (shebang.contains('node') ||
        shebang.contains('deno') ||
        shebang.contains('bun')) {
      return SyntaxLanguages.javascript;
    }
    // 06 §7: matched directly (`#!/usr/bin/ruby`) and after `env`
    // (`#!/usr/bin/env ruby`) alike — the word-boundary checks also hold
    // for the lua variants so `lua5.5` or `luabridge` never over-capture.
    if (RegExp(r'\bruby\b').hasMatch(shebang)) return SyntaxLanguages.ruby;
    if (RegExp(r'\bperl\b').hasMatch(shebang)) return SyntaxLanguages.perl;
    if (RegExp(r'\blua(?:5\.[1-4]|jit)?\b').hasMatch(shebang)) {
      return SyntaxLanguages.lua;
    }
    if (RegExp(r'\b(sh|bash|zsh|ksh|dash|ash)\b').hasMatch(shebang)) {
      return SyntaxLanguages.shell;
    }
  }
  return null;
}

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == 0x5f;

bool _isIdentPart(int c) => _isIdentStart(c) || (c >= 0x30 && c <= 0x39);

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// Scan [text] into non-overlapping, ordered [SyntaxToken]s.
List<SyntaxToken> tokenizeSyntax(String text, SyntaxLanguage language) {
  if (language.id == 'dotenv') return _tokenizeDotenv(text);
  if (language.id == 'diff') return _tokenizeDiff(text);
  final tokens = <SyntaxToken>[];
  final n = text.length;
  var i = 0;
  outer:
  while (i < n) {
    final c = text.codeUnitAt(i);

    for (final pair in language.blockComments) {
      if (text.startsWith(pair[0], i)) {
        final close = text.indexOf(pair[1], i + pair[0].length);
        final end = close < 0 ? n : close + pair[1].length;
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.comment));
        i = end;
        continue outer;
      }
    }

    for (final delimiter in language.multilineStrings) {
      if (text.startsWith(delimiter, i)) {
        final end = _scanString(text, i, delimiter, stopAtNewline: false);
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.string));
        i = end;
        continue outer;
      }
    }

    for (final pair in language.multilineStringPairs) {
      if (text.startsWith(pair[0], i)) {
        final close = text.indexOf(pair[1], i + pair[0].length);
        final end = close < 0 ? n : close + pair[1].length;
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.string));
        i = end;
        continue outer;
      }
    }

    for (final marker in language.lineComments) {
      if (text.startsWith(marker, i) &&
          (!language.lineCommentNeedsBoundary ||
              i == 0 ||
              _isWhitespace(text.codeUnitAt(i - 1)))) {
        final newline = text.indexOf('\n', i);
        final end = newline < 0 ? n : newline;
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.comment));
        i = end;
        continue outer;
      }
    }

    for (final prefix in language.rawStringPrefixes) {
      final end = _rawStringEnd(text, i, prefix);
      if (end != null) {
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.string));
        i = end;
        continue outer;
      }
    }

    for (final quote in language.strings) {
      if (text.startsWith(quote, i)) {
        if (language.charLiterals && quote == "'") {
          final end = _charLiteralEnd(text, i);
          if (end != null) {
            tokens.add(SyntaxToken(i, end, SyntaxTokenType.string));
            i = end;
            continue outer;
          }
          var nameEnd = i + 1;
          while (nameEnd < n && _isIdentPart(text.codeUnitAt(nameEnd))) {
            nameEnd++;
          }
          if (nameEnd > i + 1) {
            tokens.add(SyntaxToken(i, nameEnd, SyntaxTokenType.meta));
          }
          i = nameEnd;
          continue outer;
        }
        final end = _scanString(
          text,
          i,
          quote,
          stopAtNewline: true,
          escapes: !language.rawQuotes.contains(quote),
        );
        final key = language.quotedKeys && _colonFollows(text, end);
        tokens.add(
          SyntaxToken(
            i,
            end,
            key ? SyntaxTokenType.meta : SyntaxTokenType.string,
          ),
        );
        i = end;
        continue outer;
      }
    }

    if (_isIdentStart(c)) {
      var end = i + 1;
      while (end < n && _isIdentPart(text.codeUnitAt(end))) {
        end++;
      }
      final word = text.substring(i, end);
      final isKeyword = language.caseInsensitiveKeywords
          ? language.keywords.contains(word.toLowerCase())
          : language.keywords.contains(word);
      if (isKeyword) {
        tokens.add(SyntaxToken(i, end, SyntaxTokenType.keyword));
      }
      i = end;
      continue;
    }

    if (language.highlightNumbers && _isDigit(c)) {
      final end = _scanNumber(text, i);
      tokens.add(SyntaxToken(i, end, SyntaxTokenType.number));
      i = end;
      continue;
    }

    i++;
  }

  final meta = language.metaPattern;
  if (meta == null) return tokens;
  return _mergeMetaTokens(tokens, text, meta, language.metaGroup);
}

bool _isWhitespace(int c) => c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d;

/// End index of a string starting at [start] with [delimiter]; with
/// [escapes], a backslash escapes the next character. Unterminated
/// single-line strings stop at the newline; unterminated multiline strings
/// run to the end of the text.
int _scanString(
  String text,
  int start,
  String delimiter, {
  required bool stopAtNewline,
  bool escapes = true,
}) {
  final n = text.length;
  var i = start + delimiter.length;
  while (i < n) {
    final c = text.codeUnitAt(i);
    if (escapes && c == 0x5c /* backslash */ ) {
      i += 2;
      continue;
    }
    if (stopAtNewline && c == 0x0a) return i;
    if (text.startsWith(delimiter, i)) return i + delimiter.length;
    i++;
  }
  return n;
}

/// The end of a character literal opening at [start] (`'x'`, `'\n'`,
/// `'\u{1F600}'`, `'\x7f'`), or null when the quote does not close as one.
int? _charLiteralEnd(String text, int start) {
  final n = text.length;
  var i = start + 1;
  if (i >= n) return null;
  final c = text.codeUnitAt(i);
  if (c == 0x5c /* backslash */ ) {
    // The escaped character itself, then any hex digits or braces after it.
    i += 2;
    while (i < n && i - start < 14) {
      final tail = text.codeUnitAt(i);
      if (!_isIdentPart(tail) && tail != 0x7b && tail != 0x7d) break;
      i++;
    }
  } else if (c == 0x0a || c == 0x27 /* ' */ ) {
    return null;
  } else {
    // A supplementary-plane character is two UTF-16 code units.
    i += c >= 0xd800 && c <= 0xdbff ? 2 : 1;
  }
  return i < n && text.codeUnitAt(i) == 0x27 ? i + 1 : null;
}

/// The end of a raw string opening at [start] with [prefix], or null when
/// none opens there (for example the raw identifier `r#type`).
int? _rawStringEnd(String text, int start, String prefix) {
  if (!text.startsWith(prefix, start)) return null;
  var i = start + prefix.length;
  var hashes = 0;
  while (i < text.length && text.codeUnitAt(i) == 0x23 /* # */ ) {
    hashes++;
    i++;
  }
  if (i >= text.length || text.codeUnitAt(i) != 0x22 /* " */ ) return null;
  final closer = '"${'#' * hashes}';
  final close = text.indexOf(closer, i + 1);
  return close < 0 ? text.length : close + closer.length;
}

bool _colonFollows(String text, int from) {
  var i = from;
  while (i < text.length &&
      (text.codeUnitAt(i) == 0x20 || text.codeUnitAt(i) == 0x09)) {
    i++;
  }
  return i < text.length && text.codeUnitAt(i) == 0x3a /* : */;
}

int _scanNumber(String text, int start) {
  final n = text.length;
  var i = start;
  if (text.startsWith('0x', i) || text.startsWith('0X', i)) {
    i += 2;
    while (i < n && _isHexDigit(text.codeUnitAt(i))) {
      i++;
    }
    return i;
  }
  bool digitOrSeparator(int c) => _isDigit(c) || c == 0x5f;
  while (i < n && digitOrSeparator(text.codeUnitAt(i))) {
    i++;
  }
  if (i < n - 1 &&
      text.codeUnitAt(i) == 0x2e /* . */ &&
      _isDigit(text.codeUnitAt(i + 1))) {
    i++;
    while (i < n && digitOrSeparator(text.codeUnitAt(i))) {
      i++;
    }
  }
  if (i < n && (text.codeUnitAt(i) | 0x20) == 0x65 /* e */ ) {
    var j = i + 1;
    if (j < n && (text.codeUnitAt(j) == 0x2b || text.codeUnitAt(j) == 0x2d)) {
      j++;
    }
    if (j < n && _isDigit(text.codeUnitAt(j))) {
      j++;
      while (j < n && _isDigit(text.codeUnitAt(j))) {
        j++;
      }
      i = j;
    }
  }
  return i;
}

bool _isHexDigit(int c) =>
    _isDigit(c) ||
    (c >= 0x41 && c <= 0x46) ||
    (c >= 0x61 && c <= 0x66) ||
    c == 0x5f;

/// Add meta tokens for [pattern] matches that don't overlap scanner [tokens]
/// (a YAML "key" inside a comment stays a comment), keeping order.
List<SyntaxToken> _mergeMetaTokens(
  List<SyntaxToken> tokens,
  String text,
  RegExp pattern,
  int? group,
) {
  final merged = <SyntaxToken>[];
  var tokenIndex = 0;
  for (final match in pattern.allMatches(text)) {
    var start = match.start;
    var end = match.end;
    if (group != null) {
      // Dart's Match API exposes no per-group offsets (start/end are whole-
      // match getters), so the group is located by search. That is exact as
      // long as a metaPattern's group cannot also occur inside its own
      // prefix — true for the YAML key pattern, whose group starts with
      // [^\s#-] while the prefix is only whitespace and dashes. Keep that
      // property when adding grouped patterns.
      // A non-participating (optional) group yields no token — skip the
      // match rather than throwing on the null group.
      final groupText = match[group];
      if (groupText == null) continue;
      start = match.start + match[0]!.indexOf(groupText);
      end = start + groupText.length;
    }
    if (end <= start) continue;
    while (tokenIndex < tokens.length && tokens[tokenIndex].end <= start) {
      merged.add(tokens[tokenIndex]);
      tokenIndex++;
    }
    final overlaps =
        tokenIndex < tokens.length && tokens[tokenIndex].start < end;
    if (!overlaps) {
      merged.add(SyntaxToken(start, end, SyntaxTokenType.meta));
    }
  }
  merged.addAll(tokens.sublist(tokenIndex));
  return merged;
}

/// A half-open UTF-16 range in the searched text, independent of Flutter.
final class TextMatch {
  const TextMatch({required this.start, required this.end});

  final int start;
  final int end;
  int get length => end - start;
  bool get isCollapsed => start == end;

  @override
  bool operator ==(Object other) =>
      other is TextMatch && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'TextMatch($start, $end)';
}

/// How faithfully a case-insensitive search could compare the document.
enum CaseFolding {
  /// Both sides were lowercased and every match offset still addresses the
  /// original text.
  exact,

  /// Lowercasing changed the *document's* length, so offsets into the folded
  /// text would not address the original. The search compared
  /// case-sensitively instead, which finds fewer matches than the user asked
  /// for, and says so.
  ///
  /// The query's own length is irrelevant here. A match spans whatever the
  /// folded document holds at that offset, which is what case-insensitive
  /// matching means: `Straße` may match `strasse` because the two are case
  /// equivalents, not because they are the same string.
  lengthChanging,
}

/// A search outcome plus the case handling that produced it. Hosts that show a
/// match count can report [caseFolding] instead of quietly claiming a
/// case-insensitive result they did not deliver.
final class SearchResult {
  const SearchResult({
    required this.matches,
    required this.caseFolding,
    this.precedingCount,
  });

  final List<TextMatch> matches;
  final CaseFolding caseFolding;

  /// How many of the text's matches come before the first one in [matches],
  /// when the search counted them: 0 for a forward search from the start of
  /// the text, and every match before the window for a reverse one. Null for
  /// a forward search that began mid-text, which did not look back.
  final int? precedingCount;

  bool get caseFoldedExactly => caseFolding == CaseFolding.exact;
}

/// Folds one side of a case-insensitive comparison.
///
/// A fold that preserves the document's length — and is *index-wise*, its
/// output character at position *i* standing for the input character at *i* —
/// is applied as-is, and can fix case differences [String.toLowerCase] misses
/// while keeping match offsets valid: Greek final sigma (`toLowerCase` maps `Σ`
/// to `σ` and never to the final `ς` a Greek word actually ends with), a
/// locale's dotted and dotless i, canonical Cherokee forms.
///
/// Both halves are required. Length alone is not enough: a length-preserving
/// fold that is not index-wise — one that reorders characters, say — would
/// satisfy the length check and return confidently wrong ranges. Depending on
/// surrounding context is fine, so long as output position *i* still stands
/// for input *i*: Unicode's final-sigma rule (σ → ς at a word's end) is
/// exactly such a fold, and it is the one worth having. Injectable so the
/// guarded paths are testable at all.
///
/// A fold that *changes* the length cannot be used on a document: matches are
/// located in the folded text, so their offsets would address the wrong
/// characters. [searchText] then compares exactly and reports
/// [CaseFolding.lengthChanging]. Expanding `ß` to `ss`, which is what Unicode
/// *full* case folding does, therefore needs a folded-offset map rather than
/// a different fold — see ANALYSIS.md B37.
typedef CaseFolder = String Function(String value);

/// Substring search used by the editor's find bar, reporting how the case
/// handling went. Capped at [limit] matches. With [wholeWord], a hit counts
/// only where no word character runs on across its edges.
///
/// [start] is where the scan begins, and with [reverse] it is instead the
/// exclusive upper bound: the window is the last [limit] matches before it,
/// still in document order and enumerated exactly as a forward scan would.
/// Null, the default, means the whole haystack. A find bar that only highlights
/// its first page of matches needs both directions, and both must describe the
/// same occurrences or stepping back offers matches stepping forward never did.
///
/// [scope], when given, is a stored find-in-selection range: only matches
/// lying wholly inside it count — one straddling either edge is skipped —
/// and counts such as [SearchResult.precedingCount] are scope-relative.
SearchResult searchText(
  String text,
  String query, {
  bool caseSensitive = false,
  bool wholeWord = false,
  int limit = searchMatchLimit,
  CaseFolder fold = _lowercase,
  int? start,
  ({int start, int end})? scope,
  bool reverse = false,
}) {
  if (query.isEmpty) {
    return const SearchResult(
      matches: [],
      caseFolding: CaseFolding.exact,
      precedingCount: 0,
    );
  }
  final counted = reverse || (start ?? 0) <= 0 ? 0 : null;
  var haystack = text;
  var needle = query;
  var caseFolding = CaseFolding.exact;
  if (!caseSensitive) {
    // Only the haystack's length matters: a match is located in the folded
    // document and spans what is there, so its offsets address the original
    // exactly when the fold preserved the document's length.
    final lowered = fold(text);
    if (lowered.length == text.length) {
      haystack = lowered;
      needle = fold(query);
      // A fold may erase characters. An empty needle would "match" at every
      // offset, and Replace All would insert its text at each of them.
      if (needle.isEmpty) {
        return const SearchResult(
          matches: [],
          caseFolding: CaseFolding.exact,
          precedingCount: 0,
        );
      }
    } else {
      caseFolding = CaseFolding.lengthChanging;
    }
  }
  if (limit <= 0) {
    return SearchResult(
      matches: const [],
      caseFolding: caseFolding,
      precedingCount: reverse ? null : counted,
    );
  }
  // The scope's bounds, clamped into the text. Only matches starting at
  // or after [low] and ending at or before [high] count.
  final low = (scope?.start ?? 0).clamp(0, haystack.length);
  final high = (scope?.end ?? haystack.length).clamp(0, haystack.length);

  // One enumeration serves both directions and every option, so Find
  // Previous can never offer an occurrence Find Next would not.
  int next(int from) {
    var at = haystack.indexOf(needle, from < low ? low : from);
    while (at >= 0 &&
        wholeWord &&
        !_isWholeWordMatch(text, at, at + needle.length)) {
      // A rejected hit can hide a whole word that starts inside it.
      at = haystack.indexOf(needle, at + 1);
    }
    return at;
  }

  if (reverse) {
    // A sliding window over the forward enumeration. Scanning backwards with
    // lastIndexOf would instead report overlapping occurrences — 'aa' in
    // 'aaaa' is [0, 2] forwards and [0, 1, 2] backwards — so Find Previous
    // would offer hits Find Next never had. The window is a ring of starts,
    // so dropping the oldest hit costs nothing however many matches pass.
    final bound = (start ?? haystack.length).clamp(0, haystack.length);
    final ring = List<int>.filled(limit, 0);
    var count = 0;
    for (
      var at = next(0);
      at >= 0 && at < bound && at + needle.length <= high;
      at = next(at + needle.length)
    ) {
      ring[count % limit] = at;
      count++;
    }
    final kept = count < limit ? count : limit;
    return SearchResult(
      matches: [
        for (var i = count - kept; i < count; i++)
          TextMatch(
            start: ring[i % limit],
            end: ring[i % limit] + needle.length,
          ),
      ],
      caseFolding: caseFolding,
      precedingCount: count - kept,
    );
  }
  final matches = <TextMatch>[];
  var from = (start ?? 0).clamp(0, haystack.length);
  while (matches.length < limit) {
    final at = next(from);
    if (at < 0 || at + needle.length > high) break;
    matches.add(TextMatch(start: at, end: at + needle.length));
    from = at + needle.length;
  }
  return SearchResult(
    matches: matches,
    caseFolding: caseFolding,
    precedingCount: counted,
  );
}

String _lowercase(String value) => value.toLowerCase();

/// The matches only. Hosts that do not report case handling can use this, but
/// prefer [searchText]: it is the difference between "no matches" and "no
/// matches because this text cannot be compared case-insensitively".
List<TextMatch> findSearchMatches(
  String text,
  String query, {
  bool caseSensitive = false,
  bool wholeWord = false,
  int limit = searchMatchLimit,
  int? start,
  ({int start, int end})? scope,
  bool reverse = false,
}) => searchText(
  text,
  query,
  caseSensitive: caseSensitive,
  wholeWord: wholeWord,
  limit: limit,
  start: start,
  scope: scope,
  reverse: reverse,
).matches;

/// Whether the match from [start] to [end] stands as whole words: no word
/// character runs on across either edge. An edge only needs a boundary where
/// the match's own character there is a word character, so `==` is found
/// between `a` and `b` the way `\b==\b` finds it. Checked on the original
/// text, whose offsets a length-preserving fold keeps.
bool _isWholeWordMatch(String text, int start, int end) {
  if (start > 0 &&
      isWordRune(_runeAt(text, start)) &&
      isWordRune(_runeBefore(text, start))) {
    return false;
  }
  return end >= text.length ||
      !isWordRune(_runeBefore(text, end)) ||
      !isWordRune(_runeAt(text, end));
}

/// A word character is a letter, mark, number or connector punctuation such
/// as `_`, read by code point: accented and CJK letters are word content,
/// while curly quotes, dashes, no-break spaces, full-width punctuation and
/// emoji are boundaries.
bool isWordRune(int rune) {
  if (rune < 0x80) {
    return (rune >= 0x30 && rune <= 0x39) ||
        (rune >= 0x41 && rune <= 0x5a) ||
        (rune >= 0x61 && rune <= 0x7a) ||
        rune == 0x5f;
  }
  if (rune > 0xffff) return _wordRune.hasMatch(String.fromCharCode(rune));
  final known = _bmpWordRunes[rune];
  if (known != _unclassified) return known == _word;
  final word = _wordRune.hasMatch(String.fromCharCode(rune));
  _bmpWordRunes[rune] = word ? _word : _boundary;
  return word;
}

final _wordRune = RegExp(r'[\p{L}\p{M}\p{N}\p{Pc}]', unicode: true);

/// The Basic Multilingual Plane's answers, filled in as characters are met.
/// A whole-word search in Cyrillic or Greek asks about the same few letters
/// at every candidate, and a regular expression test per question made it
/// several times slower than in ASCII.
final _bmpWordRunes = Uint8List(0x10000);
const _unclassified = 0;
const _word = 1;
const _boundary = 2;

int _runeAt(String text, int index) {
  final unit = text.codeUnitAt(index);
  if (_isHighSurrogate(unit) && index + 1 < text.length) {
    final low = text.codeUnitAt(index + 1);
    if (_isLowSurrogate(low)) return _combine(unit, low);
  }
  return unit;
}

int _runeBefore(String text, int index) {
  final unit = text.codeUnitAt(index - 1);
  if (_isLowSurrogate(unit) && index >= 2) {
    final high = text.codeUnitAt(index - 2);
    if (_isHighSurrogate(high)) return _combine(high, unit);
  }
  return unit;
}

int _combine(int high, int low) =>
    0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00);

bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;

bool _isLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;
