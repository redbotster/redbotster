#!/usr/bin/env python3
"""
uniswap-swap.py — Swap or transfer tokens via Uniswap v3 using punkwallet from 1claw vault.

Commands:
  swap      --token-in WETH|USDC --token-out RED|GRT|WBTC --amount X
  transfer  --token RED|GRT|WBTC --to 0xADDRESS [--amount all|X]
  balance   --token RED|GRT|WBTC|WETH|USDC|ALL
  check-burn-threshold   (returns whether RED balance > 10% of total supply)

Output: JSON to stdout  {"status":"completed","response":"...","tx":"0x..."}
Logs:   stderr only
"""

import argparse
import json
import sys
import urllib.request
from web3 import Web3
from web3.middleware import ExtraDataToPOAMiddleware
from eth_account import Account

# ── 1claw config ──────────────────────────────────────────────────────────────
VAULT_ID  = "d3ac6dbb-16d8-414e-b59d-08eb8df90e9c"
AGENT_ID  = "6739c514-6be6-4f75-a481-84047aee30c5"
API_KEY   = "ocv_HGVFMhjMy0cAa7Nn7yY1qJcVoP2FFYtPXoDlxj-PCQc"
API_BASE  = "https://api.1claw.xyz/v1"

# ── Chain config ───────────────────────────────────────────────────────────────
CHAINS = {
    "base": {
        "chain_id": 8453,
        "rpc": "https://base-rpc.publicnode.com",
        "router": "0x2626664c2603336E57B271c5C0b26F421741e481",  # SwapRouter02
        "usdc":   "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
        "weth":   "0x4200000000000000000000000000000000000006",
        "usdc_decimals": 6,
        "poa": True,
    },
    "ethereum": {
        "chain_id": 1,
        "rpc": "https://ethereum.publicnode.com",
        "router": "0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45",  # SwapRouter02
        "usdc":   "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
        "weth":   "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        "usdc_decimals": 6,
        "poa": False,
    },
}

# ── Token registry ─────────────────────────────────────────────────────────────
TOKENS = {
    "RED":  {"chain": "base",     "address": "0x2e662015a501f066e043d64d04f77ffe551a4b07", "decimals": 18},
    "GRT":  {"chain": "ethereum", "address": "0xc944e90c64b2c07662a292be6244bdf05cda44a7", "decimals": 18},
    "WBTC": {"chain": "ethereum", "address": "0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599", "decimals": 8},
}

# tokenIn options (per chain) — these are the spending tokens
INPUTS = {
    "base": {
        "WETH": ("0x4200000000000000000000000000000000000006", 18),
        "USDC": ("0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", 6),
    },
    "ethereum": {
        "WETH": ("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", 18),
        "USDC": ("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", 6),
    },
}

BURN_ADDRESS       = "0x000000000000000000000000000000000000dEaD"
RED_BURN_THRESHOLD = 0.10   # only burn if wallet holds > 10% of total supply

# ── Clanker pool config (RED trades on a custom Clanker AMM, not Uniswap v3) ──
# RED uses the Clanker pool router at 0x21e99B… which routes through Uniswap v4 internally.
# Pool-specific params decoded from on-chain buy transactions for RED.
CLANKER_ROUTER = "0x21e99B325d53FE3d574ac948B9CB1519DA03E518"
CLANKER_POOL_PARAMS = {
    "RED": {
        "word2":  "0x7f77bad9eb06373fe3aee84f85a9d701ff820eeb",
        "word3":  "0x571bb664cd515b533c2fe68a23367551f6fc559d",
        "word5":  0x0dac,  # 3500
        "word6":  0x7d0,   # 2000
        "word14": "0x6ff5693b99212da76ad316178a184ab56d299b43",  # Universal Router
        "word15": "0x0d5e0f971ed27fbff6c2837bf31316121532048d",  # hook
        "word16": 0x800000,
        "word17": 0xc8,
        "word18": "0xb429d62f8f3bffb98cdb9569533ea23bf0ba28cc",
        "word19": 0x100,
    }
}

