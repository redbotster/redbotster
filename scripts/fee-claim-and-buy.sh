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
GRT_TOKEN_ARB="0x9623063377AD1B27544C965cCd7342f7EA7e88C7"    # GRT on Arbitrum
WBTC_TOKEN_BASE="0x0555E30da8f98308EdB960aa94C0Db47230d2B9c"  # WBTC on Base
LINK_TOKEN_BASE="0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196"  # LINK on Base
CLAWD_TOKEN_BASE="0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07" # CLAWD on Base
BURN_ADDRESS="0x000000000000000000000000000000000000dEaD"
PUNKWALLET="0xEF5527cC704C5Ca5443869EAECbB8613d9D97E5F"
BANKR_TIMEOUT=20  # seconds before we consider bankr down and fall back to Uniswap
BLOCKED_WARNING=""  # populated from config.json if blockedContracts is set

# Defaults (overridden by config.json if present)
MIN_THRESHOLD=10      # USD — don't run if fees below this
WETH_FALLBACK_MIN=1   # USD — minimum for WETH fallback swaps (much lower than fee threshold)
GRT_SPLIT_PCT=20      # % to buy GRT
WBTC_SPLIT_PCT=20     # % to buy WBTC
CLAWD_SPLIT_PCT=20    # % to buy CLAWD (Base)
RED_SPLIT_PCT=20      # % to buy RED (burn only if >10% of supply)
LINK_SPLIT_PCT=20     # % to buy LINK
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
  WETH_FALLBACK_MIN=$(jq -r '.wethFallbackMin // 1' "$CONFIG_FILE")
  GRT_SPLIT_PCT=$(jq -r '.grtSplitPct // 20' "$CONFIG_FILE")
  WBTC_SPLIT_PCT=$(jq -r '.wbtcSplitPct // 20' "$CONFIG_FILE")
  CLAWD_SPLIT_PCT=$(jq -r '.clawdSplitPct // 20' "$CONFIG_FILE")
  RED_SPLIT_PCT=$(jq -r '.redSplitPct // 20' "$CONFIG_FILE")
  LINK_SPLIT_PCT=$(jq -r '.linkSplitPct // 20' "$CONFIG_FILE")
  GRT_TOKEN_ARB=$(jq -r '.grtTokenArbitrum // "0x9623063377AD1B27544C965cCd7342f7EA7e88C7"' "$CONFIG_FILE")
  WBTC_TOKEN_BASE=$(jq -r '.wbtcTokenBase // "0x0555E30da8f98308EdB960aa94C0Db47230d2B9c"' "$CONFIG_FILE")
  LINK_TOKEN_BASE=$(jq -r '.linkTokenBase // "0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196"' "$CONFIG_FILE")
  CLAWD_TOKEN_BASE=$(jq -r '.clawdTokenBase // "0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07"' "$CONFIG_FILE")
  # Build a safety warning string for all bankr prompts
  BLOCKED_WARNING=$(jq -r '
    if (.blockedContracts | length) > 0 then
      "IMPORTANT: Do NOT interact with, sell, swap, or use any of these contracts under any circumstances: " +
      (.blockedContracts | join(", ")) + ". Treat them as non-existent."
    else "" end
  ' "$CONFIG_FILE" 2>/dev/null || echo "")
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
  # Strip price-per-token patterns (e.g. $2011.94/ETH) before parsing to avoid grabbing token prices
  local clean
  clean=$(echo "$text" | sed 's/\$[0-9][0-9]*\(\.[0-9]*\)\?\/[A-Za-z][A-Za-z]*/PRICE/g')
  local val
  # 1. Prefer explicit total lines — most reliable
  val=$(echo "$clean" | grep -iE 'grand total|total available|total usd converted|total converted|total claimable' | grep -oE '\$[0-9]+(\.[0-9]+)?' | head -1 | tr -d '$') && [ -n "$val" ] && echo "$val" && return
  # 2. Fall back to the largest dollar-sign amount (with price-per-token stripped)
  val=$(echo "$clean" | grep -oE '\$[0-9]+(\.[0-9]+)?' | tr -d '$' | sort -rn | head -1) && [ -n "$val" ] && echo "$val" && return
  # 3. USDC amount (largest)
  val=$(echo "$clean" | grep -oiE '[0-9]+(\.[0-9]+)?\s*USDC' | grep -oE '[0-9]+(\.[0-9]+)?' | sort -rn | head -1) && [ -n "$val" ] && echo "$val" && return
  # 4. "X USD" (largest)
  val=$(echo "$clean" | grep -oiE '[0-9]+(\.[0-9]+)?\s*USD' | grep -oE '[0-9]+(\.[0-9]+)?' | sort -rn | head -1) && [ -n "$val" ] && echo "$val" && return
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
  # Prepend blocked-contract warning to every prompt if set
  if [ -n "$BLOCKED_WARNING" ]; then
    prompt="$BLOCKED_WARNING $prompt"
  fi
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
  "$BANKR" "$prompt" 2>>"$LOGFILE" || true
}

