#!/bin/bash
# RedBotster Fee Claim + Accumulate Automation
#
# Flow:
#   1. Check unclaimed Clanker creator fees for RED
#   2. If above threshold, claim them
#   3. Split proceeds: GRT buy (Ethereum mainnet) + RED burn (Base → 0xdead)
#   4. Post character-driven tweet via xurl
#   5. Log everything to ~/RedBotster/logs/
#
# Usage: ./fee-claim-and-buy.sh [--dry-run]

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG_FILE="$PROJECT_DIR/config.json"
LOG_DIR="$PROJECT_DIR/logs"
TRACKER="$HOME/RedBotster.md"

BANKR="$HOME/.openclaw/workspace/skills/bankr/scripts/bankr.sh"
RED_TOKEN="0x2e662015a501f066e043d64d04f77ffe551a4b07"
GRT_TOKEN_ETH="0xc944E90C64B2c07662A292be6244BDf05Cda44a"  # GRT on Ethereum mainnet
BURN_ADDRESS="0x000000000000000000000000000000000000dEaD"

# Defaults (overridden by config.json if present)
MIN_THRESHOLD=10      # USD — don't run if fees below this
GRT_SPLIT_PCT=70      # % of claimed fees to buy GRT
BURN_SPLIT_PCT=30     # % to buy RED and burn (send to 0xdead)
DRY_RUN=false

# ── Parse args ────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
  esac
done

# ── Load config.json overrides ────────────────────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
  MIN_THRESHOLD=$(jq -r '.minThresholdUSD // 10' "$CONFIG_FILE")
  GRT_SPLIT_PCT=$(jq -r '.grtSplitPct // 70' "$CONFIG_FILE")
  BURN_SPLIT_PCT=$(jq -r '.burnSplitPct // 30' "$CONFIG_FILE")
fi

# ── Setup ─────────────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
LOGFILE="$LOG_DIR/$(date +%Y-%m-%d).log"
TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# log writes to stderr + logfile only — stdout is reserved for clean JSON returns
log() {
  local msg="[$TIMESTAMP] $*"
  echo "$msg" >&2
  echo "$msg" >> "$LOGFILE"
}
log_section() { echo "" >> "$LOGFILE"; log "── $* ──"; }

log_section "RedBotster Fee Automation START"
log "DRY_RUN=$DRY_RUN | threshold=\$$MIN_THRESHOLD | split=${GRT_SPLIT_PCT}% GRT / ${BURN_SPLIT_PCT}% BURN"

# ── Helpers ───────────────────────────────────────────────────────────────────

# Extract a dollar amount from bankr natural-language response.
# Tries: $X.XX | X USDC | X USD | USD X — returns empty string if not found.
parse_usd() {
  local text="$1"
  # Prefer explicit dollar sign first
  local val
  val=$(echo "$text" | grep -oE '\$[0-9]+(\.[0-9]+)?' | head -1 | tr -d '$') && [ -n "$val" ] && echo "$val" && return
  # USDC amount
  val=$(echo "$text" | grep -oiE '[0-9]+(\.[0-9]+)?\s*USDC' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?') && [ -n "$val" ] && echo "$val" && return
  # "X USD"
  val=$(echo "$text" | grep -oiE '[0-9]+(\.[0-9]+)?\s*USD' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?') && [ -n "$val" ] && echo "$val" && return
  echo ""
}

# Integer math: floor(A * B / 100)
pct_of() {
  local total="$1" pct="$2"
  echo "$total $pct" | awk '{printf "%.2f", $1 * $2 / 100}'
}

# Check if xurl is authenticated
xurl_ready() {
  xurl auth status 2>/dev/null | grep -q "Logged in" && return 0 || return 1
}

# Post to @redbotster (skip gracefully if not authed)
tweet() {
  local msg="$1"
  if xurl_ready; then
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY RUN] Would tweet: $msg"
    else
      xurl post "$msg" >> "$LOGFILE" 2>&1 && log "Tweeted: $msg" || log "WARN: Tweet failed (non-fatal)"
    fi
  else
    log "xurl not authenticated — skipping tweet (run xurl auth oauth2 to enable)"
  fi
}

# Run a bankr command and return JSON to stdout (logs go to stderr/logfile only)
bankr_run() {
  local prompt="$1"
  log "BANKR: $prompt"
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY RUN] Would run bankr: $prompt"
    # Simulate realistic responses based on prompt keywords
    if echo "$prompt" | grep -qi "check\|balance\|unclaimed"; then
      echo '{"status":"completed","response":"You have $24.50 in unclaimed Clanker creator fees for RED token on Base."}'
    elif echo "$prompt" | grep -qi "claim"; then
      echo '{"status":"completed","response":"Successfully claimed $24.50 USDC in creator fees for RED on Base."}'
    elif echo "$prompt" | grep -qi "GRT"; then
      echo '{"status":"completed","response":"Bought 850.25 GRT on Ethereum mainnet for $17.15 USDC."}'
    elif echo "$prompt" | grep -qi "buy.*RED\|RED.*buy"; then
      echo '{"status":"completed","response":"Bought 42000 RED on Base for $7.35 USDC."}'
    elif echo "$prompt" | grep -qi "send\|burn\|0xdead"; then
      echo '{"status":"completed","response":"Sent 42000 RED to burn address 0x000000000000000000000000000000000000dEaD. Transaction confirmed."}'
    else
      echo '{"status":"completed","response":"Operation completed successfully."}'
    fi
    return
  fi
  "$BANKR" "$prompt" 2>>"$LOGFILE"
}

