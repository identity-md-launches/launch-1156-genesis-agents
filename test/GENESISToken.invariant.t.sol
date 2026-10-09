// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GENESISToken} from "../src/GENESISToken.sol";

/// @notice Drives the token with random, bounded sequences of every state-changing call from a small
///         set of actors plus strangers, and keeps ghost books of what each call should have done.
contract GENESISTokenHandler is Test {
    GENESISToken public token;
    address[] public actors;

    // ghost accounting
    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    address[] public touched;
    mapping(address => bool) private seen;
    uint256 public calls;
    uint256 public transfers;
    uint256 public transferFroms;
    uint256 public approvals;
    uint256 public failedAttempts;

    constructor(GENESISToken token_, address deployer) {
        token = token_;
        actors.push(deployer);
        actors.push(makeAddr("a1"));
        actors.push(makeAddr("a2"));
        actors.push(makeAddr("a3"));
        actors.push(makeAddr("a4"));
        for (uint256 i; i < actors.length; ++i) {
            _touch(actors[i]);
        }
        ghostBalance[deployer] = token.totalSupply();
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ++transfers;
        ++calls;
    }

    function transferToStranger(uint256 fromSeed, address to, uint256 amount) external {
        if (to == address(0)) to = address(1);
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        _touch(to);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ++transfers;
        ++calls;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        ghostAllowance[owner][spender] = amount;
        ++approvals;
        ++calls;
    }

    function approveInfinite(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, type(uint256).max));
        ghostAllowance[owner][spender] = type(uint256).max;
        ++approvals;
        ++calls;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 allowed = token.allowance(owner, spender);
        uint256 cap = token.balanceOf(owner);
        if (allowed < cap) cap = allowed;
        amount = bound(amount, 0, cap);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        ghostBalance[owner] -= amount;
        ghostBalance[to] += amount;
        if (allowed != type(uint256).max) ghostAllowance[owner][spender] = allowed - amount;
        ++transferFroms;
        ++calls;
    }

    /// @dev Attempts that must fail: overdrawn transfers, overdrawn transferFroms, strangers pulling
    ///      without an allowance, the zero address. They are part of the random sequence so that a
    ///      failed call is also checked to have changed nothing.
    function failedTransfer(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 held = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - held);
        vm.prank(from);
        vm.expectRevert(abi.encodeWithSelector(GENESISToken.InsufficientBalance.selector, from, held, held + excess));
        token.transfer(to, held + excess);
        ++failedAttempts;
        ++calls;
    }

    function failedTransferFrom(uint256 ownerSeed, address thief, uint256 amount) external {
        address owner = _actor(ownerSeed);
        if (thief == address(0)) thief = address(1);
        amount = bound(amount, 1, type(uint256).max);
        uint256 allowed = token.allowance(owner, thief);
        if (allowed == type(uint256).max) return;
        if (allowed >= amount) amount = allowed + 1;
        vm.prank(thief);
        vm.expectRevert(
            abi.encodeWithSelector(GENESISToken.InsufficientAllowance.selector, owner, thief, allowed, amount)
        );
        token.transferFrom(owner, thief, amount);
        ++failedAttempts;
        ++calls;
    }

    function failedZeroAddress(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        vm.startPrank(from);
        vm.expectRevert(GENESISToken.ZeroAddress.selector);
        token.transfer(address(0), amount);
        vm.expectRevert(GENESISToken.ZeroAddress.selector);
        token.approve(address(0), amount);
        vm.stopPrank();
        ++failedAttempts;
        ++calls;
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _touch(address who) private {
        if (!seen[who]) {
            seen[who] = true;
            touched.push(who);
        }
    }
}

/// @notice Invariants of a fixed-supply token that holds every holder's balance: the supply never
///         moves, the balances always sum to it, every balance and allowance is exactly what the
///         sequence of successful calls implies, and the code never changes.
contract GENESISTokenInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;

    GENESISToken token;
    GENESISTokenHandler handler;
    address deployer = makeAddr("deployer");
    bytes32 codeHash;

    function setUp() public {
        vm.prank(deployer);
        token = new GENESISToken();
        codeHash = keccak256(address(token).code);
        handler = new GENESISTokenHandler(token, deployer);
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.touched(i));
        }
        assertEq(sum, SUPPLY, "balances do not sum to the supply");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_balancesMatchGhostBooks() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            address who = handler.touched(i);
            assertEq(token.balanceOf(who), handler.ghostBalance(who), "a balance drifted from the ledger");
            assertLe(token.balanceOf(who), SUPPLY);
        }
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_allowancesMatchGhostBooks() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
        }
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 100
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_codeNeverChanges() public view {
        assertEq(keccak256(address(token).code), codeHash);
        assertEq(address(token).balance, 0);
    }
}
