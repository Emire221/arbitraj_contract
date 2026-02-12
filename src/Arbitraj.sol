// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {FlashLoanSimpleReceiverBase} from "aave-v3-core/contracts/flashloan/base/FlashLoanSimpleReceiverBase.sol";
import {IPoolAddressesProvider} from "aave-v3-core/contracts/interfaces/IPoolAddressesProvider.sol";
import {IERC20} from "aave-v3-core/contracts/dependencies/openzeppelin/contracts/IERC20.sol";

// ══════════════════════════════════════════════════════════════
//                        CUSTOM ERRORS
// ══════════════════════════════════════════════════════════════

/// @dev Caller is not authorized
error Unauthorized();
/// @dev Only the Aave Pool may call this function
error OnlyPool();
/// @dev Flash loan was not initiated by this contract
error InvalidInitiator();
/// @dev Contract is paused
error ContractPaused();
/// @dev Reentrancy detected
error ReentrancyGuard();
/// @dev Insufficient profit after arbitrage
error InsufficientProfit(uint256 required, uint256 actual);
/// @dev Invalid Uniswap fee tier
error InvalidFeeTier();
/// @dev Amount must be > 0
error ZeroAmount();
/// @dev Address must not be zero
error ZeroAddress();
/// @dev ERC20 transfer or ETH send failed
error TransferFailed();

// ══════════════════════════════════════════════════════════════
//                   UNISWAP V3 INTERFACE
// ══════════════════════════════════════════════════════════════

/// @title ISwapRouter — Uniswap V3 SwapRouter interface
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

// ══════════════════════════════════════════════════════════════
//                       MAIN CONTRACT
// ══════════════════════════════════════════════════════════════

