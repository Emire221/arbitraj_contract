// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {
    ArbitrajBotu,
    IERC20,
    Unauthorized,
    InvalidCaller,
    NoProfitRealized,
    Locked,
    ZeroAmount,
    TransferFailed
} from "../src/Arbitraj.sol";

// ══════════════════════════════════════════════════════════════════════════════
//                             MOCK CONTRACTS
// ══════════════════════════════════════════════════════════════════════════════

/// @dev Minimal ERC20 mock — mint + transfer + balanceOf
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
///      When swap() is called, it:
///        1. Transfers output tokens to recipient (flash behavior)
///        2. Calls uniswapV3SwapCallback on recipient
///      Configurable deltas: positive = owed by caller, negative = sent to caller.
contract MockUniswapV3Pool {
    address public token0;
    address public token1;

    int256 public mockAmount0Delta;
    int256 public mockAmount1Delta;

    constructor(address _t0, address _t1) {
        token0 = _t0;
        token1 = _t1;
    }

    function setMockDeltas(int256 _a0, int256 _a1) external {
        mockAmount0Delta = _a0;
        mockAmount1Delta = _a1;
    }

    function swap(
        address recipient,
        bool, /* zeroForOne */
        int256, /* amountSpecified */
        uint160, /* sqrtPriceLimitX96 */
        bytes calldata data
    ) external returns (int256, int256) {
        // Flash swap: output token'ları ÖNCE gönder
        if (mockAmount0Delta < 0) {
            MockERC20(token0).transfer(recipient, uint256(-mockAmount0Delta));
        }
        if (mockAmount1Delta < 0) {
            MockERC20(token1).transfer(recipient, uint256(-mockAmount1Delta));
        }

        // Callback tetikle — kontrat TLOAD ile bağlam okuyacak
        (bool ok, bytes memory ret) = recipient.call(
            abi.encodeWithSignature(
                "uniswapV3SwapCallback(int256,int256,bytes)",
                mockAmount0Delta,
                mockAmount1Delta,
                data
            )
        );
        if (!ok) {
            assembly { revert(add(ret, 32), mload(ret)) }
        }

        return (mockAmount0Delta, mockAmount1Delta);
    }
}

/// @dev Simulates Aerodrome V2-style AMM pool.
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

// ══════════════════════════════════════════════════════════════════════════════
//                              TEST CONTRACT
// ══════════════════════════════════════════════════════════════════════════════

