#!/bin/bash
# Real native app proof for #193817 against the existing loopback Gateway; no live
# credentials or providers. Drives the real iOS app in a task-owned simulator:
# Rewind a seeded user message, edit the composer while the completion is held,
# then release it. The pre-fix tree overwrites the newer draft (behavioral red);
# the fixed tree preserves it, refreshes history, and refreshes the branch list.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
baseline="${1:-}"
output="$root/apps/ios/build/LifecycleTestResults"
mkdir -p "$output"
scratch="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/openclaw-rewind.XXXXXX")"
fixture_pid=""
simulator=""
video_pid=""
before_checkout=""
cleanup() {
  if [[ -n "$video_pid" ]]; then kill -INT "$video_pid" 2>/dev/null || true; wait "$video_pid" 2>/dev/null || true; fi
  if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; wait "$fixture_pid" || true; fi
  if [[ -n "$simulator" ]]; then
    xcrun simctl shutdown "$simulator" 2>/dev/null || true
    xcrun simctl delete "$simulator"
  fi
  if [[ -n "$before_checkout" ]]; then git worktree remove --force "$before_checkout"; fi
  rm -rf "$scratch"
}
trap cleanup EXIT

# Choose one installed phone/runtime for both revisions, but create only task-owned devices.
xcrun simctl list devices available --json > "$scratch/devices.json"
node -e '
const f=require("node:fs");
const entries=Object.entries(JSON.parse(f.readFileSync(process.argv[1],"utf8")).devices);
for(const [runtime,devices] of entries){
  const phone=devices.find(d=>d.isAvailable&&d.name.startsWith("iPhone"));
  if(phone){console.log(phone.name);console.log(runtime);process.exit(0);}
}
throw new Error("No available iPhone simulator");
' "$scratch/devices.json" > "$scratch/device.txt"
device="$(sed -n '1p' "$scratch/device.txt")"
runtime="$(sed -n '2p' "$scratch/device.txt")"
printf 'Candidate: %s\nBaseline: %s\nDevice: %s\nRuntime: %s\n' \
  "$(git rev-parse HEAD)" "$baseline" "$device" "$runtime" > "$output/Rewind-provenance.txt"
shasum -a 256 apps/ios/UITests/RewindComposerUITests.swift >> "$output/Rewind-provenance.txt"

# Synthetic picker photo: the newest library item on the task-owned simulator.
node -e '
const zlib = require("node:zlib");
const w = 240, h = 240;
const raw = Buffer.alloc((w * 3 + 1) * h);
for (let y = 0; y < h; y++) {
  const row = y * (w * 3 + 1);
  for (let x = 0; x < w; x++) {
    const p = row + 1 + x * 3;
    raw[p] = 0xde; raw[p + 1] = 0x30; raw[p + 2] = 0x6a;
  }
}
const table = [];
for (let n = 0; n < 256; n++) {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  table[n] = c >>> 0;
}
const crc32 = (buf) => {
  let c = 0xffffffff;
  for (const b of buf) c = table[(c ^ b) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
};
const chunk = (type, data) => {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
};
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
ihdr[8] = 8; ihdr[9] = 2; // 8-bit RGB
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk("IHDR", ihdr),
  chunk("IDAT", zlib.deflateSync(raw)),
  chunk("IEND", Buffer.alloc(0)),
]);
require("node:fs").writeFileSync(process.argv[1], png);
' "$scratch/photo.png"
shasum -a 256 "$scratch/photo.png" >> "$output/Rewind-provenance.txt"

export TEST_RUNNER_OPENCLAW_IOS_REWIND_PROOF=1
export TEST_RUNNER_OPENCLAW_IOS_LIVE_SETUP_CODE='{"url":"ws://127.0.0.1:19876","token":"synthetic-rewind-token"}'
export TEST_RUNNER_OPENCLAW_IOS_REWIND_FIXTURE_URL=http://127.0.0.1:19876

