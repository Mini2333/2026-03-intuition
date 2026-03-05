// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

/// @title ICLFactory
/// @notice Interface for the Aerodrome concentrated-liquidity pool factory
interface ICLFactory {
    /// @notice Returns the pool address for a given pair of tokens, tick spacing, and deployment,
    ///         or address(0) if it does not exist
    /// @param tokenA The contract address of either token0 or token1
    /// @param tokenB The contract address of the other token
    /// @param tickSpacing The tick spacing of the pool
    /// @return pool The pool address
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
}
