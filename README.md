# Proof-of-Life Vault

A dead-man's switch for a crypto stash that needs no keeper bot and no "I'm alive" ping.
Reactive Network watches the owner's ordinary on-chain activity and keeps time with its own Cron
ticks. If the owner goes silent for the inactivity window, the vault posts a warning. If the owner
stays silent through the grace window too, the vault pays everything to the beneficiary. Any owner
activity before that cancels the warning.

Track: Reactive Omni Buildathon, "Set It and Forget It". The live deployment watches Ethereum
Sepolia (origin and destination: the token and the vault live there). The reactive contract runs on
Reactive Lasna (chain 5318007) and keeps time with Lasna's Cron events.

Built by an AI agent (Anthropic's Claude) for the GitHub account tidelit4. Every number and
transaction below was produced and checked on-chain.

## Live on testnet (2026-11-12)

| Contract | Chain | Address |
|---|---|---|
| DemoToken (DMO) | Ethereum Sepolia | [`0x4F9aA7e938D181710cE7f2e579Abd7282889794f`](https://sepolia.etherscan.io/address/0x4F9aA7e938D181710cE7f2e579Abd7282889794f) |
| ProofOfLifeVault | Ethereum Sepolia | [`0x37e6A46f964b16F40A3961d58D5876b7Bc537612`](https://sepolia.etherscan.io/address/0x37e6A46f964b16F40A3961d58D5876b7Bc537612) |
| ProofOfLifeReactive | Reactive Lasna | [`0xFB02A93f9d425e60d50eA6E516B2b8a713dd6Df0`](https://lasna.reactscan.net/address/0xFB02A93f9d425e60d50eA6E516B2b8a713dd6Df0) |
| Beneficiary | Ethereum Sepolia | [`0xEb2c71293CdBe0ce5a9CcA9a2C236B521B25eE06`](https://sepolia.etherscan.io/address/0xEb2c71293CdBe0ce5a9CcA9a2C236B521B25eE06) |

Demo settings: warn after 300 s of silence, release after a further 300 s, Cron100 ticks. One run
went through loops A → B → D → B → C, and every step is below. Each callback landed on Sepolia about
10 s after the Lasna transaction that requested it. The beneficiary ended with 0.0002 SepETH and
100 DMO. The vault is now `Released`, and the reactive contract has unsubscribed from everything.

| Time (UTC) | Chain | Block | Event | What happened | Tx |
|---|---|---|---|---|---|
| 22:28:39 | Lasna | 8198073 | `Armed` | setVault(): subscriptions created, clock started | [`0x72cca7ab…`](https://lasna.reactscan.net/tx/0x72cca7abe2f4af42cd8ed22860d5a89f1f0114a610f189dfd106c56ac43601d1) |
| 22:29:36 | Sepolia | 12121817 | `Transfer` | owner sends DMO (proof of life) | [`0x5ef7ad51…`](https://sepolia.etherscan.io/tx/0x5ef7ad51b4fa1115925bbe6568d3365ea4a2c6304de1140544991c95c01ecff0) |
| 22:29:36 | Lasna | 8198127 | `OwnerActivity` | react(): owner Transfer seen on Sepolia | [`0xfd0e5ae9…`](https://lasna.reactscan.net/tx/0xfd0e5ae98ba9e7ba9d679d1cf1519dab938adab20759448623a8a54061526a01) |
| 22:29:36 | Lasna | 8198127 | `HeartbeatRequested` | react(): heartbeat callback requested | [`0xfd0e5ae9…`](https://lasna.reactscan.net/tx/0xfd0e5ae98ba9e7ba9d679d1cf1519dab938adab20759448623a8a54061526a01) |
| 22:29:48 | Sepolia | 12121818 | `Heartbeat` | callback: vault clock reset | [`0xbe41853d…`](https://sepolia.etherscan.io/tx/0xbe41853d822238d27094a23acb731472edd36f673916700a4b7cb26bf6020dfa) |
| 22:36:15 | Lasna | 8198501 | `WarnRequested` | react() on a Cron tick: warn requested (399 s silent) | [`0x215ccc3d…`](https://lasna.reactscan.net/tx/0x215ccc3d7249472a77527b7e55c7a4ada6ca3650db77ea09b5e8303c04d06af2) |
| 22:36:24 | Sepolia | 12121850 | `Warning` | callback: vault Warned | [`0x420f8de0…`](https://sepolia.etherscan.io/tx/0x420f8de048e5e459a9e6bb473120b53ee38ff4ff535834886ceb83d8d917a8c4) |
| 22:36:36 | Sepolia | 12121851 | `Transfer` | owner sends DMO (proof of life) | [`0xc15c8a8a…`](https://sepolia.etherscan.io/tx/0xc15c8a8a148699fc8b8d7ecf036ff8b7c0a8c75019cb453af8c81d34b4188d1d) |
| 22:36:38 | Lasna | 8198523 | `OwnerActivity` | react(): owner Transfer seen on Sepolia | [`0xd7ba4a04…`](https://lasna.reactscan.net/tx/0xd7ba4a043f6a9bd35151c42c4510af7daa2f53ee33625b1d4ef0f347c0c7e7a2) |
| 22:36:38 | Lasna | 8198523 | `HeartbeatRequested` | react(): heartbeat callback requested | [`0xd7ba4a04…`](https://lasna.reactscan.net/tx/0xd7ba4a043f6a9bd35151c42c4510af7daa2f53ee33625b1d4ef0f347c0c7e7a2) |
| 22:36:48 | Sepolia | 12121852 | `Heartbeat` | callback: vault clock reset | [`0x2b894005…`](https://sepolia.etherscan.io/tx/0x2b8940052d34ecf9726af7c0573258b31e093b2de7404d75c94dd6af008c48c8) |
| 22:36:48 | Sepolia | 12121852 | `Recovered` | callback: warning cancelled | [`0x2b894005…`](https://sepolia.etherscan.io/tx/0x2b8940052d34ecf9726af7c0573258b31e093b2de7404d75c94dd6af008c48c8) |
| 22:43:26 | Lasna | 8198901 | `WarnRequested` | react() on a Cron tick: warn requested (408 s silent) | [`0x9b162474…`](https://lasna.reactscan.net/tx/0x9b162474038e07be20dab57f4c574784dde4cf79a460bde463c14734758c9d99) |
| 22:43:36 | Sepolia | 12121885 | `Warning` | callback: vault Warned | [`0x4ebf8f0b…`](https://sepolia.etherscan.io/tx/0x4ebf8f0ba086750e3f51e26e3968342456c40b0379e6062609c562197ae30162) |
| 22:47:02 | Lasna | 8199101 | `ReleaseRequested` | react() on a Cron tick: release requested (624 s silent) | [`0xebd90622…`](https://lasna.reactscan.net/tx/0xebd90622e1a6aca1e3242cbc4f8c3818a9d3b9664b6f55154285d07ea4ac4e2b) |
| 22:47:12 | Sepolia | 12121903 | `Transfer` | vault pays DMO to the beneficiary | [`0x7b58f72c…`](https://sepolia.etherscan.io/tx/0x7b58f72ce0dbd999c00b0ef7096131b94766d1491d426840be5102b0de234b72) |
| 22:47:12 | Sepolia | 12121903 | `Released` | callback: principal + tokens paid to the beneficiary | [`0x7b58f72c…`](https://sepolia.etherscan.io/tx/0x7b58f72ce0dbd999c00b0ef7096131b94766d1491d426840be5102b0de234b72) |
| 22:47:13 | Lasna | 8199111 | `Closed` | react(): vault's Released log seen, all subscriptions dropped | [`0x4193a465…`](https://lasna.reactscan.net/tx/0x4193a465d1d9654c4975061d02a655cb8f585ec94d9d5ba1c7ab99705a74efb2) |

### Left running with production settings

A second instance runs the "set it and forget it" configuration and is left on: a 30-day inactivity
window, a 30-day grace period, Cron10000 ticks (about every 3 hours), and `ANY_TOKEN=true`, so every
ERC-20/721 transfer the owner sends on Sepolia counts as proof of life. It was deployed 2026-11-12
22:52Z, and its first heartbeat was delivered at once.

| Contract | Chain | Address |
|---|---|---|
| ProofOfLifeVault | Ethereum Sepolia | [`0x9B499c8e1CFb49de7707309Ed555596180D3B761`](https://sepolia.etherscan.io/address/0x9B499c8e1CFb49de7707309Ed555596180D3B761) |
| ProofOfLifeReactive | Reactive Lasna | [`0xE42A0F1AC2045311E2BDCDf4D47611e6A3820c9B`](https://lasna.reactscan.net/address/0xE42A0F1AC2045311E2BDCDf4D47611e6A3820c9B) |
| DemoToken | Ethereum Sepolia | [`0xE42A0F1AC2045311E2BDCDf4D47611e6A3820c9B`](https://sepolia.etherscan.io/address/0xE42A0F1AC2045311E2BDCDf4D47611e6A3820c9B) (same address as the reactive contract on Lasna: same deployer nonce on both chains) |

Video (2 min, silent with captions): [`docs/demo.mp4`](docs/demo.mp4). Raw event dump: [`docs/transactions.json`](docs/transactions.json).


## Things we learned on Lasna (Omni)

- **Callbacks with Lasna as the destination were never delivered.** Our first deployment had the
  token, vault and reactive contract all on Lasna. Subscriptions, `react()` and the Cron ticks all
  worked, and `CallbackRequest` was emitted for `heartbeat`, `warn` and `release`. But in 15 minutes
  no callback transaction ever reached the vault. Network-wide we saw only 5 Lasna-destination
  requests in about 17 hours, and the other recipient got nothing either, against hundreds to Sepolia
  and Base Sepolia. So the live deployment uses Sepolia as the destination. There, a callback lands
  one block after the Sepolia event that caused it.
- **`gasLimit` in the callback request is the gas limit of the whole destination transaction.**
  The proxy spends part of it before forwarding. At 300k, `heartbeat` (85k for the whole transaction)
  was delivered, but `warn` (the vault alone needs ~132k) failed, which showed only as a failure event
  on the proxy. Raised to 1M (`CALLBACK_GAS_LIMIT`).
- **Cron100 is expensive to keep running.** A demo reactive contract on Cron100 spends roughly
  0.01 lREACT a minute, so the production settings use Cron10000.
- Lasna's RPC rejects EIP-1559 fee fields from some clients. Send legacy transactions
  (`--legacy`, 100 gwei).

## Contracts

| Contract | Role |
|---|---|
| `src/ProofOfLifeReactive.sol` | Reactive contract (`AbstractReactive`, reactive-lib-omni). Subscribes to the owner's `Transfer` logs, the vault's own `OwnerCheckIn`/`Released`/`Cancelled` events, and a Cron topic. Decides heartbeat / warn / release and requests callbacks with `SYSTEM.requestCallbackV_1_0`. |
| `src/ProofOfLifeVault.sol` | Callback contract (`AbstractCallback`). Holds native lREACT/ETH plus one optional ERC-20. Callbacks `heartbeat`, `warn` and `release` are guarded by `onlyServiceProvider` (caller must be the callback proxy) and `onlyCallbackSender` (the injected first argument must be our reactive contract). Re-checks every timing decision against its own clock. |
| `src/DemoToken.sol` | Minimal ERC-20 so the demo can produce owner activity on demand. |

How it decides (all times are seconds since the owner was last seen):

| Input | Reactive contract does | Vault does |
|---|---|---|
| `Transfer(from = owner)` on the watched token (or on any token with `ANY_TOKEN=true`) | `lastSeen = now`, phase Active, `heartbeat` callback | `lastSeen = ts`; if warned: `Recovered` |
| Owner acts on the vault (`checkIn`, `deposit`, `withdraw`) | mirrors the vault's `OwnerCheckIn` event, no callback | resets its clock itself, `Recovered` if warned |
| Cron tick, elapsed > window, phase Active | phase Warned, `warn` callback | `Warning(lastSeen, releaseAt)` if its own clock agrees, else `CallbackIgnored` |
| Cron tick, elapsed > window + grace, phase Warned | phase Releasing, `release` callback (retried every `retryDelay` until confirmed) | pays principal and tokens to the beneficiary, `Released`; ignores it if the owner was seen since |
| Vault emits `Released` or `Cancelled` | phase Closed, unsubscribes everything (stops paying for ticks) | |

Notes:

- Omni has no ReactVM. The contract is deployed once and `react()` is an ordinary transaction called by
  the system contract, so state lives in the one contract (see the header of
  `src/ProofOfLifeReactive.sol` and https://dev.reactive.network/reactive-contracts). The callback's
  first argument, once called the RVM id, is now the reactive contract's address.
- Subscriptions match log fields only. "Any transaction from the owner" cannot be subscribed to, so
  native transfers and calls that emit no `Transfer` naming the owner are not seen. Use
  `ANY_TOKEN=true` to count every ERC-20/721 transfer the owner sends.
- Callback fees are paid by the vault from its operating balance (plain transfers to the vault, or
  `msg.value` at deployment). Principal (`deposit()`) is accounted separately and is never spent on fees.
- If the beneficiary refuses native coin, the release still succeeds and the amount becomes
  claimable with `claim()`. A failed token transfer can be retried with `pushTokens()`.

## Build and test

```
git clone --depth 1 https://github.com/foundry-rs/forge-std lib/forge-std
git clone --depth 1 https://github.com/Reactive-Network/reactive-lib-omni lib/reactive-lib-omni
forge build
forge test -vv
```

The tests put a mock of the system contract and callback proxy at `0x8888...8888` (`test/mocks/MockSystem.sol`).
It records subscriptions, routes `LogRecord`s to matching subscribers, and delivers queued callbacks as
the proxy, overwriting the first argument with the requester's address. The `test_Loop_*` tests run the
four demo loops end to end with real token transfers and real vault events.

## Deploy (cross-chain: Sepolia vault, Lasna reactive)

This is how the live deployment was made: `.github/workflows/deploy-x.yml`, run by hand. It does the
following, with `forge create` and `cast send`:

```
OWNER=$(cast wallet address --private-key $PRIVATE_KEY)
SEP=https://ethereum-sepolia-rpc.publicnode.com; LASNA=https://lasna-rpc.rnk.dev/
SEP_PROXY=0xAa14d9Cd0f788Ca23d11805986C1d8bd035D23b4   # Reactive callback proxy on Sepolia
# 1. Sepolia: the token whose transfers prove life
forge create src/DemoToken.sol:DemoToken --rpc-url $SEP --private-key $PRIVATE_KEY --broadcast --constructor-args $OWNER 1000000000000000000000000
# 2. Lasna: reactive contract; config = (owner, originChainId, token, destinationChainId, cronTopic, inactivity, grace, retry, heartbeatMin)
forge create src/ProofOfLifeReactive.sol:ProofOfLifeReactive --rpc-url $LASNA --private-key $PRIVATE_KEY --broadcast --legacy --value 0.5ether \
  --constructor-args "($OWNER,11155111,$TOKEN,11155111,$CRON_TOPIC,300,300,300,0)"
# 3. Sepolia: vault, authorising exactly that reactive contract through the Sepolia proxy
forge create src/ProofOfLifeVault.sol:ProofOfLifeVault --rpc-url $SEP --private-key $PRIVATE_KEY --broadcast --value 0.0005ether \
  --constructor-args $SEP_PROXY $RC $OWNER $BENEFICIARY $TOKEN 300 300
# 4. Lasna: arm (creates the subscriptions, starts the clock)
cast send $RC "setVault(address)" $VAULT --rpc-url $LASNA --private-key $PRIVATE_KEY --legacy
# 5. Sepolia: principal
cast send $VAULT "deposit()" --value 0.0002ether --rpc-url $SEP --private-key $PRIVATE_KEY
cast send $TOKEN "approve(address,uint256)" $VAULT 100000000000000000000 --rpc-url $SEP --private-key $PRIVATE_KEY
cast send $VAULT "depositToken(uint256)" 100000000000000000000 --rpc-url $SEP --private-key $PRIVATE_KEY
```

## Deploy (single chain, `script/Deploy.s.sol`)

This script puts all three contracts on one chain. It works on Lasna (that was our first deployment),
but Lasna did not deliver callbacks to Lasna recipients while we tested (see above). Use the
cross-chain deployment for a working loop.

Requirements: lREACT on the deployer (see https://dev.reactive.network/reactive-mainnet, faucet
contracts). A dry run of the script against a local fork of Lasna used about 5.1M gas in total
(about 0.51 lREACT at 100 gwei) plus 1.1 lREACT of funding with the defaults below, so hold about
2.2 lREACT (forge budgets a 2x max fee), or lower `REACTIVE_FUND`/`VAULT_GAS`. The key comes from
the environment only.

```
export PRIVATE_KEY=0x...          # deployer = owner whose activity proves life
export BENEFICIARY=0x...
export RPC=https://lasna-rpc.rnk.dev/
# demo timing (defaults): INACTIVITY_SECS=300 GRACE_SECS=300 RETRY_SECS=300, Cron100 (~100 blocks)
forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
```

The script deploys, in this order (the order the callback-contract docs require, because the vault
stores the reactive address immutably):

1. `DemoToken(owner, 1,000,000)`
2. `ProofOfLifeReactive{value: REACTIVE_FUND}(config)`
3. `ProofOfLifeVault{value: VAULT_GAS}(0x8888...8888, reactive, owner, beneficiary, token, inactivity, grace)`
4. `reactive.setVault(vault)`: creates the subscriptions and starts the clock
5. `vault.deposit{value: VAULT_DEPOSIT}()` and `vault.depositToken(TOKEN_DEPOSIT)`

Set `TOKEN=`, `RC=`, `VAULT=` from the printed addresses for the loops below.

If `forge script` has trouble simulating calls to the system contract, run the same steps with
`forge create` (`--value`, `--constructor-args`) and `cast send` in that order.

Production settings: `CRON_TOPIC=0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56`
(Cron10000, about every 3 hours), `INACTIVITY_SECS=2592000` (30 days), `GRACE_SECS=2592000`,
`ANY_TOKEN=true`, `HEARTBEAT_MIN=86400`.

## Demo loops

Each loop produces three transactions: the trigger (on Sepolia, or a Cron log on Lasna), the reactive
transaction on Lasna (`react` emits `CallbackRequest`), and the callback on Sepolia (the proxy calls
the vault). In the commands below, `$RPC` is the Sepolia RPC, since the token and the vault live there.

**A. Heartbeat.** The owner uses their wallet normally.
```
cast send $TOKEN "transfer(address,uint256)" 0x000000000000000000000000000000000000dEaD 1 --rpc-url $RPC --private-key $PRIVATE_KEY
cast call $VAULT "lastSeen()(uint256)" --rpc-url $RPC      # moves to the time of the transfer
```
A1 `Transfer(owner, …)` → A2 `react` requests `heartbeat` → A3 vault emits `Heartbeat`.

**B. Warning.** Do nothing for more than `INACTIVITY_SECS`. On the next Cron100 tick:
B1 Cron log from `0x...fffFfF` → B2 `react` requests `warn` → B3 vault emits `Warning(lastSeen, releaseAt)`.
```
cast call $VAULT "state()(uint8)" --rpc-url $RPC           # 1 = Warned
```

**C. Release.** Stay idle past `INACTIVITY_SECS + GRACE_SECS`. On the next tick after the warning:
C1 Cron log → C2 `react` requests `release` → C3 vault emits `Released`, beneficiary balance goes up by
the principal and the tokens. The vault's `Released` event then reaches the reactive contract, which
unsubscribes from everything.
```
cast balance $BENEFICIARY --rpc-url $RPC
cast call $VAULT "state()(uint8)" --rpc-url $RPC           # 2 = Released
```

**D. Recovery** (on a fresh deployment). Let loop B happen, then before the release:
```
cast send $TOKEN "transfer(address,uint256)" 0x000000000000000000000000000000000000dEaD 1 --rpc-url $RPC --private-key $PRIVATE_KEY
```
D1 `Transfer` → D2 `react` requests `heartbeat` → D3 vault emits `Recovered` and `Heartbeat`. After the
old release time, the beneficiary balance is unchanged. (`cast send $VAULT "checkIn()"` recovers too.)

Owner controls at any time: `withdraw(uint256 native, uint256 tokens)`, `cancel()`, `checkIn()`,
`withdrawGas(uint256)`; on the reactive contract `pause()`, `resume()`, `coverDebt()`, `withdraw(address,uint256)`.
