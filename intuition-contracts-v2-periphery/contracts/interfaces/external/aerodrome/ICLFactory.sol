// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

interface ICLFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);
}