/// @title  ArbitrajBotu — Atomic Flash-Loan Arbitrage Engine
/// @notice Executes risk-free arbitrage between Uniswap V3 fee-tier pools
///         using Aave V3 flash loans. If any step fails the entire
///         transaction reverts — you never lose the borrowed capital.
///
/// @dev    Security features:
///           • Owner-only execution with 2-step ownership transfer
///           • Reentrancy guard on every external entry point
///           • Flash-loan caller (Pool) & initiator validation
///           • Per-swap slippage protection (amountOutMinimum)
///           • Configurable minimum-profit threshold (basis points)
///           • Emergency pause + token / ETH rescue
///
///         Flow:
///           executeArbitrage() → Aave flashLoanSimple()
///             → executeOperation() → Swap 1 → Swap 2
///             → Validate profit → Repay Aave → Send profit to owner
contract ArbitrajBotu is FlashLoanSimpleReceiverBase {

    // ──────────────────────────────────────────────
    //                STATE VARIABLES
    // ──────────────────────────────────────────────

    /// @notice Current contract owner
    address public owner;

    /// @notice Pending owner for 2-step transfer
    address public pendingOwner;

    /// @notice Uniswap V3 SwapRouter (immutable = cheaper reads)
    ISwapRouter public immutable SWAP_ROUTER;

    /// @notice Minimum acceptable profit in basis points (1 bp = 0.01 %)
    ///         Set to 0 only in test environments.
    uint256 public minProfitBps;

    /// @notice Emergency pause flag
    bool public paused;

    /// @dev Reentrancy lock: 1 = unlocked, 2 = locked
    uint8 private _locked;

    // ──────────────────────────────────────────────
    //                    EVENTS
    // ──────────────────────────────────────────────

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

    /// @param _addressProvider Aave V3 PoolAddressesProvider
    /// @param _swapRouter      Uniswap V3 SwapRouter
    /// @param _minProfitBps    Minimum profit in basis points (0 = no check)
    constructor(
        address _addressProvider,
        address _swapRouter,
        uint256 _minProfitBps
    ) FlashLoanSimpleReceiverBase(IPoolAddressesProvider(_addressProvider)) {
        if (_swapRouter == address(0)) revert ZeroAddress();

        owner = msg.sender;
        SWAP_ROUTER = ISwapRouter(_swapRouter);
        minProfitBps = _minProfitBps;
        _locked = 1;

        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ══════════════════════════════════════════════
    //            CORE — ARBITRAGE TRIGGER
    // ══════════════════════════════════════════════

    /// @notice Initiates a flash-loan arbitrage between two Uniswap V3
    ///         fee-tier pools.
    /// @dev    Called by the off-chain Rust bot when a profitable
    ///         opportunity is detected.
    /// @param asset                The token to borrow (e.g. USDC)
    /// @param amount               Borrow amount in the token's smallest unit
    /// @param targetToken          Intermediate token (e.g. WETH)
    /// @param fee1                 Fee tier for Swap 1: asset → targetToken
    /// @param fee2                 Fee tier for Swap 2: targetToken → asset
    /// @param minAmountIntermediate Minimum output for Swap 1 (slippage guard)
    /// @param minAmountFinal       Minimum output for Swap 2 (slippage guard)
    function executeArbitrage(
        address asset,
        uint256 amount,
        address targetToken,
        uint24 fee1,
        uint24 fee2,
        uint256 minAmountIntermediate,
        uint256 minAmountFinal
    ) external onlyOwner whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (asset == address(0) || targetToken == address(0)) revert ZeroAddress();
        if (fee1 == 0 || fee2 == 0) revert InvalidFeeTier();

        bytes memory params = abi.encode(
            targetToken,
            fee1,
            fee2,
            minAmountIntermediate,
            minAmountFinal
        );

        POOL.flashLoanSimple(address(this), asset, amount, params, 0);
    }

    // ══════════════════════════════════════════════
    //         CORE — FLASH-LOAN CALLBACK
    // ══════════════════════════════════════════════

    /// @notice Aave calls this after depositing funds. Executes the
    ///         dual-swap arbitrage and validates profit.
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        // ── Security ───────────────────────────────
        if (msg.sender != address(POOL)) revert OnlyPool();
        if (initiator != address(this)) revert InvalidInitiator();

        // ── Decode route parameters ────────────────
        (
            address targetToken,
            uint24 fee1,
            uint24 fee2,
            uint256 minAmountIntermediate,
            uint256 minAmountFinal
        ) = abi.decode(params, (address, uint24, uint24, uint256, uint256));

        uint256 totalDebt = amount + premium;

        // ── SWAP 1: asset → targetToken ────────────
        _safeApprove(asset, address(SWAP_ROUTER), amount);

        uint256 intermediateAmount = SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           asset,
                tokenOut:          targetToken,
                fee:               fee1,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          amount,
                amountOutMinimum:  minAmountIntermediate,
                sqrtPriceLimitX96: 0
            })
        );

        // ── SWAP 2: targetToken → asset ────────────
        _safeApprove(targetToken, address(SWAP_ROUTER), intermediateAmount);

        SWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn:           targetToken,
                tokenOut:          asset,
                fee:               fee2,
                recipient:         address(this),
                deadline:          block.timestamp,
                amountIn:          intermediateAmount,
                amountOutMinimum:  minAmountFinal,
                sqrtPriceLimitX96: 0
            })
        );

        // ── Profit validation ──────────────────────
        uint256 currentBalance = IERC20(asset).balanceOf(address(this));

        if (currentBalance < totalDebt) {
            revert InsufficientProfit(totalDebt, currentBalance);
        }

        uint256 profit = currentBalance - totalDebt;
        uint256 minProfit = (amount * minProfitBps) / 10_000;

        if (profit < minProfit) {
            revert InsufficientProfit(minProfit, profit);
        }

        // ── Repay Aave ─────────────────────────────
        _safeApprove(asset, address(POOL), totalDebt);

        // ── Transfer profit to owner ───────────────
        if (profit > 0) {
            _safeTransfer(asset, owner, profit);
        }

        emit ArbitrageExecuted(
            asset, amount, profit, targetToken, fee1, fee2, block.timestamp
        );

        return true;
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

    /// @dev Reset approval to 0 then set — safe for tokens like USDT
    function _safeApprove(address token, address spender, uint256 amt) internal {
        IERC20(token).approve(spender, 0);
        IERC20(token).approve(spender, amt);
    }

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