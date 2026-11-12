// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Script, console2 } from "forge-std/Script.sol";
import { IPayable } from "@reactive/src/interfaces/IPayable.sol";
import { DemoToken } from "../src/DemoToken.sol";
import { ProofOfLifeVault } from "../src/ProofOfLifeVault.sol";
import { ProofOfLifeReactive } from "../src/ProofOfLifeReactive.sol";

/// @notice All-Lasna deployment (Lasna is both origin and destination).
///
/// Env (the key is read from the environment only, never from a file in this repo):
///   PRIVATE_KEY      deployer = vault owner = the account whose activity proves life
///   BENEFICIARY      receives the vault on release
/// Optional (demo defaults in brackets):
///   INACTIVITY_SECS  [300]     seconds of silence before a warning
///   GRACE_SECS       [300]     further seconds before release
///   RETRY_SECS       [300]     re-request an unconfirmed release after this long
///   HEARTBEAT_MIN    [0]       min seconds between heartbeat callbacks
///   CRON_TOPIC       [Cron100] topic0 of the Cron event to tick on
///   ANY_TOKEN        [false]   true = every ERC-20/721 Transfer from the owner counts, not just DemoToken
///   REACTIVE_FUND    [0.5 ether] lREACT for reactive transactions
///   VAULT_GAS        [0.5 ether] lREACT the vault keeps for callback fees
///   VAULT_DEPOSIT    [0.1 ether] principal deposited for the demo
///   TOKEN_DEPOSIT    [100 ether] DemoToken units deposited for the demo
///
/// Order (https://dev.reactive.network/callback-contracts): reactive -> vault (callback) -> setVault.
contract Deploy is Script {
    address internal constant CALLBACK_PROXY = 0x8888888888888888888888888888888888888888; // Lasna
    uint256 internal constant CRON100 = 0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70;

    struct Params {
        uint256 pk;
        address owner;
        address beneficiary;
        uint256 inactivity;
        uint256 grace;
        uint256 retry;
        uint256 hbMin;
        uint256 cronTopic;
        bool anyToken;
        uint256 reactiveFund;
        uint256 vaultGas;
        uint256 vaultDeposit;
        uint256 tokenDeposit;
    }

    function _load() internal view returns (Params memory p) {
        p.pk = vm.envUint("PRIVATE_KEY");
        p.owner = vm.addr(p.pk);
        p.beneficiary = vm.envAddress("BENEFICIARY");
        p.inactivity = vm.envOr("INACTIVITY_SECS", uint256(300));
        p.grace = vm.envOr("GRACE_SECS", uint256(300));
        p.retry = vm.envOr("RETRY_SECS", uint256(300));
        p.hbMin = vm.envOr("HEARTBEAT_MIN", uint256(0));
        p.cronTopic = vm.envOr("CRON_TOPIC", CRON100);
        p.anyToken = vm.envOr("ANY_TOKEN", false);
        p.reactiveFund = vm.envOr("REACTIVE_FUND", uint256(0.5 ether));
        p.vaultGas = vm.envOr("VAULT_GAS", uint256(0.5 ether));
        p.vaultDeposit = vm.envOr("VAULT_DEPOSIT", uint256(0.1 ether));
        p.tokenDeposit = vm.envOr("TOKEN_DEPOSIT", uint256(100 ether));
    }

    function _config(Params memory p_, address token_) internal view returns (ProofOfLifeReactive.Config memory c) {
        c.owner = p_.owner;
        c.originChainId = block.chainid;
        c.activityToken = p_.anyToken ? address(0) : token_;
        c.destinationChainId = block.chainid;
        c.cronTopic = p_.cronTopic;
        c.inactivityWindow = p_.inactivity;
        c.graceWindow = p_.grace;
        c.retryDelay = p_.retry;
        c.heartbeatMinInterval = p_.hbMin;
    }

    function run() external {
        Params memory p = _load();

        vm.startBroadcast(p.pk);

        // 1. Origin: demo token whose transfers by the owner are the "proof of life".
        DemoToken token = new DemoToken(p.owner, 1_000_000 ether);

        // 2. Reactive contract (funded for its reactive transactions).
        ProofOfLifeReactive rc = new ProofOfLifeReactive{ value: p.reactiveFund }(_config(p, address(token)));

        // 3. Vault (callback contract), authorising exactly this reactive contract.
        ProofOfLifeVault vault = new ProofOfLifeVault{ value: p.vaultGas }(
            IPayable(payable(CALLBACK_PROXY)), address(rc), p.owner, p.beneficiary, address(token), p.inactivity, p.grace
        );

        // 4. Arm: point the reactive contract at the vault (creates all subscriptions, starts the clock).
        rc.setVault(address(vault));

        // 5. Demo principal.
        if (p.vaultDeposit > 0) vault.deposit{ value: p.vaultDeposit }();
        if (p.tokenDeposit > 0) {
            token.approve(address(vault), p.tokenDeposit);
            vault.depositToken(p.tokenDeposit);
        }

        vm.stopBroadcast();

        console2.log("chainId     ", block.chainid);
        console2.log("owner       ", p.owner);
        console2.log("beneficiary ", p.beneficiary);
        console2.log("DemoToken   ", address(token));
        console2.log("Reactive    ", address(rc));
        console2.log("Vault       ", address(vault));
    }
}
