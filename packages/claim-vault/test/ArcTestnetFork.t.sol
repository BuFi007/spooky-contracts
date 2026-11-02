// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Read-only facts about the REAL Arc testnet USDC that the unit suite's mock assumes.
///         Opt-in: ARC_FORK=1 forge test --match-contract ArcTestnetFork -vv
///
/// Why no transfer here: Arc's FiatToken at 0x3600… calls native precompiles
/// (0x1800…0001 `isBlocklisted`, 0x1800…0000 `transfer` of the 18-dp native balance) on
/// every transfer. Foundry/revm cannot execute them (StackUnderflow), so a token transfer
/// cannot be simulated on a fork. The full deposit -> MFA claim round trip is exercised
/// against the live chain by script/SmokeArcTestnet.s.sol instead.
contract ArcTestnetForkTest is Test {
    address constant ARC_USDC = 0x3600000000000000000000000000000000000000;
    IERC20Metadata usdc = IERC20Metadata(ARC_USDC);
    bool fork;

    function setUp() public {
        fork = vm.envOr("ARC_FORK", false);
        if (fork) vm.createSelectFork(vm.envOr("ARC_TESTNET_RPC", string("https://rpc.testnet.arc.network")));
    }

    function test_fork_usdcIsSixDecimalErc20MirroringNativeBalance() public {
        if (!fork) vm.skip(true);
        assertEq(block.chainid, 5042002);
        assertEq(usdc.decimals(), 6);
        assertEq(keccak256(bytes(usdc.symbol())), keccak256("USDC"));

        address probe = makeAddr("probe");
        vm.deal(probe, 10 ether); // 10 native USDC (18 dp)
        assertEq(usdc.balanceOf(probe), 10_000_000); // == 10 USDC in ERC-20 units (6 dp)
    }
}