# ── ABIs ───────────────────────────────────────────────────────────────────────
ERC20_ABI = [
    {"name": "approve",     "type": "function", "inputs": [{"name": "spender", "type": "address"}, {"name": "amount", "type": "uint256"}], "outputs": [{"type": "bool"}], "stateMutability": "nonpayable"},
    {"name": "allowance",   "type": "function", "inputs": [{"name": "owner", "type": "address"}, {"name": "spender", "type": "address"}], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
    {"name": "balanceOf",   "type": "function", "inputs": [{"name": "account", "type": "address"}], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
    {"name": "totalSupply", "type": "function", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view"},
    {"name": "decimals",    "type": "function", "inputs": [], "outputs": [{"type": "uint8"}], "stateMutability": "view"},
    {"name": "symbol",      "type": "function", "inputs": [], "outputs": [{"type": "string"}], "stateMutability": "view"},
    {"name": "transfer",    "type": "function", "inputs": [{"name": "to", "type": "address"}, {"name": "amount", "type": "uint256"}], "outputs": [{"type": "bool"}], "stateMutability": "nonpayable"},
]

ROUTER_ABI = [
    {
        "name": "exactInputSingle",
        "type": "function",
        "inputs": [{"name": "params", "type": "tuple", "components": [
            {"name": "tokenIn",            "type": "address"},
            {"name": "tokenOut",           "type": "address"},
            {"name": "fee",                "type": "uint24"},
            {"name": "recipient",          "type": "address"},
            {"name": "amountIn",           "type": "uint256"},
            {"name": "amountOutMinimum",   "type": "uint256"},
            {"name": "sqrtPriceLimitX96",  "type": "uint160"},
        ]}],
        "outputs": [{"name": "amountOut", "type": "uint256"}],
        "stateMutability": "payable",
    }
]

# ── Helpers ────────────────────────────────────────────────────────────────────

def log(msg):
    print(f"[uniswap-swap] {msg}", file=sys.stderr)

def out(status, response, tx=None, data=None):
    d = {"status": status, "response": response}
    if tx:   d["tx"] = tx
    if data: d["data"] = data
    print(json.dumps(d))

def fail(msg):
    out("failed", msg)
    sys.exit(1)

def oneclaw_token():
    req = urllib.request.Request(
        f"{API_BASE}/auth/agent-token",
        data=json.dumps({"agent_id": AGENT_ID, "api_key": API_KEY}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    return json.loads(urllib.request.urlopen(req).read())["access_token"]

def get_private_key():
    token = oneclaw_token()
    url = f"{API_BASE}/vaults/{VAULT_ID}/secrets/punkwallet/private-key"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    return json.loads(urllib.request.urlopen(req).read())["value"]

def connect(chain_name):
    cfg = CHAINS[chain_name]
    w3 = Web3(Web3.HTTPProvider(cfg["rpc"], request_kwargs={"timeout": 30}))
    if cfg.get("poa"):
        w3.middleware_onion.inject(ExtraDataToPOAMiddleware, layer=0)
    if not w3.is_connected():
        fail(f"Cannot connect to {chain_name} RPC")
    return w3, cfg

def send_tx(w3, account, tx):
    tx["nonce"] = w3.eth.get_transaction_count(account.address)
    tx["gas"]   = w3.eth.estimate_gas({**tx, "from": account.address})
    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    log(f"TX sent: {tx_hash.hex()} — waiting...")
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)
    if receipt["status"] != 1:
        fail(f"TX reverted: {tx_hash.hex()}")
    log(f"TX confirmed in block {receipt['blockNumber']}")
    return tx_hash.hex()

def ensure_approval(w3, account, token_addr, spender, amount, cfg):
    token = w3.eth.contract(address=Web3.to_checksum_address(token_addr), abi=ERC20_ABI)
    current = token.functions.allowance(account.address, Web3.to_checksum_address(spender)).call()
    if current >= amount:
        log("Allowance sufficient")
        return
    log(f"Approving router for {amount}...")
    gas_price = w3.eth.gas_price
    tx = token.functions.approve(
        Web3.to_checksum_address(spender), 2**256 - 1
    ).build_transaction({
        "chainId": cfg["chain_id"],
        "from": account.address,
        "maxFeePerGas": gas_price * 2,
        "maxPriorityFeePerGas": gas_price,
    })
    send_tx(w3, account, tx)

def clanker_buy_red(w3, account, eth_amount_wei):
    """Buy RED using the Clanker pool router with native ETH."""
    import time as _time
    p = CLANKER_POOL_PARAMS["RED"]

    def pad(addr):
        return bytes(12) + bytes.fromhex(addr.lower()[2:])

    def u256(v):
        return v.to_bytes(32, "big")

    deadline = int(_time.time()) + 3600
    calldata_params = (
        u256(0) +                                 # [0] amountOutMin = 0
        u256(0x140) +                             # [1] offset
        pad(p["word2"]) +                         # [2]
        pad(p["word3"]) +                         # [3] RED pool
        pad(account.address) +                    # [4] recipient
        u256(p["word5"]) +                        # [5]
        u256(p["word6"]) +                        # [6]
        u256(0) +                                 # [7]
        u256(0) +                                 # [8]
        u256(deadline) +                          # [9] deadline
        u256(1) +                                 # [10] array length
        u256(32) +                                # [11]
        pad("0x4200000000000000000000000000000000000006") +  # [12] WETH
        pad(TOKENS["RED"]["address"]) +           # [13] RED
        pad(p["word14"]) +                        # [14] Universal Router
        pad(p["word15"]) +                        # [15] hook
        u256(p["word16"]) +                       # [16]
        u256(p["word17"]) +                       # [17]
        pad(p["word18"]) +                        # [18] RED pool
        u256(p["word19"]) +                       # [19]
        u256(0)                                   # [20]
    )
    calldata = bytes.fromhex("0f27c5c1") + calldata_params

    gas_price = w3.eth.gas_price
    tx = {
        "chainId": 8453,
        "to": Web3.to_checksum_address(CLANKER_ROUTER),
        "from": account.address,
        "value": eth_amount_wei,
        "data": "0x" + calldata.hex(),
        "maxFeePerGas": gas_price * 2,
        "maxPriorityFeePerGas": gas_price,
    }
    tx["gas"] = w3.eth.estimate_gas({**tx, "from": account.address})
    return send_tx(w3, account, tx)


def red_burn_eligible(w3, wallet_addr):
    """Returns (balance, total_supply, pct, eligible) for RED."""
    red_addr = Web3.to_checksum_address(TOKENS["RED"]["address"])
    red_c = w3.eth.contract(address=red_addr, abi=ERC20_ABI)
    balance = red_c.functions.balanceOf(Web3.to_checksum_address(wallet_addr)).call()
    total   = red_c.functions.totalSupply().call()
    pct = balance / total if total > 0 else 0
    return balance, total, pct, pct >= RED_BURN_THRESHOLD

# ── Commands ───────────────────────────────────────────────────────────────────

def cmd_swap(args):
    symbol_out = args.token_out.upper()
    symbol_in  = args.token_in.upper() if args.token_in else "WETH"

    if symbol_out not in TOKENS:
        fail(f"Unknown token-out: {symbol_out}. Supported: {', '.join(TOKENS)}")

    tok     = TOKENS[symbol_out]
    chain   = tok["chain"]
    w3, cfg = connect(chain)

    if symbol_in not in INPUTS[chain]:
        fail(f"{symbol_in} not supported as tokenIn on {chain}. Use: {', '.join(INPUTS[chain])}")

    token_in_addr, token_in_decimals = INPUTS[chain][symbol_in]
    token_out_addr = tok["address"]
    router_addr    = cfg["router"]

    log(f"Fetching private key from 1claw vault...")
    pk      = get_private_key()
    account = Account.from_key(pk)
    log(f"Wallet: {account.address}")

    amount_in = int(float(args.amount) * (10 ** token_in_decimals))
    log(f"Swap: {args.amount} {symbol_in} → {symbol_out} on {chain}")

    # Check tokenIn balance
    tin_contract = w3.eth.contract(address=Web3.to_checksum_address(token_in_addr), abi=ERC20_ABI)
    balance = tin_contract.functions.balanceOf(account.address).call()
    log(f"{symbol_in} balance: {balance / 10**token_in_decimals:.6f}")
    if balance < amount_in:
        fail(f"Insufficient {symbol_in}: have {balance / 10**token_in_decimals:.6f}, need {args.amount}")

    # Approve router
    ensure_approval(w3, account, token_in_addr, router_addr, amount_in, cfg)

    # RED trades on the Clanker pool (not Uniswap v3) — requires native ETH
    if symbol_out == "RED" and chain == "base":
        log("RED uses Clanker pool — unwrapping WETH to ETH if needed, then buying...")
        WETH_ABI_MIN = [
            {"name": "withdraw", "type": "function", "inputs": [{"name": "wad", "type": "uint256"}], "outputs": [], "stateMutability": "nonpayable"},
        ]
        weth_c = w3.eth.contract(address=Web3.to_checksum_address(token_in_addr), abi=WETH_ABI_MIN)
        if symbol_in == "WETH":
            log(f"Unwrapping {float(args.amount):.6f} WETH → ETH...")
            unwrap_tx = weth_c.functions.withdraw(amount_in).build_transaction({
                "chainId": cfg["chain_id"], "from": account.address,
                "maxFeePerGas": w3.eth.gas_price * 2, "maxPriorityFeePerGas": w3.eth.gas_price,
            })
            send_tx(w3, account, unwrap_tx)
        eth_bal = w3.eth.get_balance(account.address)
        keep_gas = int(0.001 * 1e18)
        eth_to_spend = min(amount_in, eth_bal - keep_gas)
        if eth_to_spend <= 0:
            fail("Insufficient ETH after unwrap for Clanker buy")
        log(f"Buying RED with {eth_to_spend/1e18:.6f} ETH via Clanker pool...")
        tx_hash = clanker_buy_red(w3, account, eth_to_spend)
        out("completed", f"Bought RED on base with {eth_to_spend/1e18:.6f} ETH via Clanker pool. TX: {tx_hash}", tx=tx_hash)
        return

    # All other tokens: Uniswap v3 exactInputSingle
    router    = w3.eth.contract(address=Web3.to_checksum_address(router_addr), abi=ROUTER_ABI)
    gas_price = w3.eth.gas_price
    tx_hash   = None

    for fee_tier in [3000, 500, 10000]:
        log(f"Trying fee tier {fee_tier}...")
        try:
            params = (
                Web3.to_checksum_address(token_in_addr),
                Web3.to_checksum_address(token_out_addr),
                fee_tier,
                account.address,
                amount_in,
                0,
                0,
            )
            tx = router.functions.exactInputSingle(params).build_transaction({
                "chainId": cfg["chain_id"],
                "from": account.address,
                "value": 0,
                "maxFeePerGas": gas_price * 2,
                "maxPriorityFeePerGas": gas_price,
            })
            tx_hash = send_tx(w3, account, tx)
            break
        except Exception as e:
            log(f"Fee tier {fee_tier} failed: {e}")

    if not tx_hash:
        fail(f"All fee tiers failed for {symbol_out} swap")

    out("completed",
        f"Swapped {args.amount} {symbol_in} → {symbol_out} on {chain}. TX: {tx_hash}",
        tx=tx_hash)


def cmd_transfer(args):
    symbol = args.token.upper()
    if symbol not in TOKENS:
        fail(f"Unknown token: {symbol}")

    tok     = TOKENS[symbol]
    chain   = tok["chain"]
    w3, cfg = connect(chain)

    log(f"Fetching private key from 1claw vault...")
    pk      = get_private_key()
    account = Account.from_key(pk)
    log(f"Wallet: {account.address}")

    token_addr = Web3.to_checksum_address(tok["address"])
    to_addr    = Web3.to_checksum_address(args.to)
    token      = w3.eth.contract(address=token_addr, abi=ERC20_ABI)
    decimals   = tok["decimals"]
    symbol_str = token.functions.symbol().call()

    if args.amount == "all":
        amount = token.functions.balanceOf(account.address).call()
        log(f"Transferring all: {amount / 10**decimals:.4f} {symbol_str}")
    else:
        amount = int(float(args.amount) * 10**decimals)

    if amount == 0:
        fail(f"Zero balance for {symbol_str}")

    gas_price = w3.eth.gas_price
    tx = token.functions.transfer(to_addr, amount).build_transaction({
        "chainId": cfg["chain_id"],
        "from": account.address,
        "maxFeePerGas": gas_price * 2,
        "maxPriorityFeePerGas": gas_price,
    })
    tx_hash = send_tx(w3, account, tx)

    human = amount / 10**decimals
    out("completed",
        f"Sent {human:,.4f} {symbol_str} to {to_addr}. TX: {tx_hash}",
        tx=tx_hash)


def cmd_balance(args):
    log(f"Fetching private key from 1claw vault...")
    pk      = get_private_key()
    account = Account.from_key(pk)
    log(f"Wallet: {account.address}")

    tokens = list(TOKENS.keys()) if args.token.upper() == "ALL" else [args.token.upper()]
    results = {}

    for sym in tokens:
        if sym not in TOKENS:
            continue
        tok     = TOKENS[sym]
        w3, _   = connect(tok["chain"])
        addr    = Web3.to_checksum_address(tok["address"])
        contract = w3.eth.contract(address=addr, abi=ERC20_ABI)
        bal     = contract.functions.balanceOf(account.address).call()
        total   = contract.functions.totalSupply().call()
        dec     = tok["decimals"]
        pct     = bal / total * 100 if total > 0 else 0
        results[sym] = {"balance": bal / 10**dec, "pct_supply": round(pct, 4)}

    lines = [f"{s}: {v['balance']:,.4f} ({v['pct_supply']:.4f}% of supply)" for s, v in results.items()]
    out("completed", " | ".join(lines), data=results)


def cmd_check_burn(args):
    log(f"Checking RED burn eligibility...")
    pk      = get_private_key()
    account = Account.from_key(pk)
    w3, _   = connect("base")
    bal, total, pct, eligible = red_burn_eligible(w3, account.address)
    dec = TOKENS["RED"]["decimals"]
    msg = (
        f"RED balance: {bal/10**dec:,.0f} ({pct*100:.4f}% of supply). "
        f"Burn threshold: 10%. "
        f"{'ELIGIBLE to burn.' if eligible else 'NOT eligible — accumulating.'}"
    )
    out("completed", msg, data={"eligible": eligible, "pct": pct * 100, "balance": bal / 10**dec})


# ── CLI ────────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Uniswap v3 swap/transfer via 1claw punkwallet")
    sub = parser.add_subparsers(dest="command", required=True)

    p_swap = sub.add_parser("swap", help="Swap tokenIn → tokenOut")
    p_swap.add_argument("--token-in",  default="WETH", help="Input token: WETH, USDC (default: WETH)")
    p_swap.add_argument("--token-out", required=True,   help="Output token: RED, GRT, WBTC")
    p_swap.add_argument("--amount",    type=str, required=True, help="Amount of tokenIn to spend")

    p_xfer = sub.add_parser("transfer", help="Transfer token to address")
    p_xfer.add_argument("--token",  required=True)
    p_xfer.add_argument("--to",     required=True)
    p_xfer.add_argument("--amount", default="all")

    p_bal = sub.add_parser("balance", help="Check token balance")
    p_bal.add_argument("--token", default="ALL")

    sub.add_parser("check-burn", help="Check if RED burn threshold met")

    args = parser.parse_args()
    if args.command == "swap":
        cmd_swap(args)
    elif args.command == "transfer":
        cmd_transfer(args)
    elif args.command == "balance":
        cmd_balance(args)
    elif args.command == "check-burn":
        cmd_check_burn(args)

if __name__ == "__main__":
    main()
