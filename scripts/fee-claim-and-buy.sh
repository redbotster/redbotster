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
SWAP_SCRIPT="$SCRIPT_DIR/uniswap-swap.py"
RED_TOKEN="0x2e662015a501f066e043d64d04f77ffe551a4b07"
GRT_TOKEN_ETH="0xc944e90c64b2c07662a292be6244bdf05cda44a7"  # GRT on Ethereum mainnet
WBTC_TOKEN_ETH="0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599"  # WBTC on Ethereum mainnet
BURN_ADDRESS="0x000000000000000000000000000000000000dEaD"
PUNKWALLET="0xEF5527cC704C5Ca5443869EAECbB8613d9D97E5F"
BANKR_TIMEOUT=20  # seconds before we consider bankr down and fall back to Uniswap

# Defaults (overridden by config.json if present)
MIN_THRESHOLD=10      # USD — don't run if fees below this
GRT_SPLIT_PCT=65      # % to buy GRT
RED_SPLIT_PCT=30      # % to buy RED (burn only if >10% of supply)
WBTC_SPLIT_PCT=5      # % to buy WBTC
DRY_RUN=false
TWEET_ENABLED=false   # disabled until X posting is working

# ── Parse args ────────────────────────────────────────────────────────────────
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --tweet)   TWEET_ENABLED=true ;;
  esac
done

# ── Load config.json overrides ────────────────────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
  MIN_THRESHOLD=$(jq -r '.minThresholdUSD // 10' "$CONFIG_FILE")
  GRT_SPLIT_PCT=$(jq -r '.grtSplitPct // 65' "$CONFIG_FILE")
  RED_SPLIT_PCT=$(jq -r '.redSplitPct // 30' "$CONFIG_FILE")
  WBTC_SPLIT_PCT=$(jq -r '.wbtcSplitPct // 5' "$CONFIG_FILE")
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
log "DRY_RUN=$DRY_RUN | threshold=\$$MIN_THRESHOLD | split=${GRT_SPLIT_PCT}% GRT / ${RED_SPLIT_PCT}% RED / ${WBTC_SPLIT_PCT}% WBTC"

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

# Post to @redbotster (disabled until X posting is working)
tweet() {
  local msg="$1"
  if [ "$TWEET_ENABLED" = "false" ]; then
    log "Tweeting disabled — skipping (re-enable with --tweet flag)"
    return
  fi
  if xurl_ready; then
    if [ "$DRY_RUN" = "true" ]; then
      log "[DRY RUN] Would tweet: $msg"
    else
      xurl post "$msg" >> "$LOGFILE" 2>&1 && log "Tweeted: $msg" || log "WARN: Tweet failed (non-fatal)"
    fi
  else
    log "xurl not authenticated — skipping tweet"
  fi
}

# Check if bankr is responsive (quick probe)
bankr_alive() {
  if [ ! -f "$BANKR" ]; then return 1; fi
  # Try a trivial call with a short timeout
  if command -v gtimeout &>/dev/null; then
    gtimeout "$BANKR_TIMEOUT" "$BANKR" "ping" >/dev/null 2>&1 && return 0 || return 1
  else
    # No gtimeout on macOS by default — use background job approach
    "$BANKR" "ping" >/dev/null 2>&1 &
    local pid=$!
    sleep "$BANKR_TIMEOUT"
    if kill -0 "$pid" 2>/dev/null; then kill "$pid"; return 1; fi
    return 0
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

# Swap via Uniswap v3 (fallback when bankr is down)
# uniswap_swap <token-out> <amount-usd>
uniswap_swap() {
  local token_out="$1" amount_usd="$2"
  log "UNISWAP: swap $amount_usd USD → $token_out"
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY RUN] Would uniswap swap $amount_usd USD → $token_out"
    if [ "$token_out" = "GRT" ]; then
      echo '{"status":"completed","response":"Bought 850.25 GRT on ethereum for $17.15 USDC."}'
    else
      echo '{"status":"completed","response":"Bought 42000 RED on base for $7.35 USDC."}'
    fi
    return
  fi
  python3 "$SWAP_SCRIPT" swap --token-out "$token_out" --amount-usd "$amount_usd" 2>>"$LOGFILE"
}

# Transfer token to address via Uniswap script
# uniswap_transfer <token> <to-address>
uniswap_transfer() {
  local token="$1" to="$2"
  log "UNISWAP TRANSFER: all $token → $to"
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY RUN] Would transfer all $token to $to"
    echo '{"status":"completed","response":"Sent 42000 RED to burn address. Transaction confirmed."}'
    return
  fi
  python3 "$SWAP_SCRIPT" transfer --token "$token" --to "$to" 2>>"$LOGFILE"
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

