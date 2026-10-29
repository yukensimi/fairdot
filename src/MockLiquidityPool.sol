// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./FairDotPool.sol";

/** Backward-compatible fixture name; the Factory deploys FairDotPool directly. */
contract MockLiquidityPool is FairDotPool {
    constructor(address tokenAddress) FairDotPool(tokenAddress) {}
}
