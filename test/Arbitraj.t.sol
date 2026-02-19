// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {
    ArbitrajBotu,
    IERC20,
    Unauthorized,
    InvalidCaller,
    ContractPaused,
    ReentrancyGuard,
    InsufficientProfit,
    ZeroAmount,
    ZeroAddress,
    TransferFailed,
    SlippageNotSet
} from "../src/Arbitraj.sol";

// ══════════════════════════════════════════════════════════════
//                       MOCK CONTRACTS
// ══════════════════════════════════════════════════════════════

/// @dev Minimal ERC20 mock with mint capability
contract MockERC20 {
    string public name;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, uint8 _decimals) {
        name = _name;
        decimals = _decimals;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "MockERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

/// @dev Simulates Uniswap V3 pool flash swap behavior.
///      Configurable deltas: positive = owed by caller, negative = sent to caller.
contract MockUniswapV3Pool {
    address public token0;
    address public token1;
    uint24 public fee;

    int256 public mockAmount0Delta;
    int256 public mockAmount1Delta;

    constructor(address _t0, address _t1, uint24 _fee) {
        token0 = _t0;
        token1 = _t1;
        fee = _fee;
    }

    function setMockDeltas(int256 _a0, int256 _a1) external {
        mockAmount0Delta = _a0;
        mockAmount1Delta = _a1;
    }

    function swap(
        address recipient,
        bool,
        int256,
        uint160,
        bytes calldata data
    ) external returns (int256, int256) {
        // Transfer output tokens first (flash swap behavior)
        if (mockAmount0Delta < 0) {
            MockERC20(token0).transfer(recipient, uint256(-mockAmount0Delta));
        }
        if (mockAmount1Delta < 0) {
            MockERC20(token1).transfer(recipient, uint256(-mockAmount1Delta));
        }

        // Call uniswapV3SwapCallback on the recipient
        (bool ok, bytes memory ret) = recipient.call(
            abi.encodeWithSignature(
                "uniswapV3SwapCallback(int256,int256,bytes)",
                mockAmount0Delta,
                mockAmount1Delta,
                data
            )
        );
        if (!ok) {
            // Bubble up revert reason
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }

        return (mockAmount0Delta, mockAmount1Delta);
    }
}

/// @dev Simulates Aerodrome V2-style AMM pool.
///      Configurable amountOut via setMockAmountOut.
contract MockAerodromePool {
    address public token0;
    address public token1;
    uint256 public mockAmountOut;

    constructor(address _t0, address _t1) {
        token0 = _t0;
        token1 = _t1;
    }

    function setMockAmountOut(uint256 _out) external {
        mockAmountOut = _out;
    }

    function getAmountOut(uint256, address) external view returns (uint256) {
        return mockAmountOut;
    }

    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata
    ) external {
        if (amount0Out > 0) MockERC20(token0).transfer(to, amount0Out);
        if (amount1Out > 0) MockERC20(token1).transfer(to, amount1Out);
    }
}

// ══════════════════════════════════════════════════════════════
//                       TEST CONTRACT
// ══════════════════════════════════════════════════════════════