# ── Step 3b: Sweep RED from bankr wallet to punkwallet ────────────────────────
log_section "Step 3b: Sweep RED from bankr → punkwallet"

if [ "$DRY_RUN" = "true" ]; then
  log "[DRY RUN] Would sweep RED from bankr to $PUNKWALLET"
else
  SWEEP_RESULT=$(bankr_run "Send all my RED token ($RED_TOKEN) on Base to $PUNKWALLET" 2>/dev/null) || true
  SWEEP_RESPONSE=$(echo "$SWEEP_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "bankr unavailable for sweep")
  log "Sweep response: $SWEEP_RESPONSE"
fi

# ── Step 4: Calculate splits ──────────────────────────────────────────────────
log_section "Step 4: Calculating splits"

GRT_USD=$(pct_of "$CLAIMED_USD" "$GRT_SPLIT_PCT")
RED_USD=$(pct_of "$CLAIMED_USD" "$RED_SPLIT_PCT")
WBTC_USD=$(pct_of "$CLAIMED_USD" "$WBTC_SPLIT_PCT")

log "Claimed \$$CLAIMED_USD → GRT: \$$GRT_USD (${GRT_SPLIT_PCT}%) | RED: \$$RED_USD (${RED_SPLIT_PCT}%) | WBTC: \$$WBTC_USD (${WBTC_SPLIT_PCT}%)"

# ── Step 5: Buy GRT on Ethereum mainnet ───────────────────────────────────────
log_section "Step 5: Buy GRT"

GRT_RESULT=""
if [ "$DRY_RUN" = "false" ] && [ -f "$BANKR" ]; then
  log "Attempting bankr for GRT buy..."
  GRT_RESULT=$(bankr_run "Buy exactly \$$GRT_USD worth of GRT ($GRT_TOKEN_ETH) on Ethereum mainnet." 2>/dev/null) || true
fi

if [ -z "$GRT_RESULT" ] || echo "$GRT_RESULT" | grep -qi "error\|failed\|timeout"; then
  log "Bankr unavailable for GRT — using Uniswap v3 (WETH→GRT)"
  GRT_RESULT=$(uniswap_swap "GRT" "$GRT_USD")
fi

GRT_RESPONSE=$(echo "$GRT_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "GRT buy response: $GRT_RESPONSE"
GRT_TOKENS=$(echo "$GRT_RESPONSE" | grep -oiE '[0-9]+(\.[0-9]+)?\s*GRT' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || echo "")

# ── Step 5b: Buy WBTC on Ethereum mainnet ─────────────────────────────────────
log_section "Step 5b: Buy WBTC (5%)"

WBTC_RESULT=""
if [ "$DRY_RUN" = "false" ] && [ -f "$BANKR" ]; then
  log "Attempting bankr for WBTC buy..."
  WBTC_RESULT=$(bankr_run "Buy exactly \$$WBTC_USD worth of WBTC ($WBTC_TOKEN_ETH) on Ethereum mainnet." 2>/dev/null) || true
fi

if [ -z "$WBTC_RESULT" ] || echo "$WBTC_RESULT" | grep -qi "error\|failed\|timeout"; then
  log "Bankr unavailable for WBTC — using Uniswap v3 (WETH→WBTC)"
  WBTC_RESULT=$(uniswap_swap "WBTC" "$WBTC_USD")
fi

WBTC_RESPONSE=$(echo "$WBTC_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "WBTC buy response: $WBTC_RESPONSE"
WBTC_TOKENS=$(echo "$WBTC_RESPONSE" | grep -oiE '[0-9]+(\.[0-9]+)?\s*WBTC' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || echo "")

# ── Step 6: Buy RED (and burn only if >10% of supply) ─────────────────────────
log_section "Step 6: Buy RED + conditional burn"

BUY_RED_RESULT=""
if [ "$DRY_RUN" = "false" ] && [ -f "$BANKR" ]; then
  log "Attempting bankr for RED buy..."
  BUY_RED_RESULT=$(bankr_run "Buy exactly \$$RED_USD worth of RED ($RED_TOKEN) on Base mainnet." 2>/dev/null) || true
fi

if [ -z "$BUY_RED_RESULT" ] || echo "$BUY_RED_RESULT" | grep -qi "error\|failed\|timeout"; then
  log "Bankr unavailable for RED — using Uniswap v3 (WETH→RED)"
  BUY_RED_RESULT=$(uniswap_swap "RED" "$RED_USD")
fi

BUY_RED_RESPONSE=$(echo "$BUY_RED_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "RED buy response: $BUY_RED_RESPONSE"
RED_AMOUNT_RAW=$(echo "$BUY_RED_RESPONSE" | grep -oiE '[0-9,]+(\.[0-9]+)?\s*RED' | head -1 | grep -oE '[0-9,]+(\.[0-9]+)?' | tr -d ',' || echo "")
RED_DISPLAY="${RED_AMOUNT_RAW:-unknown}"

# Check if burn threshold met (>10% of total supply)
BURN_ELIGIBLE="no"
BURN_RESPONSE="Accumulating RED — burn threshold not reached"
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY RUN] Would check RED burn threshold — skipping"
else
  THRESHOLD_CHECK=$(python3 "$SWAP_SCRIPT" check-burn 2>/dev/null || echo '{"data":{"eligible":false}}')
  BURN_ELIGIBLE=$(echo "$THRESHOLD_CHECK" | jq -r '.data.eligible // false' 2>/dev/null || echo "false")
  BURN_PCT=$(echo "$THRESHOLD_CHECK" | jq -r '.data.pct // 0' 2>/dev/null || echo "0")
  log "RED burn eligibility: $BURN_ELIGIBLE (holding ${BURN_PCT}% of supply)"
fi

if [ "$BURN_ELIGIBLE" = "true" ]; then
  log "🔥 Burn threshold reached — burning all RED"
  BURN_RESULT=$(uniswap_transfer "RED" "$BURN_ADDRESS")
  BURN_RESPONSE=$(echo "$BURN_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
  log "Burn response: $BURN_RESPONSE"
else
  log "Accumulating RED (not burning yet — need >10% of supply)"
fi

# ── Step 7: Compose and post tweet ───────────────────────────────────────────
log_section "Step 7: Tweet"

# Format RED amount with commas for readability
if [ -n "$RED_AMOUNT_RAW" ]; then
  RED_DISPLAY=$(echo "$RED_AMOUNT_RAW" | awk '{printf "%\047.0f", $1}' 2>/dev/null || echo "$RED_AMOUNT_RAW")
fi

GRT_DISPLAY="${GRT_TOKENS:-\$${GRT_USD} worth}"
WBTC_DISPLAY="${WBTC_TOKENS:-\$${WBTC_USD} worth}"

if [ "$BURN_ELIGIBLE" = "true" ]; then
  TWEET="Just ate ${RED_DISPLAY} \$RED for breakfast and burned every last one 🔥
Stacked ${GRT_DISPLAY} \$GRT on Ethereum.
Stacked ${WBTC_DISPLAY} \$WBTC.

Total claimed: \$$CLAIMED_USD in Clanker fees.
Still hungry. 🤖

\$RED \$GRT \$WBTC #DeFi #RedBotster"
else
  TWEET="Claimed \$$CLAIMED_USD in \$RED creator fees.
Stacked ${GRT_DISPLAY} \$GRT + ${WBTC_DISPLAY} \$WBTC + ${RED_DISPLAY} \$RED.

Burning RED when I hold >10% of supply.
Accumulating until then. 🤖🔥

\$RED \$GRT \$WBTC #DeFi #RedBotster"
fi

tweet "$TWEET"

# ── Step 8: Update tracker ────────────────────────────────────────────────────
log_section "Step 8: Update tracker"

BURN_NOTE=$([ "$BURN_ELIGIBLE" = "true" ] && echo "BURNED ${RED_DISPLAY} RED" || echo "Accumulated ${RED_DISPLAY} RED (below burn threshold)")
SUMMARY="Claimed \$$CLAIMED_USD fees → Bought ${GRT_DISPLAY} GRT | ${WBTC_DISPLAY} WBTC | ${BURN_NOTE}"
update_tracker "$SUMMARY"
log "Tracker updated."

# ── Done ──────────────────────────────────────────────────────────────────────
log_section "DONE"
log "Run complete. See $LOGFILE for full output."
echo ""
echo "✅ RedBotster automation complete:"
echo "   Claimed: \$$CLAIMED_USD"
echo "   GRT:     ${GRT_DISPLAY}"
echo "   WBTC:    ${WBTC_DISPLAY}"
echo "   RED:     ${RED_DISPLAY} ($([ "$BURN_ELIGIBLE" = "true" ] && echo "BURNED" || echo "accumulating"))"
