// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CurbToken} from "src/CurbToken.sol";

/// @notice Drives real token calls using a closed set of holders, without editing token storage.
/// @dev Ghost balances/allowances come from requested actions, never from post-call token state.
/// Burns are recorded separately so lost supply cannot be mistaken for authorized destruction.
contract CurbTokenHandler is Test {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 ether;
    CurbToken public immutable token;
    address public immutable outsider;
    address[5] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public totalBurned;

    constructor(CurbToken token_, address[5] memory actors_) {
        token = token_;
        actors = actors_;
        outsider = makeAddr("invariant-unapproved-outsider");
        // The fixture gives each of five actors an equal share using actual transfers.
        for (uint256 i; i < actors_.length; ++i) {
            expectedBalance[actors_[i]] = INITIAL_SUPPLY / actors_.length;
        }
    }

    modifier supplyCannotIncrease() {
        uint256 beforeSupply = token.totalSupply();
        _;
        assertLe(token.totalSupply(), beforeSupply, "supply increased during an action");
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external supplyCannotIncrease {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "transfer returned false");
        // Sequential updates also cover from == to without special casing it away.
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external supplyCannotIncrease {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // Bias toward revocations and unlimited approvals while retaining finite allowances.
        uint256 mode = amountSeed % 5;
        uint256 amount = mode == 0 ? 0 : mode == 1 ? type(uint256).max : bound(amountSeed, 0, INITIAL_SUPPLY);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "approve returned false");
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed)
        external
        supplyCannotIncrease
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _actor(toSeed);
        uint256 amount = bound(amountSeed, 0, _spendable(owner, spender));
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount), "transferFrom returned false");
        _recordSpending(owner, spender, amount);
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
    }

    function burn(uint256 ownerSeed, uint256 amountSeed) external supplyCannotIncrease {
        address owner = _actor(ownerSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[owner]);
        vm.prank(owner);
        token.burn(amount);
        expectedBalance[owner] -= amount;
        totalBurned += amount;
    }

    function burnFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external supplyCannotIncrease {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = bound(amountSeed, 0, _spendable(owner, spender));
        vm.prank(spender);
        token.burnFrom(owner, amount);
        _recordSpending(owner, spender, amount);
        expectedBalance[owner] -= amount;
        totalBurned += amount;
    }

    function rejectOverdraw(uint256 ownerSeed, uint256 toSeed, uint256 amountSeed) external supplyCannotIncrease {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[owner];
        uint256 amount = bound(amountSeed, held + 1, type(uint256).max);
        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, held, amount);
        vm.expectRevert(errorData);
        vm.prank(owner);
        token.transfer(to, amount);
        vm.expectRevert(errorData);
        vm.prank(owner);
        token.burn(amount);
        // No ghost updates: the invariants require rejected operations to leave all state intact.
    }

    function rejectUnapprovedSpend(uint256 ownerSeed, uint256 toSeed, uint256 amountSeed)
        external
        supplyCannotIncrease
    {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        uint256 held = expectedBalance[owner];
        uint256 amount = bound(amountSeed, 1, held == 0 ? 1 : held);
        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, outsider, 0, amount);
        vm.expectRevert(errorData);
        vm.prank(outsider);
        token.transferFrom(owner, to, amount);
        vm.expectRevert(errorData);
        vm.prank(outsider);
        token.burnFrom(owner, amount);
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed)
        external
        supplyCannotIncrease
    {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = bound(amountSeed, 0, _spendable(owner, spender));
        bytes memory errorData = abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0));
        vm.expectRevert(errorData);
        vm.prank(owner);
        token.transfer(address(0), amount);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.transferFrom(owner, address(0), amount);
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external supplyCannotIncrease {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, 0));
        expectedAllowance[owner][spender] = 0;
        bytes memory errorData = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.transferFrom(owner, spender, 1);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.burnFrom(owner, 1);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _spendable(address owner, address spender) internal view returns (uint256) {
        uint256 balance = expectedBalance[owner];
        uint256 allowance_ = expectedAllowance[owner][spender];
        return balance < allowance_ ? balance : allowance_;
    }

    function _recordSpending(address owner, address spender, uint256 amount) internal {
        if (expectedAllowance[owner][spender] != type(uint256).max) {
            expectedAllowance[owner][spender] -= amount;
        }
    }
}