/// @title ArbitrajBotuTest — Comprehensive unit test suite
/// @notice Run with: forge test -vvv
contract ArbitrajBotuTest is Test {

    // ── Mock Infrastructure ────────────────────────
    MockERC20 public tokenA;          // e.g. USDC (token0)
    MockERC20 public tokenB;          // e.g. WETH (token1)
    MockUniswapV3Pool public uniPool;
    MockAerodromePool public aeroPool;

    // ── Contract Under Test ────────────────────────
    ArbitrajBotu public bot;
    address public deployer;
    address public attacker;

    // ── Events (mirrored for expectEmit) ───────────
    event ArbitrageExecuted(
        address indexed uniPool,
        address indexed aeroPool,
        uint256 amountBorrowed,
        uint256 profit,
        uint256 timestamp
    );
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);
    event PauseToggled(bool isPaused, address indexed by);
    event MinProfitBpsUpdated(uint256 oldBps, uint256 newBps);
    event EnforceSlippageToggled(bool enforced, address indexed by);
    event EmergencyTokenWithdraw(address indexed token, uint256 amount, address indexed to);
    event EmergencyETHWithdraw(uint256 amount, address indexed to);

    // ──────────────────────────────────────────────
    //                    SETUP
    // ──────────────────────────────────────────────

    function setUp() public {
        deployer = address(this);
        attacker = makeAddr("attacker");

        // Deploy mock tokens
        tokenA = new MockERC20("TokenA", 6);   // USDC-like
        tokenB = new MockERC20("TokenB", 18);  // WETH-like

        // Deploy mock pools
        uniPool = new MockUniswapV3Pool(address(tokenA), address(tokenB), 3000);
        aeroPool = new MockAerodromePool(address(tokenA), address(tokenB));

        // Deploy bot with minProfitBps = 0 (test mode)
        bot = new ArbitrajBotu(0);
    }

    /// @dev Allow this test contract to receive ETH
    receive() external payable {}

    // ══════════════════════════════════════════════
    //     CORE FLOW — SUCCESSFUL ARBITRAGE
    // ══════════════════════════════════════════════
    //
    //  Scenario: Flash swap on Uni V3, sell on Aerodrome for profit.
    //
    //  1. Uni V3: owe 1000 tokenA, receive 1 tokenB
    //  2. Aerodrome: sell 1 tokenB → get 1050 tokenA
    //  3. Pay 1000 tokenA to Uni V3
    //  4. Profit: 50 tokenA → owner

    function test_executeArbitrage_Success() public {
        uint256 amountOwed = 1000e6;        // Owe 1000 tokenA to Uni V3
        uint256 amountReceived = 1e18;      // Receive 1 tokenB from Uni V3
        uint256 aeroOutput = 1050e6;        // Aerodrome gives 1050 tokenA

        // Configure mocks
        // amount0Delta > 0 → owe tokenA (token0)
        // amount1Delta < 0 → receive tokenB (token1)
        uniPool.setMockDeltas(int256(amountOwed), -int256(amountReceived));
        tokenB.mint(address(uniPool), amountReceived);   // Fund Uni V3 with output
        aeroPool.setMockAmountOut(aeroOutput);
        tokenA.mint(address(aeroPool), aeroOutput);       // Fund Aerodrome with output

        uint256 ownerBefore = tokenA.balanceOf(deployer);

        bot.executeArbitrage(
            address(uniPool),
            address(aeroPool),
            true,                   // zeroForOne
            int256(amountReceived), // amountSpecified (ignored by mock)
            0,                      // sqrtPriceLimitX96
            0                       // minProfit
        );

        uint256 profit = tokenA.balanceOf(deployer) - ownerBefore;
        assertEq(profit, 50e6, "Profit should be 50 tokenA");
        assertEq(tokenA.balanceOf(address(bot)), 0, "Bot should hold 0 tokenA");

        console.log("Profit:", profit);
    }

    function test_executeArbitrage_EmitsEvent() public {
        uint256 amountOwed = 1000e6;
        uint256 amountReceived = 1e18;
        uint256 aeroOutput = 1050e6;

        uniPool.setMockDeltas(int256(amountOwed), -int256(amountReceived));
        tokenB.mint(address(uniPool), amountReceived);
        aeroPool.setMockAmountOut(aeroOutput);
        tokenA.mint(address(aeroPool), aeroOutput);

        vm.expectEmit(true, true, false, false);
        emit ArbitrageExecuted(address(uniPool), address(aeroPool), 0, 0, 0);

        bot.executeArbitrage(
            address(uniPool), address(aeroPool), true, int256(amountReceived), 0, 0
        );
    }

    function test_executeArbitrage_ReverseDirection() public {
        // zeroForOne = false: owe tokenB (token1), receive tokenA (token0)
        uint256 amountOwed = 1e18;          // Owe 1 tokenB
        uint256 amountReceived = 1000e6;    // Receive 1000 tokenA

        // amount0Delta < 0 → receive tokenA, amount1Delta > 0 → owe tokenB
        uniPool.setMockDeltas(-int256(amountReceived), int256(amountOwed));
        tokenA.mint(address(uniPool), amountReceived);

        // Aerodrome: sell 1000 tokenA → get 1.05 tokenB
        uint256 aeroOutput = 1.05e18;
        aeroPool.setMockAmountOut(aeroOutput);
        tokenB.mint(address(aeroPool), aeroOutput);

        uint256 ownerBefore = tokenB.balanceOf(deployer);

        bot.executeArbitrage(
            address(uniPool), address(aeroPool), false, -int256(amountReceived), 0, 0
        );

        uint256 profit = tokenB.balanceOf(deployer) - ownerBefore;
        assertEq(profit, 0.05e18, "Profit should be 0.05 tokenB");
    }

    function test_executeArbitrage_ExactBreakeven() public {
        // Aerodrome output == amountOwed → profit = 0, should pass with minProfit=0
        uint256 amountOwed = 1000e6;
        uint256 amountReceived = 1e18;
        uint256 aeroOutput = 1000e6;

        uniPool.setMockDeltas(int256(amountOwed), -int256(amountReceived));
        tokenB.mint(address(uniPool), amountReceived);
        aeroPool.setMockAmountOut(aeroOutput);
        tokenA.mint(address(aeroPool), aeroOutput);

        uint256 ownerBefore = tokenA.balanceOf(deployer);

        bot.executeArbitrage(
            address(uniPool), address(aeroPool), true, int256(amountReceived), 0, 0
        );

        uint256 profit = tokenA.balanceOf(deployer) - ownerBefore;
        assertEq(profit, 0, "Breakeven: no profit");
    }

    // ══════════════════════════════════════════════
    //         PROFIT VALIDATION TESTS
    // ══════════════════════════════════════════════

    function test_executeArbitrage_RevertsIf_InsufficientOutput() public {
        uint256 amountOwed = 1000e6;
        uint256 amountReceived = 1e18;
        uint256 aeroOutput = 900e6;         // Less than owed!

        uniPool.setMockDeltas(int256(amountOwed), -int256(amountReceived));
        tokenB.mint(address(uniPool), amountReceived);
        aeroPool.setMockAmountOut(aeroOutput);
        tokenA.mint(address(aeroPool), aeroOutput);

        vm.expectRevert(); // InsufficientProfit
        bot.executeArbitrage(
            address(uniPool), address(aeroPool), true, int256(amountReceived), 0, 0
        );
    }

    function test_executeArbitrage_RevertsIf_BelowAbsoluteMinProfit() public {
        uint256 amountOwed = 1000e6;
        uint256 amountReceived = 1e18;
        uint256 aeroOutput = 1001e6;        // Only 1 tokenA profit

        uniPool.setMockDeltas(int256(amountOwed), -int256(amountReceived));
        tokenB.mint(address(uniPool), amountReceived);
        aeroPool.setMockAmountOut(aeroOutput);
        tokenA.mint(address(aeroPool), aeroOutput);

        // minProfit = 50e6, actual profit = 1e6 → revert
        vm.expectRevert();
        bot.executeArbitrage(
            address(uniPool), address(aeroPool), true, int256(amountReceived), 0, 50e6
        );
    }

    function test_executeArbitrage_RevertsIf_BelowMinProfitBps() public {
        // Set minProfitBps to 100 (1%)
        bot.setMinProfitBps(100);

        uint256 amountOwed = 1000e6;
        uint256 amountReceived = 1e18;
        uint256 aeroOutput = 1005e6;        // 5 tokenA profit = 0.5% < 1%

        uniPool.setMockDeltas(int256(amountOwed), -int256(amountReceived));
        tokenB.mint(address(uniPool), amountReceived);
        aeroPool.setMockAmountOut(aeroOutput);
        tokenA.mint(address(aeroPool), aeroOutput);

        vm.expectRevert(); // InsufficientProfit
        bot.executeArbitrage(
            address(uniPool), address(aeroPool), true, int256(amountReceived), 0, 0
        );
    }

    function test_executeArbitrage_PassesIf_AboveMinProfitBps() public {
        // Set minProfitBps to 100 (1%)
        bot.setMinProfitBps(100);

        uint256 amountOwed = 1000e6;
        uint256 amountReceived = 1e18;
        uint256 aeroOutput = 1020e6;        // 20 tokenA = 2% > 1% ✓

        uniPool.setMockDeltas(int256(amountOwed), -int256(amountReceived));
        tokenB.mint(address(uniPool), amountReceived);
        aeroPool.setMockAmountOut(aeroOutput);
        tokenA.mint(address(aeroPool), aeroOutput);

        uint256 ownerBefore = tokenA.balanceOf(deployer);

        bot.executeArbitrage(
            address(uniPool), address(aeroPool), true, int256(amountReceived), 0, 0
        );

        assertEq(tokenA.balanceOf(deployer) - ownerBefore, 20e6);
    }

    // ══════════════════════════════════════════════
    //      ENTRY POINT — ACCESS CONTROL TESTS
    // ══════════════════════════════════════════════

    function test_executeArbitrage_RevertsIf_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        bot.executeArbitrage(address(uniPool), address(aeroPool), true, 1, 0, 0);
    }

    function test_executeArbitrage_RevertsIf_Paused() public {
        bot.togglePause();

        vm.expectRevert(ContractPaused.selector);
        bot.executeArbitrage(address(uniPool), address(aeroPool), true, 1, 0, 0);
    }

    function test_executeArbitrage_RevertsIf_ZeroAmount() public {
        vm.expectRevert(ZeroAmount.selector);
        bot.executeArbitrage(address(uniPool), address(aeroPool), true, 0, 0, 0);
    }

    function test_executeArbitrage_RevertsIf_ZeroUniPool() public {
        vm.expectRevert(ZeroAddress.selector);
        bot.executeArbitrage(address(0), address(aeroPool), true, 1, 0, 0);
    }

    function test_executeArbitrage_RevertsIf_ZeroAeroPool() public {
        vm.expectRevert(ZeroAddress.selector);
        bot.executeArbitrage(address(uniPool), address(0), true, 1, 0, 0);
    }

    // ══════════════════════════════════════════════
    //        CALLBACK SECURITY TESTS
    // ══════════════════════════════════════════════

    function test_callback_RevertsIf_CallerNotExpectedPool() public {
        // Direct call from attacker — _expectedPool is address(0)
        vm.prank(attacker);
        vm.expectRevert(InvalidCaller.selector);
        bot.uniswapV3SwapCallback(0, 0, "");
    }

    function test_callback_RevertsIf_RandomContractCalls() public {
        // Even a contract address can't call if it's not _expectedPool
        address randomContract = makeAddr("randomContract");
        vm.prank(randomContract);
        vm.expectRevert(InvalidCaller.selector);
        bot.uniswapV3SwapCallback(1e6, -1e18, abi.encode(address(aeroPool), uint256(0)));
    }

    // ══════════════════════════════════════════════
    //        SLIPPAGE ENFORCEMENT TESTS
    // ══════════════════════════════════════════════

    function test_setEnforceSlippage() public {
        assertFalse(bot.enforceSlippage());

        vm.expectEmit(true, true, true, true);
        emit EnforceSlippageToggled(true, deployer);
        bot.setEnforceSlippage(true);
        assertTrue(bot.enforceSlippage());

        vm.expectEmit(true, true, true, true);
        emit EnforceSlippageToggled(false, deployer);
        bot.setEnforceSlippage(false);
        assertFalse(bot.enforceSlippage());
    }

    function test_setEnforceSlippage_RevertsIf_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        bot.setEnforceSlippage(true);
    }

    function test_executeArbitrage_RevertsIf_SlippageEnforcedAndZeroMinProfit() public {
        bot.setEnforceSlippage(true);

        vm.expectRevert(SlippageNotSet.selector);
        bot.executeArbitrage(address(uniPool), address(aeroPool), true, 1, 0, 0);
    }

    function test_executeArbitrage_PassesIf_SlippageEnforcedAndMinProfitSet() public {
        bot.setEnforceSlippage(true);

        uint256 amountOwed = 1000e6;
        uint256 amountReceived = 1e18;
        uint256 aeroOutput = 1100e6;

        uniPool.setMockDeltas(int256(amountOwed), -int256(amountReceived));
        tokenB.mint(address(uniPool), amountReceived);
        aeroPool.setMockAmountOut(aeroOutput);
        tokenA.mint(address(aeroPool), aeroOutput);

        // minProfit = 1 → SlippageNotSet should NOT revert
        bot.executeArbitrage(
            address(uniPool), address(aeroPool), true, int256(amountReceived), 0, 1
        );
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
        tokenA.mint(address(bot), 500e6);

        vm.expectEmit(true, true, true, true);
        emit EmergencyTokenWithdraw(address(tokenA), 500e6, deployer);
        bot.emergencyWithdrawToken(address(tokenA), 0); // 0 = full balance

        assertEq(tokenA.balanceOf(address(bot)), 0);
    }

    function test_emergencyWithdrawToken_PartialAmount() public {
        tokenA.mint(address(bot), 500e6);
        bot.emergencyWithdrawToken(address(tokenA), 200e6);

        assertEq(tokenA.balanceOf(address(bot)), 300e6);
    }

    function test_emergencyWithdrawToken_RevertsIf_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        bot.emergencyWithdrawToken(address(tokenA), 0);
    }

    function test_emergencyWithdrawToken_RevertsIf_ZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        bot.emergencyWithdrawToken(address(0), 0);
    }

    function test_emergencyWithdrawEth() public {
        vm.deal(address(bot), 0);
        vm.deal(address(bot), 1 ether);

        uint256 ownerBefore = deployer.balance;

        vm.expectEmit(true, true, true, true);
        emit EmergencyETHWithdraw(1 ether, deployer);
        bot.emergencyWithdrawEth();

        assertEq(address(bot).balance, 0, "Bot should have 0 ETH");
        assertEq(deployer.balance, ownerBefore + 1 ether, "Owner should receive 1 ETH");
    }

    function test_emergencyWithdrawEth_RevertsIf_ZeroBalance() public {
        vm.deal(address(bot), 0);

        vm.expectRevert(ZeroAmount.selector);
        bot.emergencyWithdrawEth();
    }

    // ══════════════════════════════════════════════
    //               VIEW HELPERS
    // ══════════════════════════════════════════════

    function test_getBalance() public {
        tokenA.mint(address(bot), 1234e6);
        assertEq(bot.getBalance(address(tokenA)), 1234e6);
    }

    // ══════════════════════════════════════════════
    //           CONSTRUCTOR VALIDATION
    // ══════════════════════════════════════════════

    function test_constructor_SetsState() public view {
        assertEq(bot.owner(), deployer);
        assertEq(bot.minProfitBps(), 0);
        assertFalse(bot.paused());
        assertFalse(bot.enforceSlippage());
    }

    function test_constructor_WithMinProfitBps() public {
        ArbitrajBotu customBot = new ArbitrajBotu(50);
        assertEq(customBot.minProfitBps(), 50);
    }

    // ══════════════════════════════════════════════
    //              RECEIVE ETH TEST
    // ══════════════════════════════════════════════

    function test_receiveETH() public {
        vm.deal(address(bot), 0);
        uint256 before = address(bot).balance;

        vm.deal(deployer, 1 ether);
        (bool ok, ) = address(bot).call{value: 0.5 ether}("");
        assertTrue(ok, "ETH transfer should succeed");
        assertEq(address(bot).balance - before, 0.5 ether, "Bot should gain 0.5 ETH");
    }
}
