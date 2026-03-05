// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { ISlipstreamSwapRouter } from "./interfaces/external/aerodrome/ISlipstreamSwapRouter.sol";
import { ICLFactory } from "./interfaces/external/aerodrome/ICLFactory.sol";
import { IMetaERC20Hub } from "./interfaces/external/metalayer/IMetaERC20Hub.sol";
import { FinalityState } from "src/interfaces/IMetaLayer.sol";

interface IWETH {
    function deposit() external payable;

    function withdraw(uint256 amount) external;
}

/// @title TrustSwapAndBridgeRouter
/// @notice Routes swaps through Aerodrome Slipstream and bridges TRUST tokens via the MetaLayer hub.
contract TrustSwapAndBridgeRouter {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error TrustSwapAndBridgeRouter_InsufficientETH();
    error TrustSwapAndBridgeRouter_InsufficientBridgeFee();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event SwappedAndBridgedFromETH(
        address indexed sender,
        uint256 swapEth,
        uint256 amountOut,
        bytes32 recipientAddress,
        bytes32 transferId
    );

    event SwappedAndBridgedWithERC20(
        address indexed sender,
        address tokenIn,
        uint256 amountIn,
        uint256 amountOut,
        bytes32 recipientAddress,
        bytes32 transferId
    );

    // -------------------------------------------------------------------------
    // Constants / Immutables
    // -------------------------------------------------------------------------

    /// @notice Aerodrome Slipstream swap router (Base mainnet)
    address public constant slipstreamSwapRouter = 0xcbBb8035cAc7D4B3Ca7aBb74cF7BdF900215Ce0D;

    /// @notice Aerodrome Slipstream CL factory (Base mainnet)
    ICLFactory public constant slipstreamFactory = ICLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);

    /// @notice MetaLayer MetaERC20Hub used for bridging TRUST (Base mainnet)
    IMetaERC20Hub public constant metaERC20Hub = IMetaERC20Hub(0xE12aaF1529Ae21899029a9b51cca2F2Bc2cfC421);

    /// @notice Wrapped ETH on Base
    address public constant weth = 0x4200000000000000000000000000000000000006;

    /// @notice TRUST token on Base
    address public constant trust = 0x6cd905dF2Ed214b22e0d48FF17CD4200C1C6d8A3;

    /// @notice Destination chain domain ID for TRUST bridging
    uint32 public constant recipientDomain = 1155;

    // -------------------------------------------------------------------------
    // External functions
    // -------------------------------------------------------------------------

    /// @notice Swap ETH → TRUST via Aerodrome Slipstream and bridge to another chain.
    /// @dev    msg.value must cover both the Aerodrome swap amount AND the bridge fee.
    ///         The bridge fee is quoted using `minTrustOut` (the slippage floor), but
    ///         the actual amount bridged is `amountOut` from the swap.
    ///
    ///         VULNERABILITY: `bridgeFee` is derived from the caller-controlled `minTrustOut`
    ///         before the swap executes. If the swap returns `amountOut > minTrustOut`, the
    ///         router bridges the larger `amountOut` while only forwarding the fee that was
    ///         quoted for the smaller `minTrustOut`. Callers can deliberately understate
    ///         `minTrustOut` to minimise the fee paid while still bridging more tokens.
    ///
    /// @param path        Encoded Slipstream multi-hop path (ETH/WETH → … → TRUST).
    /// @param minTrustOut Minimum TRUST to receive from the swap (slippage protection).
    /// @param recipient   Address on the destination chain to receive the bridged TRUST.
    /// @return amountOut  Actual TRUST received from the swap (and bridged).
    /// @return transferId MetaLayer transfer identifier.
    function swapAndBridgeWithETH(
        bytes calldata path,
        uint256 minTrustOut,
        address recipient
    )
        external
        payable
        returns (uint256 amountOut, bytes32 transferId)
    {
        bytes32 recipientAddress = _formatRecipientAddress(recipient);

        // STATE A: Bridge fee is quoted using `minTrustOut` — the caller-supplied slippage floor.
        uint256 bridgeFee = metaERC20Hub.quoteTransferRemote(recipientDomain, recipientAddress, minTrustOut);
        if (msg.value <= bridgeFee) {
            revert TrustSwapAndBridgeRouter_InsufficientETH();
        }

        uint256 swapEth = msg.value - bridgeFee;

        // Wrap ETH for the swap router.
        IWETH(weth).deposit{ value: swapEth }();
        IERC20(weth).approve(slipstreamSwapRouter, swapEth);

        // STATE B: Execute the swap — `amountOut` may be significantly larger than `minTrustOut`.
        amountOut = ISlipstreamSwapRouter(slipstreamSwapRouter).exactInput(
            ISlipstreamSwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp + 1,
                amountIn: swapEth,
                amountOutMinimum: minTrustOut
            })
        );

        // STATE C: Bridge the full `amountOut` while forwarding only the fee quoted for
        //          `minTrustOut`. No equivalence check or fee adjustment is performed here.
        transferId = _bridgeTrust(amountOut, recipientAddress, bridgeFee);

        emit SwappedAndBridgedFromETH(msg.sender, swapEth, amountOut, recipientAddress, transferId);
    }

    /// @notice Swap an ERC-20 token → TRUST via Aerodrome Slipstream and bridge to another chain.
    /// @dev    msg.value must cover the bridge fee (quoted from `minTrustOut`).
    ///
    ///         VULNERABILITY: `bridgeFee` is derived from the caller-controlled `minTrustOut`
    ///         before the swap executes. The router then bridges the actual `amountOut` — which
    ///         may be much larger than `minTrustOut` — while only forwarding the fee calculated
    ///         for the smaller amount. There is no post-swap fee re-validation.
    ///
    /// @param tokenIn     ERC-20 token to swap from.
    /// @param amountIn    Amount of `tokenIn` to swap.
    /// @param path        Encoded Slipstream multi-hop path (tokenIn → … → TRUST).
    /// @param minTrustOut Minimum TRUST to receive from the swap (slippage protection).
    /// @param recipient   Address on the destination chain to receive the bridged TRUST.
    /// @return amountOut  Actual TRUST received from the swap (and bridged).
    /// @return transferId MetaLayer transfer identifier.
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

        // STATE A: Bridge fee is quoted using `minTrustOut` — the caller-supplied slippage floor.
        uint256 bridgeFee = metaERC20Hub.quoteTransferRemote(recipientDomain, recipientAddress, minTrustOut);
        if (msg.value < bridgeFee) {
            revert TrustSwapAndBridgeRouter_InsufficientBridgeFee();
        }

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).approve(slipstreamSwapRouter, amountIn);

        // STATE B: Execute the swap — `amountOut` may be significantly larger than `minTrustOut`.
        amountOut = ISlipstreamSwapRouter(slipstreamSwapRouter).exactInput(
            ISlipstreamSwapRouter.ExactInputParams({
                path: path,
                recipient: address(this),
                deadline: block.timestamp + 1,
                amountIn: amountIn,
                amountOutMinimum: minTrustOut
            })
        );

        // STATE C: Bridge the full `amountOut` while forwarding only the fee quoted for
        //          `minTrustOut`. No equivalence check or fee adjustment is performed here.
        transferId = _bridgeTrust(amountOut, recipientAddress, bridgeFee);

        uint256 refundAmount = msg.value - bridgeFee;
        _refundExcess(refundAmount);

        emit SwappedAndBridgedWithERC20(msg.sender, tokenIn, amountIn, amountOut, recipientAddress, transferId);
    }

    /// @notice Bridge TRUST tokens directly (no swap).
    /// @param amount    Amount of TRUST to bridge.
    /// @param recipient Address on the destination chain.
    /// @return transferId MetaLayer transfer identifier.
    function bridgeTrust(uint256 amount, address recipient) external payable returns (bytes32 transferId) {
        bytes32 recipientAddress = _formatRecipientAddress(recipient);

        uint256 bridgeFee = metaERC20Hub.quoteTransferRemote(recipientDomain, recipientAddress, amount);
        if (msg.value < bridgeFee) {
            revert TrustSwapAndBridgeRouter_InsufficientBridgeFee();
        }

        IERC20(trust).safeTransferFrom(msg.sender, address(this), amount);
        transferId = _bridgeTrust(amount, recipientAddress, bridgeFee);
        _refundExcess(msg.value - bridgeFee);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _bridgeTrust(
        uint256 amount,
        bytes32 recipientAddress,
        uint256 bridgeFee
    )
        internal
        returns (bytes32 transferId)
    {
        IERC20(trust).approve(address(metaERC20Hub), amount);
        transferId = metaERC20Hub.transferRemote{ value: bridgeFee }(
            recipientDomain, recipientAddress, amount, 0, FinalityState.FINALIZED
        );
    }

    function _formatRecipientAddress(address recipient) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(recipient)));
    }

    function _refundExcess(uint256 amount) internal {
        if (amount > 0) {
            (bool success,) = msg.sender.call{ value: amount }("");
            require(success, "TrustSwapAndBridgeRouter: ETH refund failed");
        }
    }

    receive() external payable { }
}
