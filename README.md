# OpenBoard

OpenBoard is a native Flutter desktop app that turns CSV rows into a kanban board. It is built for local planning workflows: load a CSV, auto-detect common board fields when possible, map the remaining columns that matter, drag cards across status lanes, edit row details, and save back to the same file without losing unmapped columns.

## Current MVP

- Desktop targets: Windows, macOS, Linux
- Local-only workflow with no cloud sync or database
- CSV header mapping for title, status, description, assignee, due date, and extra visible fields, with auto-detect on recognizable headers
- Drag-and-drop board columns driven by a mapped status field
- Full-row editing in a detail panel or dialog
- Safe in-place CSV saves using a temp-file replacement flow
- Local persistence for recent files and saved column mappings in an app config JSON file

## Open CSV

This initial open-source build keeps dependencies minimal and uses a file-path dialog for `Open CSV` instead of a native file picker. Paste the full local path to a CSV file when prompted.

## CSV Expectations

- UTF-8 CSV input/output
- Header row required
- Quoted commas and embedded newlines are supported
- Unknown or unmapped columns are preserved when saving

## Screenshots

- TODO: add board screenshot
- TODO: add mapping dialog screenshot

## Local Development

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

For release-style smoke builds:

```bash
flutter build windows
flutter build linux
flutter build macos
```

## Repository Workflow

- Issues: use the built-in bug report and feature request templates
- CI: GitHub Actions runs analyze, test, and desktop build smoke checks on Windows, macOS, and Linux
- License: MIT

## Contributing

Open an issue before larger behavior changes so the CSV model and UX stay coherent. Small fixes and test improvements can go straight to PRs.

