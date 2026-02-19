# Ma Player

Flutter TVBox-compatible player project.

## TVBox Parsing

The parser is implemented in:

- `lib/tvbox/tvbox_models.dart`
- `lib/tvbox/tvbox_parse_report.dart`
- `lib/tvbox/tvbox_source_resolver.dart`
- `lib/tvbox/tvbox_ext_resolver.dart`
- `lib/tvbox/tvbox_normalizers.dart`
- `lib/tvbox/tvbox_parser.dart`

### Coverage

Root-level fields:

- `spider`, `wallpaper`, `logo`, `sites`, `parses`, `lives`, `flags`
- `ijk`, `ads`, `drives`, `rules`, `player`
- `cache`, `proxy`, `dns`, `headers`, `ua`, `timeout`
- `recommend`, `hotSearch`, `ext`

Unknown fields are preserved in `extras` maps at root and item levels.

### Parse Result Contract

`TvBoxParser.parseString(...)` and `TvBoxParser.parseMap(...)` return `TvBoxParseReport`:

- `config`: parsed typed config (nullable)
- `issues`: structured issues with `code`, `path`, `level`, `message`
- `hasFatalError`: true when fatal issues exist

Issue code families:

- `TVB_JSON_*`: JSON/root parsing issues
- `TVB_TYPE_*`: field type mismatch
- `TVB_EXT_*`: ext loading/recursion issues
- `TVB_REQUIRED_*`: required-field validation issues

### ext Recursive Resolution

- Supports `http`, `https`, `file`, and relative paths via `baseUri`.
- Includes cycle detection, depth limit, node limit, and request timeout.
- Root ext merge rule: local document overrides remote ext content.
- Item ext merge rule: keep original `ext` and store loaded map in `resolvedExtRaw`.
