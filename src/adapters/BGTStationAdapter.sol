// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC721} from "solady/tokens/ERC721.sol";
import {ERC20} from "solady/tokens/ERC20.sol";

import {BaseVaultAdapter} from "./BaseVaultAdapter.sol";

interface IBGTStationGauge {
    event Staked(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward(address account) external returns (uint256);
    function setOperator(address operator) external;
    function earned(address account) external view returns (uint256);
    function STAKE_TOKEN() external view returns (address);
    function REWARD_TOKEN() external view returns (address);
}

contract BGTStationAdapter is BaseVaultAdapter {
    /*###############################################################
                            STORAGE
    ###############################################################*/
    /*###############################################################
                            INITIALIZATION
    ###############################################################*/
    function initialize(
        address _locker,
        address _honeyQueen
    ) external override {
        if (locker != address(0)) revert BaseVaultAdapter__AlreadyInitialized();
        locker = _locker;
        honeyQueen = _honeyQueen;
    }
    /*###############################################################
                            EXTERNAL
    ###############################################################*/
    function stake(address vault, uint256 amount) external override onlyLocker isVaultValid(vault) {
        IBGTStationGauge bgtStationGauge = IBGTStationGauge(vault);
        address token = bgtStationGauge.STAKE_TOKEN();

        ERC721(token).transferFrom(msg.sender, address(this), amount);
        ERC721(token).approve(address(bgtStationGauge), amount);
        bgtStationGauge.stake(amount);
    }

    function unstake(address vault, uint256 amount) external override onlyLocker isVaultValid(vault) {
        IBGTStationGauge bgtStationGauge = IBGTStationGauge(vault);
        address token = bgtStationGauge.STAKE_TOKEN();

        bgtStationGauge.withdraw(amount);
        ERC20(token).transfer(locker, amount);
    }

    /*
        Claiming is disabled because we are exclusively relying on the locker to claim rewards.
        This is possible because we have set the locker as the operator of the gauge for this adapter.
    */
    function claim(address vault) external override onlyLocker isVaultValid(vault) returns (address[] memory, uint256[] memory) {
        revert BaseVaultAdapter__NotImplemented();
    }

    function wildcard(address vault, uint8 func, bytes calldata args) external override onlyLocker isVaultValid(vault) {
        IBGTStationGauge bgtStationGauge = IBGTStationGauge(vault);
        if (func == 0) {
            bgtStationGauge.setOperator(locker);
        }
    }
    /*###############################################################
                            VIEW
    ###############################################################*/
    function stakingToken(address vault) external view override returns (address) {
        return IBGTStationGauge(vault).STAKE_TOKEN();
    }

    function earned(address vault) external view override returns (address[] memory, uint256[] memory) {
        address rewardToken = IBGTStationGauge(vault).REWARD_TOKEN();
        uint256 earned = IBGTStationGauge(vault).earned(locker);

        address[] memory rewardTokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        
        rewardTokens[0] = rewardToken;
        amounts[0] = earned;
        return (rewardTokens, amounts);
    }
}

