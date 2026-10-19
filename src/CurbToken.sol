// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/// @title CurbToken
/// @notice The curb (CURB) token: a fixed-supply ERC-20 with 18 decimals.
/// @dev The whole supply is minted once, in the constructor, to the deployer (the launch factory).
/// There is no owner, no mint function, no pause, no blacklist and no transfer fee: every transfer
/// moves exactly the amount requested. Holders may burn (curb) their own tokens, or tokens they hold
/// an allowance for, which can only ever lower the supply.
contract CurbToken is ERC20, ERC20Burnable {
    /// @notice Token name returned by `name()`.
    string public constant TOKEN_NAME = "curb";
    /// @notice Token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "CURB";
    /// @notice The whole supply, 1,000,000,000 tokens in 18-decimal minor units.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}
