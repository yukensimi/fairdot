// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// EXPERIMENTAL ONLY. Do not deploy or use with real assets until audited and tested on Portaldot V3.

import "@openzeppelin/contracts/proxy/Clones.sol";
import "../FairDotFactory.sol";
import "./FairDotClone.sol";
import "./FairDotPoolClone.sol";

/**
 * @notice Local prototype of a shared Factory that creates FairDot and pool instances as EIP-1167 clones.
 * @dev The original FairDotFactory remains unchanged. This prototype deploys and binds its implementations once.
 */
contract FairDotCloneFactory {
    uint256 private constant TOKEN_SCALE = 1e18;

    address public immutable tokenImplementation;
    address public immutable poolImplementation;
    FairDotRegistry public immutable registry;

    event MemeCreated(address indexed token, address indexed pool, address indexed creator);

    constructor() {
        tokenImplementation = address(new FairDotClone());
        poolImplementation = address(new FairDotPoolClone());
        registry = new FairDotRegistry(address(this));
    }

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

        FairDotClone token = FairDotClone(Clones.clone(tokenImplementation));
        FairDotPoolClone pool = FairDotPoolClone(Clones.clone(poolImplementation));
        token.initializeClone(name, symbol, initialSupplyTokens);
        pool.initializeClone(address(token), address(this));
        tokenAddress = address(token);
        poolAddress = address(pool);

        token.setLiquidityPool(poolAddress);
        token.setMinVolumeParameters(minVolumeBps, minVolumeAbsolute);
        require(token.approve(poolAddress, tokenSeed), "Approve failed");
        pool.addLiquidity{value: msg.value}(tokenSeed);

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
