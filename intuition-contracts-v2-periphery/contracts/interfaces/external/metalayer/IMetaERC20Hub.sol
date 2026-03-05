// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

/// @notice The finality state for a cross-chain transfer
enum FinalityState {
    INSTANT,
    FINALIZED,
    ESPRESSO
}

/// @title IMetaERC20Hub
/// @notice Interface for the Metalayer ERC-20 hub used to bridge TRUST tokens cross-chain
interface IMetaERC20Hub {
    /// @notice Returns the fee (in wei) required to bridge `amount` tokens to `recipientDomain`
    /// @param recipientDomain The destination chain domain identifier
    /// @param recipientAddress The recipient address encoded as bytes32
    /// @param amount The amount of tokens to bridge
    /// @return fee The fee required in native ETH (wei)
    function quoteTransferRemote(
        uint32 recipientDomain,
        bytes32 recipientAddress,
        uint256 amount
    )
        external
        view
        returns (uint256 fee);

    /// @notice Transfers tokens to a remote chain
    /// @param recipientDomain The destination chain domain identifier
    /// @param recipientAddress The recipient address encoded as bytes32
    /// @param amount The amount of tokens to bridge
    /// @param gasLimit Additional gas limit for the remote call
    /// @param finalityState The finality state for the transfer
    /// @return transferId The unique identifier of the bridge transfer
    function transferRemote(
        uint32 recipientDomain,
        bytes32 recipientAddress,
        uint256 amount,
        uint256 gasLimit,
        FinalityState finalityState
    )
        external
        payable
        returns (bytes32 transferId);
}