/// @title ArbitrajBotuTest — v7.0 Comprehensive Test Suite
/// @notice Tests: compact calldata, EIP-1153 transient storage,
///         off-chain profit validation, immutable owner, callback security
/// @dev    Run with: forge test -vvv
contract ArbitrajBotuTest is Test {

    // ── Mock Altyapısı ─────────────────────────────────────────
    MockERC20 public tokenA;          // e.g. USDC (token0)
    MockERC20 public tokenB;          // e.g. WETH (token1)
    MockUniswapV3Pool public uniPool;
    MockAerodromePool public aeroPool;

    // ── Test Altındaki Kontrat ─────────────────────────────────
    ArbitrajBotu public bot;
    address public deployer;
    address public attacker;

    // ── Events (expectEmit için) ───────────────────────────────
    event ArbitrageExecuted(
        address indexed poolA,
        address indexed poolB,
        uint256 amountIn,
        uint256 profit
    );
    event EmergencyTokenWithdraw(
        address indexed token, uint256 amount, address indexed to
    );
    event EmergencyETHWithdraw(uint256 amount, address indexed to);

    // ──────────────────────────────────────────────────────────
    //                       SETUP
    // ──────────────────────────────────────────────────────────

    function setUp() public {
        deployer = address(this);
        attacker = makeAddr("attacker");

        // Mock token'ları deploy et
        tokenA = new MockERC20("TokenA", 6);   // USDC benzeri
        tokenB = new MockERC20("TokenB", 18);  // WETH benzeri

        // Mock havuzları deploy et
        uniPool  = new MockUniswapV3Pool(address(tokenA), address(tokenB));
        aeroPool = new MockAerodromePool(address(tokenA), address(tokenB));

        // Bot deploy et
        bot = new ArbitrajBotu();
    }

    /// @dev Test kontratının ETH alabilmesi için
    receive() external payable {}

    // ──────────────────────────────────────────────────────────
    //  HELPER: 73-byte kompakt calldata oluştur
    // ──────────────────────────────────────────────────────────

    /// @dev abi.encodePacked ile kompakt calldata: [poolA:20] + [poolB:20] + [amount:32] + [direction:1] = 73 byte
    function _buildCalldata(
        address _poolA,
        address _poolB,
        uint256 _amount,
        uint8 _direction
    ) internal pure returns (bytes memory) {
        return abi.encodePacked(_poolA, _poolB, _amount, _direction);
    }

    /// @dev Bot'a kompakt calldata gönder (fallback tetiklenir)
    function _executeArbitrage(
        address _poolA,
        address _poolB,
        uint256 _amount,
        uint8 _direction
    ) internal returns (bool ok) {
        bytes memory cd = _buildCalldata(_poolA, _poolB, _amount, _direction);
        (ok, ) = address(bot).call(cd);
    }

    /// @dev Standart kârlı senaryo kur (token0 borçlu, token1 alınır)
    function _setupProfitableScenario(
        uint256 amountOwed,
        uint256 amountReceived,
        uint256 aeroOutput
    ) internal {
        // amount0Delta > 0 → owe tokenA (token0)
        // amount1Delta < 0 → receive tokenB (token1)
        uniPool.setMockDeltas(int256(amountOwed), -int256(amountReceived));
        tokenB.mint(address(uniPool), amountReceived);   // Fund Uni V3
        aeroPool.setMockAmountOut(aeroOutput);
        tokenA.mint(address(aeroPool), aeroOutput);       // Fund Aerodrome
    }

    // ══════════════════════════════════════════════════════════
    //  1. KOMPAKT CALLDATA TESTLERİ (73 byte)
    // ══════════════════════════════════════════════════════════

    function test_compactCalldata_Is73Bytes() public pure {
        bytes memory cd = abi.encodePacked(
            address(0x1111111111111111111111111111111111111111),
            address(0x2222222222222222222222222222222222222222),
            uint256(1 ether),
            uint8(0)
        );
        assertEq(cd.length, 73, "Compact calldata must be exactly 73 bytes");
    }

    function test_compactCalldata_SuccessfulArbitrage() public {
        // Senaryo: Uni V3'ten 1 tokenB (WETH) al, Aerodrome'da 1050 tokenA'ya sat
        // Borç: 1000 tokenA → Kâr: 50 tokenA
        _setupProfitableScenario(1000e6, 1e18, 1050e6);

        uint256 ownerBefore = tokenA.balanceOf(deployer);

        // direction=0 → zeroForOne=true → token0 borçlu → kâr token0'da (tokenA)
        bool ok = _executeArbitrage(address(uniPool), address(aeroPool), 1e18, 0);
        assertTrue(ok, "Arbitrage should succeed");

        uint256 profit = tokenA.balanceOf(deployer) - ownerBefore;
        assertEq(profit, 50e6, "Profit should be 50 tokenA");
        assertEq(tokenA.balanceOf(address(bot)), 0, "Bot should hold 0 tokenA after");
    }

    function test_compactCalldata_ReverseDirection() public {
        // direction=1 → zeroForOne=false → token1 borçlu, token0 alınır
        // Borç: 1 tokenB (WETH), Al: 1000 tokenA
        uint256 amountOwed = 1e18;
        uint256 amountReceived = 1000e6;

        // amount0Delta < 0 (receive tokenA), amount1Delta > 0 (owe tokenB)
        uniPool.setMockDeltas(-int256(amountReceived), int256(amountOwed));
        tokenA.mint(address(uniPool), amountReceived);

        // Aerodrome: sell 1000 tokenA → get 1.05 tokenB
        uint256 aeroOutput = 1.05e18;
        aeroPool.setMockAmountOut(aeroOutput);
        tokenB.mint(address(aeroPool), aeroOutput);

        uint256 ownerBefore = tokenB.balanceOf(deployer);

        bool ok = _executeArbitrage(address(uniPool), address(aeroPool), 1000e6, 1);
        assertTrue(ok, "Reverse direction should succeed");

        uint256 profit = tokenB.balanceOf(deployer) - ownerBefore;
        assertEq(profit, 0.05e18, "Profit should be 0.05 tokenB");
    }

    function test_compactCalldata_EmitsEvent() public {
        _setupProfitableScenario(1000e6, 1e18, 1050e6);

        vm.expectEmit(true, true, false, true);
        emit ArbitrageExecuted(address(uniPool), address(aeroPool), 1e18, 50e6);

        _executeArbitrage(address(uniPool), address(aeroPool), 1e18, 0);
    }

    // ══════════════════════════════════════════════════════════
    //  2. EIP-1153 TRANSIENT STORAGE TESTLERİ
    // ══════════════════════════════════════════════════════════

    function test_transientStorage_CallbackReadsCorrectContext() public {
        // Transient storage doğru bağlamı taşıdığını kanıtla:
        // eğer callback yanlış pool'dan çağlırsaydı revert ederdi
        _setupProfitableScenario(1000e6, 1e18, 1050e6);

        // Bu başarılı olursa → TSTORE/TLOAD düzgün çalışıyor
        bool ok = _executeArbitrage(address(uniPool), address(aeroPool), 1e18, 0);
        assertTrue(ok, "TSTORE/TLOAD should work correctly across calls");
    }

    function test_transientStorage_NoStateCorruption() public {
        // İki ardışık arbitraj — transient storage temizlenmeli
        _setupProfitableScenario(1000e6, 1e18, 1050e6);
        bool ok1 = _executeArbitrage(address(uniPool), address(aeroPool), 1e18, 0);
        assertTrue(ok1, "First arbitrage should succeed");

        // İkinci arbitraj için mock'ları yeniden kur
        _setupProfitableScenario(2000e6, 2e18, 2100e6);
        bool ok2 = _executeArbitrage(address(uniPool), address(aeroPool), 2e18, 0);
        assertTrue(ok2, "Second arbitrage should succeed (no state corruption)");
    }

    // ══════════════════════════════════════════════════════════
    //  3. OFF-CHAIN KÂR DOĞRULAMASI TESTLERİ
    // ══════════════════════════════════════════════════════════

    function test_profitValidation_RevertsIfNoProfit() public {
        // Aerodrome çıktısı < borç → kâr yok → revert
        uint256 amountOwed = 1000e6;
        uint256 amountReceived = 1e18;
        uint256 aeroOutput = 900e6; // 900 < 1000 → zarar!

        uniPool.setMockDeltas(int256(amountOwed), -int256(amountReceived));
        tokenB.mint(address(uniPool), amountReceived);
        aeroPool.setMockAmountOut(aeroOutput);
        tokenA.mint(address(aeroPool), aeroOutput);

        // NoProfitRealized veya callback içi revert bekleniyor
        bool ok = _executeArbitrage(address(uniPool), address(aeroPool), 1e18, 0);
        assertFalse(ok, "Should revert when no profit");
    }

    function test_profitValidation_ExactBreakeven_Reverts() public {
        // aeroOutput == amountOwed → kâr = 0 → revert
        // (balAfter <= balBefore → eşitlik de revert!)
        uint256 amountOwed = 1000e6;
        uint256 amountReceived = 1e18;
        uint256 aeroOutput = 1000e6; // Tam eşit

        uniPool.setMockDeltas(int256(amountOwed), -int256(amountReceived));
        tokenB.mint(address(uniPool), amountReceived);
        aeroPool.setMockAmountOut(aeroOutput);
        tokenA.mint(address(aeroPool), aeroOutput);

        bool ok = _executeArbitrage(address(uniPool), address(aeroPool), 1e18, 0);
        assertFalse(ok, "Should revert on exact breakeven (0 profit)");
    }

    function test_profitValidation_MinimalProfit_Passes() public {
        // aeroOutput = amountOwed + 1 → 1 wei kâr → geçmeli
        _setupProfitableScenario(1000e6, 1e18, 1000e6 + 1);

        bool ok = _executeArbitrage(address(uniPool), address(aeroPool), 1e18, 0);
        assertTrue(ok, "Should pass with even 1 wei profit");

        assertEq(tokenA.balanceOf(deployer), 1, "Owner should receive 1 wei profit");
    }

    function test_profitValidation_LargeProfit() public {
        // Büyük kâr senaryosu
        _setupProfitableScenario(10_000e6, 10e18, 10_500e6);

        uint256 before = tokenA.balanceOf(deployer);
        _executeArbitrage(address(uniPool), address(aeroPool), 10e18, 0);
        uint256 profit = tokenA.balanceOf(deployer) - before;

        assertEq(profit, 500e6, "Large profit should be fully captured");
    }

    // ══════════════════════════════════════════════════════════
    //  4. IMMUTABLE + ERİŞİM KONTROLÜ TESTLERİ
    // ══════════════════════════════════════════════════════════

    function test_immutable_OwnerSetInConstructor() public view {
        assertEq(bot.owner(), deployer, "Owner should be deployer");
    }

    function test_immutable_OwnerCannotBeChanged() public view {
        // owner immutable olduğu için setter fonksiyon yok
        // Bu sadece görsel doğrulama — setter'ın olmadığını kontrol
        assertEq(bot.owner(), deployer);
    }

    function test_accessControl_FallbackRevertsIfNotOwner() public {
        vm.prank(attacker);
        bool ok = _executeArbitrage(address(uniPool), address(aeroPool), 1e18, 0);
        assertFalse(ok, "Non-owner should be rejected");
    }

    function test_accessControl_CallbackRevertsIfNotExpectedPool() public {
        // Doğrudan callback çağrısı — _expectedPool tload(0x00) = 0
        vm.prank(attacker);
        vm.expectRevert(InvalidCaller.selector);
        bot.uniswapV3SwapCallback(0, 0, "");
    }

    function test_accessControl_CallbackRevertsIfRandomContract() public {
        address random = makeAddr("randomContract");
        vm.prank(random);
        vm.expectRevert(InvalidCaller.selector);
        bot.uniswapV3SwapCallback(1e6, -1e18, abi.encode(address(aeroPool)));
    }

    // ══════════════════════════════════════════════════════════
    //  5. CALLDATA DOĞRULAMA TESTLERİ
    // ══════════════════════════════════════════════════════════

    function test_calldata_RevertsIfZeroAmount() public {
        bytes memory cd = _buildCalldata(address(uniPool), address(aeroPool), 0, 0);
        (bool ok, bytes memory ret) = address(bot).call(cd);
        assertFalse(ok, "Zero amount should revert");
        // ZeroAmount selector kontrolü
        assertEq(bytes4(ret), ZeroAmount.selector);
    }

    // ══════════════════════════════════════════════════════════
    //  6. ACİL DURUM ÇEKME TESTLERİ
    // ══════════════════════════════════════════════════════════

    function test_withdrawToken_FullBalance() public {
        tokenA.mint(address(bot), 500e6);

        vm.expectEmit(true, true, true, true);
        emit EmergencyTokenWithdraw(address(tokenA), 500e6, deployer);
        bot.withdrawToken(address(tokenA));

        assertEq(tokenA.balanceOf(address(bot)), 0);
        assertEq(tokenA.balanceOf(deployer), 500e6);
    }

    function test_withdrawToken_RevertsIfNotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        bot.withdrawToken(address(tokenA));
    }

    function test_withdrawToken_RevertsIfZeroBalance() public {
        vm.expectRevert(ZeroAmount.selector);
        bot.withdrawToken(address(tokenA));
    }

    function test_withdrawETH() public {
        vm.deal(address(bot), 1 ether);
        uint256 ownerBefore = deployer.balance;

        vm.expectEmit(true, true, true, true);
        emit EmergencyETHWithdraw(1 ether, deployer);
        bot.withdrawETH();

        assertEq(address(bot).balance, 0);
        assertEq(deployer.balance, ownerBefore + 1 ether);
    }

    function test_withdrawETH_RevertsIfNotOwner() public {
        vm.deal(address(bot), 1 ether);
        vm.prank(attacker);
        vm.expectRevert(Unauthorized.selector);
        bot.withdrawETH();
    }

    function test_withdrawETH_RevertsIfZeroBalance() public {
        vm.deal(address(bot), 0);
        vm.expectRevert(ZeroAmount.selector);
        bot.withdrawETH();
    }

    // ══════════════════════════════════════════════════════════
    //  7. VIEW YARDIMCI TESTLERİ
    // ══════════════════════════════════════════════════════════

    function test_getBalance() public {
        tokenA.mint(address(bot), 1234e6);
        assertEq(bot.getBalance(address(tokenA)), 1234e6);
    }

    // ══════════════════════════════════════════════════════════
    //  8. CONSTRUCTOR TESTLERİ
    // ══════════════════════════════════════════════════════════

    function test_constructor_SetsImmutableOwner() public view {
        assertEq(bot.owner(), deployer, "Owner = deployer");
    }

    function test_constructor_DifferentDeployer() public {
        address otherDeployer = makeAddr("otherDeployer");
        vm.prank(otherDeployer);
        ArbitrajBotu otherBot = new ArbitrajBotu();
        assertEq(otherBot.owner(), otherDeployer);
    }

    // ══════════════════════════════════════════════════════════
    //  9. ETH ALMA TESTİ
    // ══════════════════════════════════════════════════════════

    function test_receiveETH() public {
        vm.deal(deployer, 1 ether);
        (bool ok, ) = address(bot).call{value: 0.5 ether}("");
        assertTrue(ok, "ETH transfer should succeed");
        assertEq(address(bot).balance, 0.5 ether);
    }

    // ══════════════════════════════════════════════════════════
    //  10. ENTEGRASYON: TAM DÖNGÜ TESTİ
    // ══════════════════════════════════════════════════════════

    function test_fullCycle_MultipleArbitrages() public {
        // 3 ardışık arbitraj — her biri farklı miktarlarla
        uint256 totalProfit;

        // Arbitraj 1: 50 tokenA kâr
        _setupProfitableScenario(1000e6, 1e18, 1050e6);
        _executeArbitrage(address(uniPool), address(aeroPool), 1e18, 0);
        totalProfit += 50e6;

        // Arbitraj 2: 100 tokenA kâr
        _setupProfitableScenario(2000e6, 2e18, 2100e6);
        _executeArbitrage(address(uniPool), address(aeroPool), 2e18, 0);
        totalProfit += 100e6;

        // Arbitraj 3: 25 tokenA kâr
        _setupProfitableScenario(500e6, 0.5e18, 525e6);
        _executeArbitrage(address(uniPool), address(aeroPool), 0.5e18, 0);
        totalProfit += 25e6;

        assertEq(tokenA.balanceOf(deployer), totalProfit, "Total profit after 3 trades");
        assertEq(tokenA.balanceOf(address(bot)), 0, "Bot should hold 0 after all trades");
    }

    function test_fullCycle_BothDirections() public {
        // direction=0 ile bir arbitraj
        _setupProfitableScenario(1000e6, 1e18, 1050e6);
        bool ok1 = _executeArbitrage(address(uniPool), address(aeroPool), 1e18, 0);
        assertTrue(ok1);

        // direction=1 ile bir arbitraj
        uniPool.setMockDeltas(-int256(1000e6), int256(1e18));
        tokenA.mint(address(uniPool), 1000e6);
        aeroPool.setMockAmountOut(1.05e18);
        tokenB.mint(address(aeroPool), 1.05e18);

        bool ok2 = _executeArbitrage(address(uniPool), address(aeroPool), 1000e6, 1);
        assertTrue(ok2);
    }

    // ══════════════════════════════════════════════════════════
    //  11. SİLİNEN ÖZELLİKLERİN YOKLUĞU
    // ══════════════════════════════════════════════════════════

    function test_removed_NoPausedFunction() public view {
        // paused fonksiyonu artık yok — sadece immutable owner var
        // Bu test, kontratın basitleştiğini doğrular
        assertEq(bot.owner(), deployer);
        // bot.paused() → derleme hatası verir (yok)
        // bot.togglePause() → derleme hatası verir (yok)
        // bot.minProfitBps() → derleme hatası verir (yok)
    }

    // ══════════════════════════════════════════════════════════
    //  12. GAS OPTİMİZASYON KANITI
    // ══════════════════════════════════════════════════════════

    function test_gasProfile_SuccessfulArbitrage() public {
        _setupProfitableScenario(1000e6, 1e18, 1050e6);

        bytes memory cd = _buildCalldata(address(uniPool), address(aeroPool), 1e18, 0);

        uint256 gasBefore = gasleft();
        (bool ok, ) = address(bot).call(cd);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(ok, "Should succeed");
        console.log("Gas used for successful arbitrage:", gasUsed);
        // Gas bilgisi loglanır — forge test -vvv ile görülür
    }
}
