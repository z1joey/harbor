import Foundation

/// Single version source for the harbor-tui binary (`--version`) and the
/// release CI guard. Must stay in sync with MARKETING_VERSION in project.yml —
/// the release workflow checks the tag against both.
public let harborVersion = "1.0.3"
