// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.4;

import "./interfaces/IBunniHub.sol";

import {WETH} from "solmate/src/tokens/WETH.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

import {Multicall} from "./v3-periphery-0.8/contracts/base/Multicall.sol";
import {SelfPermit} from "./v3-periphery-0.8/contracts/base/SelfPermit.sol";

//BunniLpZapIn.sol, minus the Timeless stuff

contract BunniZap is Multicall, SelfPermit {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using SafeTransferLib for ERC20;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error BunniLpZapIn__SameToken();
    error BunniLpZapIn__PastDeadline();
    error BunniLpZapIn__ZeroExSwapFailed();
    error BunniLpZapIn__InsufficientOutput();

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The Wrapped Ethereum contract
    WETH public immutable weth;

    /// @notice BunniHub for managing Uniswap v3 liquidity
    IBunniHub public immutable bunniHub;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(WETH weth_, IBunniHub bunniHub_) {
        weth = weth_;
        bunniHub = bunniHub_;
    }

    /// -----------------------------------------------------------------------
    /// Zaps
    /// -----------------------------------------------------------------------

    /// @notice Deposits tokens into a Bunni LP position. Any leftover tokens
    /// are refunded to the recipient address.
    /// @dev depositParams.recipient will receive the Bunni LP tokens.
    /// depositParams.amount0Desired and depositParams.amount1Desired are overridden to the balances
    /// of address(this) if the corresponding useContractBalance flag is set to true.
    /// @param depositParams The deposit params passed to BunniHub
    /// @param token0 The token0 of the Uniswap pair to LP into
    /// @param token1 The token1 of the Uniswap pair to LP into
    /// @param recipient The recipient of the staked gauge position
    /// @param sharesMin The minimum acceptable amount of shares received. Used for controlling slippage.
    /// @param useContractBalance0 Set to true to use the token0 balance of address(this) instead of msg.sender
    /// @param useContractBalance1 Set to true to use the token1 balance of address(this) instead of msg.sender
    /// @param compound Set to true to compound the Bunni pool before depositing
    /// @return shares The new share tokens minted to the sender
    /// @return addedLiquidity The new liquidity amount as a result of the increase
    /// @return amount0 The amount of token0 to acheive resulting liquidity
    /// @return amount1 The amount of token1 to acheive resulting liquidity
    function zapInNoStake(
        IBunniHub.DepositParams memory depositParams,
        ERC20 token0,
        ERC20 token1,
        address recipient,
        uint256 sharesMin,
        bool useContractBalance0,
        bool useContractBalance1,
        bool compound
    ) external payable virtual returns (uint256 shares, uint128 addedLiquidity, uint256 amount0, uint256 amount1) {
        // transfer tokens in and modify deposit params
        if (!useContractBalance0) {
            if (depositParams.amount0Desired != 0) {
                token0.safeTransferFrom(msg.sender, address(this), depositParams.amount0Desired);
            }
        } else {
            depositParams.amount0Desired = token0.balanceOf(address(this));
        }
        if (!useContractBalance1) {
            if (depositParams.amount1Desired != 0) {
                token1.safeTransferFrom(msg.sender, address(this), depositParams.amount1Desired);
            }
        } else {
            depositParams.amount1Desired = token1.balanceOf(address(this));
        }

        // compound if requested
        if (compound) {
            bunniHub.compound(depositParams.key);
        }

        // approve tokens to Bunni
        token0.safeApprove(address(bunniHub), depositParams.amount0Desired);
        token1.safeApprove(address(bunniHub), depositParams.amount1Desired);

        // deposit tokens into Bunni
        (shares, addedLiquidity, amount0, amount1) = bunniHub.deposit(depositParams);
        if (shares < sharesMin) {
            revert BunniLpZapIn__InsufficientOutput();
        }

        // reset approvals
        if (token0.allowance(address(this), address(bunniHub)) != 0) {
            token0.safeApprove(address(bunniHub), 0);
        }
        if (token1.allowance(address(this), address(bunniHub)) != 0) {
            token1.safeApprove(address(bunniHub), 0);
        }

        // refund tokens
        uint256 balance = token0.balanceOf(address(this));
        if (balance != 0) {
            token0.safeTransfer(recipient, balance);
        }
        balance = token1.balanceOf(address(this));
        if (balance != 0) {
            token1.safeTransfer(recipient, balance);
        }
    }


// struct WithdrawParams {
    //        BunniKey key;
    //        address recipient;
    //        uint256 shares;
    //        uint256 amount0Min;
    //        uint256 amount1Min;
    //        uint256 deadline;
    //    }



    //Macro function to unwrap ETH if needed.
    //Handles all other withdrawals as well to avoid double allowances
    function zapOut(
        IBunniHub.WithdrawParams memory withdrawParams,
        ERC20 shareToken,
        ERC20 token0,
        ERC20 token1,
        address recipient,
        uint256 amount0Min,
        uint256 amount1Min,
        bool unwrapEth
    ) external payable virtual returns (uint128 removedLiquidity, uint256 amount0, uint256 amount1) {

        //internal recipient has to be the Zap contract itself
        require(withdrawParams.recipient == address(this), "WHO");

        //pull shares. can't send directly to Hub due to its logic
        shareToken.safeTransferFrom(msg.sender, address(this), withdrawParams.shares);

        // approve share tokens to Bunni
        shareToken.safeApprove(address(bunniHub), withdrawParams.shares);

        // withdraw tokens from Bunni
        (removedLiquidity, amount0, amount1) = bunniHub.withdraw(withdrawParams);
        if (amount0 < amount0Min || amount1 < amount1Min)  {
            revert BunniLpZapIn__InsufficientOutput();
        }

        // reset approvals
        if (shareToken.allowance(address(this), address(bunniHub)) != 0) {
            shareToken.safeApprove(address(bunniHub), 0);
        }

        // send tokens
        uint256 balance = token0.balanceOf(address(this));

        if (balance != 0) {
            if(address(token0) == address(weth) && unwrapEth) {
                weth.withdraw(balance);
                //Zap has no modifiable state
                (bool success,) = recipient.call{value: balance}("");
                require(success, "ETH");
            } else {
                token0.safeTransfer(recipient, balance);
            }
        }
        balance = token1.balanceOf(address(this));
        if (balance != 0) {
            if(address(token1) == address(weth) && unwrapEth) {
                weth.withdraw(balance);
                //Zap has no modifiable state
                (bool success,) = recipient.call{value: balance}("");
                require(success, "ETH");
            } else {
                token1.safeTransfer(recipient, balance);
            }
        }
    }


    /// -----------------------------------------------------------------------
    /// WETH support
    /// -----------------------------------------------------------------------

    /// @notice Wraps the user's ETH input into WETH
    /// @dev Should be used as part of a multicall to convert the user's ETH input into WETH
    /// so that it can be swapped into other tokens.
    function wrapEthInput() external payable {
        weth.deposit{value: msg.value}();
    }

    receive() external payable {
        assert(msg.sender == address(weth)); // only accept ETH via fallback from the WETH contract
    }

}
