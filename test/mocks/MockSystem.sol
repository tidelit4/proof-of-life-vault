// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";

/// @notice Test double for Reactive Network's system contract / Lasna callback proxy
///         (both live at 0x8888...8888 on Lasna). Tests `vm.etch` its code there.
///         - records subscribe/unsubscribe (exact six-criteria match, like the docs describe)
///         - routes LogRecords to matching subscribers by calling `react()` (msg.sender = 0x8888)
///         - queues callback requests and delivers them as the proxy, overwriting the first payload
///           argument with the requesting reactive contract's address
contract MockSystem {
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    struct Sub {
        address subscriber;
        uint256 chainId;
        address contract_;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
        bool active;
    }

    struct Cb {
        address requester;
        uint256 chainId;
        address recipient;
        uint64 gasLimit;
        bytes payload;
    }

    Sub[] internal _subs;
    Cb[] internal _cbs;
    uint256 public delivered;
    mapping(address => uint256) public debts;

    event CallbackDelivered(address indexed recipient, bool ok);

    receive() external payable { }

    // ------------------------------------------------------------ ISubscriptionService
    function subscribe(uint256 chainId_, address contract_, uint256 t0_, uint256 t1_, uint256 t2_, uint256 t3_)
        external
    {
        _subs.push(Sub(msg.sender, chainId_, contract_, t0_, t1_, t2_, t3_, true));
    }

    function unsubscribe(uint256 chainId_, address contract_, uint256 t0_, uint256 t1_, uint256 t2_, uint256 t3_)
        external
    {
        for (uint256 i = 0; i < _subs.length; i++) {
            Sub storage s = _subs[i];
            if (
                s.active && s.subscriber == msg.sender && s.chainId == chainId_ && s.contract_ == contract_
                    && s.topic0 == t0_ && s.topic1 == t1_ && s.topic2 == t2_ && s.topic3 == t3_
            ) {
                s.active = false;
            }
        }
    }

    // ------------------------------------------------------------ ISystemContract
    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c_) external {
        _cbs.push(Cb(msg.sender, c_.chainId, c_.recipient, c_.gasLimit, c_.payload));
    }

    function debt(address contract_) external view returns (uint256) {
        return debts[contract_];
    }

    // ------------------------------------------------------------ test helpers
    function setDebt(address contract_, uint256 amount_) external {
        debts[contract_] = amount_;
    }

    function activeSubCount(address subscriber_) external view returns (uint256 n) {
        for (uint256 i = 0; i < _subs.length; i++) {
            if (_subs[i].active && _subs[i].subscriber == subscriber_) n++;
        }
    }

    function hasActiveSub(
        address subscriber_,
        uint256 chainId_,
        address contract_,
        uint256 t0_,
        uint256 t1_,
        uint256 t2_,
        uint256 t3_
    ) external view returns (bool) {
        for (uint256 i = 0; i < _subs.length; i++) {
            Sub storage s = _subs[i];
            if (
                s.active && s.subscriber == subscriber_ && s.chainId == chainId_ && s.contract_ == contract_
                    && s.topic0 == t0_ && s.topic1 == t1_ && s.topic2 == t2_ && s.topic3 == t3_
            ) return true;
        }
        return false;
    }

    function callbackCount() external view returns (uint256) {
        return _cbs.length;
    }

    function callbackAt(uint256 i_)
        external
        view
        returns (address requester, uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload)
    {
        Cb storage c = _cbs[i_];
        return (c.requester, c.chainId, c.recipient, c.gasLimit, c.payload);
    }

    function _matches(Sub storage s_, IReactive.LogRecord memory l_) internal view returns (bool) {
        return s_.active && (s_.chainId == 0 || s_.chainId == l_.chainId)
            && (s_.contract_ == address(0) || s_.contract_ == l_.contractAddress)
            && (s_.topic0 == REACTIVE_IGNORE || s_.topic0 == l_.topic0)
            && (s_.topic1 == REACTIVE_IGNORE || s_.topic1 == l_.topic1)
            && (s_.topic2 == REACTIVE_IGNORE || s_.topic2 == l_.topic2)
            && (s_.topic3 == REACTIVE_IGNORE || s_.topic3 == l_.topic3);
    }

    /// @notice Deliver one log to every matching subscription (one react() per subscriber).
    /// @return n Number of react() calls made.
    function route(IReactive.LogRecord memory l_) external returns (uint256 n) {
        uint256 len = _subs.length;
        address[] memory done = new address[](len);
        for (uint256 i = 0; i < len; i++) {
            if (!_matches(_subs[i], l_)) continue;
            address target = _subs[i].subscriber;
            bool seen;
            for (uint256 j = 0; j < n; j++) {
                if (done[j] == target) seen = true;
            }
            if (seen) continue;
            done[n++] = target;
            IReactive(payable(target)).react(l_);
        }
    }

    /// @notice Call react() directly as the system contract, bypassing subscription matching.
    function dispatch(address reactive_, IReactive.LogRecord memory l_) external {
        IReactive(payable(reactive_)).react(l_);
    }

    /// @notice Deliver all queued callbacks as the callback proxy.
    function deliverAll() external returns (uint256 n) {
        while (delivered < _cbs.length) {
            Cb memory c = _cbs[delivered++];
            bytes memory p = c.payload;
            address requester = c.requester;
            // Overwrite the first argument (the reserved address slot) with the requester.
            assembly {
                mstore(add(p, 36), requester)
            }
            (bool ok,) = c.recipient.call{ gas: c.gasLimit }(p);
            emit CallbackDelivered(c.recipient, ok);
            n++;
        }
    }
}