run_test() {
  local tree="$1" stage="$2" expected_marker="$3"
  local result="$output/Rewind-${stage}.xcresult"
  local log="$output/Rewind-${stage}.log" status=0
  # Keep Actions log backpressure outside the simulator, retaining complete logs and xcresults.
  xcodebuild -project "$tree/apps/ios/OpenClaw.xcodeproj" -scheme OpenClawUITests \
    -configuration Debug -destination "platform=iOS Simulator,id=$simulator" \
    -testLanguage en -testRegion US -parallel-testing-enabled NO \
    -resultBundlePath "$result" \
    -only-testing:OpenClawUITests/RewindComposerUITests/testNewerComposerSurvivesDelayedRewind \
    test > "$log" 2>&1 || status=$?
  tail -c 8192 "$log"
  [[ -d "$result" ]] || return 1
  xcrun xcresulttool get test-results summary --path "$result" --compact > "$result.summary.json"
  xcrun xcresulttool export attachments --path "$result" --output-path "$output/attachments-$stage"
  if [[ -n "$expected_marker" ]]; then
    # A compile/setup/crash failure is never behavioral red.
    [[ "$status" -ne 0 ]] || return 1
    grep -q "$expected_marker" "$log" || return 1
    node -e 'const r=require(process.argv[1]);if(r.result!=="Failed"||r.failedTests!==1||r.passedTests!==0)process.exit(1)' "$result.summary.json"
    printf 'Verified baseline behavioral red: %s\n' "$expected_marker"
  else
    [[ "$status" -eq 0 ]]
    node -e 'const r=require(process.argv[1]);if(r.result!=="Passed"||r.failedTests!==0||r.passedTests<1)process.exit(1)' "$result.summary.json"
  fi
}

run_revision() {
  local tree="$1" stage="$2"
  simulator="$(xcrun simctl create "OpenClaw rewind $stage $$" "$device" "$runtime")"
  xcrun simctl boot "$simulator"
  xcrun simctl bootstatus "$simulator" -b
  xcrun simctl status_bar "$simulator" override --time 09:41 --batteryState charged --batteryLevel 100
  xcrun simctl addphoto "$simulator" "$scratch/photo.png"
  (
    cd "$tree"
    ./scripts/ios-configure-signing.sh
    ./scripts/ios-write-version-xcconfig.sh
    node scripts/ios-write-swift-filelist.mjs
    xcodegen generate --spec apps/ios/project.yml --project apps/ios
  )
  node "$root/scripts/test-ios-shell-gateway.mjs" --rewind > "$output/Rewind-$stage-gateway.log" 2>&1 &
  fixture_pid=$!
  xcrun simctl io "$simulator" recordVideo --codec=h264 --force "$output/Rewind-$stage.mov" > /dev/null 2>&1 &
  video_pid=$!
  if [[ "$stage" == before ]]; then
    run_test "$tree" "$stage" REWIND_PROOF_COMPOSER_LOST
  else
    run_test "$tree" "$stage" ""
  fi
  kill -INT "$video_pid"
  wait "$video_pid" 2>/dev/null || true
  video_pid=""
  kill "$fixture_pid"
  wait "$fixture_pid"
  fixture_pid=""
  xcrun simctl shutdown "$simulator"
  xcrun simctl delete "$simulator"
  simulator=""
}

if [[ -n "$baseline" ]]; then
  [[ "$baseline" =~ ^[0-9a-f]{40}$ ]] || { echo 'Expected an exact baseline SHA' >&2; exit 2; }
  git cat-file -e "$baseline^{commit}" || git -c gc.auto=0 fetch --no-tags --depth=1 https://github.com/openclaw/openclaw.git "$baseline"
  before_checkout="$scratch/before"
  git worktree add --detach "$before_checkout" "$baseline"
  # Drive the true pre-fix app with this exact test, like test-ios-chat-attachments.sh.
  cp apps/ios/UITests/RewindComposerUITests.swift "$before_checkout/apps/ios/UITests/"
  (cd "$before_checkout" && pnpm install --frozen-lockfile)
  if [[ -f "$before_checkout/scripts/prepare-apple-mermaid.mjs" ]]; then
    (cd "$before_checkout" && node scripts/prepare-apple-mermaid.mjs)
  fi
  git -C "$before_checkout" diff --exit-code -- apps/ios/Sources apps/shared/OpenClawKit/Sources
  run_revision "$before_checkout" before
  git -C "$before_checkout" diff --exit-code -- apps/ios/Sources apps/shared/OpenClawKit/Sources
fi
run_revision "$root" after
