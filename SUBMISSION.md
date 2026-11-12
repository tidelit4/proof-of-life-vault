# DoraHacks BUIDL fields (Reactive Omni Buildathon)

Copy each field into the DoraHacks "Submit BUIDL" form.

**BUIDL name:** Proof-of-Life Vault

**Track:** Set It and Forget It

**One-line pitch:** A dead-man's switch for crypto with no keeper bot. Reactive Network watches the
owner's ordinary on-chain activity and releases the vault to an heir after a long silence.

**GitHub:** https://github.com/tidelit4/proof-of-life-vault

**Demo video:** https://github.com/tidelit4/proof-of-life-vault/blob/main/docs/demo.mp4 (2 min)

**Description:**

Self-custody has no inheritance path. Existing dead-man's switches need either an off-chain keeper
bot that must stay online for years, or the owner to remember to send "I'm alive" transactions.

Proof-of-Life Vault needs neither. The vault lives on Ethereum (Sepolia in this demo). A reactive
contract on Reactive Network subscribes to the owner's token transfers, so ordinary wallet use
counts as proof of life. It also subscribes to the vault's own events, and it keeps time with
Reactive's Cron events. After the inactivity window it posts a warning to the vault by callback.
After the grace window it releases the principal and tokens to the beneficiary. Any owner activity
in between cancels the warning. After the release, the reactive contract unsubscribes from
everything, so it stops paying for ticks.

Safety: callbacks are accepted only from the callback proxy, and only with our reactive contract as
the injected sender. The vault re-checks every timing decision against its own clock. Release is
retried until the vault confirms it. Principal is accounted separately from callback gas. The owner
can withdraw, check in or cancel at any time. 49 Foundry tests cover this, including four end-to-end
loops.

Live on testnet (2026-11-12): one run went through heartbeat → warning → recovery → warning →
release. Every transaction is linked in the README; each callback landed on Sepolia about 10 s after
the Lasna transaction that requested it. A second instance with production settings (30 + 30 days,
Cron10000, any token counts) is left running.

We also document two things we learned on Lasna. Lasna-destination callbacks were never delivered
in our tests. And `gasLimit` is the whole destination transaction's limit: at 300k, the proxy
overhead starved `warn()`.

Built by an AI agent (Anthropic's Claude) for the GitHub account tidelit4.

**Deployed contracts (demo run):**
- ProofOfLifeVault, Sepolia: 0x37e6A46f964b16F40A3961d58D5876b7Bc537612
- ProofOfLifeReactive, Lasna: 0xFB02A93f9d425e60d50eA6E516B2b8a713dd6Df0
- DemoToken, Sepolia: 0x4F9aA7e938D181710cE7f2e579Abd7282889794f

**Origin → reactive → callback example (release):**
- Lasna react, ReleaseRequested: 0xebd90622e1a6aca1e3242cbc4f8c3818a9d3b9664b6f55154285d07ea4ac4e2b
- Sepolia callback, Released: 0x7b58f72ce0dbd999c00b0ef7096131b94766d1491d426840be5102b0de234b72

**Prize address (EVM, receives REACT):** 0x1CBfa815fea4B3bDe1F84d6ef488e496DB25c360
