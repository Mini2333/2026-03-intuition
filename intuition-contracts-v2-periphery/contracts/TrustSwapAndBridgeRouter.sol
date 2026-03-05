// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ISlipstreamSwapRouter } from "contracts/interfaces/external/aerodrome/ISlipstreamSwapRouter.sol";
import { ICLFactory } from "contracts/interfaces/external/aerodrome/ICLFactory.sol";
import { IMetaERC20Hub, FinalityState } from "contracts/interfaces/external/metalayer/IMetaERC20Hub.sol";

/// @dev Minimal WETH interface used for wrapping native ETH before swapping
interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/**
 * @title  TrustSwapAndBridgeRouter
 * @author 0xIntuition
 * @notice Peripheral router that enables users to (1) swap an ERC-20 or ETH to TRUST using the
 *         Aerodrome Slipstream concentrated-liquidity router, and (2) immediately bridge the
 *         resulting TRUST to another chain via the Metalayer ERC-20 hub — all in a single
 *         transaction.
 *
 * @dev    This contract is intentionally ownerless (no admin, no upgradability) to remain a
 *         pure, stateless helper. All Base-mainnet addresses are immutably compiled in as
 *         constants. Any upgrade requires a new deployment.
 *
 *         ⚠️  KNOWN VULNERABILITY (unfixed, for audit PoC):
 *         `swapAndBridgeWithETH` and `swapAndBridgeWithERC20` quote the bridge fee using the
 *         caller-supplied `minTrustOut` (slippage floor) BEFORE performing the swap.  The actual
 *         swap output `amountOut` can greatly exceed `minTrustOut`, but the bridge call
 *         forwards only the smaller, pre-computed fee.  A caller can therefore underpay the
 *         bridge fee by setting `minTrustOut` to a negligible value while still bridging the
 *         full `amountOut`.
 */
