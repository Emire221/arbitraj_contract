// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ══════════════════════════════════════════════════════════════
//                        CUSTOM ERRORS
// ══════════════════════════════════════════════════════════════

/// @dev Caller is not authorized
error Unauthorized();
/// @dev Callback caller is not the expected Uniswap V3 pool
error InvalidCaller();
/// @dev Contract is paused
error ContractPaused();
/// @dev Reentrancy detected
error ReentrancyGuard();
/// @dev Insufficient profit after arbitrage
error InsufficientProfit(uint256 required, uint256 actual);
/// @dev Amount must be > 0
error ZeroAmount();
/// @dev Address must not be zero
error ZeroAddress();
/// @dev ERC20 transfer failed
error TransferFailed();
/// @dev Slippage protection: minProfit must be > 0 when enforced
error SlippageNotSet();

// ══════════════════════════════════════════════════════════════
//                       MINIMAL IERC20
// ══════════════════════════════════════════════════════════════

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

// ══════════════════════════════════════════════════════════════
//                  UNISWAP V3 POOL INTERFACE
// ══════════════════════════════════════════════════════════════

/// @title IUniswapV3Pool — Direct pool-level interaction (NO router)
/// @dev   Flash swap kaynağı. swap() çağrıldığında output token'lar
///        önce gönderilir, ardından uniswapV3SwapCallback çağrılarak
///        ödeme talep edilir. Bu mekanizma EVM'deki en ucuz borçlanma yöntemidir.
interface IUniswapV3Pool {
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1);

    function token0() external view returns (address);
    function token1() external view returns (address);
    function fee() external view returns (uint24);
}

// ══════════════════════════════════════════════════════════════
//                  AERODROME POOL INTERFACE
// ══════════════════════════════════════════════════════════════

/// @title IAerodromePool — Direct pool-level interaction (V2-style AMM)
/// @dev   Arbitrajın ikinci ayağı. Uniswap'tan alınan token burada
///        daha pahalıya satılır, elde edilen token ile Uniswap borcu ödenir.
interface IAerodromePool {
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function getAmountOut(
        uint256 amountIn,
        address tokenIn
    ) external view returns (uint256);

    function token0() external view returns (address);
    function token1() external view returns (address);
}

// ══════════════════════════════════════════════════════════════
//                       MAIN CONTRACT
// ══════════════════════════════════════════════════════════════

