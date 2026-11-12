// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, Vm } from "forge-std/Test.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { MockSystem } from "./mocks/MockSystem.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { ProofOfLifeVault } from "../src/ProofOfLifeVault.sol";
import { ProofOfLifeReactive } from "../src/ProofOfLifeReactive.sol";

abstract contract Base is Test {
    address internal constant SYSTEM_ADDR = 0x8888888888888888888888888888888888888888;
    address internal constant CRON_SOURCE = 0x0000000000000000000000000000000000fffFfF;
    uint256 internal constant REACTIVE_IGNORE = 0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;
    uint256 internal constant TRANSFER_TOPIC_0 = 0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef;
    uint256 internal constant CRON100 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;
    uint256 internal constant LASNA = 5318007;

    MockSystem internal sys;
    address internal owner = makeAddr("owner");
    address internal beneficiary = makeAddr("beneficiary");
    address internal stranger = makeAddr("stranger");

    function _etchSystem() internal {
        vm.chainId(LASNA);
        MockSystem impl = new MockSystem();
        vm.etch(SYSTEM_ADDR, address(impl).code);
        sys = MockSystem(payable(SYSTEM_ADDR));
    }

    function _proxy() internal pure returns (IPayable) {
        return IPayable(payable(SYSTEM_ADDR));
    }

    // ------------------------------------------------------------ LogRecord builders

    function _transferLog(address token_, address from_, address to_, uint256 value_)
        internal
        view
        returns (IReactive.LogRecord memory l)
    {
        l.chainId = block.chainid;
        l.contractAddress = token_;
        l.topic0 = TRANSFER_TOPIC_0;
        l.topic1 = uint256(uint160(from_));
        l.topic2 = uint256(uint160(to_));
        l.data = abi.encode(value_);
        l.blockNumber = block.number;
        l.opCode = 3;
        l.txHash = uint256(keccak256(abi.encode("tx", block.number, from_, value_)));
    }

    function _cronLog() internal view returns (IReactive.LogRecord memory l) {
        l.chainId = block.chainid;
        l.contractAddress = CRON_SOURCE;
        l.topic0 = CRON100;
        l.data = abi.encode(block.number);
        l.blockNumber = block.number;
        l.opCode = 1;
    }

    function _toRecord(Vm.Log memory log_, uint256 i_) internal view returns (IReactive.LogRecord memory l) {
        l.chainId = block.chainid;
        l.contractAddress = log_.emitter;
        uint256 n = log_.topics.length;
        if (n > 0) l.topic0 = uint256(log_.topics[0]);
        if (n > 1) l.topic1 = uint256(log_.topics[1]);
        if (n > 2) l.topic2 = uint256(log_.topics[2]);
        if (n > 3) l.topic3 = uint256(log_.topics[3]);
        l.data = log_.data;
        l.blockNumber = block.number;
        l.opCode = n;
        l.logIndex = i_;
    }

    /// @dev Network simulation: route recorded logs to subscribers, deliver the resulting callbacks,
    ///      route the logs those produce, until nothing is left. Call `vm.recordLogs()` before the action.
    function _pump() internal {
        for (uint256 round = 0; round < 10; round++) {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            vm.recordLogs();
            for (uint256 i = 0; i < logs.length; i++) {
                if (logs[i].emitter == SYSTEM_ADDR) continue; // mock's own bookkeeping
                sys.route(_toRecord(logs[i], i));
            }
            uint256 n = sys.deliverAll();
            if (n == 0 && logs.length == 0) return;
        }
    }

    function _lastCallbackSelector() internal view returns (bytes4 sel) {
        (,,,, bytes memory p) = sys.callbackAt(sys.callbackCount() - 1);
        assembly {
            sel := mload(add(p, 32))
        }
    }
}
