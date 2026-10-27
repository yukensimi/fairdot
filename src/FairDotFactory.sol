// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./FairDot.sol";
import "./FairDotPool.sol";

/**
 * @title FairDotRegistry
 * @notice Canonical token-to-pool directory shared by interfaces using this Factory.
 * @dev Registry entries are written only by the paired Factory and are immutable.
 */
contract FairDotRegistry {
    struct Entry {
        address pool;
        address creator;
        uint64 createdAt;
    }

    address public immutable factory;
    address[] private _tokens;
    mapping(address => Entry) private _entries;

    event MemeRegistered(address indexed token, address indexed pool, address indexed creator, uint64 createdAt);

    modifier onlyFactory() {
        require(msg.sender == factory, "Only factory");
        _;
    }

    constructor(address factory_) {
        require(factory_ != address(0), "Zero factory");
        factory = factory_;
    }

    function register(
        address token,
        address pool,
        address creator
    ) external onlyFactory {
        require(token.code.length > 0 && pool.code.length > 0, "Contracts required");
        require(creator != address(0), "Zero creator");
        require(_entries[token].pool == address(0), "Already registered");

        uint64 createdAt = uint64(block.timestamp);
        _entries[token] = Entry(pool, creator, createdAt);
        _tokens.push(token);
        emit MemeRegistered(token, pool, creator, createdAt);
    }

    function tokenCount() external view returns (uint256) {
        return _tokens.length;
    }

    function tokenAt(uint256 index) external view returns (address) {
        return _tokens[index];
    }

    function getEntry(address token) external view returns (Entry memory) {
        return _entries[token];
    }
}

/**
 * @title FairDotFactory
 * @notice Creates one FairDot token, one canonical pool and one Registry entry per launch.
 * @dev Independent applications interoperate by using the same Factory/Registry deployment.
 */
contract FairDotFactory {
    uint256 private constant TOKEN_SCALE = 1e18;

    FairDotRegistry public immutable registry;

    event MemeCreated(address indexed token, address indexed pool, address indexed creator);

    constructor() {
        registry = new FairDotRegistry(address(this));
    }

    /**
     * @param initialSupplyTokens Total supply in whole tokens (18 decimals).
     * @param seedTokenAmountTokens Token amount placed in the initial pool, in whole tokens.
     * @param minVolumeBps Percentage of the actual quote seed used in the 24h volume threshold.
     * @param minVolumeAbsolute Absolute minimum 24h quote volume, in wei of the quote asset.
     * @dev `msg.value` is the initial native-quote liquidity seed. All launch parameters are
     *      fixed before trading starts; the creator receives the non-seeded supply as untracked
     *      inventory, so it does not gain a pool purchase cost basis.
     */
    function createMeme(
        string calldata name,
        string calldata symbol,
        uint256 initialSupplyTokens,
        uint256 seedTokenAmountTokens,
        uint256 minVolumeBps,
        uint256 minVolumeAbsolute
    ) external payable returns (address tokenAddress, address poolAddress) {
        require(bytes(name).length > 0 && bytes(name).length <= 32, "Invalid name");
        require(bytes(symbol).length > 0 && bytes(symbol).length <= 12, "Invalid symbol");
        require(initialSupplyTokens > 0, "Zero supply");
        require(seedTokenAmountTokens > 0, "Zero token seed");
        require(seedTokenAmountTokens <= initialSupplyTokens, "Seed exceeds supply");
        require(msg.value > 0, "Zero quote seed");
        require(minVolumeBps <= 10_000, "Bps too high");
        require(minVolumeBps > 0 || minVolumeAbsolute > 0, "Zero volume threshold");

        uint256 supply = initialSupplyTokens * TOKEN_SCALE;
        uint256 tokenSeed = seedTokenAmountTokens * TOKEN_SCALE;

        FairDot token = new FairDot(name, symbol, initialSupplyTokens);
        FairDotPool pool = new FairDotPool(address(token));
        tokenAddress = address(token);
        poolAddress = address(pool);

        token.setLiquidityPool(poolAddress);
        token.setMinVolumeParameters(minVolumeBps, minVolumeAbsolute);
        require(token.approve(poolAddress, tokenSeed), "Approve failed");
        pool.addLiquidity{value: msg.value}(tokenSeed);

        // The Factory temporarily owns the initial supply. Transfer the unseeded allocation
        // before enabling trading; it remains untracked and is therefore not pool-sellable.
        uint256 creatorAllocation = supply - tokenSeed;
        if (creatorAllocation > 0) {
            require(token.transfer(msg.sender, creatorAllocation), "Creator allocation failed");
        }

        token.disableMinting();
        token.enableTrading();
        token.transferOwnership(msg.sender);
        registry.register(tokenAddress, poolAddress, msg.sender);

        emit MemeCreated(tokenAddress, poolAddress, msg.sender);
    }
}
