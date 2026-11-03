// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// EXPERIMENTAL, TEST-ONLY PROBE.
// This intentionally models only per-launch deployment and initialization overhead.
// It does not implement FairDot accounting, trading rules, Registry security, or liquidity custody.
// Do not deploy this probe or treat its gas results as a production estimate.

import "@openzeppelin/contracts/proxy/Clones.sol";

contract DirectLaunchTokenProbe {
    string public name;
    string public symbol;
    address public creator;
    uint256 public totalSupply;

    constructor(string memory name_, string memory symbol_, address creator_, uint256 supply_) {
        require(bytes(name_).length != 0, "Empty name");
        require(bytes(symbol_).length != 0, "Empty symbol");
        require(creator_ != address(0), "Zero creator");
        require(supply_ != 0, "Zero supply");
        name = name_;
        symbol = symbol_;
        creator = creator_;
        totalSupply = supply_;
    }
}

contract CloneLaunchTokenProbe {
    bool public initialized;
    string public name;
    string public symbol;
    address public creator;
    uint256 public totalSupply;

    // Lock the implementation's own storage. Clone storage starts at zero.
    constructor() {
        initialized = true;
    }

    function initialize(string calldata name_, string calldata symbol_, address creator_, uint256 supply_) external {
        require(!initialized, "Already initialized");
        require(bytes(name_).length != 0, "Empty name");
        require(bytes(symbol_).length != 0, "Empty symbol");
        require(creator_ != address(0), "Zero creator");
        require(supply_ != 0, "Zero supply");
        initialized = true;
        name = name_;
        symbol = symbol_;
        creator = creator_;
        totalSupply = supply_;
    }
}

contract DirectLaunchPoolProbe {
    address public token;
    address public creator;
    uint256 public tokenReserve;
    uint256 public quoteReserve;

    constructor(address token_, address creator_, uint256 tokenSeed_, uint256 quoteSeed_) {
        require(token_ != address(0) && creator_ != address(0), "Zero address");
        require(tokenSeed_ != 0 && quoteSeed_ != 0, "Zero seed");
        token = token_;
        creator = creator_;
        tokenReserve = tokenSeed_;
        quoteReserve = quoteSeed_;
    }
}

contract CloneLaunchPoolProbe {
    bool public initialized;
    address public token;
    address public creator;
    uint256 public tokenReserve;
    uint256 public quoteReserve;

    constructor() {
        initialized = true;
    }

    function initialize(address token_, address creator_, uint256 tokenSeed_, uint256 quoteSeed_) external {
        require(!initialized, "Already initialized");
        require(token_ != address(0) && creator_ != address(0), "Zero address");
        require(tokenSeed_ != 0 && quoteSeed_ != 0, "Zero seed");
        initialized = true;
        token = token_;
        creator = creator_;
        tokenReserve = tokenSeed_;
        quoteReserve = quoteSeed_;
    }
}

contract DirectLaunchPairFactoryProbe {
    event PairCreated(address indexed token, address indexed pool, address indexed creator);

    function createMeme(
        string calldata name_,
        string calldata symbol_,
        uint256 supply_,
        uint256 tokenSeed_
    ) external payable returns (address tokenAddress, address poolAddress) {
        require(tokenSeed_ <= supply_, "Seed exceeds supply");
        require(msg.value != 0, "Zero quote seed");

        DirectLaunchTokenProbe token = new DirectLaunchTokenProbe(name_, symbol_, msg.sender, supply_);
        DirectLaunchPoolProbe pool = new DirectLaunchPoolProbe(
            address(token), msg.sender, tokenSeed_, msg.value
        );
        tokenAddress = address(token);
        poolAddress = address(pool);
        emit PairCreated(tokenAddress, poolAddress, msg.sender);
    }
}

contract CloneLaunchPairFactoryProbe {
    address public immutable tokenImplementation;
    address public immutable poolImplementation;

    event PairCreated(address indexed token, address indexed pool, address indexed creator);

    constructor() {
        tokenImplementation = address(new CloneLaunchTokenProbe());
        poolImplementation = address(new CloneLaunchPoolProbe());
    }

    function createMeme(
        string calldata name_,
        string calldata symbol_,
        uint256 supply_,
        uint256 tokenSeed_
    ) external payable returns (address tokenAddress, address poolAddress) {
        require(tokenSeed_ <= supply_, "Seed exceeds supply");
        require(msg.value != 0, "Zero quote seed");

        CloneLaunchTokenProbe token = CloneLaunchTokenProbe(Clones.clone(tokenImplementation));
        CloneLaunchPoolProbe pool = CloneLaunchPoolProbe(Clones.clone(poolImplementation));
        token.initialize(name_, symbol_, msg.sender, supply_);
        pool.initialize(address(token), msg.sender, tokenSeed_, msg.value);
        tokenAddress = address(token);
        poolAddress = address(pool);
        emit PairCreated(tokenAddress, poolAddress, msg.sender);
    }
}
