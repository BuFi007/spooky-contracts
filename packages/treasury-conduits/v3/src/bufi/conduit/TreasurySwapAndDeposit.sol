// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IERC4626Deposit {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

/**
 * @title TreasurySwapAndDeposit
 * @notice One registered `TreasuryConduit` target that swaps an ERC-3009 stable
 * into Circle USDC and opens the Earn position in the same `execute`.
 *
 * The conduit pulls `tokenIn`, `forceApprove`s this contract, and calls `run`.
 * Swap proceeds land here (the quote's receiver MUST be this address), then
 * `deposit` / `supply` mint to `beneficiary` from this call's USDC balance
 * delta only — prior/stray `tokenIn` and USDC balances on this contract are
 * preserved untouched. When calling `TreasurySwapAndDeposit` via
 * `TreasuryConduit`, sign `beneficiary = address(conduit)` because
 * `TreasuryConduit` requires `tokenOut` proceeds to be delivered to the
 * conduit before forwarding them to `auth.from`. Per-call leftover `tokenIn`
 * and USDC return to `msg.sender`.
 */
contract TreasurySwapAndDeposit is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum DestKind {
        Vault4626,
        AaveV3Supply
    }

    address public immutable USDC;

    mapping(address venue => bool allowed) public venues;
    mapping(address dest => bool allowed) public dests;

    event VenueSet(address indexed venue, bool allowed);
    event DestSet(address indexed dest, bool allowed);
    event Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error ZeroAmount();
    error NothingToSweep();
    error InexactPull();
    error PriorBalanceConsumed();
    error InvalidTarget();

    error RenounceDisabled();
    error VenueNotRegistered(address venue);
    error DestNotRegistered(address dest);
    error SwapRequired();
    error UnexpectedSwap();
    error SwapFailed(bytes reason);
    error BelowUsdcFloor(uint256 got, uint256 minUsdc);
    error ZeroShares();

    constructor(address initialOwner, address usdc_) Ownable(initialOwner) {
        if (usdc_ == address(0)) revert ZeroAddress();
        USDC = usdc_;
    }

    /// @notice Disabled (plan 398, founder 2026-10-08). An ownerless registry is frozen forever, so the
    /// Safe can only ever hand ownership on through the two-step transfer, never drop it.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    function setVenue(address venue, bool allowed) external onlyOwner {
        if (venue == address(0)) revert ZeroAddress();
        venues[venue] = allowed;
        emit VenueSet(venue, allowed);
    }

    function setDest(address dest, bool allowed) external onlyOwner {
        if (dest == address(0)) revert ZeroAddress();
        dests[dest] = allowed;
        emit DestSet(dest, allowed);
    }

    function rescue(address token, address to) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();
        emit Rescued(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    function run(
        address tokenIn,
        uint256 amountIn,
        address swapTarget,
        bytes calldata swapData,
        DestKind destKind,
        address dest,
        address beneficiary,
        uint256 minUsdc
    ) external nonReentrant {
        if (beneficiary == address(0) || tokenIn == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAmount();
        if (!dests[dest]) revert DestNotRegistered(dest);

        IERC20 inToken = IERC20(tokenIn);
        IERC20 usdc = IERC20(USDC);
        uint256 inBefore = inToken.balanceOf(address(this));
        uint256 usdcBefore = tokenIn == USDC ? inBefore : usdc.balanceOf(address(this));

        inToken.safeTransferFrom(msg.sender, address(this), amountIn);
        if (inToken.balanceOf(address(this)) != inBefore + amountIn) revert InexactPull();

        if (tokenIn != USDC) {
            if (swapTarget == address(0) || !venues[swapTarget]) revert VenueNotRegistered(swapTarget);
            if (swapTarget == tokenIn || swapTarget == USDC || swapTarget == address(this)) revert InvalidTarget();
            if (swapData.length == 0) revert SwapRequired();
            inToken.forceApprove(swapTarget, amountIn);
            (bool ok, bytes memory ret) = swapTarget.call(swapData);
            inToken.forceApprove(swapTarget, 0);
            if (!ok) revert SwapFailed(ret);
        } else if (swapTarget != address(0) || swapData.length != 0) {
            revert UnexpectedSwap();
        }

        uint256 usdcAfterSwap = usdc.balanceOf(address(this));
        if (usdcAfterSwap < usdcBefore) revert PriorBalanceConsumed();
        uint256 usdcToDeposit = usdcAfterSwap - usdcBefore;
        if (usdcToDeposit < minUsdc) revert BelowUsdcFloor(usdcToDeposit, minUsdc);

        usdc.forceApprove(dest, usdcToDeposit);
        if (destKind == DestKind.Vault4626) {
            uint256 shares = IERC4626Deposit(dest).deposit(usdcToDeposit, beneficiary);
            if (shares == 0) revert ZeroShares();
        } else {
            IAaveV3Pool(dest).supply(USDC, usdcToDeposit, beneficiary, 0);
        }
        usdc.forceApprove(dest, 0);

        uint256 inAfter = inToken.balanceOf(address(this));
        if (inAfter < inBefore) revert PriorBalanceConsumed();
        uint256 inRefund = inAfter - inBefore;
        if (inRefund > 0) inToken.safeTransfer(msg.sender, inRefund);

        if (tokenIn != USDC) {
            uint256 usdcAfter = usdc.balanceOf(address(this));
            if (usdcAfter < usdcBefore) revert PriorBalanceConsumed();
            uint256 usdcRefund = usdcAfter - usdcBefore;
            if (usdcRefund > 0) usdc.safeTransfer(msg.sender, usdcRefund);
        }
    }
}
