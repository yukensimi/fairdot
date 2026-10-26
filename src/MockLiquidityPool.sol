// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./FairDot.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MockLiquidityPool
 * @notice Testnet-only constant-product pool using native tPOTv3 as the quote asset.
 * @dev This minimal pool has no swap fee, oracle manipulation resistance, or
 *      production-grade liquidity management. It must not be treated as a mainnet DEX.
 */
contract MockLiquidityPool is ReentrancyGuard {
    FairDot public immutable token;
    address public immutable owner;

    uint256 public quoteReserve;
    uint256 public tokenReserve;
    uint256 public constant PRECISION = 1e18;
    bool public liquidityInitialized;

    event Swapped(address indexed user, bool isBuy, uint256 quoteAmount, uint256 tokenAmount, uint256 price);

    constructor(address tokenAddress) {
        require(tokenAddress != address(0), "Zero token");
        token = FairDot(tokenAddress);
        owner = msg.sender;
    }

    function addLiquidity(uint256 tokenAmount) external payable nonReentrant {
        require(msg.sender == owner, "Only owner");
        require(!liquidityInitialized, "Initial liquidity already added");
        require(tokenAmount > 0 && msg.value > 0, "Zero liquidity");
        require(token.transferFrom(msg.sender, address(this), tokenAmount), "Token transfer failed");
        tokenReserve += tokenAmount;
        quoteReserve += msg.value;
        liquidityInitialized = true;
        token.updateLiquidity(quoteReserve);
    }

    function buy() external payable nonReentrant returns (uint256 tokensOut) {
        require(msg.value > 0, "Zero quote amount");
        require(tokenReserve > 0 && quoteReserve > 0, "Pool has no liquidity");

        uint256 k = tokenReserve * quoteReserve;
        uint256 newQuoteReserve = quoteReserve + msg.value;
        uint256 newTokenReserve = k / newQuoteReserve;
        tokensOut = tokenReserve - newTokenReserve;
        require(tokensOut > 0, "Trade too small");

        quoteReserve = newQuoteReserve;
        tokenReserve = newTokenReserve;
        uint256 price = (msg.value * PRECISION) / tokensOut;

        require(token.transfer(msg.sender, tokensOut), "Token transfer failed");
        token.recordBuy(msg.sender, tokensOut, price);
        token.recordPrice(price, msg.value);
        token.updateLiquidity(quoteReserve);
        emit Swapped(msg.sender, true, msg.value, tokensOut, price);
    }

    function sell(uint256 tokenAmount) external nonReentrant returns (uint256 quoteOut) {
        require(tokenAmount > 0, "Zero token amount");
        require(tokenReserve > 0 && quoteReserve > 0, "Pool has no liquidity");

        // A protected position starts its release timer at the first sell attempt
        // observed by this pool after the trigger. Below the trigger, stale lock
        // state is cleared so a later protected period starts a new timer.
        token.activateLock(msg.sender);
        (bool allowed,) = token.validateWithdraw(msg.sender, tokenAmount);
        require(allowed, "Withdrawal not allowed");

        uint256 newTokenReserve = tokenReserve + tokenAmount;
        uint256 k = tokenReserve * quoteReserve;
        uint256 newQuoteReserve = k / newTokenReserve;
        quoteOut = quoteReserve - newQuoteReserve;
        require(quoteOut > 0, "Trade too small");

        tokenReserve = newTokenReserve;
        quoteReserve = newQuoteReserve;
        uint256 price = (quoteOut * PRECISION) / tokenAmount;

        require(token.transferFrom(msg.sender, address(this), tokenAmount), "Token transfer failed");
        token.confirmStaggerWithdraw(msg.sender, tokenAmount);
        token.recordPrice(price, quoteOut);
        token.updateLiquidity(quoteReserve);

        (bool sent,) = payable(msg.sender).call{value: quoteOut}("");
        require(sent, "Quote transfer failed");
        emit Swapped(msg.sender, false, quoteOut, tokenAmount, price);
    }

    function getPrice() external view returns (uint256) {
        if (tokenReserve == 0) return 0;
        return (quoteReserve * PRECISION) / tokenReserve;
    }
}