/// @title  ArbitrajBotu — Gas-Optimized Flash Swap Arbitrage Engine
/// @notice Executes atomic arbitrage between Uniswap V3 and Aerodrome
///         using Uniswap V3 flash swaps (zero-capital). No routers,
///         no Aave — direct pool-to-pool for minimum gas.
///
/// @dev    Architecture:
///           1. IUniswapV3Pool.swap() → receive tokens (flash swap)
///           2. uniswapV3SwapCallback() →
///              a. Sell received tokens on Aerodrome (direct pool call)
///              b. Pay Uniswap V3 pool debt
///              c. Transfer profit to owner
///
///         Security:
///           • Owner-only execution with 2-step ownership transfer
///           • Reentrancy guard on every external entry point
///           • Flash swap callback caller validation (_expectedPool)
///           • Configurable minimum-profit threshold (bps + absolute)
///           • Emergency pause + token / ETH rescue
contract ArbitrajBotu {

    // ──────────────────────────────────────────────
    //                STATE VARIABLES
    // ──────────────────────────────────────────────

    /// @notice Current contract owner
    address public owner;

    /// @notice Pending owner for 2-step transfer
    address public pendingOwner;

    /// @notice Minimum acceptable profit in basis points (1 bp = 0.01 %)
    ///         Set to 0 only in test environments.
    uint256 public minProfitBps;

    /// @notice When true, minProfit parameter in executeArbitrage
    ///         must be > 0 to prevent sandwich attacks.
    bool public enforceSlippage;

    /// @notice Emergency pause flag
    bool public paused;

    /// @dev Reentrancy lock: 1 = unlocked, 2 = locked
    uint8 private _locked;

    /// @dev Expected Uniswap V3 pool for callback validation.
    ///      Set before swap, cleared after swap returns.
    address private _expectedPool;

    // ──────────────────────────────────────────────
    //                    EVENTS
    // ──────────────────────────────────────────────

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
    //                   MODIFIERS
    // ──────────────────────────────────────────────

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier whenNotPaused() {
        _checkNotPaused();
        _;
    }

    modifier nonReentrant() {
        _nonReentrantBefore();
        _;
        _nonReentrantAfter();
    }

    function _checkOwner() internal view {
        if (msg.sender != owner) revert Unauthorized();
    }

    function _checkNotPaused() internal view {
        if (paused) revert ContractPaused();
    }

    function _nonReentrantBefore() internal {
        if (_locked == 2) revert ReentrancyGuard();
        _locked = 2;
    }

    function _nonReentrantAfter() internal {
        _locked = 1;
    }

    // ──────────────────────────────────────────────
    //                  CONSTRUCTOR
    // ──────────────────────────────────────────────

    /// @param _minProfitBps Minimum profit in basis points (0 = no check)
    constructor(uint256 _minProfitBps) {
        owner = msg.sender;
        minProfitBps = _minProfitBps;
        _locked = 1;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ══════════════════════════════════════════════
    //            CORE — ARBITRAGE TRIGGER
    // ══════════════════════════════════════════════

    /// @notice Initiates a flash swap arbitrage:
    ///         Borrow from Uniswap V3 → Sell on Aerodrome → Repay → Profit.
    /// @dev    Called by the off-chain Rust bot when a profitable
    ///         opportunity is detected.
    /// @param uniPool           Uniswap V3 pool address (flash swap source)
    /// @param aeroPool          Aerodrome pool address (second leg, profit realization)
    /// @param zeroForOne        Swap direction on Uniswap V3
    ///                          true  = token0 → token1 (receive token1, owe token0)
    ///                          false = token1 → token0 (receive token0, owe token1)
    /// @param amountSpecified   Amount for Uni V3 swap
    ///                          positive = exact input, negative = exact output
    /// @param sqrtPriceLimitX96 Price limit for Uni V3 swap
    /// @param minProfit         Minimum absolute profit in the owed token
    function executeArbitrage(
        address uniPool,
        address aeroPool,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        uint256 minProfit
    ) external onlyOwner whenNotPaused nonReentrant {
        if (uniPool == address(0) || aeroPool == address(0)) revert ZeroAddress();
        if (amountSpecified == 0) revert ZeroAmount();
        if (enforceSlippage && minProfit == 0) revert SlippageNotSet();

        // Set expected pool for callback validation
        _expectedPool = uniPool;

        bytes memory data = abi.encode(aeroPool, minProfit);

        IUniswapV3Pool(uniPool).swap(
            address(this),
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96,
            data
        );

        // Clear after swap completes (callback already executed)
        _expectedPool = address(0);
    }

    // ══════════════════════════════════════════════
    //       CORE — UNISWAP V3 FLASH SWAP CALLBACK
    // ══════════════════════════════════════════════

    /// @notice Called by Uniswap V3 pool during swap execution.
    ///         Executes the Aerodrome leg, validates profit, repays debt.
    /// @dev    Positive delta = amount owed TO the pool by this contract
    ///         Negative delta = amount sent FROM the pool to this contract
    /// @param amount0Delta Amount of token0 owed (+) or received (-)
    /// @param amount1Delta Amount of token1 owed (+) or received (-)
    /// @param data         Encoded (aeroPool, minProfit)
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // ── Security: only the expected Uniswap V3 pool may call ──
        if (msg.sender != _expectedPool) revert InvalidCaller();

        // ── Decode parameters ──
        (address aeroPool, uint256 minProfit) = abi.decode(data, (address, uint256));

        // ── Identify tokens and amounts ──
        IUniswapV3Pool uniPool = IUniswapV3Pool(msg.sender);
        address token0 = uniPool.token0();
        address token1 = uniPool.token1();

        address tokenOwed;      // Token we must pay back to Uniswap V3
        address tokenReceived;  // Token we received from Uniswap V3
        uint256 amountOwed;
        uint256 amountReceived;

        if (amount0Delta > 0) {
            // Owe token0 to pool, received token1
            tokenOwed = token0;
            tokenReceived = token1;
            amountOwed = uint256(amount0Delta);
            amountReceived = uint256(-amount1Delta);
        } else {
            // Owe token1 to pool, received token0
            tokenOwed = token1;
            tokenReceived = token0;
            amountOwed = uint256(amount1Delta);
            amountReceived = uint256(-amount0Delta);
        }

        // ── Sell received tokens on Aerodrome ──
        uint256 balanceBefore = IERC20(tokenOwed).balanceOf(address(this));
        _aerodromeSwap(aeroPool, tokenReceived, amountReceived, tokenOwed);
        uint256 balanceAfter = IERC20(tokenOwed).balanceOf(address(this));

        uint256 aeroOut = balanceAfter - balanceBefore;

        // ── Profit validation ──
        if (aeroOut < amountOwed) {
            revert InsufficientProfit(amountOwed, aeroOut);
        }

        uint256 profit = aeroOut - amountOwed;

        // Check against both absolute and bps-based minimum
        uint256 minProfitFromBps = (amountOwed * minProfitBps) / 10_000;
        uint256 effectiveMinProfit = minProfit > minProfitFromBps
            ? minProfit
            : minProfitFromBps;

        if (profit < effectiveMinProfit) {
            revert InsufficientProfit(effectiveMinProfit, profit);
        }

        // ── Repay Uniswap V3 pool ──
        _safeTransfer(tokenOwed, msg.sender, amountOwed);

        // ── Transfer profit to owner ──
        if (profit > 0) {
            _safeTransfer(tokenOwed, owner, profit);
        }

        emit ArbitrageExecuted(
            msg.sender, aeroPool, amountReceived, profit, block.timestamp
        );
    }

    // ══════════════════════════════════════════════
    //        INTERNAL — AERODROME DIRECT SWAP
    // ══════════════════════════════════════════════

    /// @dev Transfers tokens directly to Aerodrome pool and executes swap.
    ///      No router, no approve — direct transfer + swap for minimum gas.
    /// @param pool     Aerodrome pool address
    /// @param tokenIn  Token to sell
    /// @param amountIn Amount of tokenIn to sell
    /// @param tokenOut Token to receive
    function _aerodromeSwap(
        address pool,
        address tokenIn,
        uint256 amountIn,
        address tokenOut
    ) internal {
        // Transfer input tokens directly to pool (no approve needed)
        _safeTransfer(tokenIn, pool, amountIn);

        // Query expected output from pool
        uint256 amountOut = IAerodromePool(pool).getAmountOut(amountIn, tokenIn);

        // Execute swap based on output token position
        address poolToken0 = IAerodromePool(pool).token0();
        if (tokenOut == poolToken0) {
            IAerodromePool(pool).swap(amountOut, 0, address(this), "");
        } else {
            IAerodromePool(pool).swap(0, amountOut, address(this), "");
        }
    }

    // ══════════════════════════════════════════════
    //              ADMIN FUNCTIONS
    // ══════════════════════════════════════════════

    /// @notice Update the minimum-profit threshold
    /// @param _minProfitBps New value in basis points
    function setMinProfitBps(uint256 _minProfitBps) external onlyOwner {
        uint256 old = minProfitBps;
        minProfitBps = _minProfitBps;
        emit MinProfitBpsUpdated(old, _minProfitBps);
    }

    /// @notice Toggle slippage enforcement.
    ///         When enabled, executeArbitrage reverts if minProfit is 0.
    function setEnforceSlippage(bool _enforce) external onlyOwner {
        enforceSlippage = _enforce;
        emit EnforceSlippageToggled(_enforce, msg.sender);
    }

    /// @notice Toggle emergency pause
    function togglePause() external onlyOwner {
        paused = !paused;
        emit PauseToggled(paused, msg.sender);
    }

    /// @notice Step 1 — nominate a new owner
    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    /// @notice Step 2 — new owner accepts
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        address prev = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(prev, msg.sender);
    }

    /// @notice Rescue stuck ERC-20 tokens
    /// @param token Token address
    /// @param amount Amount to withdraw (0 = full balance)
    function emergencyWithdrawToken(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        uint256 bal = amount == 0
            ? IERC20(token).balanceOf(address(this))
            : amount;
        _safeTransfer(token, owner, bal);
        emit EmergencyTokenWithdraw(token, bal, owner);
    }

    /// @notice Rescue stuck ETH
    function emergencyWithdrawEth() external onlyOwner {
        uint256 bal = address(this).balance;
        if (bal == 0) revert ZeroAmount();
        (bool ok, ) = owner.call{value: bal}("");
        if (!ok) revert TransferFailed();
        emit EmergencyETHWithdraw(bal, owner);
    }

    // ══════════════════════════════════════════════
    //                VIEW HELPERS
    // ══════════════════════════════════════════════

    /// @notice Check token balance held by the contract
    function getBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    // ══════════════════════════════════════════════
    //              INTERNAL HELPERS
    // ══════════════════════════════════════════════

    /// @dev Transfer with explicit success check
    function _safeTransfer(address token, address to, uint256 amt) internal {
        bool ok = IERC20(token).transfer(to, amt);
        if (!ok) revert TransferFailed();
    }

    // ══════════════════════════════════════════════
    //                   RECEIVE
    // ══════════════════════════════════════════════

    /// @notice Accept ETH (e.g. WETH unwrap refund)
    receive() external payable {}
}
