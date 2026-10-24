// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title FairDot
 * @notice Fair & protected memecoin platform - Portaldot V3 EVM
 *
 * Core principle: A user's PRINCIPAL is ALWAYS freely withdrawable. Only outsized
 * profits (>= 5x above entry price) are released gradually - 10% per day over 10 days -
 * so no single holder can dump all gains at once and crash the market.
 *
 * Network: Portaldot V3 EVM - Chain ID: 420420777
 * Storage-lean: PortaldotV3 charges a storage deposit per byte of deployed code,
 * so this contract is optimized for size (optimizer runs=1, viaIR, no metadata).
 */
contract FairDot is ERC20, ReentrancyGuard, Ownable {
    // ============================================================
    // CONSTANTS
    // ============================================================
    uint256 public constant RATIO_TRIGGER = 5;
    uint256 public constant RELEASE_DAYS = 10;
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant STAGGER_THRESHOLD_LOW = 1000;
    uint256 public constant STAGGER_THRESHOLD_HIGH = 3000;

    // ============================================================
    // STRUCTS
    // ============================================================
    struct UserPosition {
        uint256 avgEntryPrice;
        uint256 totalInvested;
        uint256 lockedProfitStart;
        uint256 lockedProfitTokens;
    }

    struct PricePoint {
        uint256 price;
        uint256 volume;
        uint256 timestamp;
    }

    struct StaggerSchedule {
        uint256 totalAmount;
        uint256 parts;
        uint256 withdrawn;
        uint256 lastWithdraw;
        uint256 interval;
    }

    // ============================================================
    // STATE
    // ============================================================
    mapping(address => UserPosition) public positions;
    mapping(address => StaggerSchedule) public staggerSchedules;
    PricePoint[] public priceHistory;
    uint256 public totalLiquidity;
    address public liquidityPool;
    bool public tradingActive = false;
    bool public mintDisabled = false;

    // ============================================================
    // EVENTS
    // ============================================================
    event BuyRecorded(address indexed buyer, uint256 amount, uint256 avgPrice);
    event ProtectionActivated(address indexed user, uint256 ratio);
    event StaggerCreated(address indexed user, uint256 total, uint256 parts);
    event StaggerWithdrawn(address indexed user, uint256 part, uint256 remaining);

    // ============================================================
    // CONSTRUCTOR
    // ============================================================
    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        _mint(msg.sender, initialSupply_ * 10 ** decimals());
    }

    // ============================================================
    // ADMIN
    // ============================================================
    function setLiquidityPool(address _pool) external onlyOwner {
        liquidityPool = _pool;
    }

    function updateLiquidity(uint256 _totalLiquidity) external {
        require(msg.sender == liquidityPool, "Only liquidity pool");
        totalLiquidity = _totalLiquidity;
    }

    function enableTrading() external onlyOwner {
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
    }

    // ============================================================
    // BUY & PRICE RECORDING
    // ============================================================
    function recordBuy(address buyer, uint256 amount, uint256 price) external {
        require(msg.sender == liquidityPool, "Only liquidity pool");
        require(tradingActive, "Trading not active");
        require(amount > 0, "Zero amount");

        UserPosition storage pos = positions[buyer];
        uint256 newInvested = (amount * price) / (10 ** decimals());

        if (pos.totalInvested + newInvested > 0) {
            uint256 oldTotal = pos.avgEntryPrice * pos.totalInvested;
            uint256 addTotal = price * newInvested;
            pos.avgEntryPrice = (oldTotal + addTotal) / (pos.totalInvested + newInvested);
        } else {
            pos.avgEntryPrice = price;
        }

        pos.totalInvested += newInvested;
        if (pos.lockedProfitTokens == 0) pos.lockedProfitStart = 0;
        emit BuyRecorded(buyer, amount, pos.avgEntryPrice);
    }

    function recordPrice(uint256 price, uint256 volume) external {
        require(msg.sender == liquidityPool, "Only liquidity pool");
        require(price > 0, "Zero price");
        priceHistory.push(PricePoint(price, volume, block.timestamp));
    }

    // ============================================================
    // PRICE CALCULATION
    // ============================================================
    function getAvgPrice24h() public view returns (uint256 avgPrice) {
        uint256 totalVolume;
        uint256 weightedSum;
        uint256 cutoff = block.timestamp - 1 days;
        for (uint256 i = priceHistory.length; i > 0; i--) {
            PricePoint memory pt = priceHistory[i - 1];
            if (pt.timestamp < cutoff) break;
            weightedSum += pt.price * pt.volume;
            totalVolume += pt.volume;
        }
        if (totalVolume == 0) return 0;
        avgPrice = weightedSum / totalVolume;
    }

    function getCurrentPrice() public view returns (uint256) {
        if (priceHistory.length == 0) return 0;
        return priceHistory[priceHistory.length - 1].price;
    }

    function getEffectivePrice() public view returns (uint256) {
        uint256 avg = getAvgPrice24h();
        return avg > 0 ? avg : getCurrentPrice();
    }

    // ============================================================
    // WITHDRAWABLE CALCULATION
    // ============================================================
    function getWithdrawable(address user) public view returns (
        uint256 withdrawableNow,
        uint256 lockedRemaining,
        uint256 currentRatio,
        uint8 status
    ) {
        UserPosition memory pos = positions[user];
        uint256 balance = balanceOf(user);
        if (balance == 0 || pos.avgEntryPrice == 0) return (balance, 0, 0, 0);

        uint256 effPrice = getEffectivePrice();
        if (effPrice == 0) return (balance, 0, 0, 0);

        currentRatio = (effPrice * BASIS_POINTS) / pos.avgEntryPrice;
        uint256 ratioX = currentRatio / BASIS_POINTS;

        uint256 capitalTokens = (pos.totalInvested * (10 ** decimals())) / effPrice;
        if (capitalTokens > balance) capitalTokens = balance;
        uint256 profitTokens = balance - capitalTokens;

        if (ratioX < RATIO_TRIGGER) return (balance, 0, currentRatio, 0);

        if (pos.lockedProfitStart == 0 || pos.lockedProfitTokens == 0) {
            return (capitalTokens, profitTokens, currentRatio, 1);
        }

        uint256 elapsed = (block.timestamp - pos.lockedProfitStart) / 1 days;
        uint256 released;
        if (elapsed >= RELEASE_DAYS) {
            released = pos.lockedProfitTokens;
            status = 2;
        } else {
            released = (pos.lockedProfitTokens * elapsed) / RELEASE_DAYS;
            status = 1;
        }
        if (released > profitTokens) released = profitTokens;

        withdrawableNow = capitalTokens + released;
        lockedRemaining = profitTokens - released;
        if (withdrawableNow > balance) {
            withdrawableNow = balance;
            lockedRemaining = 0;
        }
    }

    // ============================================================
    // STAGGERED WITHDRAWAL
    // ============================================================
    function getStaggerInfo(uint256 valueAmount) public view returns (uint256 parts, uint256 interval) {
        if (totalLiquidity == 0) return (1, 0);
        uint256 ratio = (valueAmount * BASIS_POINTS) / totalLiquidity;
        if (ratio <= STAGGER_THRESHOLD_LOW) return (1, 0);
        if (ratio <= STAGGER_THRESHOLD_HIGH) return (3, 8 hours);
        return (10, 1 days);
    }

    function createStaggerSchedule(uint256 totalValue) external nonReentrant {
        require(tradingActive, "Trading not active");
        require(totalValue > 0, "Zero value");
        require(staggerSchedules[msg.sender].totalAmount == 0, "Schedule exists");
        (uint256 parts, uint256 intv) = getStaggerInfo(totalValue);
        require(parts > 1, "No stagger needed - withdraw directly");
        staggerSchedules[msg.sender] = StaggerSchedule(totalValue, parts, 0, block.timestamp, intv);
        emit StaggerCreated(msg.sender, totalValue, parts);
    }

    // ============================================================
    // VALIDATION & CONFIRMATION (called by Pool)
    // ============================================================
    function validateWithdraw(
        address user,
        uint256 amount
    ) external view returns (bool allowed, uint8 reason) {
        (uint256 withdrawableNow, , , ) = getWithdrawable(user);

        if (amount > withdrawableNow) {
            return (false, 1);
        }

        uint256 effectivePrice = getEffectivePrice();
        if (effectivePrice > 0 && totalLiquidity > 0) {
            uint256 valueAmount = (amount * effectivePrice) / (10 ** decimals());
            (uint256 parts, ) = getStaggerInfo(valueAmount);
            if (parts > 1) {
                StaggerSchedule memory sched = staggerSchedules[user];
                if (sched.totalAmount == 0) return (false, 2);
                if (sched.withdrawn >= sched.parts) return (false, 3);
                if (block.timestamp < sched.lastWithdraw + sched.interval) return (false, 4);
            }
        }
        return (true, 0);
    }

    function confirmStaggerWithdraw(address user, uint256 partValue) external {
        require(msg.sender == liquidityPool, "Only liquidity pool");
        StaggerSchedule storage sched = staggerSchedules[user];
        require(sched.totalAmount > 0, "No schedule");
        require(sched.withdrawn < sched.parts, "Schedule complete");
        require(block.timestamp >= sched.lastWithdraw + sched.interval, "Not yet due");

        sched.withdrawn += 1;
        sched.lastWithdraw = block.timestamp;
        emit StaggerWithdrawn(user, partValue, sched.parts - sched.withdrawn);

        if (sched.withdrawn >= sched.parts) delete staggerSchedules[user];
    }

    function activateLock(address user) external {
        require(msg.sender == liquidityPool, "Only liquidity pool");
        UserPosition storage pos = positions[user];
        require(pos.lockedProfitStart == 0, "Lock already active");

        uint256 effPrice = getEffectivePrice();
        uint256 bal = balanceOf(user);
        uint256 cap = (pos.totalInvested * (10 ** decimals())) / effPrice;
        if (cap > bal) cap = bal;
        uint256 profit = bal - cap;
        require(profit > 0, "No profit to lock");

        pos.lockedProfitStart = block.timestamp;
        pos.lockedProfitTokens = profit;
        emit ProtectionActivated(user, (effPrice * BASIS_POINTS) / pos.avgEntryPrice);
    }

    // ============================================================
    // TRANSFER INHERITANCE
    // ============================================================
    function transfer(address to, uint256 amount) public override returns (bool) {
        _inheritPosition(msg.sender, to, amount);
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _inheritPosition(from, to, amount);
        return super.transferFrom(from, to, amount);
    }

    function _inheritPosition(address from, address to, uint256 amount) internal {
        if (!tradingActive || from == address(0) || to == address(0)) return;
        UserPosition storage fromPos = positions[from];
        uint256 fromBal = balanceOf(from);
        if (fromPos.avgEntryPrice == 0 || fromBal == 0) return;

        uint256 share = (amount * BASIS_POINTS) / (fromBal + amount);
        uint256 inherited = (fromPos.totalInvested * share) / BASIS_POINTS;
        if (inherited == 0) return;

        UserPosition storage toPos = positions[to];
        if (toPos.totalInvested > 0) {
            toPos.avgEntryPrice = (
                toPos.avgEntryPrice * toPos.totalInvested +
                fromPos.avgEntryPrice * inherited
            ) / (toPos.totalInvested + inherited);
        } else {
            toPos.avgEntryPrice = fromPos.avgEntryPrice;
        }
        toPos.totalInvested += inherited;
        fromPos.totalInvested -= inherited;

        if (fromPos.totalInvested == 0) {
            fromPos.avgEntryPrice = 0;
            fromPos.lockedProfitStart = 0;
            fromPos.lockedProfitTokens = 0;
        }
    }

    // ============================================================
    // USER INFO (FOR FRONTEND)
    // ============================================================
    function getUserInfo(address user) external view returns (
        uint256 balance,
        uint256 avgEntryPrice,
        uint256 totalInvested,
        uint256 effectivePrice,
        uint256 ratioX,
        uint256 withdrawableNow,
        uint256 lockedRemaining,
        uint256 daysUntilFullRelease
    ) {
        balance = balanceOf(user);
        UserPosition memory pos = positions[user];
        avgEntryPrice = pos.avgEntryPrice;
        totalInvested = pos.totalInvested;
        effectivePrice = getEffectivePrice();

        if (avgEntryPrice > 0 && effectivePrice > 0) {
            ratioX = (effectivePrice * BASIS_POINTS) / avgEntryPrice / BASIS_POINTS;
        }

        (withdrawableNow, lockedRemaining, , ) = getWithdrawable(user);

        if (pos.lockedProfitStart > 0 && pos.lockedProfitTokens > 0) {
            uint256 elapsed = block.timestamp - pos.lockedProfitStart;
            uint256 totalDur = RELEASE_DAYS * 1 days;
            if (elapsed < totalDur) {
                daysUntilFullRelease = (totalDur - elapsed) / 1 days;
            }
        }
    }
}
