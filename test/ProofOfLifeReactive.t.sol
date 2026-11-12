// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Base } from "./Base.t.sol";
import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { ProofOfLifeVault } from "../src/ProofOfLifeVault.sol";
import { ProofOfLifeReactive } from "../src/ProofOfLifeReactive.sol";

/// @notice react() decision logic (constructed LogRecords) and full demo loops (real token
///         transfers and vault events routed through a mock of the system contract / callback proxy).
contract ProofOfLifeReactiveTest is Base {
    uint256 internal constant WINDOW = 300; // demo: warn after 5 min
    uint256 internal constant GRACE = 300; // demo: release 5 min after that
    uint256 internal constant RETRY = 300;

    DemoToken internal token;
    DemoToken internal otherToken;
    ProofOfLifeReactive internal rc;
    ProofOfLifeVault internal vault;
    uint256 internal t0;

    function setUp() public {
        _etchSystem();
        vm.warp(1_800_000_000);
        token = new DemoToken(owner, 1_000 ether);
        otherToken = new DemoToken(owner, 1_000 ether);

        // Deploy order from the docs: reactive -> callback contract -> setter.
        rc = new ProofOfLifeReactive{ value: 1 ether }(
            ProofOfLifeReactive.Config({
                owner: owner,
                originChainId: LASNA,
                activityToken: address(token),
                destinationChainId: LASNA,
                cronTopic: CRON100,
                inactivityWindow: WINDOW,
                graceWindow: GRACE,
                retryDelay: RETRY,
                heartbeatMinInterval: 0
            })
        );
        vault = new ProofOfLifeVault{ value: 1 ether }(
            _proxy(), address(rc), owner, beneficiary, address(token), WINDOW, GRACE
        );
        vm.warp(block.timestamp + 10);
        vm.prank(owner);
        rc.setVault(address(vault));
        t0 = block.timestamp;

        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        vault.deposit{ value: 3 ether }();
        token.approve(address(vault), 50 ether);
        vault.depositToken(50 ether);
        vm.stopPrank();
    }

    function _react(IReactive.LogRecord memory l_) internal {
        sys.dispatch(address(rc), l_);
    }

    function _tickAt(uint256 ts_) internal {
        vm.warp(ts_);
        vm.roll(block.number + 100);
        _react(_cronLog());
    }

    function _phase() internal view returns (ProofOfLifeReactive.Phase) {
        return rc.phase();
    }

    // ================================================================ subscriptions / access

    function test_SetVaultCreatesSubscriptions() public view {
        uint256 ownerTopic = uint256(uint160(owner));
        assertTrue(
            sys.hasActiveSub(address(rc), LASNA, address(token), TRANSFER_TOPIC_0, ownerTopic, REACTIVE_IGNORE, REACTIVE_IGNORE),
            "owner Transfer sub"
        );
        assertTrue(
            sys.hasActiveSub(address(rc), LASNA, CRON_SOURCE, CRON100, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE),
            "cron sub"
        );
        assertTrue(
            sys.hasActiveSub(
                address(rc), LASNA, address(vault), rc.VAULT_CHECKIN_TOPIC_0(), ownerTopic, REACTIVE_IGNORE, REACTIVE_IGNORE
            ),
            "vault check-in sub"
        );
        assertEq(sys.activeSubCount(address(rc)), 5);
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Active));
        assertEq(rc.lastSeen(), t0);
    }

    function test_VaultEventTopicsMatchVault() public pure {
        // The reactive contract hard-codes the vault's event signatures; keep them in sync.
        assertEq(bytes32(uint256(keccak256("OwnerCheckIn(address,uint256)"))), ProofOfLifeVault.OwnerCheckIn.selector);
        assertEq(bytes32(uint256(keccak256("Released(address,uint256,uint256)"))), ProofOfLifeVault.Released.selector);
        assertEq(bytes32(uint256(keccak256("Cancelled(uint256,uint256)"))), ProofOfLifeVault.Cancelled.selector);
    }

    function test_RevertWhen_ReactNotFromSystem() public {
        IReactive.LogRecord memory l = _transferLog(address(token), owner, stranger, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR));
        rc.react(l);
    }

    function test_RevertWhen_SetVaultTwiceOrByStranger() public {
        vm.prank(stranger);
        vm.expectRevert(ProofOfLifeReactive.OnlyOwner.selector);
        rc.setVault(address(1));
        vm.prank(owner);
        vm.expectRevert(ProofOfLifeReactive.AlreadyArmed.selector);
        rc.setVault(address(1));
    }

    function test_UnarmedIgnoresEverything() public {
        ProofOfLifeReactive fresh = new ProofOfLifeReactive(
            ProofOfLifeReactive.Config(owner, LASNA, address(token), LASNA, CRON100, WINDOW, GRACE, RETRY, 0)
        );
        assertEq(sys.activeSubCount(address(fresh)), 0, "no subscriptions before setVault");
        uint256 n = sys.callbackCount();
        vm.warp(block.timestamp + 10 days);
        sys.dispatch(address(fresh), _cronLog());
        sys.dispatch(address(fresh), _transferLog(address(token), owner, stranger, 1));
        assertEq(sys.callbackCount(), n);
    }

    // ================================================================ react(): owner activity

    function test_React_OwnerTransferRequestsHeartbeat() public {
        vm.warp(t0 + 100);
        uint256 n = sys.callbackCount();
        _react(_transferLog(address(token), owner, stranger, 1 ether));
        assertEq(sys.callbackCount(), n + 1);
        (address requester, uint256 chainId, address recipient, uint64 gasLimit, bytes memory payload) =
            sys.callbackAt(n);
        assertEq(requester, address(rc));
        assertEq(chainId, LASNA);
        assertEq(recipient, address(vault));
        assertEq(gasLimit, rc.CALLBACK_GAS_LIMIT());
        assertEq(payload, abi.encodeWithSelector(ProofOfLifeVault.heartbeat.selector, address(0), t0 + 100));
        assertEq(rc.lastSeen(), t0 + 100);
    }

    function test_React_ERC721StyleTransferCounts() public {
        IReactive.LogRecord memory l = _transferLog(address(token), owner, stranger, 0);
        l.opCode = 4;
        l.topic3 = 7; // tokenId
        l.data = "";
        vm.warp(t0 + 50);
        _react(l);
        assertEq(rc.lastSeen(), t0 + 50);
    }

    function test_React_IgnoresNonOwnerAndForeignLogs() public {
        vm.warp(t0 + 100);
        uint256 n = sys.callbackCount();

        _react(_transferLog(address(token), stranger, owner, 1)); // someone else sends (owner receives)
        _react(_transferLog(address(otherToken), owner, stranger, 1)); // owner, but not the watched token

        IReactive.LogRecord memory wrongChain = _transferLog(address(token), owner, stranger, 1);
        wrongChain.chainId = 11155111;
        _react(wrongChain);

        IReactive.LogRecord memory unindexed = _transferLog(address(token), owner, stranger, 1);
        unindexed.opCode = 1; // LOG1 variant: topic positions are not "from"
        _react(unindexed);

        IReactive.LogRecord memory otherCron = _cronLog();
        otherCron.contractAddress = stranger; // fake "cron" from a user contract
        vm.warp(t0 + WINDOW + GRACE + 1000);
        _react(otherCron);

        assertEq(sys.callbackCount(), n, "no callbacks");
        assertEq(rc.lastSeen(), t0, "clock untouched");
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Active));
    }

    function test_React_AnyTokenModeCountsEveryToken() public {
        ProofOfLifeReactive anyRc = new ProofOfLifeReactive(
            ProofOfLifeReactive.Config(owner, LASNA, address(0), LASNA, CRON100, WINDOW, GRACE, RETRY, 0)
        );
        ProofOfLifeVault v2 =
            new ProofOfLifeVault(_proxy(), address(anyRc), owner, beneficiary, address(0), WINDOW, GRACE);
        vm.prank(owner);
        anyRc.setVault(address(v2));
        assertTrue(
            sys.hasActiveSub(
                address(anyRc), LASNA, address(0), TRANSFER_TOPIC_0, uint256(uint160(owner)), REACTIVE_IGNORE, REACTIVE_IGNORE
            )
        );
        vm.warp(block.timestamp + 42);
        sys.dispatch(address(anyRc), _transferLog(address(otherToken), owner, stranger, 1));
        assertEq(anyRc.lastSeen(), block.timestamp);
    }

    function test_React_HeartbeatThrottle() public {
        ProofOfLifeReactive thr = new ProofOfLifeReactive(
            ProofOfLifeReactive.Config(owner, LASNA, address(token), LASNA, CRON100, WINDOW, GRACE, RETRY, 1 hours)
        );
        ProofOfLifeVault v2 = new ProofOfLifeVault(_proxy(), address(thr), owner, beneficiary, address(0), WINDOW, GRACE);
        vm.prank(owner);
        thr.setVault(address(v2));
        uint256 n = sys.callbackCount();
        sys.dispatch(address(thr), _transferLog(address(token), owner, stranger, 1));
        vm.warp(block.timestamp + 10 minutes);
        sys.dispatch(address(thr), _transferLog(address(token), owner, stranger, 1));
        assertEq(sys.callbackCount(), n + 1, "second heartbeat throttled");
        assertEq(thr.lastSeen(), block.timestamp, "clock still advances");
        vm.warp(block.timestamp + 1 hours);
        sys.dispatch(address(thr), _transferLog(address(token), owner, stranger, 1));
        assertEq(sys.callbackCount(), n + 2);
    }

    // ================================================================ react(): timer decisions

    function test_React_TickBeforeWindowDoesNothing() public {
        uint256 n = sys.callbackCount();
        _tickAt(t0 + WINDOW); // exactly at the window: not yet "> window"
        assertEq(sys.callbackCount(), n);
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Active));
    }

    function test_React_TickAfterWindowRequestsWarnOnce() public {
        uint256 n = sys.callbackCount();
        _tickAt(t0 + WINDOW + 1);
        assertEq(sys.callbackCount(), n + 1);
        assertEq(_lastCallbackSelector(), ProofOfLifeVault.warn.selector);
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Warned));
        _tickAt(t0 + WINDOW + 100);
        assertEq(sys.callbackCount(), n + 1, "no duplicate warn");
    }

    function test_React_ReleaseOnlyAfterWarnAndGrace() public {
        // Even if the first tick lands after window+grace, it only warns; release comes on a later tick.
        uint256 n = sys.callbackCount();
        _tickAt(t0 + WINDOW + GRACE + 50);
        assertEq(_lastCallbackSelector(), ProofOfLifeVault.warn.selector);
        _tickAt(t0 + WINDOW + GRACE + 150);
        assertEq(sys.callbackCount(), n + 2);
        assertEq(_lastCallbackSelector(), ProofOfLifeVault.release.selector);
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Releasing));
    }

    function test_React_WarnedButBeforeGraceDoesNotRelease() public {
        _tickAt(t0 + WINDOW + 1);
        uint256 n = sys.callbackCount();
        _tickAt(t0 + WINDOW + GRACE);
        assertEq(sys.callbackCount(), n);
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Warned));
    }

    function test_React_ReleaseRetriedUntilConfirmed() public {
        _tickAt(t0 + WINDOW + 1);
        _tickAt(t0 + WINDOW + GRACE + 1);
        uint256 n = sys.callbackCount();
        _tickAt(t0 + WINDOW + GRACE + 100); // before retry delay
        assertEq(sys.callbackCount(), n);
        _tickAt(t0 + WINDOW + GRACE + 1 + RETRY);
        assertEq(sys.callbackCount(), n + 1);
        assertEq(_lastCallbackSelector(), ProofOfLifeVault.release.selector);
    }

    function test_React_RecoveryAfterWarningSendsHeartbeat() public {
        _tickAt(t0 + WINDOW + 1);
        uint256 n = sys.callbackCount();
        _react(_transferLog(address(token), owner, stranger, 1));
        assertEq(sys.callbackCount(), n + 1);
        assertEq(_lastCallbackSelector(), ProofOfLifeVault.heartbeat.selector);
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Active));
        assertEq(rc.lastSeen(), t0 + WINDOW + 1);
    }

    function test_React_VaultCheckInMirrorsClockWithoutCallback() public {
        vm.warp(t0 + 200);
        IReactive.LogRecord memory l;
        l.chainId = LASNA;
        l.contractAddress = address(vault);
        l.topic0 = rc.VAULT_CHECKIN_TOPIC_0();
        l.topic1 = uint256(uint160(owner));
        l.data = abi.encode(block.timestamp);
        l.opCode = 2;
        uint256 n = sys.callbackCount();
        _react(l);
        assertEq(sys.callbackCount(), n);
        assertEq(rc.lastSeen(), t0 + 200);
    }

    function test_React_VaultReleasedClosesAndUnsubscribes() public {
        IReactive.LogRecord memory l;
        l.chainId = LASNA;
        l.contractAddress = address(vault);
        l.topic0 = rc.VAULT_RELEASED_TOPIC_0();
        l.topic1 = uint256(uint160(beneficiary));
        l.opCode = 2;
        _react(l);
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Closed));
        assertEq(sys.activeSubCount(address(rc)), 0, "stops paying for ticks");
        uint256 n = sys.callbackCount();
        _tickAt(t0 + 10 * WINDOW);
        _react(_transferLog(address(token), owner, stranger, 1));
        assertEq(sys.callbackCount(), n);
    }

    function test_React_ReleasedFromForeignContractIgnored() public {
        IReactive.LogRecord memory l;
        l.chainId = LASNA;
        l.contractAddress = stranger;
        l.topic0 = rc.VAULT_RELEASED_TOPIC_0();
        l.opCode = 2;
        _react(l);
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Active));
    }

    function test_PauseStopsTimerAndResumeRestartsClock() public {
        vm.prank(owner);
        rc.pause();
        assertFalse(
            sys.hasActiveSub(address(rc), LASNA, CRON_SOURCE, CRON100, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE)
        );
        uint256 n = sys.callbackCount();
        _tickAt(t0 + 10 * WINDOW); // even if a stale tick arrives, a paused contract does nothing
        assertEq(sys.callbackCount(), n);

        vm.prank(owner);
        rc.resume();
        assertTrue(
            sys.hasActiveSub(address(rc), LASNA, CRON_SOURCE, CRON100, REACTIVE_IGNORE, REACTIVE_IGNORE, REACTIVE_IGNORE)
        );
        assertEq(rc.lastSeen(), block.timestamp);
        assertEq(sys.callbackCount(), n + 1, "resume sends a heartbeat");
        assertEq(_lastCallbackSelector(), ProofOfLifeVault.heartbeat.selector);

        vm.prank(stranger);
        vm.expectRevert(ProofOfLifeReactive.OnlyOwner.selector);
        rc.pause();
    }

    // ================================================================ end-to-end demo loops
    // Real DemoToken transfers and real vault events, routed by subscription matching, callbacks
    // delivered by the proxy with the requester injected into the first argument.

    function _ownerTransfer() internal {
        vm.recordLogs();
        vm.prank(owner);
        token.transfer(stranger, 1 ether);
        _pump();
    }

    function _tickPump(uint256 ts_) internal {
        vm.warp(ts_);
        vm.roll(block.number + 100);
        vm.recordLogs();
        sys.route(_cronLog());
        _pump();
    }

    function test_Loop_A_Heartbeat() public {
        vm.warp(t0 + 200);
        _ownerTransfer();
        assertEq(rc.lastSeen(), t0 + 200);
        assertEq(vault.lastSeen(), t0 + 200, "vault clock reset by callback");
        _tickPump(t0 + WINDOW + 1); // 5 min after start, but only ~100 s after the heartbeat
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Active));
    }

    function test_Loop_B_Warning() public {
        _tickPump(t0 + WINDOW + 1);
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Warned));
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Warned));
    }

    function test_Loop_C_Release() public {
        _tickPump(t0 + WINDOW + 1);
        _tickPump(t0 + WINDOW + GRACE + 1);
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Released));
        assertEq(beneficiary.balance, 3 ether);
        assertEq(token.balanceOf(beneficiary), 50 ether);
        // The vault's Released event was routed back: the reactive contract closed itself.
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Closed));
        assertEq(sys.activeSubCount(address(rc)), 0);
    }

    function test_Loop_D_RecoveryByTransfer() public {
        _tickPump(t0 + WINDOW + 1);
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Warned));
        vm.warp(t0 + WINDOW + 60);
        _ownerTransfer();
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Active), "vault recovered");
        _tickPump(t0 + WINDOW + GRACE + 1);
        _tickPump(t0 + WINDOW + GRACE + 200);
        assertEq(beneficiary.balance, 0, "beneficiary gets nothing");
        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(vault.principal(), 3 ether);
    }

    function test_Loop_D_RecoveryByVaultCheckIn() public {
        _tickPump(t0 + WINDOW + 1);
        vm.warp(t0 + WINDOW + 60);
        vm.recordLogs();
        vm.prank(owner);
        vault.checkIn();
        _pump();
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Active), "reactive mirrored the vault check-in");
        assertEq(rc.lastSeen(), t0 + WINDOW + 60);
        _tickPump(t0 + WINDOW + GRACE + 1);
        assertEq(beneficiary.balance, 0);
    }

    function test_Loop_LateReleaseLosesToFreshHeartbeat() public {
        // Release is requested, but the owner shows up before the callback is delivered:
        // the vault's own clock check must reject the stale release.
        _tickPump(t0 + WINDOW + 1);
        vm.warp(t0 + WINDOW + GRACE + 1);
        vm.roll(block.number + 100);
        sys.route(_cronLog()); // release requested, NOT delivered yet
        assertEq(_lastCallbackSelector(), ProofOfLifeVault.release.selector);
        vm.recordLogs();
        vm.prank(owner);
        vault.checkIn(); // owner acts on the vault directly
        _pump(); // delivers the queued release, then routes the vault's events
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Active));
        assertEq(beneficiary.balance, 0);
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Active));
    }

    function test_Loop_CancelClosesReactive() public {
        vm.recordLogs();
        vm.prank(owner);
        vault.cancel();
        _pump();
        assertEq(uint8(_phase()), uint8(ProofOfLifeReactive.Phase.Closed));
        assertEq(sys.activeSubCount(address(rc)), 0);
    }
}
