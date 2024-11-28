// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.5.0;

import {IUniswapV3Factory} from "../v3-core-0.8/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3MintCallback} from "../v3-core-0.8/contracts/interfaces/callback/IUniswapV3MintCallback.sol";

/// @title Liquidity management functions
/// @notice Internal functions for safely managing liquidity in Uniswap V3
interface ILiquidityManagement is IUniswapV3MintCallback {
    function factory() external view returns (IUniswapV3Factory);
}
