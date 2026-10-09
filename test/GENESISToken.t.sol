// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GENESISToken} from "../src/GENESISToken.sol";

/// @notice Smoke tests for GENESISToken: deployment, supply, metadata, transfers, allowances and
///         the absence of any privileged or supply-changing entry point. A fuller suite (fuzz and
///         invariants) is written separately.
contract GENESISTokenTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    GENESISToken token;
    address deployer = makeAddr("deployer");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.prank(deployer);
        token = new GENESISToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------

    function test_metadata() public view {
        assertEq(token.name(), "Genesis Agents");
        assertEq(token.symbol(), "GENESIS");
        assertEq(token.decimals(), 18);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_constructorEmitsMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        new GENESISToken();
    }

    function test_deploysOnEmptyChainWithNoArguments() public {
        // The factory deploys the creation code through CREATE2 with no constructor arguments.
        bytes memory code = type(GENESISToken).creationCode;
        address deployed;
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), 0)
        }
        assertTrue(deployed != address(0));
        assertEq(GENESISToken(deployed).balanceOf(address(this)), SUPPLY);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Transfers
    // ---------------------------------------------------------------------------------------------

    function test_transferMovesExactAmount() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, alice, 1_000 ether);
        assertTrue(token.transfer(alice, 1_000 ether));
        assertEq(token.balanceOf(alice), 1_000 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferChainPreservesSupply() public {
        vm.prank(deployer);
        token.transfer(alice, 500 ether);
        vm.prank(alice);
        token.transfer(bob, 200 ether);
        vm.prank(bob);
        token.transfer(deployer, 50 ether);
        assertEq(token.balanceOf(alice), 300 ether);
        assertEq(token.balanceOf(bob), 150 ether);
        assertEq(token.balanceOf(deployer), SUPPLY - 450 ether);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(deployer), SUPPLY);
    }

    function test_transferToSelfAndZeroAmount() public {
        vm.startPrank(deployer);
        assertTrue(token.transfer(deployer, 10 ether));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertTrue(token.transfer(alice, 0));
        assertEq(token.balanceOf(alice), 0);
        vm.stopPrank();
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        token.transfer(alice, SUPPLY);
        assertEq(token.balanceOf(alice), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1));
        token.transfer(bob, SUPPLY + 1);
    }

    function test_transferRevertsToZeroAddress() public {
        vm.prank(deployer);
        vm.expectRevert(GENESISToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    // ---------------------------------------------------------------------------------------------
    // Allowances
    // ---------------------------------------------------------------------------------------------

    function test_approveAndTransferFrom() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, 100 ether);
        assertTrue(token.approve(alice, 100 ether));
        assertEq(token.allowance(deployer, alice), 100 ether);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(deployer, alice, 40 ether);
        vm.expectEmit(true, true, true, true);
        emit Transfer(deployer, bob, 60 ether);
        assertTrue(token.transferFrom(deployer, bob, 60 ether));
        assertEq(token.balanceOf(bob), 60 ether);
        assertEq(token.allowance(deployer, alice), 40 ether);
    }

    function test_infiniteAllowanceIsNotConsumed() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1 ether);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientAllowance.selector, deployer, alice, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    function test_transferFromRevertsOnInsufficientBalanceEvenWithAllowance() public {
        vm.prank(alice);
        token.approve(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, alice, 0, 1 ether));
        token.transferFrom(alice, bob, 1 ether);
    }

    function test_approveRevertsOnZeroSpender() public {
        vm.prank(deployer);
        vm.expectRevert(GENESISToken.ZeroAddress.selector);
        token.approve(address(0), 1);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(deployer);
        token.approve(alice, 5 ether);
        token.approve(alice, 2 ether);
        vm.stopPrank();
        assertEq(token.allowance(deployer, alice), 2 ether);
    }

    // ---------------------------------------------------------------------------------------------
    // No admin, no mint
    // ---------------------------------------------------------------------------------------------

    function test_noAdminOrMintEntryPoints() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "renounceOwnership()",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "setFee(uint256)",
            "setMaxTx(uint256)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        address attacker = makeAddr("attacker");
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            vm.prank(deployer);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_deployerHasNoPowerOverHolders() public {
        vm.prank(deployer);
        token.transfer(alice, 10 ether);
        // The deployer cannot pull from a holder without an allowance.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientAllowance.selector, alice, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        // And the holder is free to move its tokens.
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10 ether));
        assertEq(token.balanceOf(bob), 10 ether);
    }

    function test_receiveAndFallbackReject() public {
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok);
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok);
    }
}
