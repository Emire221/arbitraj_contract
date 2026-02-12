// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {
    ArbitrajBotu,
    Unauthorized,
    OnlyPool,
    InvalidInitiator,
    ContractPaused,
    InvalidFeeTier,
    ZeroAmount,
    ZeroAddress
} from "../src/Arbitraj.sol";
import {IERC20} from "aave-v3-core/contracts/dependencies/openzeppelin/contracts/IERC20.sol";

/// @title ArbitrajBotuTest — Comprehensive test suite
/// @notice Run with: forge test --fork-url <MAINNET_RPC> -vvv
contract ArbitrajBotuTest is Test {

    // ── Constants (Ethereum Mainnet) ───────────────
    address constant USDC          = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant WETH          = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant DAI           = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant AAVE_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant SWAP_ROUTER   = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // ── State ──────────────────────────────────────
    ArbitrajBotu public bot;
    address public deployer;
    address public attacker;

    // ── Events (mirrored for expectEmit) ───────────
    event ArbitrageExecuted(
        address indexed asset,
        uint256 amount,
        uint256 profit,
        address indexed targetToken,
        uint24 fee1,
        uint24 fee2,
        uint256 timestamp
    );
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);
    event PauseToggled(bool isPaused, address indexed by);
    event MinProfitBpsUpdated(uint256 oldBps, uint256 newBps);
    event EmergencyTokenWithdraw(address indexed token, uint256 amount, address indexed to);
    event EmergencyETHWithdraw(uint256 amount, address indexed to);

    // ──────────────────────────────────────────────
    //                    SETUP
    // ──────────────────────────────────────────────

    function setUp() public {
        deployer = address(this);
        attacker = makeAddr("attacker");

        // Deploy with minProfitBps = 0 (testnet mode)
        bot = new ArbitrajBotu(AAVE_PROVIDER, SWAP_ROUTER, 0);
    }

    /// @dev Allow this test contract to receive ETH (for emergencyWithdrawEth)
    receive() external payable {}

    // ══════════════════════════════════════════════
    //    CORE FLOW — DIRECT executeOperation TEST
    // ══════════════════════════════════════════════
    //
    //  We simulate the flash-loan callback directly:
    //  fund the bot with `amount` of the asset (as Aave would),
    //  plus extra to cover swap-fee losses, then call
    //  executeOperation from the POOL address.
    //  This is fork-agnostic: it tests the dual-swap + profit
    //  logic regardless of Aave Pool reserve state.

    function test_executeOperation_SwapFlow() public {
        address pool = address(bot.POOL());
        uint256 amount  = 1_000 * 1e6;  // 1 000 USDC
        uint256 premium = amount * 5 / 10_000; // 0.05 % Aave fee

        // Fund bot as if Aave transferred flash loan + extra for losses
        deal(USDC, address(bot), amount + 500 * 1e6);

        bytes memory params = abi.encode(
            WETH,             // targetToken
            uint24(500),      // fee1: 0.05 %
            uint24(3000),     // fee2: 0.30 %
            uint256(0),       // minAmountIntermediate
            uint256(0)        // minAmountFinal
        );

        uint256 ownerBefore = IERC20(USDC).balanceOf(deployer);

        vm.prank(pool);
        bool ok = bot.executeOperation(USDC, amount, premium, address(bot), params);
        assertTrue(ok, "executeOperation must return true");

        uint256 ownerAfter = IERC20(USDC).balanceOf(deployer);
        console.log("Owner balance change:", ownerAfter - ownerBefore);
        console.log("Bot residual USDC:  ", IERC20(USDC).balanceOf(address(bot)));
    }

    function test_executeOperation_EmitsArbitrageEvent() public {
        address pool = address(bot.POOL());
        uint256 amount  = 500 * 1e6;
        uint256 premium = amount * 5 / 10_000;

        deal(USDC, address(bot), amount + 500 * 1e6);

        bytes memory params = abi.encode(WETH, uint24(500), uint24(3000), uint256(0), uint256(0));

        // Expect the ArbitrageExecuted event (check indexed fields only)
        vm.expectEmit(true, true, false, false);
        emit ArbitrageExecuted(USDC, amount, 0, WETH, 500, 3000, 0);

        vm.prank(pool);
        bot.executeOperation(USDC, amount, premium, address(bot), params);
    }

    // ══════════════════════════════════════════════
    //      ENTRY POINT — ACCESS CONTROL TESTS
    // ══════════════════════════════════════════════

    function test_executeArbitrage_RevertsIf_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        bot.executeArbitrage(USDC, 1e6, WETH, 500, 3000, 0, 0);
    }

    function test_executeArbitrage_RevertsIf_Paused() public {
        bot.togglePause();

        vm.expectRevert(ContractPaused.selector);
        bot.executeArbitrage(USDC, 1e6, WETH, 500, 3000, 0, 0);
    }

    function test_executeArbitrage_RevertsIf_ZeroAmount() public {
        vm.expectRevert(ZeroAmount.selector);
        bot.executeArbitrage(USDC, 0, WETH, 500, 3000, 0, 0);
    }

    function test_executeArbitrage_RevertsIf_ZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        bot.executeArbitrage(address(0), 1e6, WETH, 500, 3000, 0, 0);
    }

    function test_executeArbitrage_RevertsIf_InvalidFee() public {
        vm.expectRevert(InvalidFeeTier.selector);
        bot.executeArbitrage(USDC, 1e6, WETH, 0, 3000, 0, 0);
    }

    // ══════════════════════════════════════════════
    //       EXECUTE OPERATION — SECURITY
    // ══════════════════════════════════════════════

    function test_executeOperation_RevertsIf_CallerIsNotPool() public {
        vm.prank(attacker);
        vm.expectRevert(OnlyPool.selector);
        bot.executeOperation(USDC, 1e6, 0, address(bot), "");
    }

    function test_executeOperation_RevertsIf_WrongInitiator() public {
        address pool = address(bot.POOL());
        bytes memory params = abi.encode(WETH, uint24(500), uint24(3000), uint256(0), uint256(0));

        vm.prank(pool);
        vm.expectRevert(InvalidInitiator.selector);
        bot.executeOperation(USDC, 1e6, 0, attacker, params);
    }

    // ══════════════════════════════════════════════
    //             MIN PROFIT TESTS
    // ══════════════════════════════════════════════

    function test_setMinProfitBps() public {
        assertEq(bot.minProfitBps(), 0);

        vm.expectEmit(true, true, true, true);
        emit MinProfitBpsUpdated(0, 50);

        bot.setMinProfitBps(50); // 0.50 %
        assertEq(bot.minProfitBps(), 50);
    }

    function test_setMinProfitBps_RevertsIf_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        bot.setMinProfitBps(10);
    }

    function test_minProfit_RevertsIf_BelowThreshold() public {
        // Set impossibly high min profit
        bot.setMinProfitBps(5000); // 50 %

        address pool = address(bot.POOL());
        uint256 amount  = 1_000 * 1e6;
        uint256 premium = amount * 5 / 10_000;

        deal(USDC, address(bot), amount + 500 * 1e6);
        bytes memory params = abi.encode(WETH, uint24(500), uint24(3000), uint256(0), uint256(0));

        vm.prank(pool);
        vm.expectRevert(); // InsufficientProfit
        bot.executeOperation(USDC, amount, premium, address(bot), params);
    }

    // ══════════════════════════════════════════════
    //               PAUSE TESTS
    // ══════════════════════════════════════════════

    function test_togglePause() public {
        assertFalse(bot.paused());

        vm.expectEmit(true, true, true, true);
        emit PauseToggled(true, deployer);
        bot.togglePause();
        assertTrue(bot.paused());

        vm.expectEmit(true, true, true, true);
        emit PauseToggled(false, deployer);
        bot.togglePause();
        assertFalse(bot.paused());
    }

    function test_togglePause_RevertsIf_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        bot.togglePause();
    }

    // ══════════════════════════════════════════════
    //          OWNERSHIP TRANSFER TESTS
    // ══════════════════════════════════════════════

    function test_transferOwnership_TwoStep() public {
        address newOwner = makeAddr("newOwner");

        // Step 1: nominate
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferStarted(deployer, newOwner);
        bot.transferOwnership(newOwner);

        assertEq(bot.pendingOwner(), newOwner);
        assertEq(bot.owner(), deployer); // not changed yet

        // Step 2: accept
        vm.prank(newOwner);
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(deployer, newOwner);
        bot.acceptOwnership();

        assertEq(bot.owner(), newOwner);
        assertEq(bot.pendingOwner(), address(0));
    }

    function test_transferOwnership_RevertsIf_ZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        bot.transferOwnership(address(0));
    }

    function test_acceptOwnership_RevertsIf_NotPending() public {
        bot.transferOwnership(makeAddr("newOwner"));

        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        bot.acceptOwnership();
    }

    // ══════════════════════════════════════════════
    //          EMERGENCY WITHDRAW TESTS
    // ══════════════════════════════════════════════

    function test_emergencyWithdrawToken_FullBalance() public {
        deal(USDC, address(bot), 500 * 1e6);

        vm.expectEmit(true, true, true, true);
        emit EmergencyTokenWithdraw(USDC, 500 * 1e6, deployer);
        bot.emergencyWithdrawToken(USDC, 0); // 0 = full balance

        assertEq(IERC20(USDC).balanceOf(address(bot)), 0);
    }

    function test_emergencyWithdrawToken_PartialAmount() public {
        deal(USDC, address(bot), 500 * 1e6);
        bot.emergencyWithdrawToken(USDC, 200 * 1e6);

        assertEq(IERC20(USDC).balanceOf(address(bot)), 300 * 1e6);
    }

    function test_emergencyWithdrawToken_RevertsIf_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        bot.emergencyWithdrawToken(USDC, 0);
    }

    function test_emergencyWithdrawToken_RevertsIf_ZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        bot.emergencyWithdrawToken(address(0), 0);
    }

    function test_emergencyWithdrawEth() public {
        // Reset bot ETH to 0 first (fork may have residual balance)
        vm.deal(address(bot), 0);
        // Then set exactly 1 ETH
        vm.deal(address(bot), 1 ether);

        uint256 ownerBefore = deployer.balance;

        vm.expectEmit(true, true, true, true);
        emit EmergencyETHWithdraw(1 ether, deployer);
        bot.emergencyWithdrawEth();

        assertEq(address(bot).balance, 0, "Bot should have 0 ETH");
        assertEq(deployer.balance, ownerBefore + 1 ether, "Owner should receive 1 ETH");
    }

    function test_emergencyWithdrawEth_RevertsIf_ZeroBalance() public {
        // Ensure bot has 0 ETH
        vm.deal(address(bot), 0);

        vm.expectRevert(ZeroAmount.selector);
        bot.emergencyWithdrawEth();
    }

    // ══════════════════════════════════════════════
    //               VIEW HELPERS
    // ══════════════════════════════════════════════

    function test_getBalance() public {
        deal(USDC, address(bot), 1234 * 1e6);
        assertEq(bot.getBalance(USDC), 1234 * 1e6);
    }

    // ══════════════════════════════════════════════
    //           CONSTRUCTOR VALIDATION
    // ══════════════════════════════════════════════

    function test_constructor_SetsState() public view {
        assertEq(bot.owner(), deployer);
        assertEq(address(bot.SWAP_ROUTER()), SWAP_ROUTER);
        assertEq(bot.minProfitBps(), 0);
        assertFalse(bot.paused());
    }

    function test_constructor_RevertsIf_ZeroRouter() public {
        vm.expectRevert(ZeroAddress.selector);
        new ArbitrajBotu(AAVE_PROVIDER, address(0), 0);
    }

    // ══════════════════════════════════════════════
    //              RECEIVE ETH TEST
    // ══════════════════════════════════════════════

    function test_receiveETH() public {
        // Reset and check delta
        vm.deal(address(bot), 0);
        uint256 before = address(bot).balance;

        vm.deal(deployer, 1 ether);
        (bool ok, ) = address(bot).call{value: 0.5 ether}("");
        assertTrue(ok, "ETH transfer should succeed");
        assertEq(address(bot).balance - before, 0.5 ether, "Bot should gain 0.5 ETH");
    }
}