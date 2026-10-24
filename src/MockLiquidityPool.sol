// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./FairDot.sol";

/**
 * @title MockLiquidityPool
 * @notice A mock DEX pool for testnet testing. Simulates a simple AMM
 *         (constant-product) and calls the required hooks on FairDot.
 *         In production, integrate with a real DEX (e.g. Uniswap V2 fork).
 */
contract MockLiquidityPool {
    FairDot public token;
    address public owner;

    uint256 public quoteReserve;
    uint256 public tokenReserve;
    uint256 public constant PRECISION = 1e18;

    event Swapped(address indexed user, bool isBuy, uint256 amountIn, uint256 amountOut, uint256 price);

    constructor(address _token) {
        token = FairDot(_token);
        owner = msg.sender;
    }

    function addLiquidity(uint256 tokenAmount, uint256 quoteAmount) external {
        require(msg.sender == owner, "Only owner");
        token.transferFrom(msg.sender, address(this), tokenAmount);
        tokenReserve += tokenAmount;
        quoteReserve += quoteAmount;
        token.updateLiquidity(quoteReserve);
    }

    function buy(uint256 quoteAmount) external returns (uint256 tokensOut) {
        require(quoteAmount > 0, "Zero amount");

        uint256 newQuoteReserve = quoteReserve + quoteAmount;
        uint256 k = tokenReserve * quoteReserve;
        uint256 newTokenReserve = k / newQuoteReserve;
        tokensOut = tokenReserve - newTokenReserve;

        tokenReserve = newTokenReserve;
        quoteReserve = newQuoteReserve;

        uint256 price = (quoteAmount * PRECISION) / tokensOut;

        token.transfer(msg.sender, tokensOut);
        token.recordBuy(msg.sender, tokensOut, price);
        token.recordPrice(price, quoteAmount);
        token.updateLiquidity(quoteReserve);

        emit Swapped(msg.sender, true, quoteAmount, tokensOut, price);
    }

    function sell(uint256 tokenAmount) external returns (uint256 quoteOut) {
        require(tokenAmount > 0, "Zero amount");

        (bool allowed, ) = token.validateWithdraw(msg.sender, tokenAmount);
        require(allowed, "Withdrawal not allowed");

        uint256 newTokenReserve = tokenReserve + tokenAmount;
        uint256 k = tokenReserve * quoteReserve;
        uint256 newQuoteReserve = k / newTokenReserve;
        quoteOut = quoteReserve - newQuoteReserve;

        tokenReserve = newTokenReserve;
        quoteReserve = newQuoteReserve;

        uint256 price = (quoteOut * PRECISION) / tokenAmount;

        token.transferFrom(msg.sender, address(this), tokenAmount);
        token.recordPrice(price, tokenAmount);
        token.updateLiquidity(quoteReserve);

        emit Swapped(msg.sender, false, tokenAmount, quoteOut, price);
    }

    function getPrice() external view returns (uint256) {
        if (tokenReserve == 0) return 0;
        return (quoteReserve * PRECISION) / tokenReserve;
    }
}
