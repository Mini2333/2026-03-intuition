// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import { FinalityState } from "src/interfaces/IMetaLayer.sol";

interface IMetaERC20Hub {
    function quoteTransferRemote(
        uint32 destination,
        bytes32 recipient,
        uint256 amount
    )
        external
        view
        returns (uint256 fee);

    function transferRemote(
        uint32 destination,
        bytes32 recipient,
        uint256 amount,
        uint256 gasLimit,
        FinalityState finalityState
    )
        external
        payable
        returns (bytes32 transferId);
}
