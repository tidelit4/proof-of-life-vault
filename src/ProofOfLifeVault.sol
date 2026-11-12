// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";

interface IERC20Minimal {
    function balanceOf(address account_) external view returns (uint256);
}

/// @title ProofOfLifeVault
/// @notice Destination (callback) contract of the Proof-of-Life dead-man's switch.
///
///         Holds native coin (lREACT on Lasna, ETH elsewhere) and optionally one ERC-20 for `owner`.
///         If the owner shows no on-chain activity for `inactivityWindow`, the reactive contract
///         sends `warn`; if the owner stays silent for a further `graceWindow`, it sends `release`
///         and the vault pays everything to `beneficiary`. Any owner activity, seen by the reactive
///         contract (heartbeat callback) or done directly on the vault, resets the clock and clears a
///         pending warning (recovery).
///
///         Callback authentication follows https://dev.reactive.network/callback-contracts and
///         reactive-lib-omni `src/base/AbstractCallback.sol`: every callback method is guarded by
///         `onlyServiceProvider` (msg.sender must be the callback proxy) AND
///         `onlyCallbackSender(sender_)` (the first argument, which the network overwrites with the
///         requesting reactive contract's address, must equal `_CALLBACK_SENDER`). In the pre-Omni
///         network this first argument was the "RVM id"; on Omni the RVM is gone and it is the
///         reactive contract's own address.
///
///         The vault never trusts the reactive contract's clock alone: `warn` and `release` are
///         re-checked against the vault's own `lastSeen`, so a late or out-of-order callback can
///         never release early or override a fresher heartbeat.
contract ProofOfLifeVault is AbstractCallback {
    enum State {
        Active,
        Warned,
        Released,
        Cancelled
    }

    // ---------------------------------------------------------------- config (immutable)
    address public immutable owner;
    address public immutable beneficiary;
    /// @notice Optional ERC-20 held by the vault (address(0) = native only).
    address public immutable asset;
    uint256 public immutable inactivityWindow;
    uint256 public immutable graceWindow;

    // ---------------------------------------------------------------- state
    State public state;
    /// @notice Last moment the owner was seen alive (vault clock).
    uint256 public lastSeen;
    /// @notice Native principal that belongs to the owner / beneficiary. Everything above it is
    ///         operating balance that pays the callback proxy.
    uint256 public principal;
    /// @notice Native payouts that could not be pushed (recipient reverted); claim with `claim()`.
    mapping(address => uint256) public claimable;
    /// @notice Sum of `claimable`; excluded from the operating balance.
    uint256 public reserved;

    uint256 private _lock = 1;

    // ---------------------------------------------------------------- events
    event Deposited(address indexed from, uint256 amount);
    event TokenDeposited(address indexed from, uint256 amount);
    event GasFunded(address indexed from, uint256 amount);
    event OwnerCheckIn(address indexed owner, uint256 timestamp);
    event Heartbeat(uint256 lastSeen, uint256 reportedAt);
    event Warning(uint256 lastSeen, uint256 releaseAt);
    event Recovered(uint256 lastSeen);
    event Released(address indexed beneficiary, uint256 nativeAmount, uint256 tokenAmount);
    event Withdrawn(address indexed to, uint256 nativeAmount, uint256 tokenAmount);
    event Cancelled(uint256 nativeAmount, uint256 tokenAmount);
    event CallbackIgnored(bytes4 indexed selector, string reason);
    event Claimed(address indexed account, uint256 amount);

    // ---------------------------------------------------------------- errors
    error OnlyOwner();
    error Closed();
    error ZeroAddress();
    error AmountTooLarge();
    error TokenTransferFailed();
    error NoAsset();
    error Reentrancy();
    error NativeTransferFailed();
    error NotReleased();

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier whenOpen() {
        if (state == State.Released || state == State.Cancelled) revert Closed();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    /// @param callbackProxy_ Callback proxy of this chain (Lasna: 0x8888...8888).
    /// @param reactive_ The ProofOfLifeReactive contract authorised to send callbacks.
    /// @param owner_ Account whose activity proves life; the only one who can withdraw/cancel.
    /// @param beneficiary_ Receives the vault if the owner goes silent.
    /// @param asset_ Optional ERC-20 to hold (address(0) = native only).
    /// @param inactivityWindow_ Seconds of silence before a warning.
    /// @param graceWindow_ Further seconds of silence after the warning threshold before release.
    /// @dev msg.value funds callback gas (operating balance), not principal.
    constructor(
        IPayable callbackProxy_,
        address reactive_,
        address owner_,
        address beneficiary_,
        address asset_,
        uint256 inactivityWindow_,
        uint256 graceWindow_
    ) payable AbstractCallback(callbackProxy_, reactive_) {
        if (owner_ == address(0) || beneficiary_ == address(0) || reactive_ == address(0)) revert ZeroAddress();
        owner = owner_;
        beneficiary = beneficiary_;
        asset = asset_;
        inactivityWindow = inactivityWindow_;
        graceWindow = graceWindow_;
        lastSeen = block.timestamp;
        if (msg.value > 0) emit GasFunded(msg.sender, msg.value);
        emit OwnerCheckIn(owner_, block.timestamp);
    }

    // ================================================================ views

    function releaseAt() public view returns (uint256) {
        return lastSeen + inactivityWindow + graceWindow;
    }

    function warnAt() public view returns (uint256) {
        return lastSeen + inactivityWindow;
    }

    function operatingBalance() public view returns (uint256) {
        return address(this).balance - principal - reserved;
    }

    function tokenBalance() public view returns (uint256) {
        return asset == address(0) ? 0 : IERC20Minimal(asset).balanceOf(address(this));
    }

    // ================================================================ funding

    /// @notice Plain transfers fund callback gas (operating balance), not principal.
    receive() external payable override {
        emit GasFunded(msg.sender, msg.value);
    }

    /// @notice Add native principal. Anyone may top up; only the owner's deposits count as a check-in.
    function deposit() external payable whenOpen {
        principal += msg.value;
        emit Deposited(msg.sender, msg.value);
        if (msg.sender == owner) _checkIn();
    }

    /// @notice Pull `amount_` of `asset` from the caller (needs prior approve).
    function depositToken(uint256 amount_) external nonReentrant whenOpen {
        if (asset == address(0)) revert NoAsset();
        _safeTokenCall(abi.encodeWithSelector(0x23b872dd, msg.sender, address(this), amount_)); // transferFrom
        emit TokenDeposited(msg.sender, amount_);
        if (msg.sender == owner) _checkIn();
    }

    // ================================================================ owner actions (each one is a check-in)

    /// @notice Explicit "I'm alive" without moving funds. Also clears a warning.
    function checkIn() external onlyOwner whenOpen {
        _checkIn();
    }

    /// @notice Withdraw principal and/or tokens to the owner at any time (also a check-in).
    function withdraw(uint256 nativeAmount_, uint256 tokenAmount_) external nonReentrant onlyOwner whenOpen {
        if (nativeAmount_ > principal) revert AmountTooLarge();
        principal -= nativeAmount_;
        _checkIn();
        if (tokenAmount_ > 0) _sendToken(owner, tokenAmount_);
        if (nativeAmount_ > 0) _sendNativeStrict(owner, nativeAmount_);
        emit Withdrawn(owner, nativeAmount_, tokenAmount_);
    }

    /// @notice Close the vault: everything (principal, tokens, leftover gas) goes back to the owner.
    ///         The reactive contract sees `Cancelled` and drops its subscriptions.
    function cancel() external nonReentrant onlyOwner whenOpen {
        state = State.Cancelled;
        principal = 0;
        uint256 tokens = tokenBalance();
        if (tokens > 0) _sendToken(owner, tokens);
        // Settle what we owe the proxy if the operating balance covers it; never block the owner's exit on it.
        uint256 debt = _SERVICE_PROVIDER.debt(address(this));
        if (debt > 0 && debt <= address(this).balance) _pay(payable(address(_SERVICE_PROVIDER)), debt);
        uint256 native = address(this).balance;
        if (native > 0) _sendNativeStrict(owner, native);
        emit Cancelled(native, tokens);
    }

    /// @notice Withdraw surplus operating balance (owner only).
    function withdrawGas(uint256 amount_) external nonReentrant onlyOwner {
        if (amount_ > operatingBalance()) revert AmountTooLarge();
        _sendNativeStrict(owner, amount_);
    }

    /// @notice Settle any outstanding debt to the callback proxy from the operating balance.
    function coverDebt() external {
        _coverDebt();
    }

    /// @notice Pull a native payout that could not be pushed.
    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        claimable[msg.sender] = 0;
        reserved -= amount;
        _sendNativeStrict(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    /// @notice After release, retry a token payout to the beneficiary that failed inside the callback.
    function pushTokens() external nonReentrant {
        if (state != State.Released) revert NotReleased();
        uint256 tokens = tokenBalance();
        _sendToken(beneficiary, tokens);
        emit Released(beneficiary, 0, tokens);
    }

    // ================================================================ callbacks (Reactive Network only)

    /// @notice Owner activity observed by the reactive contract.
    /// @param sender_ Overwritten by the network with the requesting reactive contract's address.
    /// @param seenAt_ Timestamp at which the reactive contract saw the activity.
    function heartbeat(address sender_, uint256 seenAt_)
        external
        onlyServiceProvider
        onlyCallbackSender(sender_)
    {
        if (_closed()) {
            emit CallbackIgnored(this.heartbeat.selector, "closed");
            return;
        }
        uint256 ts = seenAt_ > block.timestamp ? block.timestamp : seenAt_;
        if (ts > lastSeen) lastSeen = ts;
        if (state == State.Warned) {
            state = State.Active;
            emit Recovered(lastSeen);
        }
        emit Heartbeat(lastSeen, seenAt_);
    }

    /// @notice Inactivity threshold passed (according to the reactive contract).
    function warn(address sender_, uint256 /* reactiveLastSeen_ */)
        external
        onlyServiceProvider
        onlyCallbackSender(sender_)
    {
        if (_closed()) {
            emit CallbackIgnored(this.warn.selector, "closed");
            return;
        }
        if (state == State.Warned) {
            emit CallbackIgnored(this.warn.selector, "already warned");
            return;
        }
        if (block.timestamp < warnAt()) {
            emit CallbackIgnored(this.warn.selector, "owner seen recently");
            return;
        }
        state = State.Warned;
        emit Warning(lastSeen, releaseAt());
    }

    /// @notice Inactivity + grace passed (according to the reactive contract): pay the beneficiary.
    function release(address sender_, uint256 /* reactiveLastSeen_ */)
        external
        nonReentrant
        onlyServiceProvider
        onlyCallbackSender(sender_)
    {
        if (_closed()) {
            emit CallbackIgnored(this.release.selector, "closed");
            return;
        }
        if (block.timestamp < releaseAt()) {
            emit CallbackIgnored(this.release.selector, "owner seen recently");
            return;
        }
        state = State.Released;
        uint256 native = principal;
        principal = 0;
        uint256 tokens = tokenBalance();
        if (tokens > 0 && !_tryToken(beneficiary, tokens)) tokens = 0; // left in the vault; anyone can retry with pushTokens()
        if (native > 0) _sendNativeOrCredit(beneficiary, native);
        emit Released(beneficiary, native, tokens);
    }

    // ================================================================ internals

    function _closed() internal view returns (bool) {
        return state == State.Released || state == State.Cancelled;
    }

    function _checkIn() internal {
        lastSeen = block.timestamp;
        if (state == State.Warned) {
            state = State.Active;
            emit Recovered(lastSeen);
        }
        emit OwnerCheckIn(owner, block.timestamp);
    }

    function _sendNativeStrict(address to_, uint256 amount_) internal {
        (bool ok,) = payable(to_).call{ value: amount_ }("");
        if (!ok) revert NativeTransferFailed();
    }

    /// @dev A callback must not revert because the beneficiary is a contract that refuses ETH:
    ///      fall back to a pull payment.
    function _sendNativeOrCredit(address to_, uint256 amount_) internal {
        bool ok;
        // Gas-capped call that copies no return data (a hostile beneficiary cannot return-bomb the callback).
        assembly {
            ok := call(50000, to_, amount_, 0, 0, 0, 0)
        }
        if (!ok) {
            claimable[to_] += amount_;
            reserved += amount_;
        }
    }

    function _sendToken(address to_, uint256 amount_) internal {
        _safeTokenCall(abi.encodeWithSelector(0xa9059cbb, to_, amount_)); // transfer
    }

    function _tryToken(address to_, uint256 amount_) internal returns (bool) {
        (bool ok, bytes memory ret) = asset.call(abi.encodeWithSelector(0xa9059cbb, to_, amount_));
        return ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    function _safeTokenCall(bytes memory data_) internal {
        (bool ok, bytes memory ret) = asset.call(data_);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenTransferFailed();
    }
}
