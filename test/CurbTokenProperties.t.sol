// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CurbToken} from "src/CurbToken.sol";

/// forge-config: default.fuzz.runs = 1000
contract CurbTokenPropertiesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    CurbToken internal token;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        token = new CurbToken();
        alice = makeAddr("property-alice");
        bob = makeAddr("property-bob");
        spender = makeAddr("property-spender");
    }

    function testFuzz_transferRoundTripRestoresBalancesAndPreservesApproval(
        uint256 initialAlice,
        uint256 amount,
        uint256 allowance_
    ) public {
        initialAlice = bound(initialAlice, 0, SUPPLY);
        token.transfer(alice, initialAlice);
        token.transfer(bob, SUPPLY - initialAlice);
        vm.prank(alice);
        token.approve(spender, allowance_);
        amount = bound(amount, 0, initialAlice);

        vm.prank(alice);
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(alice), initialAlice - amount);
        assertEq(token.balanceOf(bob), SUPPLY - initialAlice + amount);
        vm.prank(bob);
        assertTrue(token.transfer(alice, amount));

        assertEq(token.balanceOf(alice), initialAlice);
        assertEq(token.balanceOf(bob), SUPPLY - initialAlice);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.allowance(alice, spender), allowance_);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_approvalOverwritesRatherThanAddsAndIsIsolated(uint256 first, uint256 second) public {
        token.approve(spender, first);
        vm.prank(alice);
        assertTrue(token.approve(spender, first));
        vm.prank(alice);
        assertTrue(token.approve(bob, first));
        vm.prank(alice);
        assertTrue(token.approve(spender, second));

        assertEq(token.allowance(alice, spender), second);
        assertEq(token.allowance(alice, bob), first);
        assertEq(token.allowance(address(this), spender), first);
        assertEq(token.allowance(spender, alice), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferAndBurnCannotExceedTheirSharedAllowance(
        uint256 held,
        uint256 allowed,
        uint256 transferred
    ) public {
        held = bound(held, 1, SUPPLY);
        allowed = bound(allowed, 0, held - 1);
        transferred = bound(transferred, 0, allowed);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, allowed);

        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, transferred));
        assertEq(token.allowance(alice, spender), allowed - transferred);
        vm.prank(spender);
        token.burnFrom(alice, allowed - transferred);

        // At least one token remains: these failures must be due to authorization, not balance.
        bytes memory errorData = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.burnFrom(alice, 1);

        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), held - allowed);
        assertEq(token.balanceOf(bob), transferred);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY - (allowed - transferred));
    }

    function testFuzz_insufficientAllowancePreservesAllState(uint256 held, uint256 allowed, uint256 amount) public {
        held = bound(held, 1, SUPPLY);
        allowed = bound(allowed, 0, held - 1);
        amount = bound(amount, allowed + 1, held);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, allowed);

        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), allowed);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.burnFrom(alice, amount);

        assertEq(token.allowance(alice, spender), allowed);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_insufficientBalanceRollsBackDelegatedAllowance(uint256 held, uint256 amount) public {
        held = bound(held, 0, SUPPLY);
        amount = bound(amount, held + 1, type(uint256).max);
        token.transfer(alice, held);
        vm.prank(alice);
        token.approve(spender, amount);

        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, held, amount);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.transferFrom(alice, bob, amount);
        assertEq(token.allowance(alice, spender), amount);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.burnFrom(alice, amount);

        assertEq(token.allowance(alice, spender), amount);
        assertEq(token.balanceOf(alice), held);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY - held);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitBurnEqualsSingleBurn(uint256 totalBurned, uint256 ownBurn) public {
        totalBurned = bound(totalBurned, 0, SUPPLY);
        ownBurn = bound(ownBurn, 0, totalBurned);
        CurbToken singleBurn = new CurbToken();
        singleBurn.burn(totalBurned);

        token.burn(ownBurn);
        token.approve(spender, totalBurned - ownBurn);
        vm.prank(spender);
        token.burnFrom(address(this), totalBurned - ownBurn);

        assertEq(token.totalSupply(), singleBurn.totalSupply());
        assertEq(token.balanceOf(address(this)), singleBurn.balanceOf(address(this)));
        assertEq(token.totalSupply(), SUPPLY - totalBurned);
        assertEq(token.balanceOf(address(this)), SUPPLY - totalBurned);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(this), spender), 0);
    }

    function testFuzz_delegatedTransfersHandleAliasedParticipants(
        uint8 ownerSeed,
        uint8 spenderSeed,
        uint8 recipientSeed,
        uint256 amount,
        bool infinite
    ) public {
        address[3] memory actors = [address(this), alice, bob];
        // Three is not a divisor of the supply: keep the remainder with the deployer.
        token.transfer(alice, SUPPLY / 3);
        token.transfer(bob, SUPPLY / 3);
        address owner = actors[ownerSeed % 3];
        address caller = actors[spenderSeed % 3];
        address recipient = actors[recipientSeed % 3];
        uint256 ownerBefore = token.balanceOf(owner);
        uint256 recipientBefore = token.balanceOf(recipient);
        amount = bound(amount, 0, ownerBefore);
        uint256 approved = infinite ? type(uint256).max : amount;
        vm.prank(owner);
        token.approve(caller, approved);
        vm.prank(caller);
        assertTrue(token.transferFrom(owner, recipient, amount));

        assertEq(token.balanceOf(owner), owner == recipient ? ownerBefore : ownerBefore - amount);
        assertEq(token.balanceOf(recipient), owner == recipient ? recipientBefore : recipientBefore + amount);
        assertEq(token.allowance(owner, caller), infinite ? type(uint256).max : 0);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(alice) + token.balanceOf(bob), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