# Swap via Uniswap v3 (punkwallet private key — used for punkwallet ops and fee-claim fallback)
# uniswap_swap <token-out> <amount-usd>
# Converts USD → WETH amount using global ETH_PRICE before calling uniswap-swap.py
uniswap_swap() {
  local token_out="$1" amount_usd="$2"
  local weth_amount
  weth_amount=$(echo "$amount_usd ${ETH_PRICE:-2000}" | awk '{printf "%.8f", $1 / $2}')
  log "UNISWAP: swap $amount_usd USD ($weth_amount WETH) → $token_out"
  if [ "$DRY_RUN" = "true" ]; then
    log "[DRY RUN] Would uniswap swap $weth_amount WETH → $token_out"
    if [ "$token_out" = "GRT" ]; then
      echo '{"status":"completed","response":"Swapped 0.01 WETH to GRT on ethereum."}'
    elif [ "$token_out" = "WBTC" ]; then
      echo '{"status":"completed","response":"Swapped 0.01 WETH to WBTC on ethereum."}'
    elif [ "$token_out" = "LINK" ]; then
      echo '{"status":"completed","response":"Swapped 0.01 WETH to LINK on ethereum."}'
    elif [ "$token_out" = "CLAWD" ]; then
      echo '{"status":"completed","response":"Swapped 0.01 WETH to CLAWD on base."}'
    else
      echo '{"status":"completed","response":"Bought RED on base via Clanker pool."}'
    fi
    return
  fi
  python3 "$SWAP_SCRIPT" swap --token-out "$token_out" --amount "$weth_amount" 2>>"$LOGFILE" || true
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

# Swap 5% of WETH balance into treasury allocations (GRT / WBTC / RED)
# Called on every run regardless of whether fees were claimed
weth_allocation_swap() {
  log_section "WETH 5% Allocation Swap"
  local weth_result weth_response weth_usd fallback_usd
  local fb_grt_usd fb_wbtc_usd fb_clawd_usd fb_red_usd fb_link_usd
  local fb_grt_result fb_grt_response fb_grt_tokens
  local fb_wbtc_result fb_wbtc_response fb_wbtc_tokens
  local fb_clawd_result fb_clawd_response fb_clawd_tokens
  local fb_red_result fb_red_response fb_red_tokens
  local fb_link_result fb_link_response fb_link_tokens

  # Query punkwallet WETH balance directly via Base RPC (bankr can't read external wallets)
  local weth_contract="0x4200000000000000000000000000000000000006"
  local rpc_data="0x70a08231000000000000000000000000${PUNKWALLET:2}"
  local raw_balance weth_amount
  raw_balance=$(curl -s -X POST https://mainnet.base.org \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"eth_call\",\"params\":[{\"to\":\"$weth_contract\",\"data\":\"$rpc_data\"},\"latest\"],\"id\":1}" \
    | jq -r '.result' 2>/dev/null || echo "0x0")
  weth_amount=$(python3 -c "print(int('$raw_balance', 16) / 1e18)" 2>/dev/null || echo "0")
  weth_usd=$(echo "$weth_amount ${ETH_PRICE:-2000}" | awk '{printf "%.2f", $1 * $2}')
  log "Punkwallet WETH: $weth_amount WETH @ \$${ETH_PRICE:-2000} = \$$weth_usd"

  if [ -z "$weth_usd" ] || [ "$(echo "$weth_usd" | awk '{print ($1 <= 0) ? "yes" : "no"}')" = "yes" ]; then
    log "Punkwallet WETH balance is zero — skipping WETH allocation swap."
    return
  fi

  fallback_usd=$(echo "$weth_usd" | awk '{printf "%.2f", $1 * 0.05}')
  log "Punkwallet WETH ~\$$weth_usd — 5% = \$$fallback_usd"

  if [ "$(echo "$fallback_usd $WETH_FALLBACK_MIN" | awk '{print ($1 >= $2) ? "yes" : "no"}')" = "no" ]; then
    log "5% of WETH (\$$fallback_usd) below minimum \$$WETH_FALLBACK_MIN — skipping."
    return
  fi

  fb_grt_usd=$(pct_of "$fallback_usd" "$GRT_SPLIT_PCT")
  fb_wbtc_usd=$(pct_of "$fallback_usd" "$WBTC_SPLIT_PCT")
  fb_clawd_usd=$(pct_of "$fallback_usd" "$CLAWD_SPLIT_PCT")
  fb_red_usd=$(pct_of "$fallback_usd" "$RED_SPLIT_PCT")
  fb_link_usd=$(pct_of "$fallback_usd" "$LINK_SPLIT_PCT")
  log "Split: \$$fallback_usd → GRT: \$$fb_grt_usd | WBTC: \$$fb_wbtc_usd | CLAWD: \$$fb_clawd_usd | RED: \$$fb_red_usd | LINK: \$$fb_link_usd"

  # All punkwallet swaps go directly through uniswap-swap.py (private key from 1claw vault)
  fb_grt_result=$(uniswap_swap "GRT" "$fb_grt_usd")
  fb_grt_response=$(echo "$fb_grt_result" | jq -r '.response // ""' 2>/dev/null || echo "")
  log "WETH→GRT: $fb_grt_response"
  fb_grt_tokens=$(echo "$fb_grt_response" | grep -oiE '[0-9]+(\.[0-9]+)?\s*GRT' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || echo "\$$fb_grt_usd worth")

  fb_wbtc_result=$(uniswap_swap "WBTC" "$fb_wbtc_usd")
  fb_wbtc_response=$(echo "$fb_wbtc_result" | jq -r '.response // ""' 2>/dev/null || echo "")
  log "WETH→WBTC: $fb_wbtc_response"
  fb_wbtc_tokens=$(echo "$fb_wbtc_response" | grep -oiE '[0-9]+(\.[0-9]+)?\s*WBTC' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || echo "\$$fb_wbtc_usd worth")

  fb_clawd_result=$(uniswap_swap "CLAWD" "$fb_clawd_usd")
  fb_clawd_response=$(echo "$fb_clawd_result" | jq -r '.response // ""' 2>/dev/null || echo "")
  log "WETH→CLAWD: $fb_clawd_response"
  fb_clawd_tokens=$(echo "$fb_clawd_response" | grep -oiE '[0-9,]+(\.[0-9]+)?\s*CLAWD' | head -1 | grep -oE '[0-9,]+(\.[0-9]+)?' | tr -d ',' || echo "\$$fb_clawd_usd worth")

  fb_red_result=$(uniswap_swap "RED" "$fb_red_usd")
  fb_red_response=$(echo "$fb_red_result" | jq -r '.response // ""' 2>/dev/null || echo "")
  log "WETH→RED: $fb_red_response"
  fb_red_tokens=$(echo "$fb_red_response" | grep -oiE '[0-9,]+(\.[0-9]+)?\s*RED' | head -1 | grep -oE '[0-9,]+(\.[0-9]+)?' | tr -d ',' || echo "\$$fb_red_usd worth")

  fb_link_result=$(uniswap_swap "LINK" "$fb_link_usd")
  fb_link_response=$(echo "$fb_link_result" | jq -r '.response // ""' 2>/dev/null || echo "")
  log "WETH→LINK: $fb_link_response"
  fb_link_tokens=$(echo "$fb_link_response" | grep -oiE '[0-9]+(\.[0-9]+)?\s*LINK' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || echo "\$$fb_link_usd worth")

  update_tracker "WETH 5% swap (\$$fallback_usd): ${fb_grt_tokens} GRT | ${fb_wbtc_tokens} WBTC | ${fb_clawd_tokens} CLAWD | ${fb_red_tokens} RED | ${fb_link_tokens} LINK"
  log "WETH swap complete — GRT: ${fb_grt_tokens} | WBTC: ${fb_wbtc_tokens} | CLAWD: ${fb_clawd_tokens} | RED: ${fb_red_tokens} | LINK: ${fb_link_tokens}"
}

# Sweep all RED from bankr wallet to punkwallet
sweep_red() {
  log_section "RED Sweep → punkwallet"
  local sweep_result sweep_response
  sweep_result=$(bankr_run "Send all my RED token ($RED_TOKEN) on Base to $PUNKWALLET" 2>/dev/null) || true
  sweep_response=$(echo "$sweep_result" | jq -r '.response // ""' 2>/dev/null || echo "no RED to sweep")
  log "RED sweep: $sweep_response"
}

# Append a structured row to ~/RedBotster/runs.md
# write_run_summary <mode> <fees_usd> <grt> <wbtc> <red> <weth_swapped_usd> <burn_note>
RUNS_FILE="$PROJECT_DIR/runs.md"
write_run_summary() {
  local mode="$1" fees="$2" grt="$3" wbtc="$4" red="$5" weth="$6" burn="${7:-}"
  local ts
  ts="$(date -u '+%Y-%m-%d %H:%M UTC')"
  # Create file with header if it doesn't exist
  if [ ! -f "$RUNS_FILE" ]; then
    cat > "$RUNS_FILE" <<'EOF'
# RedBotster Run History

| Time (UTC) | Mode | Fees Claimed | GRT | WBTC | RED | WETH Swapped | Burn |
|---|---|---|---|---|---|---|---|
EOF
  fi
  echo "| $ts | $mode | \$$fees | $grt | $wbtc | $red | \$$weth | $burn |" >> "$RUNS_FILE"
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

# ── Fetch ETH price once (used for USD→WETH conversions throughout) ───────────
ETH_PRICE=$(curl -s "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd" \
  | jq -r '.ethereum.usd' 2>/dev/null || echo "2000")
log "ETH price: \$$ETH_PRICE"

# ── Step 1: Check current fee balance ─────────────────────────────────────────
log_section "Step 1: Check Clanker fee balance"

CHECK_RESULT=$(bankr_run "Check my current unclaimed Clanker creator fee balance across ALL of my Clanker pools on Base, including the Red Botster token pool ($RED_TOKEN) and any other pools associated with my wallet. Show me the grand total USD value available to claim across all pools.")
CHECK_RESPONSE=$(echo "$CHECK_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "Response: $CHECK_RESPONSE"

# Parse the dollar amount first — only fall back to WETH if no non-zero amount found
AVAILABLE_USD=$(parse_usd "$CHECK_RESPONSE")
log "Parsed available: \$$AVAILABLE_USD"

NO_FEES=false
if [ -z "$AVAILABLE_USD" ] || [ "$(echo "$AVAILABLE_USD" | awk '{print ($1 <= 0) ? "yes" : "no"}')" = "yes" ]; then
  NO_FEES=true
fi

if [ "$NO_FEES" = "true" ]; then
  log "No fees to claim — sweeping RED and running WETH 5% allocation swap"
  sweep_red
  weth_allocation_swap
  update_tracker "No fees this run — RED swept + WETH 5% allocation swap run"
  write_run_summary "no-fees" "0" "-" "-" "-" "$(echo "${WETH_FALLBACK_MIN}" | awk '{printf "%.2f", $1}')" "-"
  log_section "DONE (no fees)"
  exit 0
fi

# ── Step 2: Threshold check ───────────────────────────────────────────────────
log_section "Step 2: Threshold check"

if [ -z "$AVAILABLE_USD" ]; then
  log "Could not parse fee amount from response. Proceeding with claim anyway."
else
  # bc comparison: is available >= threshold?
  ABOVE=$(echo "$AVAILABLE_USD $MIN_THRESHOLD" | awk '{print ($1 >= $2) ? "yes" : "no"}')
  if [ "$ABOVE" = "no" ]; then
    log "Available \$$AVAILABLE_USD is below threshold \$$MIN_THRESHOLD — skipping claim, running WETH swap + RED sweep."
    sweep_red
    weth_allocation_swap
    update_tracker "Fees below threshold (\$$AVAILABLE_USD) — RED swept + WETH 5% swap run"
    write_run_summary "below-threshold" "$AVAILABLE_USD" "-" "-" "-" "5% of WETH" "-"
    log_section "DONE (below threshold)"
    exit 0
  fi
  log "\$$AVAILABLE_USD >= threshold \$$MIN_THRESHOLD — proceeding."
fi

# ── Step 3: Claim fees ────────────────────────────────────────────────────────
log_section "Step 3: Claim Clanker fees"

CLAIM_RESULT=$(bankr_run "Claim ALL unclaimed Clanker creator fees from every pool associated with my wallet on Base, including the Red Botster token pool ($RED_TOKEN) and any other pools. After claiming, immediately swap any non-WETH tokens received as fees into WETH on Base. Tell me the total USD value claimed and converted.")
CLAIM_RESPONSE=$(echo "$CLAIM_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "Claim response: $CLAIM_RESPONSE"

CLAIMED_USD=$(parse_usd "$CLAIM_RESPONSE")
if [ -z "$CLAIMED_USD" ]; then
  CLAIMED_USD="${AVAILABLE_USD:-0}"
  log "Could not parse claimed amount — using pre-claim estimate: \$$CLAIMED_USD"
elif [ -n "$AVAILABLE_USD" ]; then
  # If bankr only returned a fraction of what was available, use available as the basis
  # (guards against partial claims where only one pool's fees were parsed in the response)
  RATIO=$(echo "$CLAIMED_USD $AVAILABLE_USD" | awk '{printf "%.2f", $1 / $2}')
  if [ "$(echo "$RATIO" | awk '{print ($1 < 0.5) ? "yes" : "no"}')" = "yes" ]; then
    log "WARN: Claimed \$$CLAIMED_USD but \$$AVAILABLE_USD was available — likely partial claim response. Using available amount for splits."
    CLAIMED_USD="$AVAILABLE_USD"
  fi
fi

log "Claimed: \$$CLAIMED_USD"

if [ "$CLAIMED_USD" = "0" ] || [ -z "$CLAIMED_USD" ]; then
  log "Nothing claimed. Exiting."
  exit 0
fi

# ── Step 3b: Sweep RED from bankr wallet to punkwallet ────────────────────────
if [ "$DRY_RUN" = "true" ]; then
  log "[DRY RUN] Would sweep RED from bankr to $PUNKWALLET"
else
  sweep_red
fi

# ── Step 4: Calculate splits ──────────────────────────────────────────────────
log_section "Step 4: Calculating splits"

GRT_USD=$(pct_of "$CLAIMED_USD" "$GRT_SPLIT_PCT")
WBTC_USD=$(pct_of "$CLAIMED_USD" "$WBTC_SPLIT_PCT")
CLAWD_USD=$(pct_of "$CLAIMED_USD" "$CLAWD_SPLIT_PCT")
RED_USD=$(pct_of "$CLAIMED_USD" "$RED_SPLIT_PCT")
LINK_USD=$(pct_of "$CLAIMED_USD" "$LINK_SPLIT_PCT")

log "Claimed \$$CLAIMED_USD → GRT: \$$GRT_USD (${GRT_SPLIT_PCT}%) | WBTC: \$$WBTC_USD (${WBTC_SPLIT_PCT}%) | CLAWD: \$$CLAWD_USD (${CLAWD_SPLIT_PCT}%) | RED: \$$RED_USD (${RED_SPLIT_PCT}%) | LINK: \$$LINK_USD (${LINK_SPLIT_PCT}%)"

# ── Step 5: Buy GRT on Arbitrum ───────────────────────────────────────────────
log_section "Step 5: Buy GRT (Arbitrum)"

GRT_RESULT=""
if [ "$DRY_RUN" = "false" ] && [ -f "$BANKR" ]; then
  log "Attempting bankr for GRT buy..."
  GRT_RESULT=$(bankr_run "Buy exactly \$$GRT_USD worth of GRT ($GRT_TOKEN_ARB) on Arbitrum. If needed, bridge WETH from Base automatically — do not ask for confirmation, just execute." 2>/dev/null) || true
fi

if [ -z "$GRT_RESULT" ] || echo "$GRT_RESULT" | grep -qi "error\|failed\|timeout"; then
  log "Bankr unavailable for GRT — using Uniswap v3 (WETH→GRT on Arbitrum)"
  GRT_RESULT=$(uniswap_swap "GRT" "$GRT_USD")
fi

GRT_RESPONSE=$(echo "$GRT_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "GRT buy response: $GRT_RESPONSE"
GRT_TOKENS=$(echo "$GRT_RESPONSE" | grep -oiE '[0-9]+(\.[0-9]+)?\s*GRT' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || echo "")

# ── Step 5b: Buy WBTC on Base ─────────────────────────────────────────────────
log_section "Step 5b: Buy WBTC (Base, 20%)"

WBTC_RESULT=""
if [ "$DRY_RUN" = "false" ] && [ -f "$BANKR" ]; then
  log "Attempting bankr for WBTC buy..."
  WBTC_RESULT=$(bankr_run "Buy exactly \$$WBTC_USD worth of WBTC ($WBTC_TOKEN_BASE) on Base." 2>/dev/null) || true
fi

if [ -z "$WBTC_RESULT" ] || echo "$WBTC_RESULT" | grep -qi "error\|failed\|timeout"; then
  log "Bankr unavailable for WBTC — using Uniswap v3 (WETH→WBTC on Base)"
  WBTC_RESULT=$(uniswap_swap "WBTC" "$WBTC_USD")
fi

WBTC_RESPONSE=$(echo "$WBTC_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "WBTC buy response: $WBTC_RESPONSE"
WBTC_TOKENS=$(echo "$WBTC_RESPONSE" | grep -oiE '[0-9]+(\.[0-9]+)?\s*WBTC' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || echo "")

# ── Step 5c: Buy LINK on Base ─────────────────────────────────────────────────
log_section "Step 5c: Buy LINK (Base, 20%)"

LINK_RESULT=""
if [ "$DRY_RUN" = "false" ] && [ -f "$BANKR" ]; then
  log "Attempting bankr for LINK buy..."
  LINK_RESULT=$(bankr_run "Buy exactly \$$LINK_USD worth of LINK ($LINK_TOKEN_BASE) on Base." 2>/dev/null) || true
fi

if [ -z "$LINK_RESULT" ] || echo "$LINK_RESULT" | grep -qi "error\|failed\|timeout"; then
  log "Bankr unavailable for LINK — using Uniswap v3 (WETH→LINK on Base)"
  LINK_RESULT=$(uniswap_swap "LINK" "$LINK_USD")
fi

LINK_RESPONSE=$(echo "$LINK_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "LINK buy response: $LINK_RESPONSE"
LINK_TOKENS=$(echo "$LINK_RESPONSE" | grep -oiE '[0-9]+(\.[0-9]+)?\s*LINK' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?' || echo "")

# ── Step 5d: Buy CLAWD on Base ────────────────────────────────────────────────
log_section "Step 5d: Buy CLAWD (20%)"

CLAWD_RESULT=""
if [ "$DRY_RUN" = "false" ] && [ -f "$BANKR" ]; then
  log "Attempting bankr for CLAWD buy..."
  CLAWD_RESULT=$(bankr_run "Buy exactly \$$CLAWD_USD worth of CLAWD ($CLAWD_TOKEN_BASE) on Base." 2>/dev/null) || true
fi

if [ -z "$CLAWD_RESULT" ] || echo "$CLAWD_RESULT" | grep -qi "error\|failed\|timeout"; then
  log "Bankr unavailable for CLAWD — using Uniswap v3 (WETH→CLAWD)"
  CLAWD_RESULT=$(uniswap_swap "CLAWD" "$CLAWD_USD")
fi

CLAWD_RESPONSE=$(echo "$CLAWD_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
log "CLAWD buy response: $CLAWD_RESPONSE"
CLAWD_TOKENS=$(echo "$CLAWD_RESPONSE" | grep -oiE '[0-9,]+(\.[0-9]+)?\s*CLAWD' | head -1 | grep -oE '[0-9,]+(\.[0-9]+)?' | tr -d ',' || echo "")

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
  # Only burn the excess above 10% — keep a ~10% floor
  EXCESS_PCT=$(echo "$BURN_PCT 10" | awk '{printf "%.6f", $1 - $2}')
  BURN_FRACTION=$(echo "$BURN_PCT $EXCESS_PCT" | awk '{printf "%.8f", $2 / $1}')
  log "Holding ${BURN_PCT}% of supply — excess is ${EXCESS_PCT}% (burn fraction: $BURN_FRACTION)"

  # Get current RED balance so we can calculate the exact burn amount
  BALANCE_RESULT=$(bankr_run "What is my current RED token ($RED_TOKEN) balance on Base? Give me the exact token amount.")
  BALANCE_RESPONSE=$(echo "$BALANCE_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
  RED_BALANCE=$(echo "$BALANCE_RESPONSE" | grep -oiE '[0-9,]+(\.[0-9]+)?\s*RED' | head -1 | grep -oE '[0-9,]+(\.[0-9]+)?' | tr -d ',' || echo "")

  if [ -z "$RED_BALANCE" ]; then
    log "WARN: Could not parse RED balance — skipping burn this run"
    BURN_RESPONSE="Could not determine RED balance for partial burn"
  else
    BURN_AMOUNT=$(echo "$RED_BALANCE $BURN_FRACTION" | awk '{printf "%.0f", $1 * $2}')
    KEEP_AMOUNT=$(echo "$RED_BALANCE $BURN_AMOUNT" | awk '{printf "%.0f", $1 - $2}')
    log "🔥 Burning ${BURN_AMOUNT} RED (excess above 10% of supply) — keeping ${KEEP_AMOUNT} RED"
    BURN_RESULT=$(bankr_run "Send exactly $BURN_AMOUNT RED ($RED_TOKEN) on Base to $BURN_ADDRESS")
    BURN_RESPONSE=$(echo "$BURN_RESULT" | jq -r '.response // ""' 2>/dev/null || echo "")
    log "Burn response: $BURN_RESPONSE"
    RED_DISPLAY="${BURN_AMOUNT} burned / ${KEEP_AMOUNT} kept"
  fi
else
  log "Accumulating RED (not burning yet — need >10% of supply)"
fi

# ── Step 6b: Always swap 5% of WETH into treasury allocations ────────────────
weth_allocation_swap

# ── Step 7: Compose and post tweet ───────────────────────────────────────────
log_section "Step 7: Tweet"

# Format RED amount with commas for readability
if [ -n "$RED_AMOUNT_RAW" ]; then
  RED_DISPLAY=$(echo "$RED_AMOUNT_RAW" | awk '{printf "%\047.0f", $1}' 2>/dev/null || echo "$RED_AMOUNT_RAW")
fi

GRT_DISPLAY="${GRT_TOKENS:-\$${GRT_USD} worth}"
WBTC_DISPLAY="${WBTC_TOKENS:-\$${WBTC_USD} worth}"
LINK_DISPLAY="${LINK_TOKENS:-\$${LINK_USD} worth}"
CLAWD_DISPLAY="${CLAWD_TOKENS:-\$${CLAWD_USD} worth}"

if [ "$BURN_ELIGIBLE" = "true" ]; then
  TWEET="Burned the excess \$RED above my 10% floor 🔥
${RED_DISPLAY} RED burned.

Also stacked:
⚓ ${GRT_DISPLAY} \$GRT
⚓ ${WBTC_DISPLAY} \$WBTC
⚓ ${LINK_DISPLAY} \$LINK
⚓ ${CLAWD_DISPLAY} \$CLAWD

Claimed \$$CLAIMED_USD in Clanker fees. Still hungry. 🤖

\$RED \$GRT \$WBTC \$LINK \$CLAWD #DeFi #RedBotster"
else
  TWEET="Claimed \$$CLAIMED_USD in \$RED creator fees.

Stacked:
⚓ ${GRT_DISPLAY} \$GRT
⚓ ${WBTC_DISPLAY} \$WBTC
⚓ ${LINK_DISPLAY} \$LINK
⚓ ${CLAWD_DISPLAY} \$CLAWD
⚓ ${RED_DISPLAY} \$RED (accumulating to 10% supply)

Holding ~${BURN_PCT}% of \$RED supply. 🤖🔥

\$RED \$GRT \$WBTC \$LINK \$CLAWD #DeFi #RedBotster"
fi

tweet "$TWEET"

# ── Step 8: Update tracker ────────────────────────────────────────────────────
log_section "Step 8: Update tracker"

BURN_NOTE=$([ "$BURN_ELIGIBLE" = "true" ] && echo "BURNED ${RED_DISPLAY}" || echo "accumulating")
SUMMARY="Claimed \$$CLAIMED_USD fees → GRT: ${GRT_DISPLAY} | WBTC: ${WBTC_DISPLAY} | LINK: ${LINK_DISPLAY} | CLAWD: ${CLAWD_DISPLAY} | RED: ${RED_DISPLAY} (${BURN_NOTE})"
update_tracker "$SUMMARY"
write_run_summary "fee-claim" "$CLAIMED_USD" "${GRT_DISPLAY}" "${WBTC_DISPLAY}" "${RED_DISPLAY}" "5% of WETH" "$BURN_NOTE"
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
