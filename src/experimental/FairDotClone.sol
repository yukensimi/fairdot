// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IFairDotClonePoolSeedStatus {
    function liquidityInitialized() external view returns (bool);
    function hasActiveSchedule(address user) external view returns (bool);
}

/** Experimental cloneable copy of FairDot; do not use as production code yet. */
contract FairDotClone is ERC20, Ownable {
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
        uint256 peakPrice;
        uint256 peakPrincipalAvailable;
        uint256 appreciationReleasedProfit;
        uint256 checkpointScheduleAmount;
        uint256 checkpointProfitConsumed;
    }
    struct AppreciationBucket {
        uint64 utcDay;
        uint64 startActiveTime;
        uint256 scheduledAmount;
        uint256 amount;
        uint256 released;
        uint256 consumed;
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
    mapping(address => mapping(uint256 => AppreciationBucket[])) private _appreciationBuckets;
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
    bool public cloneInitialized;
    string private _cloneName;
    string private _cloneSymbol;
    address public immutable cloneFactory;

    event BuyRecorded(address indexed buyer, uint256 amount, uint256 quotePaid, uint256 lotIndex);
    event ProtectionActivated(address indexed user, uint256 indexed lotIndex, uint256 ratio);
    event LiquidityPoolSet(address indexed pool);
    event MinVolumeConfigured(uint256 minVolumeBps, uint256 minVolumeAbsolute);
    event LotTransferred(address indexed from, address indexed to, uint256 quantity, uint256 quoteBasis, uint256 lotIndex);
    event AppreciationBucketCreated(address indexed user, uint256 indexed lotIndex, uint64 indexed utcDay, uint256 amount);

    constructor() ERC20("", "") Ownable(msg.sender) {
        // Lock the implementation. A newly created clone has independent zeroed storage.
        cloneFactory = msg.sender;
        cloneInitialized = true;
    }

    function initializeClone(string calldata name_, string calldata symbol_, uint256 initialSupply_) external {
        require(msg.sender == cloneFactory, "Only clone factory");
        require(!cloneInitialized, "Already initialized");
        require(bytes(name_).length != 0 && bytes(symbol_).length != 0, "Empty metadata");
        require(initialSupply_ != 0, "Zero supply");
        cloneInitialized = true;
        _cloneName = name_;
        _cloneSymbol = symbol_;
        _transferOwnership(msg.sender);
        uint256 supply = initialSupply_ * 10 ** decimals();
        _mint(msg.sender, supply);
        _positions[msg.sender].untrackedTokens = supply;
    }

    function name() public view override returns (string memory) {
        return cloneInitialized ? _cloneName : super.name();
    }

    function symbol() public view override returns (string memory) {
        return cloneInitialized ? _cloneSymbol : super.symbol();
    }

    function positions(address user) external view returns (UserPosition memory) { return _positionView(user); }
    function getLotCount(address user) external view returns (uint256) { return _lots[user].length; }
    function lots(address user, uint256 index) external view returns (Lot memory) { return _lots[user][index]; }
    function appreciationBucketCount(address user, uint256 lotIndex) external view returns (uint256) {
        return _appreciationBuckets[user][lotIndex].length;
    }
    function appreciationBucket(address user, uint256 lotIndex, uint256 bucketIndex)
        external view returns (AppreciationBucket memory)
    {
        return _appreciationBuckets[user][lotIndex][bucketIndex];
    }

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
        require(IFairDotClonePoolSeedStatus(liquidityPool).liquidityInitialized(), "Initial liquidity not set");
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
        a.push(Lot(amount, quotePaid, day, 0, 0, 0, 0, 0, false, true, 0, 0, 0, 0, 0));
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
        bool volumeMet = _volumeThresholdMet(getQuoteVolume24h());
        for (uint256 i; i < a.length; ++i) {
            Lot storage lot = a[i];
            if (lot.quantity == 0 || !lot.checkpointed) continue;
            _persistReleased(user, i, price, true, activeNow);
            if (volumeMet) _bookAppreciation(user, i, price, activeNow);
        }
        if (!volumeMet) { _syncPosition(user); return; }
        for (uint256 i; i < a.length; ++i) {
            Lot storage lot = a[i];
            if (lot.quantity == 0 || lot.checkpointed || !_triggerMet(lot, price)) continue;
            lot.principalBudget = _principal(lot, price);
            lot.principalConsumed = 0;
            lot.checkpointProfit = lot.quantity - lot.principalBudget;
            lot.checkpointActiveTime = uint64(activeNow);
            lot.checkpointed = true;
            lot.peakPrice = price;
            lot.peakPrincipalAvailable = lot.principalBudget;
            lot.checkpointScheduleAmount = lot.checkpointProfit;
            lot.checkpointProfitConsumed = 0;
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
                Lot[] storage a = _lots[user];
                for (uint256 i; i < a.length; ++i) {
                    Lot storage lot = a[i];
                    if (lot.quantity == 0) continue;
                    if (lot.checkpointed) {
                        // Freeze only the release accrued while observations were active.
                        // Do not count the stale gap or unlock profit from stale price data.
                        if (_triggerMet(lot, e.priceSnapshot)) {
                            _persistReleased(user, i, e.priceSnapshot, true, activeClock);
                        }
                        continue;
                    }
                    lot.principalBudget = _principal(lot, e.priceSnapshot);
                    lot.checkpointProfit = lot.quantity - lot.principalBudget;
                    lot.checkpointActiveTime = uint64(activeClock);
                    lot.checkpointed = true;
                    lot.peakPrice = e.priceSnapshot;
                    lot.peakPrincipalAvailable = lot.principalBudget;
                    lot.checkpointScheduleAmount = lot.checkpointProfit;
                    lot.checkpointProfitConsumed = 0;
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
            uint256 principalTotal;
            uint256 releasedProfitTotal;
            for (uint256 i; i < emergencyLots.length; ++i) {
                Lot storage lot = emergencyLots[i];
                if (lot.quantity == 0) continue;
                uint256 entry = _entryPrice(lot);
                if (entry != 0) currentRatio = emergency.priceSnapshot * BASIS_POINTS / entry;
                if (lot.checkpointed) {
                    principalTotal += _principalAvailable(lot, emergency.priceSnapshot);
                    releasedProfitTotal += lot.releasedProfit + lot.appreciationReleasedProfit
                        + _storedBucketReleases(user, i);
                }
            }
            uint256 cap = emergency.snapshot * EMERGENCY_QUOTA_BPS / BASIS_POINTS;
            uint256 used = _rollingEmergencyUsed(user);
            uint256 remaining = cap > used ? cap - used : 0;
            withdrawableNow = (principalTotal < remaining ? principalTotal : remaining) + releasedProfitTotal;
            if (withdrawableNow > pos.trackedTokens) withdrawableNow = pos.trackedTokens;
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
                eligible = _principalAvailable(lot, price)
                    + _releasedNow(lot, price, activeNow, !fresh || _triggerMet(lot, price))
                    + lot.appreciationReleasedProfit
                    + _appreciationReleasedNow(user, i, activeNow, !fresh || _triggerMet(lot, price));
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
                require(!IFairDotClonePoolSeedStatus(liquidityPool).hasActiveSchedule(from), "Stagger schedule active");
                require(!IFairDotClonePoolSeedStatus(liquidityPool).hasActiveSchedule(to), "Stagger schedule active");
            }
            if (from == liquidityPool) {
                UserPosition storage poolPos = _positions[from];
                require(poolPos.untrackedTokens >= amount, "Pool inventory mismatch");
                poolPos.untrackedTokens -= amount;
            } else if (to == liquidityPool) {
                bool seed = from == owner() && msg.sender == liquidityPool
                    && !IFairDotClonePoolSeedStatus(liquidityPool).liquidityInitialized();
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
            uint256 oldQuantity = lot.quantity;
            bool fullLot = moved == oldQuantity;
            uint256 basis = fullLot ? lot.quoteBasis : lot.quoteBasis * moved / oldQuantity;
            uint256 profit = fullLot ? lot.checkpointProfit : lot.checkpointProfit * moved / oldQuantity;
            uint256 released = fullLot ? lot.releasedProfit : lot.releasedProfit * moved / oldQuantity;
            uint256 principalBudget = fullLot ? lot.principalBudget : lot.principalBudget * moved / oldQuantity;
            uint256 principalConsumed = fullLot ? lot.principalConsumed : lot.principalConsumed * moved / oldQuantity;
            uint256 checkpointSchedule = fullLot
                ? lot.checkpointScheduleAmount : lot.checkpointScheduleAmount * moved / oldQuantity;
            uint256 appreciationReleased = fullLot
                ? lot.appreciationReleasedProfit : lot.appreciationReleasedProfit * moved / oldQuantity;
            uint256 peakPrice = lot.peakPrice;
            lot.quantity -= moved; lot.quoteBasis -= basis; lot.checkpointProfit -= profit; lot.releasedProfit -= released;
            lot.principalBudget -= principalBudget; lot.principalConsumed -= principalConsumed;
            lot.appreciationReleasedProfit -= appreciationReleased;
            lot.checkpointScheduleAmount -= checkpointSchedule;
            lot.checkpointProfitConsumed = lot.checkpointScheduleAmount - lot.checkpointProfit;
            dst.push(Lot(moved, basis, lot.purchaseDay, lot.checkpointActiveTime, profit, released,
                principalBudget, principalConsumed, lot.checkpointed, false, peakPrice, 0, appreciationReleased,
                checkpointSchedule, checkpointSchedule - profit));
            uint256 dstIndex = dst.length - 1;
            AppreciationBucket[] storage srcBuckets = _appreciationBuckets[from][i];
            AppreciationBucket[] storage dstBuckets = _appreciationBuckets[to][dstIndex];
            for (uint256 b; b < srcBuckets.length; ++b) {
                AppreciationBucket storage bucket = srcBuckets[b];
                uint256 bucketSchedule = fullLot ? bucket.scheduledAmount : bucket.scheduledAmount * moved / oldQuantity;
                uint256 bucketAmount = fullLot ? bucket.amount : bucket.amount * moved / oldQuantity;
                uint256 bucketReleased = fullLot ? bucket.released : bucket.released * moved / oldQuantity;
                if (bucketSchedule < bucketAmount) bucketSchedule = bucketAmount;
                bucket.scheduledAmount -= bucketSchedule;
                bucket.amount -= bucketAmount;
                bucket.released -= bucketReleased;
                bucket.consumed = bucket.scheduledAmount - bucket.amount;
                dstBuckets.push(AppreciationBucket(bucket.utcDay, bucket.startActiveTime, bucketSchedule,
                    bucketAmount, bucketReleased, bucketSchedule - bucketAmount));
            }
            if (fullLot) delete _appreciationBuckets[from][i];
            if (lot.peakPrice != 0) lot.peakPrincipalAvailable = _principalAvailable(lot, lot.peakPrice);
            if (peakPrice != 0) dst[dstIndex].peakPrincipalAvailable = _principalAvailable(dst[dstIndex], peakPrice);
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
        uint256 emergencyPrincipalRemaining;
        uint256 emergencyPrincipalSold;
        if (emergency.windowStart != 0) {
            uint256 cap = emergency.snapshot * EMERGENCY_QUOTA_BPS / BASIS_POINTS;
            uint256 used = _rollingEmergencyUsed(user);
            emergencyPrincipalRemaining = cap > used ? cap - used : 0;
        }
        uint256 remaining = amount;
        Lot[] storage a = _lots[user];
        // FIFO among eligible lots; locked portions in older lots are skipped.
        for (uint256 i; i < a.length && remaining > 0; ++i) {
            Lot storage lot = a[i];
            if (lot.quantity == 0) continue;
            uint256 principalAvailable;
            uint256 available;
            if (emergency.windowStart != 0) {
                if (!lot.checkpointed) continue;
                principalAvailable = _principalAvailable(lot, price);
                if (principalAvailable > emergencyPrincipalRemaining) {
                    principalAvailable = emergencyPrincipalRemaining;
                }
                available = principalAvailable + lot.releasedProfit + lot.appreciationReleasedProfit
                    + _storedBucketReleases(user, i);
            } else {
                available = _eligibleLot(user, i, lot, price, fresh, activeNow);
                principalAvailable = lot.checkpointed ? _principalAvailable(lot, price) : 0;
            }
            if (available == 0) continue;
            uint256 taken = available < remaining ? available : remaining;
            uint256 basis = taken == lot.quantity ? lot.quoteBasis : lot.quoteBasis * taken / lot.quantity;
            uint256 principalTaken = taken < principalAvailable ? taken : principalAvailable;
            uint256 profitTaken = taken - principalTaken;
            lot.quantity -= taken;
            lot.quoteBasis -= basis;
            if (lot.checkpointed && profitTaken > 0) _consumeReleasedProfit(user, i, lot, profitTaken);
            lot.principalConsumed += principalTaken;
            if (lot.peakPrice != 0) lot.peakPrincipalAvailable = _principalAvailable(lot, lot.peakPrice);
            if (emergency.windowStart != 0) {
                emergencyPrincipalRemaining -= principalTaken;
                emergencyPrincipalSold += principalTaken;
            }
            remaining -= taken;
        }
        require(remaining == 0, "Withdrawal not allowed");
        if (emergency.windowStart != 0 && emergencyPrincipalSold > 0) {
            _emergencySales[user].push(EmergencySale(uint64(block.timestamp), emergencyPrincipalSold));
            emergencyState[user].used = _rollingEmergencyUsed(user);
        }
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
        bool volumeMet = _volumeThresholdMet(getQuoteVolume24h());
        for (uint256 i; i < a.length; ++i) {
            if (a[i].quantity == 0) continue;
            bool triggered = !fresh || _triggerMet(a[i], price);
            _persistReleased(user, i, price, triggered, activeNow);
            if (fresh && volumeMet) _bookAppreciation(user, i, price, activeNow);
        }
    }
    function _persistReleased(address user, uint256 lotIndex, uint256 price, bool volumeMet, uint256 activeNow) private {
        Lot storage lot = _lots[user][lotIndex];
        if (!lot.checkpointed) return;
        uint256 released = _releasedNow(lot, price, activeNow, volumeMet && _triggerMet(lot, price));
        if (released > lot.releasedProfit) lot.releasedProfit = released;
        AppreciationBucket[] storage buckets = _appreciationBuckets[user][lotIndex];
        uint256 i;
        while (i < buckets.length) {
            AppreciationBucket storage bucket = buckets[i];
            uint256 bucketReleased = _bucketReleasedNow(bucket, activeNow, volumeMet && _triggerMet(lot, price));
            if (bucketReleased > bucket.released) bucket.released = bucketReleased;
            if (bucket.released == bucket.amount) {
                lot.appreciationReleasedProfit += bucket.amount;
                for (uint256 j = i; j + 1 < buckets.length; ++j) buckets[j] = buckets[j + 1];
                buckets.pop();
            } else {
                ++i;
            }
        }
    }
    function _bookAppreciation(address user, uint256 lotIndex, uint256 price, uint256 activeNow) private {
        Lot storage lot = _lots[user][lotIndex];
        if (!lot.checkpointed || !_triggerMet(lot, price) || price <= lot.peakPrice) return;
        uint256 principalNow = _principalAvailable(lot, price);
        uint256 amount = lot.peakPrincipalAvailable > principalNow
            ? lot.peakPrincipalAvailable - principalNow : 0;
        lot.peakPrice = price;
        lot.peakPrincipalAvailable = principalNow;
        if (amount == 0) return;

        uint256 alreadyAllocated = lot.checkpointProfit + lot.appreciationReleasedProfit;
        AppreciationBucket[] storage buckets = _appreciationBuckets[user][lotIndex];
        for (uint256 i; i < buckets.length; ++i) alreadyAllocated += buckets[i].amount;
        if (principalNow + alreadyAllocated >= lot.quantity) return;
        uint256 unallocated = lot.quantity - principalNow - alreadyAllocated;
        if (amount > unallocated) amount = unallocated;
        if (amount == 0) return;

        uint64 day = uint64(block.timestamp / 1 days);
        if (buckets.length > 0 && buckets[buckets.length - 1].utcDay == day) {
            // Increments recognized on the same UTC day share that day's first active-time start.
            buckets[buckets.length - 1].scheduledAmount += amount;
            buckets[buckets.length - 1].amount += amount;
        } else {
            buckets.push(AppreciationBucket(day, uint64(activeNow), amount, amount, 0, 0));
        }
        emit AppreciationBucketCreated(user, lotIndex, day, amount);
    }
    function _releasedNow(Lot storage lot, uint256, uint256 activeNow, bool triggered) private view returns (uint256) {
        if (!lot.checkpointed || lot.checkpointProfit == 0) return 0;
        if (!triggered) return lot.checkpointProfit;
        uint256 elapsed = activeNow > lot.checkpointActiveTime ? activeNow - lot.checkpointActiveTime : 0;
        uint256 cumulative = elapsed >= RELEASE_DAYS * 1 days
            ? lot.checkpointScheduleAmount : lot.checkpointScheduleAmount * elapsed / (RELEASE_DAYS * 1 days);
        uint256 linear = cumulative > lot.checkpointProfitConsumed ? cumulative - lot.checkpointProfitConsumed : 0;
        if (linear > lot.checkpointProfit) linear = lot.checkpointProfit;
        return linear > lot.releasedProfit ? linear : lot.releasedProfit;
    }
    function _bucketReleasedNow(AppreciationBucket storage bucket, uint256 activeNow, bool triggered)
        private view returns (uint256)
    {
        if (!triggered) return bucket.amount;
        uint256 elapsed = activeNow > bucket.startActiveTime ? activeNow - bucket.startActiveTime : 0;
        uint256 cumulative = elapsed >= RELEASE_DAYS * 1 days
            ? bucket.scheduledAmount : bucket.scheduledAmount * elapsed / (RELEASE_DAYS * 1 days);
        uint256 linear = cumulative > bucket.consumed ? cumulative - bucket.consumed : 0;
        if (linear > bucket.amount) linear = bucket.amount;
        return linear > bucket.released ? linear : bucket.released;
    }
    function _appreciationReleasedNow(address user, uint256 lotIndex, uint256 activeNow, bool triggered)
        private view returns (uint256 released)
    {
        AppreciationBucket[] storage buckets = _appreciationBuckets[user][lotIndex];
        for (uint256 i; i < buckets.length; ++i) released += _bucketReleasedNow(buckets[i], activeNow, triggered);
    }
    function _storedBucketReleases(address user, uint256 lotIndex) private view returns (uint256 released) {
        AppreciationBucket[] storage buckets = _appreciationBuckets[user][lotIndex];
        for (uint256 i; i < buckets.length; ++i) released += buckets[i].released;
    }
    function _lockedAppreciation(address user, uint256 lotIndex) private view returns (uint256 locked) {
        AppreciationBucket[] storage buckets = _appreciationBuckets[user][lotIndex];
        for (uint256 i; i < buckets.length; ++i) locked += buckets[i].amount - buckets[i].released;
    }
    function _earliestLockedStart(address user, uint256 lotIndex, Lot storage lot)
        private view returns (uint256 start)
    {
        bool found;
        if (lot.checkpointProfit > lot.releasedProfit) {
            start = lot.checkpointActiveTime;
            found = true;
        }
        AppreciationBucket[] storage buckets = _appreciationBuckets[user][lotIndex];
        for (uint256 i; i < buckets.length; ++i) {
            if (buckets[i].amount > buckets[i].released
                && (!found || buckets[i].startActiveTime < start)) {
                start = buckets[i].startActiveTime;
                found = true;
            }
        }
    }
    function _consumeReleasedProfit(address user, uint256 lotIndex, Lot storage lot, uint256 amount) private {
        uint256 remaining = amount;
        uint256 fromBase = remaining < lot.releasedProfit ? remaining : lot.releasedProfit;
        lot.releasedProfit -= fromBase;
        lot.checkpointProfit -= fromBase;
        lot.checkpointProfitConsumed += fromBase;
        remaining -= fromBase;

        uint256 fromAggregate = remaining < lot.appreciationReleasedProfit
            ? remaining : lot.appreciationReleasedProfit;
        lot.appreciationReleasedProfit -= fromAggregate;
        remaining -= fromAggregate;

        AppreciationBucket[] storage buckets = _appreciationBuckets[user][lotIndex];
        uint256 i;
        while (remaining > 0 && i < buckets.length) {
            AppreciationBucket storage bucket = buckets[i];
            uint256 fromBucket = remaining < bucket.released ? remaining : bucket.released;
            bucket.released -= fromBucket;
            bucket.amount -= fromBucket;
            bucket.consumed += fromBucket;
            remaining -= fromBucket;
            if (bucket.amount == 0) {
                for (uint256 j = i; j + 1 < buckets.length; ++j) buckets[j] = buckets[j + 1];
                buckets.pop();
            } else {
                ++i;
            }
        }
        require(remaining == 0, "Profit not released");
    }
    function _eligibleLot(address user, uint256 lotIndex, Lot storage lot, uint256 price, bool fresh, uint256 activeNow)
        private view returns (uint256)
    {
        if (!lot.checkpointed || (fresh && !_triggerMet(lot, price))) return lot.quantity;
        uint256 eligible = _principalAvailable(lot, price)
            + _releasedNow(lot, price, activeNow, !fresh || _triggerMet(lot, price))
            + lot.appreciationReleasedProfit
            + _appreciationReleasedNow(user, lotIndex, activeNow, !fresh || _triggerMet(lot, price));
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
            if (lot.quantity > 0) {
                if (lot.checkpointProfit > lot.releasedProfit) p.lockedProfitTokens += lot.checkpointProfit - lot.releasedProfit;
                p.lockedProfitTokens += _lockedAppreciation(user, i);
                uint256 lockedStart = _earliestLockedStart(user, i, lot);
                if (lockedStart != 0 && (p.lockedProfitStart == 0 || lockedStart < p.lockedProfitStart)) {
                    p.lockedProfitStart = lockedStart;
                }
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
            if (lot.quantity > 0) {
                if (lot.checkpointProfit > lot.releasedProfit) p.lockedProfitTokens += lot.checkpointProfit - lot.releasedProfit;
                p.lockedProfitTokens += _lockedAppreciation(user, i);
                uint256 lockedStart = _earliestLockedStart(user, i, lot);
                if (lockedStart != 0 && (p.lockedProfitStart == 0 || lockedStart < p.lockedProfitStart)) {
                    p.lockedProfitStart = lockedStart;
                }
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
