// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {CurbToken} from "../src/CurbToken.sol";

contract CurbTokenTest is Test {
    CurbToken internal token;

    address internal constant FACTORY = address(0xFAC7);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant SPENDER = address(0x5BE7);

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(FACTORY);
        token = new CurbToken();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "curb");
        assertEq(token.symbol(), "CURB");
        assertEq(token.decimals(), 18);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
    }

    function test_wholeSupplyMintedToDeployer() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsMintFromZero() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.prank(ALICE);
        new CurbToken();
    }

    function test_noMintOrAdminEntryPoints() public {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "blacklist(address)",
            "setFee(uint256)",
            "renounceOwnership()"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            vm.prank(FACTORY);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], ALICE, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- transfers

    function test_transferMovesExactAmount() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(FACTORY, ALICE, 1_000 ether);
        vm.prank(FACTORY);
        assertTrue(token.transfer(ALICE, 1_000 ether));
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 1_000 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        token.transfer(BOB, 11 ether);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_transferFromUsesAllowance() public {
        vm.prank(FACTORY);
        vm.expectEmit(true, true, false, true);
        emit Approval(FACTORY, SPENDER, 500 ether);
        token.approve(SPENDER, 500 ether);

        vm.prank(SPENDER);
        assertTrue(token.transferFrom(FACTORY, BOB, 200 ether));
        assertEq(token.balanceOf(BOB), 200 ether);
        assertEq(token.allowance(FACTORY, SPENDER), 300 ether);
    }

    function test_transferFromRevertsBeyondAllowance() public {
        vm.prank(FACTORY);
        token.approve(SPENDER, 5 ether);
        vm.prank(SPENDER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 5 ether, 6 ether)
        );
        token.transferFrom(FACTORY, BOB, 6 ether);
    }

    function test_transferFromWithoutApprovalReverts() public {
        vm.prank(SPENDER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        token.transferFrom(FACTORY, SPENDER, 1);
    }

    function test_infiniteAllowanceIsNotDecreased() public {
        vm.prank(FACTORY);
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(FACTORY, BOB, 1 ether);
        assertEq(token.allowance(FACTORY, SPENDER), type(uint256).max);
    }

    // ---------------------------------------------------------------- burning (curbing supply)

    function test_holderBurnsOwnTokens() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 100 ether);

        vm.expectEmit(true, true, false, true);
        emit Transfer(ALICE, address(0), 40 ether);
        vm.prank(ALICE);
        token.burn(40 ether);

        assertEq(token.balanceOf(ALICE), 60 ether);
        assertEq(token.totalSupply(), SUPPLY - 40 ether);
    }

    function test_burnRevertsBeyondBalance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1 ether, 2 ether));
        token.burn(2 ether);
    }

    function test_burnFromNeedsAllowance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10 ether);

        // The deployer has no power over a holder's balance.
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, FACTORY, 0, 1 ether));
        token.burnFrom(ALICE, 1 ether);
        assertEq(token.balanceOf(ALICE), 10 ether);

        vm.prank(ALICE);
        token.approve(SPENDER, 3 ether);
        vm.prank(SPENDER);
        token.burnFrom(ALICE, 3 ether);
        assertEq(token.balanceOf(ALICE), 7 ether);
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.totalSupply(), SUPPLY - 3 ether);
    }

    // ---------------------------------------------------------------- launch flows

    function test_launchFlowsMoveExactAmounts() public {
        address distributor = address(0xD157);
        address poolManager = address(0x9001);
        uint256 swarm = SUPPLY / 10;
        uint256 pool = SUPPLY / 2;

        vm.startPrank(FACTORY);
        token.transfer(distributor, swarm);
        token.transfer(poolManager, pool);
        token.transfer(BOB, SUPPLY - swarm - pool);
        vm.stopPrank();

        assertEq(token.balanceOf(distributor), swarm);
        assertEq(token.balanceOf(poolManager), pool);
        assertEq(token.balanceOf(BOB), SUPPLY * 4 / 10);

        vm.prank(distributor);
        token.transfer(ALICE, swarm);
        vm.prank(poolManager);
        token.transfer(ALICE, 123 ether);
        assertEq(token.balanceOf(ALICE), swarm + 123 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_runtimeHasNoDelegatecallOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += op - 0x5F;
                continue;
            }
            assertTrue(op != 0xF4 && op != 0xF2 && op != 0xFF);
        }
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(uint256 toAlice, uint256 toBob) public {
        toAlice = bound(toAlice, 0, SUPPLY);
        vm.prank(FACTORY);
        token.transfer(ALICE, toAlice);
        toBob = bound(toBob, 0, toAlice);
        vm.prank(ALICE);
        token.transfer(BOB, toBob);

        assertEq(token.balanceOf(ALICE), toAlice - toBob);
        assertEq(token.balanceOf(BOB), toBob);
        assertEq(token.balanceOf(FACTORY) + token.balanceOf(ALICE) + token.balanceOf(BOB), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_burnOnlyLowersSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(FACTORY);
        token.burn(amount);
        assertEq(token.totalSupply(), SUPPLY - amount);
        assertEq(token.balanceOf(FACTORY), SUPPLY - amount);
    }

    function testFuzz_overspendReverts(uint256 held, uint256 extra) public {
        held = bound(held, 0, SUPPLY - 1);
        extra = bound(extra, 1, SUPPLY - held);
        vm.prank(FACTORY);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        vm.expectRevert();
        token.transfer(BOB, held + extra);
    }
}