# Append a summary line to ~/RedBotster.md
update_tracker() {
  local line="$1"
  if [ -f "$TRACKER" ]; then
    # Insert under ## Decisions Log
    local entry="- $(date +%Y-%m-%d): $line"
    # Append to end of file
    echo "$entry" >> "$TRACKER"
  fi
}

# ── Step 1: Check current fee balance ─────────────────────────────────────────
log_section "Step 1: Check Clanker fee balance"

CHECK_RESULT=$(bankr_run "Check my current unclaimed Clanker creator fee balance for the RED token. Show me the USD value available to claim.")
CHECK_RESPONSE=$(echo "$CHECK_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "Response: $CHECK_RESPONSE"

# Check for "no fees" / "nothing to claim" language
if echo "$CHECK_RESPONSE" | grep -qiE "no fees|nothing to claim|0\.00|no unclaimed|zero"; then
  log "No fees to claim. Exiting."
  update_tracker "Fee check: nothing to claim."
  exit 0
fi

AVAILABLE_USD=$(parse_usd "$CHECK_RESPONSE")
log "Parsed available: \$$AVAILABLE_USD"

# ── Step 2: Threshold check ───────────────────────────────────────────────────
log_section "Step 2: Threshold check"

if [ -z "$AVAILABLE_USD" ]; then
  log "Could not parse fee amount from response. Proceeding with claim anyway."
else
  # bc comparison: is available >= threshold?
  ABOVE=$(echo "$AVAILABLE_USD $MIN_THRESHOLD" | awk '{print ($1 >= $2) ? "yes" : "no"}')
  if [ "$ABOVE" = "no" ]; then
    log "Available \$$AVAILABLE_USD is below threshold \$$MIN_THRESHOLD. Skipping."
    update_tracker "Fee check: \$$AVAILABLE_USD available, below \$$MIN_THRESHOLD threshold."
    exit 0
  fi
  log "\$$AVAILABLE_USD >= threshold \$$MIN_THRESHOLD — proceeding."
fi

# ── Step 3: Claim fees ────────────────────────────────────────────────────────
log_section "Step 3: Claim Clanker fees"

CLAIM_RESULT=$(bankr_run "Claim all my unclaimed Clanker creator fees for the RED token on Base. Tell me the total USD value claimed.")
CLAIM_RESPONSE=$(echo "$CLAIM_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "Claim response: $CLAIM_RESPONSE"

CLAIMED_USD=$(parse_usd "$CLAIM_RESPONSE")
if [ -z "$CLAIMED_USD" ]; then
  # Fall back to the available amount we already parsed
  CLAIMED_USD="${AVAILABLE_USD:-0}"
  log "Could not parse claimed amount — using pre-claim estimate: \$$CLAIMED_USD"
fi

log "Claimed: \$$CLAIMED_USD"

if [ "$CLAIMED_USD" = "0" ] || [ -z "$CLAIMED_USD" ]; then
  log "Nothing claimed. Exiting."
  exit 0
fi

# ── Step 4: Calculate splits ──────────────────────────────────────────────────
log_section "Step 4: Calculating splits"

GRT_USD=$(pct_of "$CLAIMED_USD" "$GRT_SPLIT_PCT")
BURN_USD=$(pct_of "$CLAIMED_USD" "$BURN_SPLIT_PCT")

log "Claimed \$$CLAIMED_USD → GRT: \$$GRT_USD (${GRT_SPLIT_PCT}%) | BURN: \$$BURN_USD (${BURN_SPLIT_PCT}%)"

# ── Step 5: Buy GRT on Ethereum mainnet ───────────────────────────────────────
log_section "Step 5: Buy GRT"

GRT_RESULT=$(bankr_run "Buy exactly \$$GRT_USD worth of GRT ($GRT_TOKEN_ETH) on Ethereum mainnet.")
GRT_RESPONSE=$(echo "$GRT_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "GRT buy response: $GRT_RESPONSE"

GRT_AMOUNT=$(parse_usd "$GRT_RESPONSE")

# Try to extract GRT token amount (e.g. "123.45 GRT")
GRT_TOKENS=$(echo "$GRT_RESPONSE" | grep -oiE '[0-9]+(\.[0-9]+)?\s*GRT' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || echo "")

# ── Step 6: Buy RED and burn ──────────────────────────────────────────────────
log_section "Step 6: Buy RED + Burn"

# Buy RED on Base
BUY_RED_RESULT=$(bankr_run "Buy exactly \$$BURN_USD worth of RED ($RED_TOKEN) on Base mainnet.")
BUY_RED_RESPONSE=$(echo "$BUY_RED_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "RED buy response: $BUY_RED_RESPONSE"

# Extract RED token amount bought
RED_AMOUNT_RAW=$(echo "$BUY_RED_RESPONSE" | grep -oiE '[0-9,]+(\.[0-9]+)?\s*RED' | head -1 | grep -oE '[0-9,]+(\.[0-9]+)?' | tr -d ',' || echo "")
RED_DISPLAY="${RED_AMOUNT_RAW:-unknown}"

# Send RED to burn address
if [ -n "$RED_AMOUNT_RAW" ] && [ "$RED_AMOUNT_RAW" != "unknown" ]; then
  BURN_RESULT=$(bankr_run "Send all my RED ($RED_TOKEN) on Base to the burn address $BURN_ADDRESS")
  BURN_RESPONSE=$(echo "$BURN_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
  log "Burn response: $BURN_RESPONSE"
else
  log "WARN: Could not determine RED amount to burn — manual burn may be needed"
  BURN_RESPONSE="Could not parse RED amount for burn"
fi

# ── Step 7: Compose and post tweet ───────────────────────────────────────────
log_section "Step 7: Tweet"

# Format RED amount with commas for readability
if [ -n "$RED_AMOUNT_RAW" ]; then
  RED_DISPLAY=$(echo "$RED_AMOUNT_RAW" | awk '{printf "%\047.0f", $1}' 2>/dev/null || echo "$RED_AMOUNT_RAW")
fi

GRT_DISPLAY="${GRT_TOKENS:-\$${GRT_USD} worth}"

TWEET="Just ate ${RED_DISPLAY} \$RED for breakfast and burned every last one 🔥
Bought ${GRT_DISPLAY} \$GRT on Ethereum.

Total claimed: \$$CLAIMED_USD in fees.
Still hungry. 🤖

\$RED \$GRT #DeFi #RedBotster"

tweet "$TWEET"

# ── Step 8: Update tracker ────────────────────────────────────────────────────
log_section "Step 8: Update tracker"

SUMMARY="Claimed \$$CLAIMED_USD fees → Bought ${GRT_DISPLAY} GRT | Burned ${RED_DISPLAY} RED"
update_tracker "$SUMMARY"
log "Tracker updated."

# ── Done ──────────────────────────────────────────────────────────────────────
log_section "DONE"
log "Run complete. See $LOGFILE for full output."
echo ""
echo "✅ RedBotster automation complete:"
echo "   Claimed: \$$CLAIMED_USD"
echo "   GRT:     ${GRT_DISPLAY}"
echo "   Burned:  ${RED_DISPLAY} RED"
