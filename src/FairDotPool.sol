// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./FairDot.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title FairDotPool
 * @notice Single canonical constant-product pool using native quote asset.
 * @dev A minimal market implementation with no swap fee or liquidity-management functions.
 *      It does not provide a manipulation-resistant oracle or guarantee sale proceeds.
 */
contract FairDotPool is ReentrancyGuard {
    FairDot public immutable token;
    address public immutable owner;
    uint256 public quoteReserve;
    uint256 public tokenReserve;
    uint256 public constant PRECISION = 1e18;
    bool public liquidityInitialized;

    struct Schedule {
        uint256 totalAmount;
        uint8 parts;
        uint8 completed;
        uint256 interval;
        uint256 lastSuccess;
    }

    mapping(address => Schedule) public schedules;
    mapping(address => uint256) public cooldownUntil;

    event Swapped(address indexed user, bool isBuy, uint256 quoteAmount, uint256 tokenAmount, uint256 price);
    event ScheduleStarted(address indexed user, uint256 totalTokens, uint8 parts, uint256 interval);
    event InstallmentCompleted(address indexed user, uint256 tokenAmount, uint8 completed, uint8 parts);
    event InstallmentDeferred(address indexed user, uint256 tokenAmount);
    event ScheduleCancelled(address indexed user, uint256 completed, uint256 remaining);
    event LockCheckpointed(address indexed user);

    constructor(address tokenAddress) {
        require(tokenAddress != address(0), "Zero token");
        token = FairDot(tokenAddress);
        owner = msg.sender;
    }

    function hasActiveSchedule(address user) external view returns (bool) {
        return schedules[user].totalAmount != 0;
    }

    function addLiquidity(uint256 tokenAmount) external payable nonReentrant {
        require(msg.sender == owner, "Only owner");
        require(!liquidityInitialized, "Initial liquidity already added");
        require(tokenAmount > 0 && msg.value > 0, "Zero liquidity");
        require(token.transferFrom(msg.sender, address(this), tokenAmount), "Token transfer failed");
        tokenReserve = tokenAmount;
        quoteReserve = msg.value;
        liquidityInitialized = true;
        token.recordSeed(msg.value);
        token.updateLiquidity(quoteReserve);
    }

    function buy(uint256 minTokensOut) external payable nonReentrant returns (uint256 tokensOut) {
        require(msg.value > 0, "Zero quote amount");
        require(token.tradingActive(), "Trading not active");
        require(tokenReserve > 0 && quoteReserve > 0, "Pool has no liquidity");

        uint256 k = tokenReserve * quoteReserve;
        uint256 newQuote = quoteReserve + msg.value;
        uint256 newToken = k / newQuote;
        tokensOut = tokenReserve - newToken;
        require(tokensOut > 0, "Trade too small");
        require(tokensOut >= minTokensOut, "Slippage exceeded");

        tokenReserve = newToken;
        quoteReserve = newQuote;
        uint256 price = msg.value * PRECISION / tokensOut;
        require(token.transfer(msg.sender, tokensOut), "Token transfer failed");
        token.recordBuy(msg.sender, tokensOut, msg.value);
        token.recordPrice(price, msg.value);
        token.updateLiquidity(quoteReserve);
        emit Swapped(msg.sender, true, msg.value, tokensOut, price);
    }

    /// Holder-triggered, separate transaction. A later failed sale cannot undo the checkpoint.
    function checkpointLock() external {
        require(token.tradingActive(), "Trading not active");
        token.checkpointLock(msg.sender);
        emit LockCheckpointed(msg.sender);
    }

    function cancelSchedule() external nonReentrant {
        Schedule memory schedule = schedules[msg.sender];
        require(schedule.totalAmount != 0, "No active schedule");
        delete schedules[msg.sender];
        // cooldownUntil remains anchored to the last successful installment.
        emit ScheduleCancelled(msg.sender, schedule.completed, schedule.parts - schedule.completed);
    }

    /// The first call supplies the full requested amount and auto-starts a schedule if needed.
    /// Later calls may supply either the full scheduled quantity or its next installment.
    function sell(uint256 tokenAmount, uint256 minQuoteOut) external nonReentrant returns (uint256 quoteOut) {
        require(tokenAmount > 0, "Zero token amount");
        require(token.tradingActive(), "Trading not active");
        require(tokenReserve > 0 && quoteReserve > 0, "Pool has no liquidity");
        // Persist any lock/unlock checkpoint even when this attempted installment is deferred.
        token.checkpointLock(msg.sender);

        Schedule storage schedule = schedules[msg.sender];
        bool scheduled = schedule.totalAmount != 0;
        uint256 installment;

        if (!scheduled) {
            require(block.timestamp >= cooldownUntil[msg.sender], "Sell cooldown active");
            uint256 estimatedFullOutput = _quoteOut(tokenAmount);
            (uint256 parts, uint256 interval) = token.getStaggerInfo(estimatedFullOutput);
            if (parts > 1) {
                schedule.totalAmount = tokenAmount;
                schedule.parts = uint8(parts);
                schedule.interval = interval;
                scheduled = true;
                emit ScheduleStarted(msg.sender, tokenAmount, uint8(parts), interval);
            } else {
                installment = tokenAmount;
            }
        }

        if (scheduled) {
            uint256 expected = _installmentAmount(schedule);
            require(tokenAmount == expected || tokenAmount == schedule.totalAmount, "Wrong installment amount");
            installment = expected;
            if (schedule.completed > 0) {
                require(block.timestamp >= schedule.lastSuccess + schedule.interval, "Installment not due");
            }
        }

        if (!token.validateSell(msg.sender, installment)) {
            emit InstallmentDeferred(msg.sender, installment);
            return 0;
        }

        uint256 nextTokenReserve = tokenReserve + installment;
        uint256 nextQuoteReserve = tokenReserve * quoteReserve / nextTokenReserve;
        quoteOut = quoteReserve - nextQuoteReserve;
        require(quoteOut > 0, "Trade too small");
        require(quoteOut >= minQuoteOut, "Slippage exceeded");

        require(token.transferFrom(msg.sender, address(this), installment), "Token transfer failed");
        token.consumeEmergencyQuota(msg.sender, installment);
        tokenReserve = nextTokenReserve;
        quoteReserve = nextQuoteReserve;
        uint256 price = quoteOut * PRECISION / installment;
        token.recordPrice(price, quoteOut);
        token.updateLiquidity(quoteReserve);

        if (scheduled) {
            schedule.completed += 1;
            schedule.lastSuccess = block.timestamp;
            cooldownUntil[msg.sender] = block.timestamp + schedule.interval;
            emit InstallmentCompleted(msg.sender, installment, schedule.completed, schedule.parts);
            if (schedule.completed == schedule.parts) delete schedules[msg.sender];
        } else {
            cooldownUntil[msg.sender] = block.timestamp + 8 hours;
        }

        (bool sent,) = payable(msg.sender).call{value: quoteOut}("");
        require(sent, "Quote transfer failed");
        emit Swapped(msg.sender, false, quoteOut, installment, price);
    }

    function getPrice() external view returns (uint256) {
        return tokenReserve == 0 ? 0 : quoteReserve * PRECISION / tokenReserve;
    }

    function quoteSell(uint256 tokenAmount) external view returns (uint256) {
        return _quoteOut(tokenAmount);
    }

    function _installmentAmount(Schedule storage schedule) private view returns (uint256) {
        uint256 base = schedule.totalAmount / schedule.parts;
        return schedule.completed + 1 == schedule.parts
            ? schedule.totalAmount - base * (schedule.parts - 1)
            : base;
    }

    function _quoteOut(uint256 amount) private view returns (uint256) {
        if (tokenReserve == 0 || tokenReserve + amount == 0) return 0;
        uint256 newQuote = tokenReserve * quoteReserve / (tokenReserve + amount);
        return quoteReserve - newQuote;
    }
}
