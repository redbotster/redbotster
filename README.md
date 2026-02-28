# RedBotster 🤖🔥

**RedBotster.eth** is an AI agent running on [OpenClaw](https://openclaw.ai) that:

1. Collects Bankr creator fees from $RED token trades on Base
2. Buys $GRT (The Graph) on Ethereum to support decentralized indexing
3. Burns $RED — racing toward 5% supply destruction
4. Posts every move to [@redbotster](https://x.com/redbotster) in real time

## Tokens

| Token | Chain | Contract |
|-------|-------|----------|
| RED | Base | [`0x2e662015a501f066e043d64d04f77ffe551a4b07`](https://basescan.org/token/0x2e662015a501f066e043d64d04f77ffe551a4b07) |
| GRT | Ethereum | [`0xc944E90C64B2c07662A292be6244BDf05Cda44a`](https://etherscan.io/token/0xc944E90C64B2c07662A292be6244BDf05Cda44a) |
| GRT | Arbitrum | [`0x9623063377AD1B27544C965cCd7342f7EA7e88C7`](https://arbiscan.io/token/0x9623063377AD1B27544C965cCd7342f7EA7e88C7) |

## How It Works

```
RED trades on Base
  → Clanker accumulates creator fees
  → Daily automation claims fees
  → 70% buys GRT on Ethereum
  → 30% buys RED and burns to 0xdead
  → @redbotster tweets the receipt
```

## Automation

The fee-claim script runs daily via OpenClaw cron:

```bash
# Manual run
./scripts/fee-claim-and-buy.sh

# Dry run (no real transactions)
./scripts/fee-claim-and-buy.sh --dry-run
```

### Config (`config.json`)

```json
{
  "minThresholdUSD": 10,
  "grtSplitPct": 70,
  "burnSplitPct": 30
}
```

## Stack

- [OpenClaw](https://openclaw.ai) — AI agent runtime
- [Bankr](https://bankr.bot) — Natural language DeFi execution
- [xurl](https://github.com/xdevplatform/xurl) — X/Twitter API CLI
- [ethskills.com](https://ethskills.com) — Ethereum smart contract reference

## Security

- No private keys in this repo
- Bankr API key lives in `~/.clawdbot/skills/bankr/config.json` (excluded via `.gitignore`)
- xurl credentials live in `~/.xurl` (excluded via `.gitignore`)
- See `.gitignore` for full exclusion list

## Follow Along

- X: [@redbotster](https://x.com/redbotster)
- Token: [RED on Dexscreener](https://dexscreener.com/base/0x2e662015a501f066e043d64d04f77ffe551a4b07)
