// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractReactive } from "@reactive/src/base/AbstractReactive.sol";
import { ProofOfLifeVault } from "./ProofOfLifeVault.sol";

/// @title ProofOfLifeReactive
/// @notice Reactive half of the Proof-of-Life dead-man's switch.
///
///         It watches the owner's ordinary on-chain life (ERC-20/ERC-721 `Transfer` logs with the
///         owner as `from`, plus any owner check-in on the vault itself) and keeps time with the
///         network's own Cron ticks. No keeper bot, no manual "I'm alive" ping:
///           - owner activity        -> `heartbeat` callback to the vault (resets the clock, clears a warning)
///           - tick, silent > window -> `warn` callback
///           - tick, silent > window + grace (after a warning) -> `release` callback (vault pays the beneficiary)
///           - vault emits Released / Cancelled -> drop all subscriptions so the contract stops paying for ticks
///
///         Written against reactive-lib-omni (`src/base/AbstractReactive.sol`,
///         `src/interfaces/ISystemContract.sol`) and https://dev.reactive.network/reactive-contracts.
///         On the Omni fork the RVM is gone: a reactive contract is deployed once, to a single
///         environment, and `react()` is an ordinary transaction on Reactive Network called by the
///         system contract. So all state below lives in this one contract instance and is read and
///         written directly by `react()` and by the owner's admin calls; there is no ReactVM copy to
///         keep in sync and no `vmOnly`/`rnOnly` split (those belong to the deprecated `reactive-lib`).
///
///         Limitation (documented, not hidden): subscriptions match log criteria only
///         (chainId, contract, topic0..3). There is no way to subscribe to "any transaction sent by
///         address X", so plain native transfers or calls that emit no log naming the owner are not
///         seen. With `activityToken = address(0)` every ERC-20/721 transfer the owner sends on the
///         origin chain counts.
contract ProofOfLifeReactive is AbstractReactive {
    enum Phase {
        Unarmed, // deployed, vault not set yet, no subscriptions
        Active, // watching
        Warned, // warn callback requested
        Releasing, // release callback requested, waiting for the vault's Released event
        Closed // vault released or cancelled, all subscriptions dropped
    }

    struct Config {
        address owner; // account whose activity proves life; also the admin
        uint256 originChainId; // chain whose Transfer logs count as activity
        address activityToken; // token to watch, or address(0) for every token on the origin chain
        uint256 destinationChainId; // chain of the vault
        uint256 cronTopic; // Cron topic0 to tick on (Cron100 for demos, Cron10000 for real use)
        uint256 inactivityWindow; // seconds of silence before `warn`
        uint256 graceWindow; // further seconds before `release`
        uint256 retryDelay; // seconds before re-requesting an unconfirmed `release`
        uint256 heartbeatMinInterval; // throttle for heartbeat callbacks (0 = every activity)
    }

    // ------------------------------------------------------------ protocol constants
    /// @dev keccak256("Transfer(address,address,uint256)"): same topic0 for ERC-20 (LOG3) and ERC-721 (LOG4).
    uint256 public constant TRANSFER_TOPIC_0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    /// @dev Legacy system contract that emits Cron events (docs: "Subscribing To CRON Events").
    address public constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;
    uint256 public constant CRON100_TOPIC_0 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 public constant CRON1000_TOPIC_0 = 0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4;
    uint256 public constant CRON10000_TOPIC_0 = 0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56;
    /// @dev This is the gas limit of the whole destination transaction, and the callback proxy spends part of
    ///      it before forwarding. Measured on Sepolia: 300k delivered `heartbeat` (85k total) but not `warn`
    ///      (the vault alone needs ~132k), which surfaced as the proxy's failure event. 1M is the value the
    ///      Reactive docs use and leaves ample headroom for `release` with a token transfer.
    uint64 public constant CALLBACK_GAS_LIMIT = 1_000_000;

    uint256 public constant VAULT_CHECKIN_TOPIC_0 = uint256(keccak256("OwnerCheckIn(address,uint256)"));
    uint256 public constant VAULT_RELEASED_TOPIC_0 = uint256(keccak256("Released(address,uint256,uint256)"));
    uint256 public constant VAULT_CANCELLED_TOPIC_0 = uint256(keccak256("Cancelled(uint256,uint256)"));

    // ------------------------------------------------------------ config
    address public immutable owner;
    uint256 public immutable originChainId;
    address public immutable activityToken;
    uint256 public immutable destinationChainId;
    uint256 public immutable cronTopic;
    uint256 public immutable inactivityWindow;
    uint256 public immutable graceWindow;
    uint256 public immutable retryDelay;
    uint256 public immutable heartbeatMinInterval;

    // ------------------------------------------------------------ state (single Omni instance)
    address public vault;
    Phase public phase;
    bool public paused;
    uint256 public lastSeen;
    uint256 public lastHeartbeatSent;
    uint256 public lastRequestAt;

    // ------------------------------------------------------------ events
    event Armed(address indexed vault, uint256 lastSeen);
    event OwnerActivity(uint256 indexed sourceChainId, address indexed sourceContract, uint256 txHash, uint256 lastSeen);
    event HeartbeatRequested(uint256 lastSeen);
    event WarnRequested(uint256 lastSeen, uint256 elapsed);
    event ReleaseRequested(uint256 lastSeen, uint256 elapsed);
    event Closed(uint256 topic0);
    event Paused();
    event Resumed(uint256 lastSeen);

    // ------------------------------------------------------------ errors
    error OnlyOwner();
    error AlreadyArmed();
    error NotArmed();
    error ZeroAddress();
    error BadPauseState();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @dev `payable` so the contract can be funded at deployment (it pays for its reactive transactions).
    constructor(Config memory c_) payable {
        if (c_.owner == address(0)) revert ZeroAddress();
        owner = c_.owner;
        originChainId = c_.originChainId;
        activityToken = c_.activityToken;
        destinationChainId = c_.destinationChainId;
        cronTopic = c_.cronTopic;
        inactivityWindow = c_.inactivityWindow;
        graceWindow = c_.graceWindow;
        retryDelay = c_.retryDelay;
        heartbeatMinInterval = c_.heartbeatMinInterval;
    }

    // ================================================================ admin

    /// @notice Step 3 of the documented deploy order (reactive -> callback contract -> setter).
    ///         Arms the switch: starts the clock and creates every subscription.
    function setVault(address vault_) external onlyOwner {
        if (phase != Phase.Unarmed) revert AlreadyArmed();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        phase = Phase.Active;
        lastSeen = block.timestamp;
        _subscribeActivity(true);
        _subscribeVault(true);
        _subscribeCron(true);
        emit Armed(vault_, block.timestamp);
    }

    /// @notice Stop the timer (and its per-tick billing). Owner activity is still tracked.
    function pause() external onlyOwner {
        if (paused || phase == Phase.Unarmed || phase == Phase.Closed) revert BadPauseState();
        paused = true;
        _subscribeCron(false);
        emit Paused();
    }

    /// @notice Restart the timer. Settles debt first (a contract in debt receives nothing), and
    ///         counts as owner activity, so the clock restarts from now.
    function resume() external payable onlyOwner {
        if (!paused || phase == Phase.Closed) revert BadPauseState();
        paused = false;
        _coverDebt();
        _subscribeCron(true);
        _onOwnerActivity(block.chainid, address(this), 0, true, true);
        emit Resumed(lastSeen);
    }

    /// @notice Settle outstanding debt to the system contract from this contract's balance (anyone).
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Recover unused REACT/lREACT.
    function withdraw(address payable to_, uint256 amount_) external onlyOwner {
        _pay(to_, amount_);
    }

    // ================================================================ react

    /// @inheritdoc IReactive
    /// @dev Never reverts as a filter (docs: a revert is still billed); non-matching logs fall through.
    function react(LogRecord calldata log_) external onlySystem {
        if (phase == Phase.Unarmed || phase == Phase.Closed) return;

        // 1) Cron tick from the network itself.
        if (log_.topic0 == cronTopic && log_.contractAddress == CRON_SOURCE && log_.chainId == block.chainid) {
            if (!paused) _onTick();
            return;
        }

        // 2) Owner's ordinary activity on the origin chain: Transfer(from = owner, ...).
        if (
            log_.topic0 == TRANSFER_TOPIC_0 && log_.chainId == originChainId
                && (log_.opCode == 3 || log_.opCode == 4) && log_.topic1 == uint256(uint160(owner))
                && (activityToken == address(0) || log_.contractAddress == activityToken)
        ) {
            _onOwnerActivity(log_.chainId, log_.contractAddress, log_.txHash, true, false);
            return;
        }

        // 3) Feedback from the vault itself.
        if (log_.chainId == destinationChainId && log_.contractAddress == vault) {
            if (log_.topic0 == VAULT_CHECKIN_TOPIC_0 && log_.topic1 == uint256(uint160(owner))) {
                // The vault already reset its own clock; just mirror it, no callback needed.
                _onOwnerActivity(log_.chainId, log_.contractAddress, log_.txHash, false, false);
            } else if (log_.topic0 == VAULT_RELEASED_TOPIC_0 || log_.topic0 == VAULT_CANCELLED_TOPIC_0) {
                _close(log_.topic0);
            }
        }
    }

    // ================================================================ decision logic

    function _onTick() internal {
        uint256 elapsed = block.timestamp - lastSeen;
        if (phase == Phase.Active) {
            if (elapsed > inactivityWindow) {
                phase = Phase.Warned;
                lastRequestAt = block.timestamp;
                _requestCallback(ProofOfLifeVault.warn.selector, lastSeen);
                emit WarnRequested(lastSeen, elapsed);
            }
        } else if (phase == Phase.Warned) {
            // Release only on a later tick than the warning, so a warning always comes first.
            if (elapsed > inactivityWindow + graceWindow) {
                phase = Phase.Releasing;
                lastRequestAt = block.timestamp;
                _requestCallback(ProofOfLifeVault.release.selector, lastSeen);
                emit ReleaseRequested(lastSeen, elapsed);
            }
        } else if (phase == Phase.Releasing) {
            // Release not confirmed by the vault yet (callback failed or still in flight): retry.
            if (block.timestamp >= lastRequestAt + retryDelay) {
                lastRequestAt = block.timestamp;
                _requestCallback(ProofOfLifeVault.release.selector, lastSeen);
                emit ReleaseRequested(lastSeen, elapsed);
            }
        }
    }

    function _onOwnerActivity(uint256 chainId_, address source_, uint256 txHash_, bool notifyVault_, bool force_)
        internal
    {
        bool alarmed = phase == Phase.Warned || phase == Phase.Releasing;
        lastSeen = block.timestamp;
        phase = Phase.Active;
        emit OwnerActivity(chainId_, source_, txHash_, block.timestamp);
        if (
            notifyVault_
                && (force_ || alarmed || lastHeartbeatSent == 0 || block.timestamp >= lastHeartbeatSent + heartbeatMinInterval)
        ) {
            lastHeartbeatSent = block.timestamp;
            _requestCallback(ProofOfLifeVault.heartbeat.selector, block.timestamp);
            emit HeartbeatRequested(block.timestamp);
        }
    }

    function _close(uint256 topic0_) internal {
        phase = Phase.Closed;
        _subscribeActivity(false);
        _subscribeVault(false);
        if (!paused) _subscribeCron(false);
        emit Closed(topic0_);
    }

    /// @dev First payload argument is a placeholder the network overwrites with this contract's address.
    function _requestCallback(bytes4 selector_, uint256 value_) internal {
        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: vault,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: abi.encodeWithSelector(selector_, address(0), value_)
            })
        );
    }

    // ================================================================ subscriptions
    // Each pair keeps subscribe/unsubscribe criteria identical (docs: unsubscribe must match all six exactly).

    function _subscribeActivity(bool on_) internal {
        _sub(on_, originChainId, activityToken, TRANSFER_TOPIC_0, uint256(uint160(owner)), REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _subscribeVault(bool on_) internal {
        _sub(on_, destinationChainId, vault, VAULT_CHECKIN_TOPIC_0, uint256(uint160(owner)), REACTIVE_IGNORE, REACTIVE_IGNORE);
        _sub(on_, destinationChainId, vault, VAULT_RELEASED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
        _sub(on_, destinationChainId, vault, VAULT_CANCELLED_TOPIC_0, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _subscribeCron(bool on_) internal {
        _sub(on_, block.chainid, CRON_SOURCE, cronTopic, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE);
    }

    function _sub(bool on_, uint256 chainId_, address contract_, uint256 t0_, uint256 t1_, uint256 t2_, uint256 t3_)
        internal
    {
        if (on_) SYSTEM.subscribe(chainId_, contract_, t0_, t1_, t2_, t3_);
        else SYSTEM.unsubscribe(chainId_, contract_, t0_, t1_, t2_, t3_);
    }
}
