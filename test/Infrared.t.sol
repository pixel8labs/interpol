// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "solady/tokens/ERC20.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console2} from "forge-std/console2.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";

import {BaseTest} from "./Base.t.sol";
import {HoneyLocker} from "../src/HoneyLocker.sol";
import {InfraredAdapter, IInfraredVault} from "../src/adapters/InfraredAdapter.sol";
import {BaseVaultAdapter as BVA} from "../src/adapters/BaseVaultAdapter.sol";
import {IBGT} from "../src/utils/IBGT.sol";

contract BGTStationTest is BaseTest {    
    /*###############################################################
                            STATE VARIABLES
    ###############################################################*/
    InfraredAdapter     public adapter;
    BVA                 public lockerAdapter;   // adapter for BGT Station used by locker

    // Infrared HONEY-WBERA gauge
    address     public constant GAUGE       = 0xA8C3A7fe0cD52d7A57A5Df7A6e3c71fB1ed428b1;
    // BEX HONEY-WBERA LP token
    ERC20       public constant LP_TOKEN    = ERC20(0x3aD1699779eF2c5a4600e649484402DFBd3c503C);

    address     public constant IRED        = 0x0000000000000000000000000000000000000000;
    /*###############################################################
                            SETUP
    ###############################################################*/
    function setUp() public override {
        vm.createSelectFork(RPC_URL_ALT, uint256(5498655));

        super.setUp();

        // Deploy adapter implementation that will be cloned
        address adapterLogic = address(new InfraredAdapter());
        address adapterBeacon = address(new UpgradeableBeacon(adapterLogic, THJ));

        vm.startPrank(THJ);

        queen.setAdapterBeaconForProtocol("INFRARED", address(adapterBeacon));
        queen.setVaultForProtocol("INFRARED", GAUGE, address(LP_TOKEN), true);
        locker.registerAdapter("INFRARED");

        lockerAdapter = BVA(locker.adapterOfProtocol("INFRARED"));

        vm.stopPrank();

        vm.label(address(lockerAdapter), "InfraredAdapter");
        vm.label(address(GAUGE), "Infrared HONEY-WBERA Gauge");
        vm.label(address(LP_TOKEN), "BEX HONEY-WBERA LP Token");
    }

    /*###############################################################
                            TESTS
    ###############################################################*/

    function test_stake(uint256 amountToDeposit, bool _useOperator) external prankAsTHJ(_useOperator) {
        amountToDeposit = StdUtils.bound(amountToDeposit, 1, type(uint64).max);

        StdCheats.deal(address(LP_TOKEN), address(locker), amountToDeposit);

        vm.expectEmit(true, false, false, true, address(GAUGE));
        emit IInfraredVault.Staked(address(lockerAdapter), amountToDeposit);
        vm.expectEmit(true, true, false, true, address(locker));
        emit HoneyLocker.HoneyLocker__Staked(address(GAUGE), address(LP_TOKEN), amountToDeposit);
        locker.stake(address(GAUGE), amountToDeposit);

        assertEq(LP_TOKEN.balanceOf(THJ), 0);
        assertEq(LP_TOKEN.balanceOf(address(locker)), 0);
        assertEq(LP_TOKEN.balanceOf(address(lockerAdapter)), 0);
    }

    function test_unstake(uint256 amountToDeposit, bool _useOperator) external prankAsTHJ(_useOperator) {
        amountToDeposit = StdUtils.bound(amountToDeposit, 1, type(uint32).max);

        StdCheats.deal(address(LP_TOKEN), address(locker), amountToDeposit);

        locker.stake(address(GAUGE), amountToDeposit);

        vm.expectEmit(true, false, false, true, address(GAUGE));
        emit IInfraredVault.Withdrawn(address(lockerAdapter), amountToDeposit);
        vm.expectEmit(true, true, false, true, address(locker));
        emit HoneyLocker.HoneyLocker__Unstaked(address(GAUGE), address(LP_TOKEN), amountToDeposit);
        locker.unstake(address(GAUGE), amountToDeposit);

        assertEq(LP_TOKEN.balanceOf(THJ), 0);
        assertEq(LP_TOKEN.balanceOf(address(locker)), amountToDeposit);
        assertEq(LP_TOKEN.balanceOf(address(lockerAdapter)), 0);
    }

    function test_rewards(uint256 amountToDeposit, bool _useOperator) external prankAsTHJ(_useOperator) {
        amountToDeposit = StdUtils.bound(amountToDeposit, 1, type(uint32).max);

        StdCheats.deal(address(LP_TOKEN), address(locker), amountToDeposit);

        locker.stake(address(GAUGE), amountToDeposit);

        // pass time
        vm.warp(block.timestamp + 10 days);

        // get reward tokens and earned
        (address[] memory rewardTokens, uint256[] memory earned) = lockerAdapter.earned(address(GAUGE));

        for (uint256 i; i < rewardTokens.length; i++) {
            // special case if iRed token because as of now, 13th December, it's not transferable
            if (rewardTokens[i] == IRED) {
                earned[i] = 0;
            }
            vm.expectEmit(true, true, false, true, address(locker));
            emit HoneyLocker.HoneyLocker__Claimed(address(GAUGE), rewardTokens[i], earned[i]);
        }

        locker.claim(address(GAUGE));

        for (uint256 i; i < rewardTokens.length; i++) {
            assertEq(ERC20(rewardTokens[i]).balanceOf(address(locker)), earned[i]);
        }
    }
}

