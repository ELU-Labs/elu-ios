#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <exact-semver-tag> <network-trace.json>" >&2
  exit 2
fi

release_tag="$1"
network_trace="$2"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

if [[ ! -f "$network_trace" ]]; then
  echo "release preflight requires a captured network trace" >&2
  exit 1
fi
network_trace="$(cd "$(dirname "$network_trace")" && pwd)/$(basename "$network_trace")"

python3 scripts/verify-release-tag.py "$release_tag"
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "release preflight requires full Xcode" >&2
  exit 1
fi

output="$repo_root/.build/release-preflight"
symbols="$output/symbol-graphs"
derived="$output/DerivedData"
archive="$output/EluAnalytics.xcarchive"
source_archive="$output/elu-ios-source.zip"
logs="$output/logs"
rm -rf -- "$output"
mkdir -p "$symbols" "$logs"

run_logged() {
  local name="$1"
  shift
  "$@" 2>&1 | tee "$logs/$name.log"
}

python3 scripts/verify-baseline.py
python3 Conformance/validate-baselines.py
run_logged resolve swift package resolve
swift package dump-package > "$output/package-metadata.json" 2> "$logs/dump-package.log"
python3 scripts/verify-package-surface.py --mode owned-runtime "$output/package-metadata.json"
python3 scripts/verify-dependencies.py --mode owned-runtime

run_logged simulator-tests xcodebuild test \
  -scheme EluAnalytics \
  -destination "${IOS_SIMULATOR_DESTINATION:-platform=iOS Simulator,name=iPhone 16 Pro,OS=latest}" \
  -derivedDataPath "${derived}-tests" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO

run_logged archive xcodebuild archive \
  -scheme EluAnalytics \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -derivedDataPath "$derived" \
  -skipMacroValidation \
  CODE_SIGNING_ALLOWED=NO \
  SKIP_INSTALL=NO \
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES \
  OTHER_SWIFT_FLAGS="-emit-symbol-graph -emit-symbol-graph-dir $symbols"

(
  cd Fixtures/Consumers
  run_logged uikit-consumer xcodebuild build \
    -scheme UIKitConsumer \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO
  run_logged swiftui-consumer xcodebuild build \
    -scheme SwiftUIConsumer \
    -destination 'generic/platform=iOS Simulator' \
    CODE_SIGNING_ALLOWED=NO
)

run_logged source-archive git archive \
  --format=zip \
  --prefix="elu-ios-$release_tag/" \
  --output="$source_archive" \
  "$release_tag"
python3 scripts/verify-symbol-graph.py "$symbols"
python3 scripts/generate-release-evidence.py \
  --output "$output/evidence" \
  --artifact "$archive" \
  --artifact "$source_archive" \
  --artifact "$network_trace"
(cd "$output/evidence" && shasum -a 256 -c SHA256SUMS)

scan_inputs=(
  --input "$archive"
  --input "$source_archive"
  --input "$symbols"
  --input "$output/evidence"
  --input "$output/package-metadata.json"
  --input "$logs"
)
if [[ -f Package.resolved ]]; then
  scan_inputs+=(--input "$repo_root/Package.resolved")
fi
python3 scripts/zero-brand-scan.py --mode strict \
  "${scan_inputs[@]}" \
  --network-trace "$network_trace"

echo "release preflight passed; no tag, package, or deployment was changed"
