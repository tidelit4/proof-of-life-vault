// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Base } from "./Base.t.sol";
import { AbstractPayer } from "@reactive/src/base/AbstractPayer.sol";
import { AbstractCallback } from "@reactive/src/base/AbstractCallback.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { ProofOfLifeVault } from "../src/ProofOfLifeVault.sol";

contract RefusingBeneficiary {
    bool public accept;

    function setAccept(bool a_) external {
        accept = a_;
    }

    function claimFrom(ProofOfLifeVault v_) external {
        v_.claim();
    }

    receive() external payable {
        require(accept, "no thanks");
    }
}

/// @notice Vault-only tests: callbacks are driven directly as the callback proxy (0x8888).
contract ProofOfLifeVaultTest is Base {
    uint256 internal constant WINDOW = 1 days;
    uint256 internal constant GRACE = 2 days;

    DemoToken internal token;
    ProofOfLifeVault internal vault;
    address internal reactive = makeAddr("reactive");
    uint256 internal t0;

    event Heartbeat(uint256 lastSeen, uint256 reportedAt);
    event Warning(uint256 lastSeen, uint256 releaseAt);
    event Recovered(uint256 lastSeen);
    event Released(address indexed beneficiary, uint256 nativeAmount, uint256 tokenAmount);
    event CallbackIgnored(bytes4 indexed selector, string reason);

    function setUp() public {
        _etchSystem();
        vm.warp(1_800_000_000);
        t0 = block.timestamp;
        token = new DemoToken(owner, 1_000 ether);
        vault = new ProofOfLifeVault{ value: 1 ether }(
            _proxy(), reactive, owner, beneficiary, address(token), WINDOW, GRACE
        );
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        vault.deposit{ value: 5 ether }();
        token.approve(address(vault), 100 ether);
        vault.depositToken(100 ether);
        vm.stopPrank();
    }

    function _hb(uint256 ts_) internal {
        vm.prank(SYSTEM_ADDR);
        vault.heartbeat(reactive, ts_);
    }

    function _warn() internal {
        vm.prank(SYSTEM_ADDR);
        vault.warn(reactive, 0);
    }

    function _release() internal {
        vm.prank(SYSTEM_ADDR);
        vault.release(reactive, 0);
    }

    // ------------------------------------------------------------ setup sanity
    function test_SetupBalances() public view {
        assertEq(vault.principal(), 5 ether);
        assertEq(vault.operatingBalance(), 1 ether);
        assertEq(vault.tokenBalance(), 100 ether);
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Active));
        assertEq(vault.lastSeen(), t0);
    }

    function test_PlainTransferFundsGasNotPrincipal() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(vault).call{ value: 0.5 ether }("");
        assertTrue(ok);
        assertEq(vault.principal(), 5 ether);
        assertEq(vault.operatingBalance(), 1.5 ether);
    }

    // ------------------------------------------------------------ heartbeat
    function test_HeartbeatResetsClock() public {
        vm.warp(t0 + 20 hours);
        vm.expectEmit(address(vault));
        emit Heartbeat(t0 + 20 hours, t0 + 20 hours);
        _hb(block.timestamp);
        assertEq(vault.lastSeen(), t0 + 20 hours);
        assertEq(vault.warnAt(), t0 + 20 hours + WINDOW);

        // 25 h after start, only 5 h after the heartbeat: a warn must be ignored.
        vm.warp(t0 + 25 hours);
        vm.expectEmit(address(vault));
        emit CallbackIgnored(ProofOfLifeVault.warn.selector, "owner seen recently");
        _warn();
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Active));
    }

    function test_HeartbeatFutureTimestampIsCapped() public {
        vm.warp(t0 + 1 hours);
        _hb(t0 + 365 days);
        assertEq(vault.lastSeen(), t0 + 1 hours);
    }

    function test_HeartbeatOlderThanLastSeenDoesNotRewind() public {
        vm.warp(t0 + 10 hours);
        _hb(t0 + 10 hours);
        _hb(t0 + 2 hours);
        assertEq(vault.lastSeen(), t0 + 10 hours);
    }

    // ------------------------------------------------------------ warn then recover
    function test_WarnThenRecoverByHeartbeat() public {
        vm.warp(t0 + WINDOW + 1);
        vm.expectEmit(address(vault));
        emit Warning(t0, t0 + WINDOW + GRACE);
        _warn();
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Warned));

        vm.warp(t0 + WINDOW + 2 hours);
        vm.expectEmit(address(vault));
        emit Recovered(t0 + WINDOW + 2 hours);
        _hb(block.timestamp);
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Active));

        // The old release time passes: a release must not pay out.
        vm.warp(t0 + WINDOW + GRACE + 1);
        uint256 before = beneficiary.balance;
        _release();
        assertEq(beneficiary.balance, before);
        assertEq(vault.principal(), 5 ether);
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Active));
    }

    function test_WarnThenRecoverByOwnerCheckIn() public {
        vm.warp(t0 + WINDOW + 1);
        _warn();
        vm.prank(owner);
        vault.checkIn();
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Active));
        vm.warp(t0 + WINDOW + GRACE + 1);
        _release();
        assertEq(beneficiary.balance, 0);
        assertEq(token.balanceOf(beneficiary), 0);
    }

    function test_WarnThenRecoverByOwnerWithdraw() public {
        vm.warp(t0 + WINDOW + 1);
        _warn();
        vm.prank(owner);
        vault.withdraw(1 ether, 0);
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Active));
        assertEq(vault.lastSeen(), block.timestamp);
    }

    function test_WarnTwiceIgnored() public {
        vm.warp(t0 + WINDOW + 1);
        _warn();
        vm.expectEmit(address(vault));
        emit CallbackIgnored(ProofOfLifeVault.warn.selector, "already warned");
        _warn();
    }

    // ------------------------------------------------------------ warn then release
    function test_WarnThenReleaseToBeneficiary() public {
        vm.warp(t0 + WINDOW + 1);
        _warn();
        vm.warp(t0 + WINDOW + GRACE);
        vm.expectEmit(address(vault));
        emit Released(beneficiary, 5 ether, 100 ether);
        _release();

        assertEq(beneficiary.balance, 5 ether);
        assertEq(token.balanceOf(beneficiary), 100 ether);
        assertEq(vault.principal(), 0);
        assertEq(vault.tokenBalance(), 0);
        assertEq(vault.operatingBalance(), 1 ether, "gas reserve untouched");
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Released));

        // Closed: further callbacks are ignored, owner actions revert.
        _hb(block.timestamp);
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Released));
        vm.prank(owner);
        vm.expectRevert(ProofOfLifeVault.Closed.selector);
        vault.withdraw(0, 0);
        // Leftover gas can still be recovered by the owner.
        vm.prank(owner);
        vault.withdrawGas(1 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_ReleaseTooEarlyIgnored() public {
        vm.warp(t0 + WINDOW + 1);
        _warn();
        vm.warp(t0 + WINDOW + GRACE - 1);
        vm.expectEmit(address(vault));
        emit CallbackIgnored(ProofOfLifeVault.release.selector, "owner seen recently");
        _release();
        assertEq(beneficiary.balance, 0);
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Warned));
    }

    function test_ReleaseToRefusingBeneficiaryFallsBackToClaim() public {
        RefusingBeneficiary rb = new RefusingBeneficiary();
        ProofOfLifeVault v = new ProofOfLifeVault{ value: 1 ether }(
            _proxy(), reactive, owner, address(rb), address(0), WINDOW, GRACE
        );
        vm.prank(owner);
        v.deposit{ value: 2 ether }();
        vm.warp(t0 + WINDOW + GRACE);
        vm.prank(SYSTEM_ADDR);
        v.release(reactive, 0); // must not revert even though the beneficiary refuses ETH
        assertEq(uint8(v.state()), uint8(ProofOfLifeVault.State.Released));
        assertEq(v.claimable(address(rb)), 2 ether);
        assertEq(v.operatingBalance(), 1 ether);
        rb.setAccept(true);
        rb.claimFrom(v);
        assertEq(address(rb).balance, 2 ether);
        assertEq(v.reserved(), 0);
    }

    // ------------------------------------------------------------ authentication
    function test_RevertWhen_CallbackFromNonProxy() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR));
        vault.heartbeat(reactive, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR));
        vault.warn(reactive, 0);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR));
        vault.release(reactive, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_OwnerCallsCallbackDirectly() public {
        vm.warp(t0 + WINDOW + GRACE + 1);
        vm.prank(beneficiary);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, beneficiary, SYSTEM_ADDR));
        vault.release(reactive, 0);
    }

    function test_RevertWhen_ProxyRelaysForeignReactive() public {
        address evil = makeAddr("evilReactive");
        vm.warp(t0 + WINDOW + GRACE + 1);
        vm.prank(SYSTEM_ADDR);
        vm.expectRevert(abi.encodeWithSelector(AbstractCallback.CallbackNotAuthorized.selector, evil, reactive));
        vault.release(evil, 0);
        assertEq(beneficiary.balance, 0);
    }

    function test_RevertWhen_PayFromNonProxy() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AbstractPayer.NotAuthorized.selector, stranger, SYSTEM_ADDR));
        vault.pay(1 ether);
    }

    // ------------------------------------------------------------ owner controls
    function test_OwnerWithdraw() public {
        uint256 ethBefore = owner.balance;
        vm.prank(owner);
        vault.withdraw(2 ether, 40 ether);
        assertEq(owner.balance, ethBefore + 2 ether);
        assertEq(token.balanceOf(owner), 900 ether + 40 ether);
        assertEq(vault.principal(), 3 ether);
        assertEq(vault.tokenBalance(), 60 ether);
        assertEq(vault.operatingBalance(), 1 ether);
    }

    function test_RevertWhen_WithdrawByNonOwner() public {
        vm.prank(beneficiary);
        vm.expectRevert(ProofOfLifeVault.OnlyOwner.selector);
        vault.withdraw(1 ether, 0);
    }

    function test_RevertWhen_WithdrawMoreThanPrincipal() public {
        vm.prank(owner);
        vm.expectRevert(ProofOfLifeVault.AmountTooLarge.selector);
        vault.withdraw(5 ether + 1, 0);
    }

    function test_OwnerCancelReturnsEverything() public {
        uint256 ethBefore = owner.balance;
        vm.prank(owner);
        vault.cancel();
        assertEq(owner.balance, ethBefore + 6 ether); // principal + leftover gas
        assertEq(token.balanceOf(owner), 1_000 ether);
        assertEq(uint8(vault.state()), uint8(ProofOfLifeVault.State.Cancelled));
        vm.warp(t0 + WINDOW + GRACE + 1);
        _release();
        assertEq(beneficiary.balance, 0);
    }

    function test_CancelPaysProxyDebtFirst() public {
        sys.setDebt(address(vault), 0.1 ether);
        uint256 ethBefore = owner.balance;
        vm.prank(owner);
        vault.cancel();
        assertEq(SYSTEM_ADDR.balance, 0.1 ether);
        assertEq(owner.balance, ethBefore + 5.9 ether);
    }

    function test_DepositByStrangerIsNotACheckIn() public {
        vm.warp(t0 + 5 hours);
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vault.deposit{ value: 1 ether }();
        assertEq(vault.lastSeen(), t0);
        assertEq(vault.principal(), 6 ether);
    }
}
