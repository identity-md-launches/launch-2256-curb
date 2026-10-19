// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CurbToken} from "src/CurbToken.sol";

contract CurbDeploymentProbe {
    function deploy() external returns (CurbToken) {
        return new CurbToken();
    }
}

/// @notice Regression tests for boundary values, authorization and transaction rollback.
/// @dev Test actors are local fixtures; no launch addresses or external state are required.
contract CurbTokenEdgeCasesTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    CurbToken internal token;
    address internal alice;
    address internal bob;
    address internal spender;
    address internal stranger;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        alice = makeAddr("edge-alice");
        bob = makeAddr("edge-bob");
        spender = makeAddr("edge-spender");
        stranger = makeAddr("edge-stranger");
        token = new CurbToken();
    }

    function test_contractDeployerReceivesSupplyAndDeploymentsAreIndependent() public {
        CurbDeploymentProbe factory = new CurbDeploymentProbe();
        vm.prank(alice);
        CurbToken first = factory.deploy();
        vm.prank(bob);
        CurbToken second = factory.deploy();

        assertTrue(address(first) != address(second));
        assertEq(first.balanceOf(address(factory)), SUPPLY);
        assertEq(second.balanceOf(address(factory)), SUPPLY);
        assertEq(first.balanceOf(alice), 0);
        assertEq(second.balanceOf(bob), 0);
        assertEq(first.balanceOf(address(this)), 0);
        assertEq(first.totalSupply(), SUPPLY);
        assertEq(second.totalSupply(), SUPPLY);

        vm.prank(address(factory));
        first.burn(1);
        assertEq(first.totalSupply(), SUPPLY - 1);
        assertEq(second.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroTransfersFromEmptyHolderSucceedAndEmitEvents() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_oneWeiAndEntireSupplyCanRoundTrip() public {
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), 1));

        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        vm.prank(alice);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_selfTransferPreservesBalanceButStillChecksFunds() public {
        token.transfer(alice, 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, alice, 1);
        vm.prank(alice);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2));
        vm.prank(alice);
        token.transfer(alice, 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_delegatedSelfTransferConsumesAllowanceWithoutChangingBalances() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(spender, 10);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, alice, 10);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, alice, 10));
        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_holderNeedsSelfApprovalForDelegatedEntryPoints() public {
        token.transfer(alice, 10);
        bytes memory errorData = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, alice, 0, 1);
        vm.expectRevert(errorData);
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        vm.expectRevert(errorData);
        vm.prank(alice);
        token.burnFrom(alice, 1);

        vm.prank(alice);
        token.approve(alice, 10);
        vm.prank(alice);
        assertTrue(token.transferFrom(alice, bob, 4));
        vm.prank(alice);
        token.burnFrom(alice, 6);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 4);
        assertEq(token.allowance(alice, alice), 0);
        assertEq(token.totalSupply(), SUPPLY - 6);
    }

    function test_approvalReplacementAndRevocationEmitExactValues() public {
        vm.startPrank(alice);
        token.approve(spender, type(uint256).max);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, spender, 1);
        assertTrue(token.approve(spender, 1));
        assertEq(token.allowance(alice, spender), 1);
        assertTrue(token.approve(spender, 1));
        assertEq(token.allowance(alice, spender), 1);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(alice, spender, 0);
        assertTrue(token.approve(spender, 0));
        vm.stopPrank();

        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_approvalCannotBeUsedByAnotherSpenderOrForAnotherOwner() public {
        token.transfer(alice, 10);
        token.transfer(bob, 10);
        vm.prank(alice);
        token.approve(spender, 10);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, stranger, 0, 1));
        vm.prank(stranger);
        token.transferFrom(alice, stranger, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.burnFrom(bob, 1);

        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(bob), 10);
        assertEq(token.balanceOf(stranger), 0);
        assertEq(token.allowance(alice, spender), 10);
        assertEq(token.allowance(bob, spender), 0);
        assertEq(token.allowance(alice, stranger), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_revokingInfiniteApprovalStopsTransfersAndBurns() public {
        token.transfer(alice, 10);
        vm.startPrank(alice);
        token.approve(spender, type(uint256).max);
        token.approve(spender, 0);
        vm.stopPrank();

        bytes memory errorData = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.burnFrom(alice, 1);

        assertEq(token.balanceOf(alice), 10);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_maximumFiniteAllowanceIsSpentByBothTransferAndBurn() public {
        token.approve(spender, type(uint256).max - 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), bob, 1));
        assertEq(token.allowance(address(this), spender), type(uint256).max - 2);
        vm.prank(spender);
        token.burnFrom(address(this), 1);
        assertEq(token.allowance(address(this), spender), type(uint256).max - 3);
        assertEq(token.balanceOf(bob), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 2);
        assertEq(token.totalSupply(), SUPPLY - 1);
    }

    function test_infiniteAllowanceSurvivesTransfersBurnsAndZeroAmounts() public {
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        assertTrue(token.transferFrom(address(this), bob, 1));
        token.burnFrom(address(this), 1);
        assertTrue(token.transferFrom(address(this), bob, 0));
        token.burnFrom(address(this), 0);
        vm.stopPrank();

        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(bob), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 2);
        assertEq(token.totalSupply(), SUPPLY - 1);
    }

    function test_transferAndBurnShareOneAllowanceBudget() public {
        token.transfer(alice, 100);
        vm.prank(alice);
        token.approve(spender, 10);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 4));
        assertEq(token.allowance(alice, spender), 6);

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 6);
        vm.prank(spender);
        token.burnFrom(alice, 6);

        bytes memory errorData = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.transferFrom(alice, bob, 1);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.burnFrom(alice, 1);
        assertEq(token.balanceOf(alice), 90);
        assertEq(token.balanceOf(bob), 4);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY - 6);
    }

    function test_failedDelegatedCallsRestoreFiniteAllowance() public {
        _checkDelegatedBalanceFailure(10);
    }

    function test_failedDelegatedCallsPreserveInfiniteAllowance() public {
        _checkDelegatedBalanceFailure(type(uint256).max);
    }

    function test_zeroRecipientRevertsEvenForZeroAmount() public {
        for (uint256 amount; amount <= 1; ++amount) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            token.transfer(address(0), amount);
        }
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_invalidDelegatedRecipientRestoresSpentAllowance() public {
        token.approve(spender, 10);
        for (uint256 amount; amount <= 1; ++amount) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(spender);
            token.transferFrom(address(this), address(0), amount);
            assertEq(token.allowance(address(this), spender), 10);
        }
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroSpenderCannotBeApprovedEvenForZeroAmount() public {
        uint256[3] memory amounts = [uint256(0), uint256(1), type(uint256).max];
        for (uint256 i; i < amounts.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
            token.approve(address(0), amounts[i]);
        }
        assertEq(token.allowance(address(this), address(0)), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroSourceCannotBeTransferredOrBurnedEvenForZeroAmount() public {
        // Both functions must reject the zero source; error ordering is not part of this property.
        vm.expectRevert();
        vm.prank(spender);
        token.transferFrom(address(0), bob, 0);
        vm.expectRevert();
        vm.prank(spender);
        token.burnFrom(address(0), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroBurnsFromEmptyHolderEmitEventsWithoutChangingSupply() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 0);
        vm.prank(alice);
        token.burn(0);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, address(0), 0);
        vm.prank(spender);
        token.burnFrom(alice, 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_entireSupplyCanBeBurnedOnlyOnce() public {
        token.burn(SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.burn(1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), 0, 1));
        token.transfer(alice, 1);
        token.burn(0);
        assertTrue(token.transfer(alice, 0));
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_entireSupplyCanBeBurnedThroughExactApproval() public {
        token.approve(spender, SUPPLY);
        vm.prank(spender);
        token.burnFrom(address(this), SUPPLY);
        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.allowance(address(this), spender), 0);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.burnFrom(address(this), 1);
        assertEq(token.totalSupply(), 0);
    }

    function test_maximumAmountsRevertWithoutOverflowOrStateChanges() public {
        uint256 amount = type(uint256).max;
        bytes memory errorData =
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, amount);
        vm.expectRevert(errorData);
        token.transfer(alice, amount);
        vm.expectRevert(errorData);
        token.burn(amount);
        token.approve(spender, amount);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.transferFrom(address(this), alice, amount);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.burnFrom(address(this), amount);

        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.allowance(address(this), spender), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_holderBurnDoesNotConsumeApprovalAndRefillingAllowsLaterSpend() public {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.approve(spender, 10);
        vm.prank(alice);
        token.burn(10);
        assertEq(token.allowance(alice, spender), 10);
        assertEq(token.totalSupply(), SUPPLY - 10);

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10));
        vm.prank(spender);
        token.transferFrom(alice, bob, 10);
        assertEq(token.allowance(alice, spender), 10);

        token.transfer(alice, 10);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 10));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 10);
        assertEq(token.allowance(alice, spender), 0);
        assertEq(token.totalSupply(), SUPPLY - 10);
    }

    function _checkDelegatedBalanceFailure(uint256 allowance_) internal {
        token.transfer(alice, 1);
        vm.prank(alice);
        token.approve(spender, allowance_);
        bytes memory errorData = abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1, 2);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.transferFrom(alice, bob, 2);
        assertEq(token.allowance(alice, spender), allowance_);
        vm.expectRevert(errorData);
        vm.prank(spender);
        token.burnFrom(alice, 2);
        assertEq(token.allowance(alice, spender), allowance_);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }
}
