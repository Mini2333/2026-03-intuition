// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.29;

import { TrustBondingBase } from "tests/unit/TrustBonding/TrustBondingBase.t.sol";

/**
 * @title  PoCCore
 * @notice Proof-of-Concept demonstrating a Medium-severity vulnerability in TrustBonding.sol:
 *
 *         Vulnerability Title:
 *           Single-Epoch Claim Window Causes Permanent, Unrecoverable Reward Loss
 *
 *         Risk Rating: Medium — Permanent loss of user rewards through a one-epoch expiry window.
 *
 *         Description:
 *         `claimRewards()` enforces a strict one-epoch claiming window: rewards for epoch N
 *         are only claimable during epoch N+1. Once epoch N+2 begins the rewards expire
 *         silently — there is no extension, no grace period, and no user-accessible recovery
 *         path. Unclaimed rewards accumulate in the SatelliteEmissionsController and can
 *         later be redirected by an admin via `withdrawUnclaimedEmissions()`, but the
 *         original beneficiary receives nothing.
 *
 *         Attack Path:
 *         1. Alice bonds veTRUST in epoch 0 and earns a share of epoch-0 emissions.
 *         2. Epoch 1 begins — the only window in which Alice can claim her epoch-0 rewards.
 *         3. Alice does not call `claimRewards()` during epoch 1 (she may be unaware, or a
 *            MEV searcher deliberately delays her transaction until epoch 2 begins).
 *         4. Epoch 2 begins — `claimRewards()` now targets epoch 1.  Alice's epoch-0 rewards
 *            are permanently forfeited and cannot be claimed by any user-level call.
 *         5. An admin can call `withdrawUnclaimedEmissions(0, adminAddr)` to recover the
 *            funds, but Alice receives nothing from her own earned rewards.
 *
 *         Impact:
 *         Alice permanently loses all rewards she earned in epoch 0.  At scale, a malicious
 *         MEV searcher can systematically front-run or delay claim transactions, causing
 *         repeated, compounding reward losses for users.  The single-epoch window (~14 days)
 *         is especially punishing for infrequent on-chain users.
 *
 *         Root Cause:
 *         `claimRewards()` hardcodes `prevEpoch = currentEpoch - 1` without any mechanism to
 *         claim rewards from older epochs, and there is no per-user recovery path for expired
 *         windows.
 */
contract PoCCore is TrustBondingBase {
    function setUp() public override {
        super.setUp();
        // Fund the emissions controller with native ETH so reward transfers succeed
        vm.deal(address(protocol.satelliteEmissionsController), 10_000_000 ether);
    }

    function test_submissionValidity() external {
        // ---------------------------------------------------------------
        // Step 1: Alice bonds veTRUST in epoch 0.
        //         She is the only locker, so she earns 100 % of epoch-0
        //         emissions (~1_000 ether per the test configuration).
        // ---------------------------------------------------------------
        _createLock(users.alice, initialTokens); // 10_000 ether veTRUST

        assertEq(protocol.trustBonding.currentEpoch(), 0, "Must be epoch 0");

        // ---------------------------------------------------------------
        // Step 2: Advance to epoch 1.
        //         Epoch-0 rewards are now claimable (the only window).
        // ---------------------------------------------------------------
        _advanceToEpoch(1);
        assertEq(protocol.trustBonding.currentEpoch(), 1, "Must be epoch 1");

        uint256 aliceEpoch0Rewards = protocol.trustBonding.userEligibleRewardsForEpoch(users.alice, 0);
        assertGt(aliceEpoch0Rewards, 0, "Alice earned epoch-0 rewards");

        // ---------------------------------------------------------------
        // Step 3: Alice does NOT claim during epoch 1.
        //         Advance to epoch 2 — the epoch-0 claim window is now
        //         permanently closed.
        // ---------------------------------------------------------------
        _advanceToEpoch(2);
        assertEq(protocol.trustBonding.currentEpoch(), 2, "Must be epoch 2");

        // ---------------------------------------------------------------
        // Step 4: Prove Alice's epoch-0 rewards are unclaimable.
        //         claimRewards() now targets epoch 1; it cannot reach
        //         epoch 0.
        // ---------------------------------------------------------------
        assertEq(
            protocol.trustBonding.userEligibleRewardsForEpoch(users.alice, 0),
            aliceEpoch0Rewards,
            "Epoch-0 eligible rewards are unchanged (never claimed)"
        );
        assertFalse(
            protocol.trustBonding.hasClaimedRewardsForEpoch(users.alice, 0),
            "Alice never claimed epoch-0 rewards"
        );
        assertEq(
            protocol.trustBonding.userClaimedRewardsForEpoch(users.alice, 0),
            0,
            "userClaimedRewardsForEpoch confirms no claim was recorded"
        );

        // ---------------------------------------------------------------
        // Step 5: Confirm the rewards are visible to the admin but not
        //         to Alice.  getUnclaimedRewardsForEpoch() requires
        //         currentEpoch >= epoch + 2; with currentEpoch = 2 the
        //         call for epoch 0 is valid.
        // ---------------------------------------------------------------
        uint256 systemUnclaimed = protocol.trustBonding.getUnclaimedRewardsForEpoch(0);
        assertGt(systemUnclaimed, 0, "Epoch-0 rewards are locked in the emissions controller");

        // Alice was the sole locker, so all epoch-0 emissions are unclaimed.
        uint256 epoch0Emissions = protocol.satelliteEmissionsController.getEmissionsAtEpoch(0);
        assertEq(
            systemUnclaimed,
            epoch0Emissions,
            "All epoch-0 rewards are permanently inaccessible to Alice"
        );

        // ---------------------------------------------------------------
        // Step 6: The admin CAN recover Alice's forfeited rewards, but
        //         Alice receives nothing.
        // ---------------------------------------------------------------
        address adminRecipient = users.admin;
        uint256 adminBalanceBefore = adminRecipient.balance;

        vm.prank(users.admin);
        protocol.satelliteEmissionsController.withdrawUnclaimedEmissions(0, adminRecipient);

        uint256 adminBalanceAfter = adminRecipient.balance;
        assertEq(
            adminBalanceAfter - adminBalanceBefore,
            epoch0Emissions,
            "Admin recovered all of Alice's forfeited epoch-0 rewards"
        );

        // Alice still has zero claimed rewards — her share is gone.
        assertEq(
            protocol.trustBonding.userClaimedRewardsForEpoch(users.alice, 0),
            0,
            "Alice's epoch-0 rewards were permanently forfeited"
        );
    }
}
