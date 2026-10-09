// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GENESISToken} from "../src/GENESISToken.sol";

/// @notice Property tests for GENESISToken at the edges the smoke suite does not reach: random
///         amounts, random callers, the maximum, zero, exact allowances, one-below-infinite
///         allowances, and the failure paths that must leave state untouched.
contract GENESISTokenFuzzTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    GENESISToken token;
    address deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new GENESISToken();
    }

    // ---------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------

    function testFuzz_anyDeployerReceivesTheWholeSupply(address who) public {
        vm.assume(who != address(0));
        vm.assume(who.code.length == 0);
        vm.assume(uint160(who) > 0xff);
        vm.prank(who);
        GENESISToken t = new GENESISToken();
        assertEq(t.balanceOf(who), SUPPLY);
        assertEq(t.totalSupply(), SUPPLY);
        // The fixture's deployer holds the new supply only if it is the one who deployed it.
        assertEq(t.balanceOf(deployer), who == deployer ? SUPPLY : 0);
        // ...and the new deployment never touches the fixture token's balances.
        assertEq(token.balanceOf(who), who == deployer ? SUPPLY : 0);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(deployer);
        GENESISToken other = new GENESISToken();
        assertEq(other.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        vm.prank(deployer);
        other.transfer(address(1), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY, "a transfer on one deployment touched another");
    }

    // ---------------------------------------------------------------------------------------------
    // transfer
    // ---------------------------------------------------------------------------------------------

    function testFuzz_transferMovesExactlyTheAmount(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, to, amount);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAboveBalanceRevertsAndChangesNothing(address from, uint256 held, uint256 amount) public {
        address receiver = makeAddr("receiver");
        vm.assume(from != address(0) && from != deployer && from != receiver);
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(from, held);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, from, held, amount));
        token.transfer(receiver, amount);
        assertEq(token.balanceOf(from), held);
        assertEq(token.balanceOf(receiver), 0);
    }

    function test_transferOfMaxUintRevertsAsInsufficientNotOverflow() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, deployer, SUPPLY, type(uint256).max)
        );
        token.transfer(address(1), type(uint256).max);
    }

    function testFuzz_selfTransferIsANoOpOnBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, deployer, amount);
        assertTrue(token.transfer(deployer, amount));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testFuzz_selfTransferAboveBalanceStillReverts(uint256 amount) public {
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, deployer, SUPPLY, amount));
        token.transfer(deployer, amount);
    }

    function testFuzz_transferToZeroRevertsForAnyAmount(uint256 amount) public {
        vm.prank(deployer);
        vm.expectRevert(GENESISToken.ZeroAddress.selector);
        token.transfer(address(0), amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testFuzz_zeroAmountTransferSucceedsFromAnyone(address from, address to) public {
        vm.assume(from != address(0) && to != address(0));
        vm.prank(from);
        assertTrue(token.transfer(to, 0));
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testFuzz_chainOfTransfersConservesSupply(uint256 a, uint256 b, uint256 c) public {
        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, a);
        c = bound(c, 0, b);
        vm.prank(deployer);
        token.transfer(alice, a);
        vm.prank(alice);
        token.transfer(bob, b);
        vm.prank(bob);
        token.transfer(deployer, c);
        assertEq(token.balanceOf(alice), a - b);
        assertEq(token.balanceOf(bob), b - c);
        assertEq(token.balanceOf(deployer), SUPPLY - a + c);
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(deployer), SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // approve / transferFrom
    // ---------------------------------------------------------------------------------------------

    function testFuzz_approveSetsExactlyAndOverwrites(address spender, uint256 first, uint256 second) public {
        vm.assume(spender != address(0));
        vm.startPrank(deployer);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(deployer, spender, first);
        assertTrue(token.approve(spender, first));
        assertEq(token.allowance(deployer, spender), first);
        assertTrue(token.approve(spender, second));
        assertEq(token.allowance(deployer, spender), second, "approve did not overwrite");
        vm.stopPrank();
        assertEq(token.balanceOf(deployer), SUPPLY, "approve moved tokens");
    }

    function testFuzz_approveNeverMovesTokens(address owner, address spender, uint256 amount) public {
        vm.assume(owner != address(0) && spender != address(0));
        vm.prank(owner);
        token.approve(spender, amount);
        assertEq(token.balanceOf(owner), owner == deployer ? SUPPLY : 0);
        assertEq(token.balanceOf(spender), spender == deployer ? SUPPLY : 0);
    }

    function testFuzz_approveZeroSpenderRevertsForAnyAmount(uint256 amount) public {
        vm.prank(deployer);
        vm.expectRevert(GENESISToken.ZeroAddress.selector);
        token.approve(address(0), amount);
    }

    function testFuzz_transferFromConsumesExactlyTheAmount(address spender, address to, uint256 allowed, uint256 amount)
        public
    {
        vm.assume(spender != address(0) && to != address(0) && to != deployer);
        allowed = bound(allowed, 0, type(uint256).max - 1); // finite
        amount = bound(amount, 0, allowed < SUPPLY ? allowed : SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        vm.expectEmit(true, true, true, true, address(token));
        emit Approval(deployer, spender, allowed - amount);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(deployer, to, amount);
        assertTrue(token.transferFrom(deployer, to, amount));
        assertEq(token.allowance(deployer, spender), allowed - amount, "allowance not reduced by exactly the amount");
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        // `to != deployer`, so the spender is the recipient, the owner itself (approving and pulling from
        // its own balance), or a stranger who must end with nothing.
        uint256 expectedSpender = spender == to ? amount : (spender == deployer ? SUPPLY - amount : 0);
        assertEq(token.balanceOf(spender), expectedSpender, "the spender received tokens it did not ask for");
    }

    function testFuzz_transferFromWithExactAllowanceLeavesZero(uint256 amount) public {
        address spender = makeAddr("spender");
        amount = bound(amount, 1, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(deployer, spender, amount);
        assertEq(token.allowance(deployer, spender), 0);
        // The same call again fails on allowance, with the exact numbers.
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(GENESISToken.InsufficientAllowance.selector, deployer, spender, 0, amount)
        );
        token.transferFrom(deployer, spender, amount);
    }

    function testFuzz_transferFromOneAboveAllowanceReverts(uint256 allowed) public {
        address spender = makeAddr("spender");
        allowed = bound(allowed, 0, SUPPLY - 1);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(GENESISToken.InsufficientAllowance.selector, deployer, spender, allowed, allowed + 1)
        );
        token.transferFrom(deployer, spender, allowed + 1);
        assertEq(token.allowance(deployer, spender), allowed, "a failed transferFrom changed the allowance");
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testFuzz_transferFromAboveBalanceRevertsEvenWithAllowance(uint256 held, uint256 amount) public {
        address owner = makeAddr("owner");
        address spender = makeAddr("spender");
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max - 1);
        vm.prank(deployer);
        token.transfer(owner, held);
        vm.prank(owner);
        token.approve(spender, amount);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, owner, held, amount));
        token.transferFrom(owner, spender, amount);
        // The whole call reverted: the allowance was not spent either.
        assertEq(token.allowance(owner, spender), amount);
        assertEq(token.balanceOf(owner), held);
    }

    function testFuzz_infiniteAllowanceIsNeverConsumed(uint256 a, uint256 b, uint256 c) public {
        address spender = makeAddr("spender");
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        c = bound(c, 0, SUPPLY - a - b);
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        token.transferFrom(deployer, spender, a);
        token.transferFrom(deployer, spender, b);
        token.transferFrom(deployer, spender, c);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(spender), a + b + c);
    }

    function testFuzz_oneBelowMaxAllowanceIsFiniteAndConsumed(uint256 amount) public {
        address spender = makeAddr("spender");
        amount = bound(amount, 1, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        token.transferFrom(deployer, spender, amount);
        assertEq(token.allowance(deployer, spender), type(uint256).max - 1 - amount);
    }

    function testFuzz_infiniteAllowanceDoesNotBypassBalance(uint256 amount) public {
        address spender = makeAddr("spender");
        amount = bound(amount, SUPPLY + 1, type(uint256).max);
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, deployer, SUPPLY, amount));
        token.transferFrom(deployer, spender, amount);
    }

    function testFuzz_transferFromZeroOwnerRevertsForAnyAmount(address spender, uint256 amount) public {
        vm.assume(spender != address(0));
        // allowance[address(0)][spender] can never be set, so the zero owner fails on allowance for
        // amount > 0 and on the zero-address check for amount == 0: either way nothing moves.
        vm.prank(spender);
        vm.expectRevert();
        token.transferFrom(address(0), spender, amount);
        assertEq(token.balanceOf(spender), spender == deployer ? SUPPLY : 0);
    }

    function testFuzz_transferFromToZeroRevertsEvenWhenAllowed(uint256 amount) public {
        address spender = makeAddr("spender");
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert(GENESISToken.ZeroAddress.selector);
        token.transferFrom(deployer, address(0), amount);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_ownerNeedsAnAllowanceToTransferFromItself() public {
        // transferFrom(self) is not a shortcut around approve: standard ERC-20 behaviour, documented.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientAllowance.selector, deployer, deployer, 0, 1));
        token.transferFrom(deployer, address(1), 1);
    }

    function testFuzz_allowanceIsPerSpender(address a, address b, uint256 amount) public {
        vm.assume(a != address(0) && b != address(0) && a != b);
        vm.prank(deployer);
        token.approve(a, amount);
        assertEq(token.allowance(deployer, a), amount);
        assertEq(token.allowance(deployer, b), 0, "an approval leaked to another spender");
        // The reverse pair (a -> deployer) is only set when a is the deployer approving itself.
        assertEq(token.allowance(a, deployer), a == deployer ? amount : 0, "an approval leaked to the reverse pair");
        assertEq(token.allowance(b, deployer), 0, "an approval leaked to an unrelated pair");
    }

    // ---------------------------------------------------------------------------------------------
    // No privileged caller, no unknown entry point
    // ---------------------------------------------------------------------------------------------

    function testFuzz_noCallerCanMoveWhatItDoesNotHold(address caller, address victim, uint256 amount) public {
        vm.assume(caller != address(0) && victim != address(0) && caller != deployer && victim != deployer);
        amount = bound(amount, 1, type(uint256).max);
        vm.startPrank(caller);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, caller, 0, amount));
        token.transfer(victim, amount);
        vm.expectRevert(
            abi.encodeWithSelector(GENESISToken.InsufficientAllowance.selector, deployer, caller, 0, amount)
        );
        token.transferFrom(deployer, caller, amount);
        vm.stopPrank();
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(caller), 0);
    }

    /// @dev Any selector outside the ERC-20 surface reverts, from anyone, with or without value, and
    ///      leaves the supply and the deployer's balance where they were.
    function testFuzz_unknownSelectorsAlwaysRevert(bytes4 selector, bytes memory args, address caller, uint96 value)
        public
    {
        vm.assume(!_isErc20Selector(selector));
        vm.assume(caller != address(0));
        // Funding the token itself would make the ETH-balance check below measure the deal, not the call.
        vm.assume(caller != address(token));
        vm.deal(caller, value);
        vm.prank(caller);
        (bool ok,) = address(token).call{value: value}(abi.encodePacked(selector, args));
        assertFalse(ok, "an unknown selector was accepted");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(address(token).balance, 0);
    }

    function testFuzz_erc20CallsWithValueRevert(uint96 value, address to) public {
        vm.assume(to != address(0));
        value = uint96(bound(value, 1, type(uint96).max));
        vm.deal(deployer, value);
        vm.prank(deployer);
        (bool ok,) = address(token).call{value: value}(abi.encodeCall(GENESISToken.transfer, (to, 1)));
        assertFalse(ok, "a non-payable transfer accepted ETH");
        assertEq(token.balanceOf(to), to == deployer ? SUPPLY : 0);
        assertEq(token.balanceOf(deployer), SUPPLY, "a rejected call moved tokens");
        assertEq(address(token).balance, 0, "a rejected call kept ETH");
    }

    function test_runtimeCodeIsFixedByConstruction() public {
        // No selfdestruct and no code-changing path: the runtime is the compiled runtime and nothing else.
        bytes memory runtime = address(token).code;
        assertEq(keccak256(runtime), keccak256(type(GENESISToken).runtimeCode));
        vm.prank(deployer);
        token.transfer(address(1), SUPPLY);
        assertEq(keccak256(address(token).code), keccak256(runtime));
    }

    function _isErc20Selector(bytes4 s) internal pure returns (bool) {
        return s == GENESISToken.transfer.selector || s == GENESISToken.transferFrom.selector
            || s == GENESISToken.approve.selector || s == bytes4(keccak256("allowance(address,address)"))
            || s == bytes4(keccak256("balanceOf(address)")) || s == GENESISToken.totalSupply.selector
            || s == bytes4(keccak256("name()")) || s == bytes4(keccak256("symbol()"))
            || s == bytes4(keccak256("decimals()")) || s == bytes4(keccak256("TOTAL_SUPPLY()"));
    }
}
