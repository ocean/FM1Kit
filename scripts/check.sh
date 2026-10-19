#!/usr/bin/env bash
# Runs every check CI runs: formatting, lint, a warnings-as-errors build, tests, an iOS build,
# documentation and unused-code analysis. Needs Xcode, SwiftLint and Periphery
# (`brew install swiftlint periphery`).
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$1"; }

step "Formatting (swift format)"
swift format lint --strict --recursive Sources Tests Package.swift

step "Lint (SwiftLint)"
swiftlint lint --strict --quiet

step "Build with warnings as errors"
swift build --build-tests -Xswiftc -warnings-as-errors

step "Tests"
swift test

step "iOS build"
xcodebuild build -scheme FM1Kit -destination 'generic/platform=iOS' -quiet

step "Documentation (DocC, warnings as errors)"
xcodebuild docbuild -scheme FM1Kit -destination 'generic/platform=macOS' -derivedDataPath .build/docs \
    OTHER_DOCC_FLAGS="--warnings-as-errors" -quiet

step "Unused code (SwiftLint analyze, Periphery)"
mkdir -p .build/logs
xcodebuild clean build-for-testing -scheme FM1Kit-Package -destination 'platform=macOS' \
    -derivedDataPath .build/xcode COMPILER_INDEX_STORE_ENABLE=YES > .build/logs/xcodebuild.log 2>&1
swiftlint analyze --strict --quiet --compiler-log-path .build/logs/xcodebuild.log
periphery scan --retain-public --retain-codable-properties --strict --quiet --skip-build --index-store-path .build/xcode/Index.noindex/DataStore

printf '\nAll checks passed.\n'
