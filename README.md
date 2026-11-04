# Morpheus Capital Protocol — PoC (Foundry, mainnet fork)

Two Foundry tests against the DEPLOYED Morpheus contracts on an Ethereum
mainnet fork pinned to block **26340900**. No privileged accounts are used
(the attacker is an ordinary `makeAddr` address); the only test-environment
workaround is mocking the Chainlink price-feed consumer to return the prices
live at the fork block, because `distributeRewards` reverts on a stale feed
after `vm.warp` (`allowedPriceUpdateDelay` = 3600s). The mock touches only
the external oracle, never a Morpheus contract.

## Run (one command, from a clean clone)

```bash
forge test --fork-url https://eth.drpc.org --fork-block-number 26340900 -vv
```

Any public Ethereum RPC works as `--fork-url`. No other setup is needed
(`forge-std` is vendored under `lib/`).

## Tests

| Test | Finding | Result |
|---|---|---|
| `test/H02_DonationYieldShare.t.sol` | Donating yield token (aToken) to the Distributor inflates a pool's measured yield and diverts the fixed daily MOR emission to the attacker's pool. | 2/2 PASS. Attack: wETH pool 1,531.75 → 4,070.25 MOR (+2,538.5); stETH −2,111.5 MOR; USDC −422.4 MOR. Attacker captures 2,186.58 MOR (~$1,859 at MOR $0.85) for a 0.25 WETH (~$565) donation → net ~$1,293/day. |
| `test/H01_SelfReferralTier3.t.sol` | `stake()` accepts `referrer == msg.sender`; the same capital earns the user reward (+1% multiplier) AND the referrer reward (tier 3 = 15%). | 1/1 PASS. Alice (100 WETH, self-referral) total 1,108.32 MOR vs Bob (100 WETH, no referrer) 955.45 MOR — ratio 115.99% (~16% boost). |

## Scope

MorpheusAIs/SmartContracts, main, commit `07f6032`. Deployed addresses:
DepositPool stETH `0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790`, wETH
`0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384`, Distributor
`0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A`, RewardPool
`0xb7994dE339AEe515C9b2792831CD83f3C9D8df87`.
