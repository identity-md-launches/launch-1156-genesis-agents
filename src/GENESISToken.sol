// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title Genesis Agents (GENESIS)
/// @notice A fixed-supply, plain ERC-20 token. The whole supply of 1,000,000,000 GENESIS
///         (1e27 minor units at 18 decimals) is minted once, in the constructor, to the deployer.
/// @dev Design constraints, all deliberate:
///      - No owner, no admin, no roles: every parameter is a compile-time constant.
///      - No mint after construction: `totalSupply` is immutable in practice. There is no burn either,
///        so the supply never changes at all.
///      - No fee, tax, limit, pause, blacklist or hook on transfers: `transfer` and `transferFrom`
///        move exactly the amount requested, for every caller.
///      - No proxy, no upgradeability, no delegatecall, no selfdestruct, no external calls at all.
///      - The constructor takes no arguments and calls no other contract, so it deploys on an empty
///        chain and the launch factory (msg.sender at deployment) receives the entire supply.
///      Self-contained on purpose: no inherited library, so the deployed bytes are exactly this file.
contract GENESISToken {
    // ---------------------------------------------------------------------------------------------
    // Events (ERC-20)
    // ---------------------------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    /// @notice A transfer or approval named the zero address as sender, receiver, owner or spender.
    error ZeroAddress();
    /// @notice `from` holds less than `amount`.
    error InsufficientBalance(address from, uint256 balance, uint256 amount);
    /// @notice `spender` is allowed less than `amount` by `owner`.
    error InsufficientAllowance(address owner, address spender, uint256 allowance, uint256 amount);

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    string public constant name = "Genesis Agents";
    string public constant symbol = "GENESIS";
    uint8 public constant decimals = 18;

    /// @notice 1,000,000,000 GENESIS in minor units. Fixed forever: nothing mints or burns.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    mapping(address account => uint256) public balanceOf;
    mapping(address owner => mapping(address spender => uint256)) public allowance;

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @notice Mints the entire supply to the deployer. At launch the deployer is the launch factory,
    ///         which distributes the supply (swarm share, pool seed, remainder) itself.
    constructor() {
        balanceOf[msg.sender] = TOTAL_SUPPLY;
        emit Transfer(address(0), msg.sender, TOTAL_SUPPLY);
    }

    // ---------------------------------------------------------------------------------------------
    // ERC-20
    // ---------------------------------------------------------------------------------------------

    /// @notice The supply, constant for the life of the contract.
    function totalSupply() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        return true;
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance(from, fromBalance, amount);
        unchecked {
            // fromBalance >= amount was checked above, and the sum of all balances is TOTAL_SUPPLY,
            // so the receiver's balance cannot exceed uint256.
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        if (owner == address(0) || spender == address(0)) revert ZeroAddress();
        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _spendAllowance(address owner, address spender, uint256 amount) private {
        uint256 current = allowance[owner][spender];
        if (current == type(uint256).max) return;
        if (current < amount) revert InsufficientAllowance(owner, spender, current, amount);
        unchecked {
            allowance[owner][spender] = current - amount;
        }
        emit Approval(owner, spender, current - amount);
    }
}
