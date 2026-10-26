// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IFairDotPoolSeedStatus {
    function liquidityInitialized() external view returns (bool);
}

/**
 * @title FairDot
 * @notice Testnet prototype for a pool-integrated profit-release token.
 * @dev Contract-address transfers are restricted to the configured pool. This
 *      does not make private/off-chain transfers impossible and is not a
 *      substitute for a production DEX integration or security audit.
 */
contract FairDot is ERC20, ReentrancyGuard, Ownable {
    uint256 public constant RATIO_TRIGGER = 5;
    uint256 public constant RELEASE_DAYS = 10;
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant STAGGER_THRESHOLD_LOW = 1000;
    uint256 public constant STAGGER_THRESHOLD_HIGH = 3000;
    uint256 private constant PRICE_SCALE = 1e18;

    struct UserPosition {
        uint256 avgEntryPrice;
        uint256 totalInvested;
        uint256 trackedTokens;
        uint256 untrackedTokens;
        uint256 lockedProfitStart;
        uint256 lockedProfitTokens;
    }

    struct PricePoint {
        uint256 price;
        uint256 quoteVolume;
        uint256 timestamp;
    }

    struct StaggerSchedule {
        uint256 totalAmount;
        uint256 parts;
        uint256 withdrawn;
        uint256 lastWithdraw;
        uint256 interval;
        uint256 withdrawnAmount;
    }

    mapping(address => UserPosition) public positions;
    mapping(address => StaggerSchedule) public staggerSchedules;
    PricePoint[] public priceHistory;
    uint256 public totalLiquidity;
    address public liquidityPool;
    bool public tradingActive;
    bool public mintDisabled;

    event BuyRecorded(address indexed buyer, uint256 amount, uint256 avgPrice);
    event ProtectionActivated(address indexed user, uint256 ratio);
    event StaggerCreated(address indexed user, uint256 totalTokens, uint256 parts);
    event StaggerWithdrawn(address indexed user, uint256 tokenAmount, uint256 remainingParts);
    event LiquidityPoolSet(address indexed pool);

    constructor(string memory name_, string memory symbol_, uint256 initialSupply_)
        ERC20(name_, symbol_)
        Ownable(msg.sender)
    {
        uint256 supply = initialSupply_ * 10 ** decimals();
        _mint(msg.sender, supply);
        positions[msg.sender].untrackedTokens = supply;
    }

    // Pool and launch configuration. The pool cannot be changed after trading starts.
    function setLiquidityPool(address pool) external onlyOwner {
        require(!tradingActive, "Trading already active");
        require(pool != address(0) && pool.code.length > 0, "Pool must be a contract");
        liquidityPool = pool;
        emit LiquidityPoolSet(pool);
    }

    function updateLiquidity(uint256 totalQuoteLiquidity) external onlyPool {
        totalLiquidity = totalQuoteLiquidity;
    }

    function enableTrading() external onlyOwner {
        require(liquidityPool != address(0), "Pool not set");
        require(IFairDotPoolSeedStatus(liquidityPool).liquidityInitialized(), "Initial liquidity not set");
        require(mintDisabled, "Minting not disabled");
        require(!tradingActive, "Already active");
        tradingActive = true;
    }

    function disableMinting() external onlyOwner {
        require(!mintDisabled, "Already disabled");
        mintDisabled = true;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        require(!mintDisabled, "Minting is disabled");
        _mint(to, amount);
        positions[to].untrackedTokens += amount;
    }

    // Market hooks. Price and volume are both denominated in the same quote asset.
    function recordBuy(address buyer, uint256 amount, uint256 price) external onlyPool {
        require(tradingActive, "Trading not active");
        require(amount > 0 && price > 0, "Invalid buy data");

        UserPosition storage pos = positions[buyer];
        uint256 invested = (amount * price) / PRICE_SCALE;
        pos.totalInvested += invested;
        pos.trackedTokens += amount;
        pos.avgEntryPrice = (pos.totalInvested * PRICE_SCALE) / pos.trackedTokens;

        // A new purchase changes the aggregate position. The pool will start a
        // fresh protection schedule if the new aggregate position is protected.
        pos.lockedProfitStart = 0;
        pos.lockedProfitTokens = 0;
        emit BuyRecorded(buyer, amount, pos.avgEntryPrice);
    }

    function recordPrice(uint256 price, uint256 quoteVolume) external onlyPool {
        require(price > 0 && quoteVolume > 0, "Invalid price data");
        priceHistory.push(PricePoint(price, quoteVolume, block.timestamp));
    }

    function getAvgPrice24h() public view returns (uint256 avgPrice) {
        uint256 totalQuoteVolume;
        uint256 weightedSum;
        uint256 cutoff = block.timestamp > 1 days ? block.timestamp - 1 days : 0;

        for (uint256 i = priceHistory.length; i > 0; i--) {
            PricePoint memory point = priceHistory[i - 1];
            if (point.timestamp < cutoff) break;
            weightedSum += point.price * point.quoteVolume;
            totalQuoteVolume += point.quoteVolume;
        }

        if (totalQuoteVolume == 0) return 0;
        avgPrice = weightedSum / totalQuoteVolume;
    }

    function getCurrentPrice() public view returns (uint256) {
        if (priceHistory.length == 0) return 0;
        return priceHistory[priceHistory.length - 1].price;
    }

    function getEffectivePrice() public view returns (uint256) {
        uint256 average = getAvgPrice24h();
        if (average > 0) return average;

        // Never use an arbitrarily stale price as a fallback.
        if (priceHistory.length == 0) return 0;
        PricePoint memory latest = priceHistory[priceHistory.length - 1];
        if (block.timestamp - latest.timestamp > 1 days) return 0;
        return latest.price;
    }

    function getWithdrawable(address user)
        public
        view
        returns (uint256 withdrawableNow, uint256 lockedRemaining, uint256 currentRatio, uint8 status)
    {
        UserPosition memory pos = positions[user];
        uint256 balance = balanceOf(user);
        if (balance == 0) return (0, 0, 0, 0);
        if (pos.avgEntryPrice == 0 || pos.trackedTokens == 0) return (0, balance, 0, 3);
        uint256 trackedBalance = pos.trackedTokens < balance ? pos.trackedTokens : balance;

        uint256 effectivePrice = getEffectivePrice();
        if (effectivePrice == 0) return (0, balance, 0, 3);

        currentRatio = (effectivePrice * BASIS_POINTS) / pos.avgEntryPrice;
        uint256 capitalTokens = (pos.totalInvested * PRICE_SCALE) / effectivePrice;
        if (capitalTokens > trackedBalance) capitalTokens = trackedBalance;
        uint256 profitTokens = trackedBalance - capitalTokens;

        if (currentRatio < RATIO_TRIGGER * BASIS_POINTS) {
            return (trackedBalance, 0, currentRatio, 0);
        }

        if (pos.lockedProfitStart == 0 || pos.lockedProfitTokens == 0) {
            return (capitalTokens, profitTokens, currentRatio, 1);
        }

        uint256 elapsed = block.timestamp - pos.lockedProfitStart;
        uint256 released;
        if (elapsed >= RELEASE_DAYS * 1 days) {
            released = profitTokens;
            status = 2;
        } else {
            released = (pos.lockedProfitTokens * elapsed) / (RELEASE_DAYS * 1 days);
            status = 1;
        }
        if (released > profitTokens) released = profitTokens;

        withdrawableNow = capitalTokens + released;
        lockedRemaining = profitTokens - released;
        if (withdrawableNow > trackedBalance) {
            withdrawableNow = trackedBalance;
            lockedRemaining = 0;
        }
    }

    function getStaggerInfo(uint256 valueAmount) public view returns (uint256 parts, uint256 interval) {
        if (totalLiquidity == 0) return (1, 0);
        uint256 ratio = (valueAmount * BASIS_POINTS) / totalLiquidity;
        if (ratio <= STAGGER_THRESHOLD_LOW) return (1, 0);
        if (ratio <= STAGGER_THRESHOLD_HIGH) return (3, 8 hours);
        return (10, 1 days);
    }

    // The schedule is bound to a token amount, not a caller-supplied quote value.
    function createStaggerSchedule(uint256 totalTokenAmount) external nonReentrant {
        require(tradingActive, "Trading not active");
        require(totalTokenAmount > 0, "Zero amount");
        require(staggerSchedules[msg.sender].totalAmount == 0, "Schedule exists");
        (uint256 withdrawableNow,,,) = getWithdrawable(msg.sender);
        require(totalTokenAmount <= withdrawableNow, "Amount not withdrawable");

        uint256 effectivePrice = getEffectivePrice();
        require(effectivePrice > 0, "Price unavailable");
        uint256 valueAmount = (totalTokenAmount * effectivePrice) / PRICE_SCALE;
        (uint256 parts, uint256 interval) = getStaggerInfo(valueAmount);
        require(parts > 1, "No stagger needed");

        staggerSchedules[msg.sender] = StaggerSchedule({
            totalAmount: totalTokenAmount,
            parts: parts,
            withdrawn: 0,
            lastWithdraw: 0,
            interval: interval,
            withdrawnAmount: 0
        });
        emit StaggerCreated(msg.sender, totalTokenAmount, parts);
    }

    function validateWithdraw(address user, uint256 amount)
        external
        view
        returns (bool allowed, uint8 reason)
    {
        (uint256 withdrawableNow,,,) = getWithdrawable(user);
        if (amount > withdrawableNow) return (false, 1);

        uint256 effectivePrice = getEffectivePrice();
        if (effectivePrice == 0) return (false, 5);
        uint256 valueAmount = (amount * effectivePrice) / PRICE_SCALE;
        (uint256 requiredParts,) = getStaggerInfo(valueAmount);
        StaggerSchedule memory schedule = staggerSchedules[user];

        if (schedule.totalAmount == 0) {
            if (requiredParts > 1) return (false, 2);
            return (true, 0);
        }
        if (schedule.withdrawn >= schedule.parts) return (false, 3);
        if (schedule.withdrawn > 0 && block.timestamp < schedule.lastWithdraw + schedule.interval) {
            return (false, 4);
        }

        uint256 expectedAmount;
        if (schedule.withdrawn + 1 == schedule.parts) {
            expectedAmount = schedule.totalAmount - schedule.withdrawnAmount;
        } else {
            expectedAmount = schedule.totalAmount / schedule.parts;
        }
        if (amount != expectedAmount) return (false, 6);
        return (true, 0);
    }

    function confirmStaggerWithdraw(address user, uint256 tokenAmount) external onlyPool {
        StaggerSchedule storage schedule = staggerSchedules[user];
        if (schedule.totalAmount == 0) return;
        require(schedule.withdrawn < schedule.parts, "Schedule complete");

        uint256 expectedAmount = schedule.withdrawn + 1 == schedule.parts
            ? schedule.totalAmount - schedule.withdrawnAmount
            : schedule.totalAmount / schedule.parts;
        require(tokenAmount == expectedAmount, "Wrong installment amount");
        if (schedule.withdrawn > 0) {
            require(block.timestamp >= schedule.lastWithdraw + schedule.interval, "Not yet due");
        }

        schedule.withdrawn += 1;
        schedule.withdrawnAmount += tokenAmount;
        schedule.lastWithdraw = block.timestamp;
        emit StaggerWithdrawn(user, tokenAmount, schedule.parts - schedule.withdrawn);
        if (schedule.withdrawn >= schedule.parts) delete staggerSchedules[user];
    }

    // Anyone may start a holder's timer after the 5x trigger. The pool calls
    // this before validating a sell so the timer cannot be skipped by a seller.
    function activateLock(address user) external {
        UserPosition storage pos = positions[user];
        if (pos.avgEntryPrice == 0) return;

        uint256 effectivePrice = getEffectivePrice();
        if (effectivePrice == 0) return;
        uint256 ratio = (effectivePrice * BASIS_POINTS) / pos.avgEntryPrice;
        if (ratio < RATIO_TRIGGER * BASIS_POINTS) {
            pos.lockedProfitStart = 0;
            pos.lockedProfitTokens = 0;
            return;
        }
        if (pos.lockedProfitStart != 0) return;

        uint256 trackedBalance = pos.trackedTokens;
        uint256 actualBalance = balanceOf(user);
        if (trackedBalance > actualBalance) trackedBalance = actualBalance;
        uint256 capitalTokens = (pos.totalInvested * PRICE_SCALE) / effectivePrice;
        if (capitalTokens > trackedBalance) capitalTokens = trackedBalance;
        uint256 profitTokens = trackedBalance - capitalTokens;
        if (profitTokens == 0) return;

        pos.lockedProfitStart = block.timestamp;
        pos.lockedProfitTokens = profitTokens;
        emit ProtectionActivated(user, ratio);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _enforceApprovedPoolRoute(msg.sender, to);
        _inheritPosition(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _enforceApprovedPoolRoute(from, to);
        if (to == liquidityPool && from != liquidityPool) {
            bool isInitialSeed = from == owner()
                && msg.sender == liquidityPool
                && !IFairDotPoolSeedStatus(liquidityPool).liquidityInitialized();
            if (!isInitialSeed) {
                (bool allowed,) = this.validateWithdraw(from, amount);
                require(allowed, "Withdrawal not allowed");
            }
        }
        _inheritPosition(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    function _enforceApprovedPoolRoute(address from, address to) internal view {
        if (from == address(0) || to == address(0)) return;

        if (from == liquidityPool || to == liquidityPool) {
            require(msg.sender == liquidityPool, "Only approved pool may move pool tokens");
            return;
        }
        require(from.code.length == 0 && to.code.length == 0, "Unapproved contract market");
        if (!tradingActive) return;
        require(
            staggerSchedules[from].totalAmount == 0 && staggerSchedules[to].totalAmount == 0,
            "Stagger schedule active"
        );
    }

    function _inheritPosition(address from, address to, uint256 amount) internal {
        if (from == address(0) || to == address(0) || from == to) {
            return;
        }

        UserPosition storage fromPos = positions[from];
        uint256 fromBalance = balanceOf(from);
        if (fromBalance == 0) return;

        // The pool's inventory is untracked. A buy removes inventory here;
        // recordBuy adds tracked basis to the buyer in the same transaction.
        if (from == liquidityPool) {
            require(fromPos.untrackedTokens >= amount, "Pool inventory mismatch");
            fromPos.untrackedTokens -= amount;
            return;
        }

        UserPosition storage toPos = positions[to];

        // Initial owner inventory moves into the pool exactly once and remains
        // untracked. Later pool-bound transfers are sells and consume tracked
        // tokens only; untracked treasury tokens cannot be sold.
        if (to == liquidityPool) {
            bool isInitialSeed = from == owner()
                && !IFairDotPoolSeedStatus(liquidityPool).liquidityInitialized();
            if (isInitialSeed) {
                require(fromPos.untrackedTokens >= amount, "Untracked balance mismatch");
                fromPos.untrackedTokens -= amount;
                toPos.untrackedTokens += amount;
                return;
            }

            require(amount <= fromPos.trackedTokens, "Cannot sell untracked tokens");
            uint256 soldInvested = amount == fromPos.trackedTokens
                ? fromPos.totalInvested
                : (fromPos.totalInvested * amount) / fromPos.trackedTokens;
            uint256 soldLocked = amount == fromPos.trackedTokens
                ? fromPos.lockedProfitTokens
                : (fromPos.lockedProfitTokens * amount) / fromPos.trackedTokens;
            fromPos.totalInvested -= soldInvested;
            fromPos.trackedTokens -= amount;
            fromPos.lockedProfitTokens -= soldLocked;
            toPos.untrackedTokens += amount;
            _refreshEntryPrice(fromPos);
            if (fromPos.trackedTokens == 0) _clearTrackedPosition(fromPos);
            return;
        }

        // Wallet-to-wallet transfers preserve both tracked and untracked token
        // quantities. Any fractional rounding remainder is treated as untracked.
        uint256 movedTracked = amount == fromBalance
            ? fromPos.trackedTokens
            : (fromPos.trackedTokens * amount) / fromBalance;
        if (movedTracked > fromPos.trackedTokens) movedTracked = fromPos.trackedTokens;
        uint256 movedUntracked = amount - movedTracked;
        if (movedUntracked > fromPos.untrackedTokens) {
            movedUntracked = fromPos.untrackedTokens;
            movedTracked = amount - movedUntracked;
        }
        uint256 movedInvested = movedTracked == fromPos.trackedTokens
            ? fromPos.totalInvested
            : (fromPos.totalInvested * movedTracked) / fromPos.trackedTokens;
        uint256 movedLocked = movedTracked == fromPos.trackedTokens
            ? fromPos.lockedProfitTokens
            : (fromPos.lockedProfitTokens * movedTracked) / fromPos.trackedTokens;
        uint256 sourceLockStart = fromPos.lockedProfitStart;

        fromPos.totalInvested -= movedInvested;
        fromPos.trackedTokens -= movedTracked;
        fromPos.untrackedTokens -= movedUntracked;
        fromPos.lockedProfitTokens -= movedLocked;
        _refreshEntryPrice(fromPos);

        toPos.totalInvested += movedInvested;
        toPos.trackedTokens += movedTracked;
        toPos.untrackedTokens += movedUntracked;
        _refreshEntryPrice(toPos);

        if (movedLocked > 0) {
            if (toPos.lockedProfitTokens == 0) {
                toPos.lockedProfitStart = sourceLockStart;
                toPos.lockedProfitTokens = movedLocked;
            } else {
                if (sourceLockStart > toPos.lockedProfitStart) toPos.lockedProfitStart = sourceLockStart;
                toPos.lockedProfitTokens += movedLocked;
            }
        }

        if (fromPos.trackedTokens == 0) _clearTrackedPosition(fromPos);
    }

    function _refreshEntryPrice(UserPosition storage pos) internal {
        if (pos.trackedTokens == 0) {
            pos.avgEntryPrice = 0;
        } else {
            pos.avgEntryPrice = (pos.totalInvested * PRICE_SCALE) / pos.trackedTokens;
        }
    }

    function _clearTrackedPosition(UserPosition storage pos) internal {
        pos.avgEntryPrice = 0;
        pos.totalInvested = 0;
        pos.trackedTokens = 0;
        pos.lockedProfitStart = 0;
        pos.lockedProfitTokens = 0;
    }

    function getUserInfo(address user)
        external
        view
        returns (
            uint256 balance,
            uint256 avgEntryPrice,
            uint256 totalInvested,
            uint256 effectivePrice,
            uint256 ratioX,
            uint256 withdrawableNow,
            uint256 lockedRemaining,
            uint256 daysUntilFullRelease
        )
    {
        balance = balanceOf(user);
        UserPosition memory pos = positions[user];
        avgEntryPrice = pos.avgEntryPrice;
        totalInvested = pos.totalInvested;
        effectivePrice = getEffectivePrice();
        if (avgEntryPrice > 0 && effectivePrice > 0) {
            ratioX = (effectivePrice * BASIS_POINTS) / avgEntryPrice / BASIS_POINTS;
        }
        (withdrawableNow, lockedRemaining,,) = getWithdrawable(user);
        if (pos.lockedProfitStart > 0 && pos.lockedProfitTokens > 0) {
            uint256 duration = RELEASE_DAYS * 1 days;
            uint256 elapsed = block.timestamp - pos.lockedProfitStart;
            if (elapsed < duration) daysUntilFullRelease = (duration - elapsed) / 1 days;
        }
    }

    modifier onlyPool() {
        require(msg.sender == liquidityPool && liquidityPool != address(0), "Only approved pool");
        _;
    }
}
