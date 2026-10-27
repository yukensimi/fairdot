// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IFairDotPoolSeedStatus {
    function liquidityInitialized() external view returns (bool);
    function hasActiveSchedule(address user) external view returns (bool);
}

/** One token and one immutable canonical pool per memecoin. */
contract FairDot is ERC20, Ownable {
    uint256 public constant RATIO_TRIGGER = 5;
    uint256 public constant RELEASE_DAYS = 10;
    uint256 public constant BASIS_POINTS = 10_000;
    uint256 public constant PRECISION = 1e18;
    uint256 public constant STALE_EMERGENCY_DELAY = 7 days;
    uint256 public constant EMERGENCY_QUOTA_BPS = 1_000;
    uint256 private constant MAX_CLOCK_STEP = 1 days;

    struct Lot {
        uint256 quantity;
        uint256 quoteBasis;
        uint64 purchaseDay;
        uint64 checkpointActiveTime;
        uint256 checkpointProfit;
        uint256 releasedProfit;
        // Principal is a checkpoint-time token-quantity budget and cannot be recycled after sales.
        uint256 principalBudget;
        uint256 principalConsumed;
        bool checkpointed;
        bool mergeable;
    }
    struct UserPosition {
        uint256 avgEntryPrice;
        uint256 totalInvested;
        uint256 trackedTokens;
        uint256 untrackedTokens;
        uint256 lockedProfitStart;
        uint256 lockedProfitTokens;
    }
    struct PricePoint { uint256 price; uint256 quoteVolume; uint256 timestamp; }
    struct EmergencyState { uint256 snapshot; uint256 used; uint256 windowStart; uint256 priceSnapshot; }
    struct EmergencySale { uint64 timestamp; uint256 amount; }

    mapping(address => Lot[]) private _lots;
    mapping(address => UserPosition) private _positions;
    mapping(address => EmergencyState) public emergencyState;
    mapping(address => EmergencySale[]) private _emergencySales;
    PricePoint[] public priceHistory;
    address public liquidityPool;
    bool public tradingActive;
    bool public mintDisabled;
    bool public minVolumeConfigured;
    uint256 public minVolumeBps;
    uint256 public minVolumeAbsolute;
    uint256 public initialQuoteSeed;
    uint256 public activeClock;
    uint256 public lastObservationTimestamp;
    uint256 public quoteReserve;
    uint256 public lastBuyTimestamp;

    event BuyRecorded(address indexed buyer, uint256 amount, uint256 quotePaid, uint256 lotIndex);
    event ProtectionActivated(address indexed user, uint256 indexed lotIndex, uint256 ratio);
    event LiquidityPoolSet(address indexed pool);
    event MinVolumeConfigured(uint256 minVolumeBps, uint256 minVolumeAbsolute);
    event LotTransferred(address indexed from, address indexed to, uint256 quantity, uint256 quoteBasis, uint256 lotIndex);

    constructor(string memory name_, string memory symbol_, uint256 initialSupply_)
        ERC20(name_, symbol_) Ownable(msg.sender)
    {
        uint256 supply = initialSupply_ * 10 ** decimals();
        _mint(msg.sender, supply);
        _positions[msg.sender].untrackedTokens = supply;
    }

    function positions(address user) external view returns (UserPosition memory) { return _positionView(user); }
    function getLotCount(address user) external view returns (uint256) { return _lots[user].length; }
    function lots(address user, uint256 index) external view returns (Lot memory) { return _lots[user][index]; }

    function setLiquidityPool(address pool) external onlyOwner {
        require(!tradingActive, "Trading already active");
        require(liquidityPool == address(0), "Pool already set");
        require(pool != address(0) && pool.code.length > 0, "Pool must be a contract");
        liquidityPool = pool;
        emit LiquidityPoolSet(pool);
    }
    function setMinVolumeParameters(uint256 bps, uint256 absolute) external onlyOwner {
        require(!tradingActive, "Trading already active");
        require(bps <= BASIS_POINTS, "Bps too high");
        minVolumeBps = bps;
        minVolumeAbsolute = absolute;
        minVolumeConfigured = true;
        emit MinVolumeConfigured(bps, absolute);
    }
    function updateLiquidity(uint256 reserve) external onlyPool { quoteReserve = reserve; }
    function recordSeed(uint256 seed) external onlyPool {
        require(initialQuoteSeed == 0, "Seed already recorded");
        require(seed > 0, "Zero seed");
        initialQuoteSeed = seed;
    }
    function enableTrading() external onlyOwner {
        require(liquidityPool != address(0), "Pool not set");
        require(IFairDotPoolSeedStatus(liquidityPool).liquidityInitialized(), "Initial liquidity not set");
        require(mintDisabled, "Minting not disabled");
        require(minVolumeConfigured, "Min volume not configured");
        require(!tradingActive, "Already active");
        tradingActive = true;
    }
    function disableMinting() external onlyOwner { require(!mintDisabled, "Already disabled"); mintDisabled = true; }
    function mint(address to, uint256 amount) external onlyOwner {
        require(!mintDisabled, "Minting is disabled");
        _mint(to, amount);
        _positions[to].untrackedTokens += amount;
    }

    // quotePaid is actual quote spent rather than a rounded price-times-quantity estimate.
    function recordBuy(address buyer, uint256 amount, uint256 quotePaid) external onlyPool {
        require(tradingActive, "Trading not active");
        require(amount > 0 && quotePaid > 0, "Invalid buy data");
        Lot[] storage a = _lots[buyer];
        uint64 day = uint64(block.timestamp / 1 days);
        if (a.length > 0) {
            uint256 lastIndex = a.length - 1;
            Lot storage lastLot = a[lastIndex];
            if (lastLot.quantity > 0 && lastLot.purchaseDay == day && !lastLot.checkpointed && lastLot.mergeable) {
                lastLot.quantity += amount;
                lastLot.quoteBasis += quotePaid;
                emit BuyRecorded(buyer, amount, quotePaid, lastIndex);
                _syncPosition(buyer);
                lastBuyTimestamp = block.timestamp;
                return;
            }
        }
        a.push(Lot(amount, quotePaid, day, 0, 0, 0, 0, 0, false, true));
        emit BuyRecorded(buyer, amount, quotePaid, a.length - 1);
        _syncPosition(buyer);
        lastBuyTimestamp = block.timestamp;
    }
    function recordPrice(uint256 price, uint256 volume) external onlyPool {
        require(price > 0 && volume > 0, "Invalid price data");
        if (lastObservationTimestamp != 0) {
            uint256 gap = block.timestamp - lastObservationTimestamp;
            activeClock += gap > MAX_CLOCK_STEP ? MAX_CLOCK_STEP : gap;
        }
        lastObservationTimestamp = block.timestamp;
        priceHistory.push(PricePoint(price, volume, block.timestamp));
    }
    function checkpointLock(address user) external onlyPool {
        uint256 price = getEffectivePrice();
        if (price == 0) {
            if (_isEmergencyStale()) _startEmergency(user);
            return;
        }
        EmergencyState storage emergency = emergencyState[user];
        if (emergency.windowStart != 0) {
            // Only an explicit checkpoint after a fresh BUY may clear emergency mode.
            if (lastBuyTimestamp <= emergency.windowStart) return;
            delete emergencyState[user];
            delete _emergencySales[user];
        }
        uint256 activeNow = activeClockNow();
        Lot[] storage a = _lots[user];
        for (uint256 i; i < a.length; ++i) {
            Lot storage lot = a[i];
            if (lot.quantity > 0) _persistReleased(lot, price, true, activeNow);
        }
        if (!_volumeThresholdMet(getQuoteVolume24h())) { _syncPosition(user); return; }
        for (uint256 i; i < a.length; ++i) {
            Lot storage lot = a[i];
            if (lot.quantity == 0 || lot.checkpointed || !_triggerMet(lot, price)) continue;
            lot.principalBudget = _principal(lot, price);
            lot.principalConsumed = 0;
            lot.checkpointProfit = lot.quantity - lot.principalBudget;
            lot.checkpointActiveTime = uint64(activeNow);
            lot.checkpointed = true;
            emit ProtectionActivated(user, i, price * BASIS_POINTS / _entryPrice(lot));
        }
        _syncPosition(user);
    }
    function _startEmergency(address user) private {
        EmergencyState storage e = emergencyState[user];
        if (e.windowStart == 0) {
            e.snapshot = _positionView(user).trackedTokens;
            e.windowStart = block.timestamp;
            e.priceSnapshot = getCurrentPrice();
            if (e.priceSnapshot != 0) {
                uint256 activeNow = activeClockNow();
                Lot[] storage a = _lots[user];
                for (uint256 i; i < a.length; ++i) {
                    Lot storage lot = a[i];
                    if (lot.quantity == 0 || lot.checkpointed) continue;
                    lot.principalBudget = _principal(lot, e.priceSnapshot);
                    lot.checkpointProfit = lot.quantity - lot.principalBudget;
                    lot.checkpointActiveTime = uint64(activeNow);
                    lot.checkpointed = true;
                }
                _syncPosition(user);
            }
        }
    }

    function getQuoteVolume24h() public view returns (uint256 volume) {
        uint256 cutoff = block.timestamp > 1 days ? block.timestamp - 1 days : 0;
        for (uint256 i = priceHistory.length; i > 0; --i) {
            PricePoint memory p = priceHistory[i - 1];
            if (p.timestamp < cutoff) break;
            volume += p.quoteVolume;
        }
    }
    function volumeThreshold() public view returns (uint256) {
        uint256 proportional = minVolumeBps * initialQuoteSeed / BASIS_POINTS;
        return proportional > minVolumeAbsolute ? proportional : minVolumeAbsolute;
    }
    function getCurrentPrice() public view returns (uint256) {
        return priceHistory.length == 0 ? 0 : priceHistory[priceHistory.length - 1].price;
    }
    function getEffectivePrice() public view returns (uint256) {
        if (priceHistory.length == 0 || block.timestamp - lastObservationTimestamp > 1 days) return 0;
        uint256 volume;
        uint256 weighted;
        uint256 cutoff = block.timestamp > 1 days ? block.timestamp - 1 days : 0;
        for (uint256 i = priceHistory.length; i > 0; --i) {
            PricePoint memory p = priceHistory[i - 1];
            if (p.timestamp < cutoff) break;
            volume += p.quoteVolume;
            weighted += p.price * p.quoteVolume;
        }
        return volume == 0 ? 0 : weighted / volume;
    }
    function activeClockNow() public view returns (uint256) {
        if (lastObservationTimestamp == 0) return activeClock;
        uint256 gap = block.timestamp - lastObservationTimestamp;
        return activeClock + (gap > MAX_CLOCK_STEP ? MAX_CLOCK_STEP : gap);
    }

    function getWithdrawable(address user)
        public view returns (uint256 withdrawableNow, uint256 lockedRemaining, uint256 currentRatio, uint8 status)
    {
        UserPosition memory pos = _positionView(user);
        if (pos.trackedTokens == 0) return (0, 0, 0, 3);
        EmergencyState memory emergency = emergencyState[user];
        if (emergency.windowStart != 0) {
            if (emergency.snapshot == 0 || emergency.priceSnapshot == 0) return (0, pos.trackedTokens, 0, 4);
            Lot[] storage emergencyLots = _lots[user];
            for (uint256 i; i < emergencyLots.length; ++i) {
                Lot storage lot = emergencyLots[i];
                if (lot.quantity == 0) continue;
                uint256 entry = _entryPrice(lot);
                if (entry != 0) currentRatio = emergency.priceSnapshot * BASIS_POINTS / entry;
                withdrawableNow += _principalAvailable(lot, emergency.priceSnapshot);
            }
            uint256 cap = emergency.snapshot * EMERGENCY_QUOTA_BPS / BASIS_POINTS;
            uint256 used = _rollingEmergencyUsed(user);
            uint256 remaining = cap > used ? cap - used : 0;
            if (withdrawableNow > remaining) withdrawableNow = remaining;
            lockedRemaining = pos.trackedTokens - withdrawableNow;
            return (withdrawableNow, lockedRemaining, currentRatio, 4);
        }
        if (getEffectivePrice() == 0 && _isEmergencyStale())
            return (0, pos.trackedTokens, 0, 3);
        uint256 price = getEffectivePrice();
        if (price == 0) price = getCurrentPrice(); // stale price is principal/emergency reference only, never a checkpoint trigger
        if (price == 0) return (0, pos.trackedTokens, 0, 3);
        bool fresh = getEffectivePrice() != 0;
        uint256 activeNow = activeClockNow();
        Lot[] storage a = _lots[user];
        for (uint256 i; i < a.length; ++i) {
            Lot storage lot = a[i];
            if (lot.quantity == 0) continue;
            uint256 entry = _entryPrice(lot);
            bool locked = lot.checkpointed && !(fresh && !_triggerMet(lot, price));
            uint256 eligible;
            if (!locked) eligible = lot.quantity;
            else {
                eligible = _principalAvailable(lot, price) + _releasedNow(lot, price, activeNow, !fresh || _triggerMet(lot, price));
                if (eligible > lot.quantity) eligible = lot.quantity;
                lockedRemaining += lot.quantity - eligible;
                status = 1;
            }
            withdrawableNow += eligible;
            if (entry != 0) currentRatio = price * BASIS_POINTS / entry;
        }
        if (lockedRemaining == 0) status = 0;
    }
    function validateSell(address user, uint256 amount) external view onlyPool returns (bool) {
        (uint256 available,,,) = getWithdrawable(user);
        return amount > 0 && amount <= available;
    }
    function consumeEmergencyQuota(address user, uint256 amount) external onlyPool {
        EmergencyState storage e = emergencyState[user];
        if (e.windowStart == 0) return;
        _emergencySales[user].push(EmergencySale(uint64(block.timestamp), amount));
        e.used = _rollingEmergencyUsed(user);
    }
    function getStaggerInfo(uint256 quoteValue) public view returns (uint256 parts, uint256 interval) {
        if (quoteReserve == 0) return (1, 0);
        if (quoteValue * BASIS_POINTS <= quoteReserve * 1_000) return (1, 0);
        if (quoteValue * BASIS_POINTS <= quoteReserve * 3_000) return (3, 8 hours);
        return (10, 1 days);
    }
    function getUserInfo(address user) external view returns (
        uint256 balance, uint256 avgEntryPrice, uint256 totalInvested, uint256 effectivePrice,
        uint256 ratioX, uint256 withdrawableNow, uint256 lockedRemaining, uint256 daysUntilFullRelease
    ) {
        UserPosition memory p = _positionView(user);
        balance = balanceOf(user); avgEntryPrice = p.avgEntryPrice; totalInvested = p.totalInvested;
        effectivePrice = getEffectivePrice();
        if (avgEntryPrice > 0 && effectivePrice > 0) ratioX = effectivePrice / avgEntryPrice;
        (withdrawableNow, lockedRemaining,,) = getWithdrawable(user);
        if (lockedRemaining > 0) daysUntilFullRelease = RELEASE_DAYS;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            _enforceRoute(from, to);
            if (from != liquidityPool && to != liquidityPool && tradingActive) {
                require(!IFairDotPoolSeedStatus(liquidityPool).hasActiveSchedule(from), "Stagger schedule active");
                require(!IFairDotPoolSeedStatus(liquidityPool).hasActiveSchedule(to), "Stagger schedule active");
            }
            if (from == liquidityPool) {
                UserPosition storage poolPos = _positions[from];
                require(poolPos.untrackedTokens >= amount, "Pool inventory mismatch");
                poolPos.untrackedTokens -= amount;
            } else if (to == liquidityPool) {
                bool seed = from == owner() && msg.sender == liquidityPool
                    && !IFairDotPoolSeedStatus(liquidityPool).liquidityInitialized();
                if (seed) {
                    require(_positions[from].untrackedTokens >= amount, "Untracked balance mismatch");
                    _positions[from].untrackedTokens -= amount;
                    _positions[to].untrackedTokens += amount;
                } else {
                    _consumeLots(from, amount);
                    _positions[to].untrackedTokens += amount;
                }
            } else _moveLots(from, to, amount);
        }
        super._update(from, to, amount);
    }
    function _enforceRoute(address from, address to) private view {
        if (from == liquidityPool || to == liquidityPool) {
            require(msg.sender == liquidityPool, "Only approved pool may move pool tokens");
            return;
        }
        // A Factory may distribute the non-seeded, untracked initial allocation to the
        // creator before launch. This exception is unavailable after trading begins.
        if (!tradingActive && from == owner() && msg.sender == owner() && to.code.length == 0) return;
        require(from.code.length == 0 && to.code.length == 0, "Unapproved contract market");
    }
    function _moveLots(address from, address to, uint256 amount) private {
        _persistUserReleases(from);
        uint256 remaining = amount;
        Lot[] storage src = _lots[from];
        Lot[] storage dst = _lots[to];
        for (uint256 i; i < src.length && remaining > 0; ++i) {
            Lot storage lot = src[i];
            if (lot.quantity == 0) continue;
            uint256 moved = lot.quantity < remaining ? lot.quantity : remaining;
            uint256 basis = moved == lot.quantity ? lot.quoteBasis : lot.quoteBasis * moved / lot.quantity;
            uint256 profit = moved == lot.quantity ? lot.checkpointProfit : lot.checkpointProfit * moved / lot.quantity;
            uint256 released = moved == lot.quantity ? lot.releasedProfit : lot.releasedProfit * moved / lot.quantity;
            uint256 principalBudget = moved == lot.quantity ? lot.principalBudget : lot.principalBudget * moved / lot.quantity;
            uint256 principalConsumed = moved == lot.quantity ? lot.principalConsumed : lot.principalConsumed * moved / lot.quantity;
            lot.quantity -= moved; lot.quoteBasis -= basis; lot.checkpointProfit -= profit; lot.releasedProfit -= released;
            lot.principalBudget -= principalBudget; lot.principalConsumed -= principalConsumed;
            dst.push(Lot(moved, basis, lot.purchaseDay, lot.checkpointActiveTime, profit, released,
                principalBudget, principalConsumed, lot.checkpointed, false));
            emit LotTransferred(from, to, moved, basis, dst.length - 1);
            remaining -= moved;
        }
        uint256 trackedMoved = amount - remaining;
        require(trackedMoved + _positions[from].untrackedTokens >= amount, "Untracked balance mismatch");
        _positions[from].untrackedTokens -= amount - trackedMoved;
        _positions[to].untrackedTokens += amount - trackedMoved;
        _syncPosition(from); _syncPosition(to);
    }
    function _consumeLots(address user, uint256 amount) private {
        require(amount <= _positionView(user).trackedTokens, "Cannot sell untracked tokens");
        (uint256 eligible,,,) = getWithdrawable(user);
        require(amount <= eligible, "Withdrawal not allowed");
        _persistUserReleases(user);
        EmergencyState memory emergency = emergencyState[user];
        uint256 price = emergency.windowStart != 0 ? emergency.priceSnapshot : getEffectivePrice();
        if (price == 0) price = getCurrentPrice();
        bool fresh = emergency.windowStart == 0 && getEffectivePrice() != 0;
        uint256 activeNow = activeClockNow();
        uint256 remaining = amount;
        Lot[] storage a = _lots[user];
        // FIFO among eligible lots; locked portions in older lots are skipped.
        for (uint256 i; i < a.length && remaining > 0; ++i) {
            Lot storage lot = a[i];
            if (lot.quantity == 0) continue;
            uint256 available = emergency.windowStart != 0
                ? (lot.checkpointed ? _principalAvailable(lot, price) : lot.quantity)
                : _eligibleLot(lot, price, fresh, activeNow);
            if (available == 0) continue;
            uint256 taken = available < remaining ? available : remaining;
            uint256 basis = taken == lot.quantity ? lot.quoteBasis : lot.quoteBasis * taken / lot.quantity;
            uint256 principalAvailable = lot.checkpointed ? _principalAvailable(lot, price) : 0;
            uint256 principalTaken = taken < principalAvailable ? taken : principalAvailable;
            uint256 profitTaken = taken - principalTaken;
            lot.quantity -= taken;
            lot.quoteBasis -= basis;
            if (lot.checkpointed && profitTaken > 0) {
                require(profitTaken <= lot.releasedProfit, "Profit not released");
                lot.checkpointProfit -= profitTaken;
                lot.releasedProfit -= profitTaken;
            }
            lot.principalConsumed += principalTaken;
            remaining -= taken;
        }
        require(remaining == 0, "Withdrawal not allowed");
        _syncPosition(user);
    }
    function _persistUserReleases(address user) private {
        if (emergencyState[user].windowStart != 0) return;
        uint256 price = getEffectivePrice();
        if (price == 0) price = getCurrentPrice();
        if (price == 0) return;
        bool fresh = getEffectivePrice() != 0;
        uint256 activeNow = activeClockNow();
        Lot[] storage a = _lots[user];
        for (uint256 i; i < a.length; ++i) if (a[i].quantity > 0) _persistReleased(a[i], price, !fresh || _triggerMet(a[i], price), activeNow);
    }
    function _persistReleased(Lot storage lot, uint256 price, bool volumeMet, uint256 activeNow) private {
        if (!lot.checkpointed) return;
        uint256 released = _releasedNow(lot, price, activeNow, volumeMet && _triggerMet(lot, price));
        if (released > lot.releasedProfit) lot.releasedProfit = released;
    }
    function _releasedNow(Lot storage lot, uint256, uint256 activeNow, bool triggered) private view returns (uint256) {
        if (!lot.checkpointed || lot.checkpointProfit == 0) return 0;
        if (!triggered) return lot.checkpointProfit;
        uint256 elapsed = activeNow > lot.checkpointActiveTime ? activeNow - lot.checkpointActiveTime : 0;
        uint256 linear = elapsed >= RELEASE_DAYS * 1 days
            ? lot.checkpointProfit : lot.checkpointProfit * elapsed / (RELEASE_DAYS * 1 days);
        return linear > lot.releasedProfit ? linear : lot.releasedProfit;
    }
    function _eligibleLot(Lot storage lot, uint256 price, bool fresh, uint256 activeNow) private view returns (uint256) {
        if (!lot.checkpointed || (fresh && !_triggerMet(lot, price))) return lot.quantity;
        uint256 eligible = _principalAvailable(lot, price) + _releasedNow(lot, price, activeNow, !fresh || _triggerMet(lot, price));
        return eligible > lot.quantity ? lot.quantity : eligible;
    }
    function _positionView(address user) private view returns (UserPosition memory p) {
        p = _positions[user];
        p.trackedTokens = 0; p.totalInvested = 0; p.lockedProfitTokens = 0; p.lockedProfitStart = 0;
        Lot[] storage a = _lots[user];
        for (uint256 i; i < a.length; ++i) {
            Lot storage lot = a[i];
            p.trackedTokens += lot.quantity;
            p.totalInvested += lot.quoteBasis;
            if (lot.quantity > 0 && lot.checkpointProfit > lot.releasedProfit) {
                p.lockedProfitTokens += lot.checkpointProfit - lot.releasedProfit;
                if (p.lockedProfitStart == 0) p.lockedProfitStart = lot.checkpointActiveTime;
            }
        }
        p.avgEntryPrice = p.trackedTokens == 0 ? 0 : p.totalInvested * PRECISION / p.trackedTokens;
    }
    function _syncPosition(address user) private {
        UserPosition storage p = _positions[user];
        p.trackedTokens = 0; p.totalInvested = 0; p.lockedProfitTokens = 0; p.lockedProfitStart = 0;
        Lot[] storage a = _lots[user];
        for (uint256 i; i < a.length; ++i) {
            Lot storage lot = a[i];
            p.trackedTokens += lot.quantity; p.totalInvested += lot.quoteBasis;
            if (lot.quantity > 0 && lot.checkpointProfit > lot.releasedProfit) {
                p.lockedProfitTokens += lot.checkpointProfit - lot.releasedProfit;
                if (p.lockedProfitStart == 0) p.lockedProfitStart = lot.checkpointActiveTime;
            }
        }
        p.avgEntryPrice = p.trackedTokens == 0 ? 0 : p.totalInvested * PRECISION / p.trackedTokens;
    }
    function _entryPrice(Lot storage lot) private view returns (uint256) {
        return lot.quantity == 0 ? 0 : lot.quoteBasis * PRECISION / lot.quantity;
    }
    function _principal(Lot storage lot, uint256 price) private view returns (uint256) {
        if (price == 0) return 0;
        uint256 principal = lot.quoteBasis * PRECISION / price;
        return principal > lot.quantity ? lot.quantity : principal;
    }
    function _principalAvailable(Lot storage lot, uint256 price) private view returns (uint256) {
        if (price == 0 || !lot.checkpointed || lot.principalConsumed >= lot.principalBudget) return 0;
        uint256 remainingBudget = lot.principalBudget - lot.principalConsumed;
        uint256 currentPrincipal = _principal(lot, price);
        return currentPrincipal < remainingBudget ? currentPrincipal : remainingBudget;
    }
    function _rollingEmergencyUsed(address user) private view returns (uint256 used) {
        EmergencySale[] storage sales = _emergencySales[user];
        uint256 cutoff = block.timestamp > 1 days ? block.timestamp - 1 days : 0;
        for (uint256 i = sales.length; i > 0; ) {
            unchecked { --i; }
            EmergencySale storage sale = sales[i];
            if (sale.timestamp < cutoff) break;
            used += sale.amount;
        }
    }
    function _triggerMet(Lot storage lot, uint256 price) private view returns (bool) {
        uint256 entry = _entryPrice(lot);
        return entry > 0 && price >= entry * RATIO_TRIGGER;
    }
    function _volumeThresholdMet(uint256 volume) private view returns (bool) {
        return minVolumeConfigured && volume >= volumeThreshold();
    }
    function _isEmergencyStale() private view returns (bool) {
        return lastObservationTimestamp != 0 && block.timestamp - lastObservationTimestamp > STALE_EMERGENCY_DELAY;
    }
    modifier onlyPool() { require(msg.sender == liquidityPool && liquidityPool != address(0), "Only approved pool"); _; }
}