contract TrustSwapAndBridgeRouter {
    using SafeERC20 for IERC20;

    /* =================================================== */
    /*                      ERRORS                         */
    /* =================================================== */

    /// @notice Reverts when the ETH sent is insufficient to cover the bridge fee plus the swap amount
    error TrustSwapAndBridgeRouter_InsufficientETH();

    /// @notice Reverts when the ETH sent to cover the bridge fee is insufficient
    error TrustSwapAndBridgeRouter_InsufficientBridgeFee();

    /// @notice Reverts when the path supplied is invalid (pool does not exist)
    error TrustSwapAndBridgeRouter_InvalidPath();

    /// @notice Reverts when a native-ETH refund transfer fails
    error TrustSwapAndBridgeRouter_TransferFailed();

    /* =================================================== */
    /*                      EVENTS                         */
    /* =================================================== */

    /// @notice Emitted after a successful swap-from-ETH-and-bridge operation
    event SwappedAndBridgedFromETH(
        address indexed sender,
        uint256 swapAmount,
        uint256 trustAmount,
        bytes32 indexed recipient,
        bytes32 transferId
    );

    /// @notice Emitted after a successful swap-from-ERC20-and-bridge operation
    event SwappedAndBridgedFromERC20(
        address indexed sender,
        uint256 trustAmount,
        bytes32 indexed recipient,
        bytes32 transferId
    );

    /// @notice Emitted after a direct bridge of existing TRUST tokens
    event BridgedTrust(address indexed sender, uint256 amount, bytes32 indexed recipient, bytes32 transferId);

    /* =================================================== */
    /*                    CONSTANTS                        */
    /* =================================================== */

    /// @notice TRUST token on Base mainnet
    address public constant TRUST = 0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3;

    /// @notice Wrapped Ether (WETH) on Base mainnet
    address payable public constant WETH = payable(0x4200000000000000000000000000000000000006);

    /// @notice Aerodrome Slipstream swap router on Base mainnet
    address public constant slipstreamSwapRouter = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;

    /// @notice Aerodrome concentrated-liquidity pool factory on Base mainnet
    ICLFactory public constant slipstreamFactory = ICLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);

    /// @notice Metalayer ERC-20 hub on Base mainnet used for cross-chain TRUST bridging
    IMetaERC20Hub public constant metaERC20Hub = IMetaERC20Hub(0x0D63128D887f2c628Fc6E814F4Ce6B9Da9ee90D7);

    /// @notice Destination chain domain identifier (Intuition / OP Stack)
    uint32 public constant recipientDomain = 8453;

    /* =================================================== */
    /*                     RECEIVE                         */
    /* =================================================== */

    /// @notice Accept native ETH (used for refunds and bridge fees)
    receive() external payable { }

    /* =================================================== */
    /*               EXTERNAL FUNCTIONS                    */
    /* =================================================== */

    /**
     * @notice Wraps the caller's ETH, swaps it to TRUST via Aerodrome Slipstream, then bridges
     *         the TRUST to the destination chain.
     *
     * @dev    ⚠️  The bridge fee is quoted from `minTrustOut` before the swap, not from the
     *         actual `amountOut`.  If the swap produces more TRUST than `minTrustOut`, the full
     *         output is bridged while the fee remains pegged to the smaller quote.
     *
     * @param path        ABI-packed Slipstream swap path (tokenIn, tickSpacing, …, TRUST)
     * @param minTrustOut Minimum acceptable TRUST output (slippage guard and — incorrectly —
     *                    the basis for the bridge fee quote)
     * @param recipient   Address on the destination chain to receive the bridged TRUST
     * @return transferId The unique identifier of the resulting bridge transfer
     */
    function swapAndBridgeWithETH(
        bytes calldata path,
        uint256 minTrustOut,
        address recipient
    )
        external
        payable
        returns (bytes32 transferId)
    {
        bytes32 recipientAddress = _formatRecipientAddress(recipient);

        // VULNERABILITY: fee is quoted for minTrustOut (slippage minimum), not actual amountOut
        uint256 bridgeFee = metaERC20Hub.quoteTransferRemote(recipientDomain, recipientAddress, minTrustOut);
        if (msg.value <= bridgeFee) {
            revert TrustSwapAndBridgeRouter_InsufficientETH();
        }

        uint256 swapEth = msg.value - bridgeFee;

        // Wrap ETH and approve the swap router
        IWETH(WETH).deposit{ value: swapEth }();
        IERC20(WETH).approve(slipstreamSwapRouter, swapEth);

        // Swap WETH → TRUST
        uint256 amountOut = ISlipstreamSwapRouter(slipstreamSwapRouter).exactInput(
            ISlipstreamSwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: swapEth,
                amountOutMinimum: minTrustOut
            })
        );

        // Bridge full amountOut but only with the smaller bridgeFee (quoted for minTrustOut)
        transferId = _bridgeTrust(amountOut, recipientAddress, bridgeFee);

        emit SwappedAndBridgedFromETH(msg.sender, swapEth, amountOut, recipientAddress, transferId);
    }

    /**
     * @notice Pulls `amountIn` of `tokenIn` from the caller, swaps to TRUST via Aerodrome
     *         Slipstream, then bridges the TRUST to the destination chain.
     *
     * @dev    ⚠️  The bridge fee is quoted from `minTrustOut` before the swap, not from the
     *         actual `amountOut`.  If the swap produces more TRUST than `minTrustOut`, the full
     *         output is bridged while the fee remains pegged to the smaller quote.
     *
     * @param tokenIn     The ERC-20 token to swap from (must be approved by caller)
     * @param amountIn    The amount of `tokenIn` to swap
     * @param path        ABI-packed Slipstream swap path (tokenIn, tickSpacing, …, TRUST)
     * @param minTrustOut Minimum acceptable TRUST output (slippage guard and — incorrectly —
     *                    the basis for the bridge fee quote)
     * @param recipient   Address on the destination chain to receive the bridged TRUST
     * @return amountOut  The actual amount of TRUST that was swapped and bridged
     * @return transferId The unique identifier of the resulting bridge transfer
     */
    function swapAndBridgeWithERC20(
        address tokenIn,
        uint256 amountIn,
        bytes calldata path,
        uint256 minTrustOut,
        address recipient
    )
        external
        payable
        returns (uint256 amountOut, bytes32 transferId)
    {
        bytes32 recipientAddress = _formatRecipientAddress(recipient);

        // VULNERABILITY: fee is quoted for minTrustOut (slippage minimum), not actual amountOut
        uint256 bridgeFee = metaERC20Hub.quoteTransferRemote(recipientDomain, recipientAddress, minTrustOut);
        if (msg.value < bridgeFee) {
            revert TrustSwapAndBridgeRouter_InsufficientBridgeFee();
        }

        // Pull tokenIn from the caller into this contract, then grant the swap router an allowance
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).safeIncreaseAllowance(slipstreamSwapRouter, amountIn);

        amountOut = ISlipstreamSwapRouter(slipstreamSwapRouter).exactInput(
            ISlipstreamSwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minTrustOut
            })
        );

        // Bridge full amountOut but only with the smaller bridgeFee (quoted for minTrustOut)
        transferId = _bridgeTrust(amountOut, recipientAddress, bridgeFee);

        // Refund any ETH sent beyond the bridge fee
        uint256 refundAmount = msg.value - bridgeFee;
        _refundExcess(refundAmount);

        emit SwappedAndBridgedFromERC20(msg.sender, amountOut, recipientAddress, transferId);
    }

    /**
     * @notice Bridges existing TRUST tokens held by the caller to the destination chain.
     * @param amount    The amount of TRUST to bridge
     * @param recipient Address on the destination chain to receive the bridged TRUST
     * @return transferId The unique identifier of the resulting bridge transfer
     */
    function bridgeTrust(uint256 amount, address recipient) external payable returns (bytes32 transferId) {
        bytes32 recipientAddress = _formatRecipientAddress(recipient);

        uint256 bridgeFee = metaERC20Hub.quoteTransferRemote(recipientDomain, recipientAddress, amount);
        if (msg.value < bridgeFee) {
            revert TrustSwapAndBridgeRouter_InsufficientBridgeFee();
        }

        IERC20(TRUST).safeTransferFrom(msg.sender, address(this), amount);
        transferId = _bridgeTrust(amount, recipientAddress, bridgeFee);

        uint256 refundAmount = msg.value - bridgeFee;
        _refundExcess(refundAmount);

        emit BridgedTrust(msg.sender, amount, recipientAddress, transferId);
    }

    /* =================================================== */
    /*              INTERNAL FUNCTIONS                     */
    /* =================================================== */

    /**
     * @notice Approves the MetaERC20 hub for `amount` TRUST and initiates the bridge transfer
     * @param amount           The amount of TRUST to bridge
     * @param recipientAddress The recipient address on the destination chain (bytes32-encoded)
     * @param fee              The bridge fee in native ETH (wei) to forward with the call
     * @return transferId      The bridge transfer identifier
     */
    function _bridgeTrust(
        uint256 amount,
        bytes32 recipientAddress,
        uint256 fee
    )
        internal
        returns (bytes32 transferId)
    {
        IERC20(TRUST).approve(address(metaERC20Hub), amount);
        transferId = metaERC20Hub.transferRemote{ value: fee }(
            recipientDomain, recipientAddress, amount, 0, FinalityState.INSTANT
        );
    }

    /**
     * @notice Encodes a recipient address as a left-zero-padded bytes32 value
     * @param recipient The EVM address to encode
     * @return The bytes32 representation
     */
    function _formatRecipientAddress(address recipient) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(recipient)));
    }

    /**
     * @notice Sends `amount` native ETH back to the caller; reverts if the transfer fails
     * @param amount The ETH amount to refund (no-op if zero)
     */
    function _refundExcess(uint256 amount) internal {
        if (amount > 0) {
            (bool success,) = payable(msg.sender).call{ value: amount }("");
            if (!success) {
                revert TrustSwapAndBridgeRouter_TransferFailed();
            }
        }
    }
}
