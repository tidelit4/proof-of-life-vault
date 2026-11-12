// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @title DemoToken
/// @notice Minimal ERC-20 used only to generate "owner activity" on demand for the demo.
///         Every `transfer` from the vault owner emits `Transfer(owner, to, value)`, which the
///         reactive contract treats as a proof-of-life heartbeat.
contract DemoToken {
    string public constant name = "Proof-of-Life Demo Token";
    string public constant symbol = "PLD";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(address holder_, uint256 supply_) {
        _mint(holder_, supply_);
    }

    function transfer(address to_, uint256 value_) external returns (bool) {
        _transfer(msg.sender, to_, value_);
        return true;
    }

    function approve(address spender_, uint256 value_) external returns (bool) {
        allowance[msg.sender][spender_] = value_;
        emit Approval(msg.sender, spender_, value_);
        return true;
    }

    function transferFrom(address from_, address to_, uint256 value_) external returns (bool) {
        uint256 allowed = allowance[from_][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value_) revert InsufficientAllowance();
            allowance[from_][msg.sender] = allowed - value_;
        }
        _transfer(from_, to_, value_);
        return true;
    }

    function _transfer(address from_, address to_, uint256 value_) internal {
        if (balanceOf[from_] < value_) revert InsufficientBalance();
        unchecked {
            balanceOf[from_] -= value_;
        }
        balanceOf[to_] += value_;
        emit Transfer(from_, to_, value_);
    }

    function _mint(address to_, uint256 value_) internal {
        totalSupply += value_;
        balanceOf[to_] += value_;
        emit Transfer(address(0), to_, value_);
    }
}
