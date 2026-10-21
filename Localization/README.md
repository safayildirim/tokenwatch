# Localization

Tokenwatch ships in English and Turkish. macOS chooses the language: the first of the user's preferred languages
that the app supports, falling back to English. A user can pick another language for Tokenwatch alone in
System Settings › General › Language & Region › Applications.

- The English text in the source code is the key. SwiftUI literals (`Text("…")`, `Button("…")`, `.help("…")`) are
  looked up automatically; strings built in code use `String(localized: "…")`.
- `tr.lproj/Localizable.strings` holds the Turkish translations. `en.lproj` is empty on purpose.
- `scripts/build-app.sh` copies both folders into the app bundle and declares them in `Info.plist`.
- `LocalizationTests` checks that the table parses and that every translation keeps its key's placeholders
  (`%@`, `%lld`, `%lf`, including positional forms such as `%2$@`).

When adding a string, add its Turkish translation to `tr.lproj/Localizable.strings`. A missing entry is not an error:
the English text is shown instead.
