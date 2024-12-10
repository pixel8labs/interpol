// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "solady/tokens/ERC20.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console2} from "forge-std/console2.sol";

import {BaseTest} from "./Base.t.sol";
import {HoneyLocker} from "../src/HoneyLocker.sol";
import {BGTStationAdapter} from "../src/adapters/BGTStationAdapter.sol";
import {BaseVaultAdapter as BVA} from "../src/adapters/BaseVaultAdapter.sol";
import {IBGT} from "../src/utils/IBGT.sol";
import {Constants} from "../src/Constants.sol";

interface IBGTStationGauge {
    event Staked(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    function earned(address account) external view returns (uint256);
}

contract BGTStationTest is BaseTest {    
    /*###############################################################
                            STATE VARIABLES
    ###############################################################*/
    BGTStationAdapter   public adapter;
    BVA                 public lockerAdapter;   // adapter for BGT Station used by locker

    // LBGT-WBERA gauge
    address public constant GAUGE = 0x7a6b92457e7D7e7a5C1A2245488b850B7Da8E01D;
    // LBGT-WBERA LP token
    ERC20 public constant LP_TOKEN = ERC20(0x6AcBBedEcD914dE8295428B4Ee51626a1908bB12);
    IBGT public constant BGT = IBGT(0xbDa130737BDd9618301681329bF2e46A016ff9Ad);

    uint256 public constant INITIAL_LP_BALANCE = 1000 ether;
    /*###############################################################
                            SETUP
    ###############################################################*/
    function setUp() public override {
        /*
            Choosing this block number because the vault LBGT-WBERA is active
        */
        vm.createSelectFork("https://bartio.rpc.berachain.com/", uint256(7925685));

        super.setUp();

        // Deploy adapter implementation that will be cloned
        adapter = new BGTStationAdapter();

        vm.startPrank(THJ);

        queen.setAdapterApproval(GAUGE, address(adapter), true);
        queen.setVaultAdapter(GAUGE, address(adapter), address(LP_TOKEN));
        locker.registerVault(GAUGE, false);

        lockerAdapter = BVA(locker.vaultToAdapter(GAUGE));

        vm.stopPrank();

        vm.label(address(adapter), "BGTStationAdapter");
        vm.label(address(GAUGE), "LBGT-WBERA Gauge");
        vm.label(address(LP_TOKEN), "LBGT-WBERA LP Token");
    }

    /*###############################################################
                            TESTS
    ###############################################################*/

    /*
        This test a single simple deposit.
        It checks ;
        - proper events
        - balance is updated
    */
    function test_singleDeposit(uint256 amountToDeposit, uint256 expiration) external prankAsTHJ {
        StdCheats.deal(address(LP_TOKEN), THJ, amountToDeposit);

        LP_TOKEN.approve(address(locker), amountToDeposit);

        vm.expectEmit(true, true, false, false, address(locker));
        emit HoneyLocker.Deposited(address(LP_TOKEN), amountToDeposit);
        vm.expectEmit(true, false, false, false, address(locker));
        emit HoneyLocker.LockedUntil(address(LP_TOKEN), expiration);
        locker.depositAndLock(address(LP_TOKEN), amountToDeposit, expiration);

        assertEq(LP_TOKEN.balanceOf(address(locker)), amountToDeposit);
    }

    /*
        This test multiple deposits.
        It checks ;
        - balance is updated
        - expiration is updated
    */
    function test_multipleDeposits(uint32[4] memory amounts, uint128[4] memory expirations) external prankAsTHJ {
        uint runningBalance;

        // mint, deposit the first amount
        uint256 amount = uint256(amounts[0]);
        uint256 expiration = uint256(expirations[0]);

        runningBalance += amount;
        StdCheats.deal(address(LP_TOKEN), THJ, amount);
        LP_TOKEN.approve(address(locker), amount);
        locker.depositAndLock(address(LP_TOKEN), amount, expiration);

        for (uint i = 1; i < amounts.length; i++) {
            uint256 _amount = uint256(amounts[i]);
            uint256 _expiration = uint256(expirations[i]);

            StdCheats.deal(address(LP_TOKEN), THJ, _amount);
            LP_TOKEN.approve(address(locker), _amount);

            // getting ready to revert if the new expiration is less than the current one
            if (expiration >_expiration) {
                vm.expectRevert(HoneyLocker.HoneyLocker__ExpirationNotMatching.selector);
            } else {
                // if the new expiration is greater than the current one, update the expiration
                // and add the amount to the running balance because successful deposit
                expiration = _expiration;
                runningBalance += _amount;
            }

            locker.depositAndLock(address(LP_TOKEN), _amount, _expiration);
        }

        assertEq(LP_TOKEN.balanceOf(address(locker)), runningBalance);
    }

    /*
        This test a single simple withdrawal.
        It checks ;
        - proper events
        - expiration is respected
        - withdrawal is successful
    */
    function test_singleWithdrawal(uint256 amountTDeposit, uint256 expiration) external prankAsTHJ {
        expiration = StdUtils.bound(expiration, 0, type(uint256).max - 1);

        StdCheats.deal(address(LP_TOKEN), THJ, amountTDeposit);

        LP_TOKEN.approve(address(locker), amountTDeposit);
        locker.depositAndLock(address(LP_TOKEN), amountTDeposit, expiration);

        // cannot withdraw too early if expiration is in the future
        if (expiration > block.timestamp) {
            vm.expectRevert(HoneyLocker.HoneyLocker__NotExpiredYet.selector);
            locker.withdrawLPToken(address(LP_TOKEN), amountTDeposit);
        }

        // move forward in time
        vm.warp(expiration + 1);

        vm.expectEmit(true, false, false, true, address(locker));
        emit HoneyLocker.Withdrawn(address(LP_TOKEN), amountTDeposit);
        locker.withdrawLPToken(address(LP_TOKEN), amountTDeposit);

        assertEq(LP_TOKEN.balanceOf(THJ), amountTDeposit);
    }

    /*
        This test a single stake.
        It checks ;
        - proper events
        - proper balances
    */
    function test_stake(uint256 amountToDeposit, uint128 expiration) external prankAsTHJ {
        amountToDeposit = StdUtils.bound(amountToDeposit, 1, type(uint32).max);

        StdCheats.deal(address(LP_TOKEN), THJ, amountToDeposit);

        LP_TOKEN.approve(address(locker), amountToDeposit);
        locker.depositAndLock(address(LP_TOKEN), amountToDeposit, uint256(expiration));

        vm.expectEmit(true, false, false, true, address(GAUGE));
        emit IBGTStationGauge.Staked(address(lockerAdapter), amountToDeposit);
        vm.expectEmit(true, true, false, true, address(locker));
        emit HoneyLocker.Staked(address(GAUGE), address(LP_TOKEN), amountToDeposit);
        locker.stake(address(GAUGE), amountToDeposit);

        assertEq(LP_TOKEN.balanceOf(THJ), 0);
        assertEq(LP_TOKEN.balanceOf(address(locker)), 0);
        assertEq(LP_TOKEN.balanceOf(address(lockerAdapter)), 0);
    }

    /*
        This test a single unstake.
        It checks ;
        - proper events
        - proper balances
    */
    function test_unstake(uint256 amountToDeposit, uint128 expiration) external prankAsTHJ {
        amountToDeposit = StdUtils.bound(amountToDeposit, 1, type(uint32).max);

        StdCheats.deal(address(LP_TOKEN), THJ, amountToDeposit);

        LP_TOKEN.approve(address(locker), amountToDeposit);
        locker.depositAndLock(address(LP_TOKEN), amountToDeposit, uint256(expiration));

        locker.stake(address(GAUGE), amountToDeposit);

        vm.expectEmit(true, false, false, true, address(GAUGE));
        emit IBGTStationGauge.Withdrawn(address(lockerAdapter), amountToDeposit);
        vm.expectEmit(true, true, false, true, address(locker));
        emit HoneyLocker.Unstaked(address(GAUGE), address(LP_TOKEN), amountToDeposit);
        locker.unstake(address(GAUGE), amountToDeposit);

        assertEq(LP_TOKEN.balanceOf(THJ), 0);
        assertEq(LP_TOKEN.balanceOf(address(locker)), amountToDeposit);
        assertEq(LP_TOKEN.balanceOf(address(lockerAdapter)), 0);
    }

    /*
        This test claiming rewards, which should be only BGT.
        It checks ;
        - proper events
        - proper balances
    */
    function test_claimRewards(uint256 amountToDeposit, uint128 expiration) external prankAsTHJ {
        amountToDeposit = StdUtils.bound(amountToDeposit, 1, type(uint32).max);

        StdCheats.deal(address(LP_TOKEN), THJ, amountToDeposit);

        LP_TOKEN.approve(address(locker), amountToDeposit);
        locker.depositAndLock(address(LP_TOKEN), amountToDeposit, expiration);
        locker.stake(address(GAUGE), amountToDeposit);

        vm.warp(block.timestamp + 10000);

        uint256 earned = IBGTStationGauge(GAUGE).earned(address(lockerAdapter));

        vm.expectEmit(true, true, true, true, address(locker));
        emit BVA.Claimed(address(locker), address(GAUGE), Constants.BGT, earned);
        locker.claimBGT(address(GAUGE));

        assertEq(BGT.unboostedBalanceOf(address(locker)), earned);
        assertEq(BGT.unboostedBalanceOf(address(lockerAdapter)), 0);
        assertEq(BGT.unboostedBalanceOf(THJ), 0);


    }
}

