// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {CurbToken} from "src/CurbToken.sol";
import {CurbTokenHandler} from "./handlers/CurbTokenHandler.sol";

/// @notice Conservation and authorization must survive arbitrary interleavings of transfers,
/// approvals, revocations, burns, delegated spending, and rejected calls.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract CurbTokenInvariantTest is StdInvariant, Test {
    uint256 internal constant SUPPLY = 1_000_000_000 ether;
    CurbToken internal token;
    CurbTokenHandler internal handler;
    address[5] internal actors;

    function setUp() public {
        token = new CurbToken();
        actors = [
            address(this),
            makeAddr("invariant-alice"),
            makeAddr("invariant-bob"),
            makeAddr("invariant-carol"),
            makeAddr("invariant-dave")
        ];
        for (uint256 i = 1; i < actors.length; ++i) {
            assertTrue(token.transfer(actors[i], SUPPLY / actors.length));
        }
        handler = new CurbTokenHandler(token, actors);

        // Seed a ring of finite approvals and one infinite approval, so delegated calls can
        // move real value immediately. Later random approvals/revocations replace these grants.
        for (uint256 i; i < actors.length; ++i) {
            handler.approve(i, (i + 1) % actors.length, SUPPLY / 10 + 2);
        }
        handler.approve(0, 2, 1);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.burn.selector;
        selectors[4] = handler.burnFrom.selector;
        selectors[5] = handler.rejectOverdraw.selector;
        selectors[6] = handler.rejectUnapprovedSpend.selector;
        selectors[7] = handler.rejectZeroRecipient.selector;
        selectors[8] = handler.revoke.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balancesSumToLiveSupplyAndBurnsExplainEveryMissingToken() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply(), "balances do not sum to live supply");
        assertEq(token.totalSupply() + handler.totalBurned(), SUPPLY, "unaccounted mint or burn");
        assertEq(token.balanceOf(address(0)), 0, "burns credited the zero address");
        assertEq(token.balanceOf(address(handler)), 0, "handler received unrequested tokens");
        assertEq(token.balanceOf(address(token)), 0, "token collected an unrequested fee");
        assertEq(token.balanceOf(handler.outsider()), 0, "outsider took holder funds");
    }

    function invariant_eachHolderOwnsExactlyTheTokensTheyReceivedLessSpendingAndBurns() public view {
        for (uint256 i; i < actors.length; ++i) {
            assertEq(token.balanceOf(actors[i]), handler.expectedBalance(actors[i]), "holder accounting mismatch");
        }
    }

    function invariant_allowancesMatchAuthorizationsAndSpending() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.expectedAllowance(actors[i], actors[j]),
                    "allowance changed without authorization or spending"
                );
            }
            assertEq(token.allowance(actors[i], handler.outsider()), 0, "outsider obtained approval");
        }
    }

    function test_handlerExercisesSuccessfulAndRejectedActionsWithValue() public {
        // A deterministic smoke sequence supplements the random campaign and checks the harness
        // can reach nonzero transfers and both burn paths without discarding unexpected reverts.
        handler.transfer(0, 1, 100);
        handler.approve(1, 2, 102);
        handler.transferFrom(1, 2, 3, 40);
        handler.burnFrom(1, 2, 30);
        handler.burn(3, 10);
        handler.transferFrom(0, 2, 0, 1); // Infinite allowance, self-transfer.
        handler.rejectOverdraw(1, 2, type(uint256).max);
        handler.rejectUnapprovedSpend(1, 2, 1);
        handler.rejectZeroRecipient(1, 2, 1);
        handler.revoke(1, 2);

        assertEq(handler.totalBurned(), 40);
        assertEq(token.allowance(actors[0], actors[2]), type(uint256).max);
        assertEq(token.allowance(actors[1], actors[2]), 0);
        assertEq(token.balanceOf(actors[1]), SUPPLY / 5 + 30);
        assertEq(token.balanceOf(actors[3]), SUPPLY / 5 + 30);
        invariant_balancesSumToLiveSupplyAndBurnsExplainEveryMissingToken();
        invariant_eachHolderOwnsExactlyTheTokensTheyReceivedLessSpendingAndBurns();
        invariant_allowancesMatchAuthorizationsAndSpending();
    }
}
