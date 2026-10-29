// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../FairDot.sol";
import "../FairDotPool.sol";

/// Test-only contract wallet that attempts to cancel its sale schedule during quote payout.
contract MockReentrantSeller {
    FairDotPool public immutable pool;
    FairDot public immutable token;
    bool public cancelOnReceive;
    bool public cancelAttempted;

    constructor(address poolAddress) {
        pool = FairDotPool(poolAddress);
        token = pool.token();
    }

    function buy() external payable {
        pool.buy{value: msg.value}(0);
    }

    function sell(uint256 tokenAmount, uint256 minQuoteOut) external {
        token.approve(address(pool), tokenAmount);
        pool.sell(tokenAmount, minQuoteOut);
    }

    function setCancelOnReceive(bool enabled) external {
        cancelOnReceive = enabled;
    }

    receive() external payable {
        if (cancelOnReceive) {
            cancelAttempted = true;
            try pool.cancelSchedule() {} catch {}
        }
    }
}
